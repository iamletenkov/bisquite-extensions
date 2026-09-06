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

changed=0
if [[ -f /etc/gdm3/custom.conf ]]; then
    sed -i -e "s/^\s*AutomaticLoginEnable\s*=.*/AutomaticLoginEnable=True/" \
           -e "s/^\s*AutomaticLogin\s*=.*/AutomaticLogin=${user}/" \
           /etc/gdm3/custom.conf
    grep -q "^AutomaticLogin=${user}$" /etc/gdm3/custom.conf || \
        printf 'AutomaticLogin=%s\n' "$user" >> /etc/gdm3/custom.conf
    changed=1
    log_info "gdm3: автологин включён для $user"
fi
for conf in /etc/lightdm/lightdm.conf /etc/lightdm/lightdm.conf.d/*.conf; do
    [[ -f "$conf" ]] || continue
    sed -i "s/^\s*autologin-user\s*=.*/autologin-user=${user}/" "$conf"
    changed=1
    log_info "lightdm: автологин включён для $user ($conf)"
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
