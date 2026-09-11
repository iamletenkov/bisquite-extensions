#!/usr/bin/env bash
# Первая загрузка: включить автологин для пользователя cloud-init.
#
# Вендорская учётка к этому моменту уже удалена — на сборке. Здесь
# остаётся одно: узнать имя нового пользователя, которого на сборке
# знать было неоткуда, и вернуть автологин.
set -euo pipefail
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} cloud-user-desktop: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} cloud-user-desktop: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} cloud-user-desktop: $*"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

user=""
if [[ -x "$HERE/get_cloud_user.sh" ]]; then
    user="$("$HERE/get_cloud_user.sh" 2>/dev/null || true)"
fi
if [[ -z "$user" ]]; then
    log_error "пользователь не определился — автологин остаётся выключенным"
    log_error "вход через приглашение менеджера входа или по ssh"
    exit 1
fi
if [[ ! -d "/home/${user}" ]]; then
    log_error "у '$user' нет домашнего каталога — автологин не включаю"
    exit 1
fi

# ГРУППЫ ДЛЯ РАБОЧЕГО СТОЛА: без `video` графический сеанс не поднимается.
#
# Замер 2026-09-06 на Jetson Nano. cloud-init заводит пользователя
# с группами из seed — у нас это `sudo`, — а устройства видеоядра
# принадлежат группе `video`:
#
#     crw-rw---- root video /dev/nvhost-ctrl
#     crw-rw---- root video /dev/nvhost-gpu
#     crw-rw---- root video /dev/nvmap
#
# X-сервер сеанса не может их открыть и умирает:
#
#     (EE) NVIDIA(GPU-0): Failed to initialize the NVIDIA graphics device!
#     gdm3: GdmDisplay: Session never registered, failing
#
# Менеджер возвращает приглашение, и его СОБСТВЕННЫЙ X поднимается
# прекрасно — потому что `gdm` в группе `video` состоит. Отсюда
# обманчивая картина: экран жив, а сеанса пользователя нет, и VNC,
# которому нужна сессия, молчит. Вендорская учётка в этих группах
# была, поэтому на исходном образе всё работало; ломается ровно тогда,
# когда её заменяют пользователем cloud-init.
#
# Набор по назначению, а не «на всякий случай»: video — видеоядро и X,
# audio с pulse — звук, input — устройства ввода, render — DRI,
# dialout и plugdev — типовые для рабочей станции. Несуществующие
# группы пропускаются: состав зависит от дистрибутива.
for grp in video render audio pulse input dialout plugdev; do
    getent group "$grp" >/dev/null 2>&1 || continue
    if id -nG "$user" | tr ' ' '\n' | grep -qx "$grp"; then
        continue
    fi
    if usermod -aG "$grp" "$user" 2>/dev/null; then
        log_info "'$user' добавлен в группу $grp"
    else
        log_warn "не удалось добавить '$user' в группу $grp"
    fi
done

# ЗАПИСЬ КЛЮЧА INI — НА МЕСТЕ, В СВОЮ СЕКЦИЮ И С ПРОВЕРКОЙ РЕЗУЛЬТАТА.
#
# Три дефекта, которые это заменяет, и все три — в одну сторону «молча
# не сделали»:
#
# 1. `sed -i 's/^\s*AutomaticLoginEnable\s*=.*/…/'` правит ключ ТОЛЬКО там,
#    где он уже есть. В gdm3 от Debian ключи поставляются закомментированными
#    (`#  AutomaticLoginEnable = true`), а `#` — не пробел, то есть для `sed`
#    ключа нет. Дописывался при этом один `AutomaticLogin=<user>`, и автологин
#    оставался выключенным.
# 2. Дописывать `>>` в конец файла нельзя: у gdm3 файл многосекционный
#    (`[daemon]`, `[security]`, `[xdmcp]`, `[chooser]`, `[debug]` — см.
#    `../gnome/daemon.conf`), и ключ, приписанный в конец, попадает в
#    `[debug]`, где GDM его не ищет. Отсюда аргумент `section`.
# 3. `changed=1` ставился по факту ВЫЗОВА `sed`, а не по факту записи:
#    у lightdm при отсутствующем `autologin-user` файл не менялся вовсе,
#    а в журнал уходило «автологин включён». Отказ не молчал, а врал.
#    Поэтому функция заканчивается проверкой результата и её код возврата
#    — единственное основание для `changed=1`.
#
# Значение пишется ровно так, как в шаблоне `../gnome/daemon.conf`
# (`AutomaticLoginEnable=true`, строчными): это единственное написание
# в дереве, про которое известно, что оно применяется на обоих замеренных
# дистрибутивах, и держать рядом второе незачем.
set_ini_key(){
    local file="$1" section="$2" key="$3" value="$4" tmp
    tmp="$(mktemp)" || return 1
    awk -v want="$section" -v key="$key" -v value="$value" '
        function emit() { print key "=" value; done = 1 }
        /^[[:space:]]*\[/ {
            # Ушли из нужной секции, а ключа в ней не было — дописываем
            # перед заголовком следующей, то есть внутрь нужной.
            if (cur == want && !done) emit()
            line = $0
            sub(/^[[:space:]]*\[/, "", line)
            sub(/\].*$/, "", line)
            cur = line
            print
            next
        }
        {
            # Закомментированный ключ — это тоже «ключа нет», и заменить его
            # целиком правильнее, чем оставить рядом с новым.
            if (cur == want && !done && $0 ~ "^[[:space:]]*#*[[:space:]]*" key "[[:space:]]*=") {
                emit()
                next
            }
            print
        }
        END {
            if (!done) {
                if (cur == want) emit()
                else { print ""; print "[" want "]"; emit() }
            }
        }
    ' "$file" > "$tmp" || { rm -f "$tmp"; return 1; }
    # Усечение на месте, а не `mv`: у файла остаются его владелец и права.
    cat "$tmp" > "$file" || { rm -f "$tmp"; return 1; }
    rm -f "$tmp"
    grep -qxF "${key}=${value}" "$file"
}

# lightdm переименовал `[SeatDefaults]` в `[Seat:*]`, старое имя понимает
# до сих пор, и вендорские drop-in'ы его несут. Дописать `[Seat:*]` в файл,
# настроенный через `[SeatDefaults]`, значило бы оставить в нём две секции
# с одним ключом и неочевидным порядком слияния — поэтому пишем в ту
# секцию, которая в файле уже есть.
lightdm_seat_section(){
    local file="$1"
    if grep -q '^[[:space:]]*\[SeatDefaults\]' "$file" \
       && ! grep -q '^[[:space:]]*\[Seat:\*\]' "$file"; then
        echo 'SeatDefaults'
    else
        echo 'Seat:*'
    fi
}

# КАКОЙ ФАЙЛ ЧИТАЕТ GDM, РЕШАЕТСЯ НА СБОРКЕ ПАКЕТА, и дистрибутивы
# расходятся. Замер 2026-09-03 распаковкой пакетов записан в
# `../gnome/configure.sh:18-38`: Debian 13 несёт `/etc/gdm3/daemon.conf`,
# Ubuntu 24.04 — `/etc/gdm3/custom.conf`. Здесь знали только про второй,
# то есть на Debian не правилось ничего и молчало об этом.
#
# В отличие от `gnome/configure.sh`, который выбирает ОДИН файл и пишет его
# целиком из шаблона, здесь правка идёт по ключам в уже существующих файлах,
# поэтому правим ВСЕ, какие нашлись: лишний файл GDM просто не прочитает
# (запись в него не ошибка и предупреждения не даёт), а промах по нужному
# стоит рабочего стола. Заодно это тот случай, про который пишет
# `install.sh`: вендорские сборки нередко несут конфиг и того менеджера,
# который не запущен.
gdm_confs=()
for conf in /etc/gdm3/daemon.conf /etc/gdm3/custom.conf; do
    [[ -f "$conf" ]] && gdm_confs+=("$conf")
done
if (( ${#gdm_confs[@]} == 0 )) \
   && { command -v gdm3 >/dev/null 2>&1 || command -v gdm >/dev/null 2>&1; }; then
    # GDM стоит, а ни одного знакомого файла нет — дистрибутив, которого мы
    # не замеряли. Заводим тот, что несёт Debian 13: без файла автологина
    # не будет вовсе, а лишний файл безвреден.
    log_warn "gdm3 есть, а ни daemon.conf, ни custom.conf нет — создаю daemon.conf"
    install -D -m 0644 /dev/null /etc/gdm3/daemon.conf
    printf '[daemon]\n' > /etc/gdm3/daemon.conf
    gdm_confs=(/etc/gdm3/daemon.conf)
fi

changed=0
for conf in "${gdm_confs[@]:-}"; do
    [[ -n "$conf" ]] || continue
    if set_ini_key "$conf" daemon AutomaticLoginEnable true \
       && set_ini_key "$conf" daemon AutomaticLogin "$user"; then
        changed=1
        log_info "gdm3: автологин включён для $user ($conf)"
    else
        log_error "gdm3: не удалось записать автологин в $conf"
        exit 1
    fi
done
for conf in /etc/lightdm/lightdm.conf /etc/lightdm/lightdm.conf.d/*.conf; do
    [[ -f "$conf" ]] || continue
    section="$(lightdm_seat_section "$conf")"
    if set_ini_key "$conf" "$section" autologin-user "$user"; then
        changed=1
        log_info "lightdm: автологин включён для $user ($conf, [$section])"
    else
        log_error "lightdm: не удалось записать autologin-user в $conf"
        exit 1
    fi
done
(( changed )) || { log_warn "менеджера входа не нашлось — автологин не потребовался"; exit 0; }

# ПЕРЕЗАПУСК МЕНЕДЖЕРА ВХОДА, иначе правка не применится до следующей
# загрузки.
#
# Порядок неустраним: менеджер поднимается по `graphical.target`, а имя
# пользователя cloud-init становится известно только после `cloud-final`,
# то есть позже. К моменту нашей правки на экране уже висит приглашение,
# и прочитанный при старте `custom.conf` его не касается.
#
# Замер 2026-09-06 на Jetson Nano: файл правился верно
# (`AutomaticLogin=garage`), а сессии не появлялось; из-за этого не
# поднимался и VNC, которому нужна сессия пользователя.
#
# ЧУЖУЮ СЕССИЮ НЕ ТРОГАЕМ. Если графическая сессия уже есть, перезапуск
# её оборвёт — а это может быть работающий человек. Тогда правка просто
# ждёт следующей загрузки, и об этом говорится вслух.
# Класс сессии, а не только её тип. Приглашение менеджера входа — тоже
# графическая сессия (`Type=x11`), но принадлежит она пользователю `gdm`
# и имеет `Class=greeter`. Условие по одному типу считало её работой
# человека и отказывалось перезапускать менеджер (замер 2026-09-06).
graphical_user_session=0
for _sid in $(loginctl list-sessions --no-legend 2>/dev/null | awk '{print $1}'); do
    _class="$(loginctl show-session "$_sid" -p Class --value 2>/dev/null)"
    _type="$(loginctl show-session "$_sid" -p Type --value 2>/dev/null)"
    if [[ "$_class" == "user" ]] && [[ "$_type" == "x11" || "$_type" == "wayland" ]]; then
        graphical_user_session=1
        break
    fi
done
if (( graphical_user_session )); then
    log_warn "графическая сессия уже открыта — менеджер входа не перезапускаю"
    log_warn "автологин для '$user' применится со следующей загрузки"
    exit 0
fi

for dm in gdm3 lightdm; do
    if systemctl is-active "$dm" >/dev/null 2>&1; then
        log_info "перезапускаю $dm, чтобы автологин применился сейчас"
        systemctl restart "$dm" || log_warn "$dm не перезапустился"
        break
    fi
done
log_info "готово"
