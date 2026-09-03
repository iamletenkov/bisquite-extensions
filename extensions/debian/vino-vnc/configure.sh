#!/usr/bin/env bash
# Первая загрузка: применить настройки vino пользователю, которого создал
# cloud-init, и включить его автозапуск.
#
# ПОЧЕМУ ЭТО НЕЛЬЗЯ БЫЛО СДЕЛАТЬ НА СБОРКЕ. `gsettings` пишет в dconf
# конкретного пользователя (~/.config/dconf/user), а автозапуск — в его
# ~/.config/autostart. Имя пользователя приходит из seed cloud-init и
# известно только здесь.
#
# ПОЧЕМУ АВТОЗАПУСК .desktop, А НЕ `systemctl --user enable`. Юнит у пакета
# есть — /usr/lib/systemd/user/vino-server.service, — но у него НЕТ секции
# [Install] (проверено на пакетах vino 3.22.0-5ubuntu2.2 из focal и
# 3.22.0-6ubuntu5 из noble, 2026-09-03), поэтому `systemctl --user enable`
# отвечает «no installation config» и ничего не включает. Юнит рассчитан на
# активацию по D-Bus (Type=dbus, BusName=org.gnome.Vino), то есть на запуск
# по требованию, а не на автостарт.
#
# ПОЧЕМУ ФАЙЛ АВТОЗАПУСКА КОПИРУЕТСЯ, А НЕ ПИШЕТСЯ. Путь к бинарю зависит от
# выпуска: focal — Exec=/usr/lib/vino/vino-server, noble — /usr/libexec/…
# (в noble /usr/lib/vino/vino-server остался симлинком, в focal /usr/libexec
# нет вовсе). Собственный .desktop с прибитым путём — это ровно тот класс
# дефекта, который уже был у x11vnc с прибитым путём к X authority: он
# «работает» до первой смены выпуска, а ломается молча.
#
# Штатного автозапуска у пакета нет: файл лежит в /usr/share/applications
# (с NoDisplay=true), а не в /etc/xdg/autostart. Поэтому положить его копию
# в ~/.config/autostart — не костыль, а единственный способ поднять vino
# на безголовой плате.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} vino-vnc: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} vino-vnc: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} vino-vnc: $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE=/etc/default/bisquite-vino
DESKTOP_SRC=/usr/share/applications/vino-server.desktop

# Умолчания те же, что в install.sh. Файла может не быть, если расширение
# подключили не целиком, — тогда работаем на умолчаниях, а не падаем.
VINO_PORT=5900
VINO_LISTEN=localhost
VINO_ENCRYPTION=false
VINO_PASSWORD_FILE=""
if [[ -f "$ENV_FILE" ]]; then
    # shellcheck source=/dev/null
    source "$ENV_FILE"
else
    log_warn "нет $ENV_FILE — беру умолчания"
fi

check_prereqs(){
    local missing=()
    command -v gsettings        >/dev/null 2>&1 || missing+=("gsettings (пакет libglib2.0-bin)")
    command -v dbus-run-session >/dev/null 2>&1 || missing+=("dbus-run-session (пакет dbus)")
    command -v runuser          >/dev/null 2>&1 || missing+=("runuser (пакет util-linux)")
    if (( ${#missing[@]} )); then
        log_error "в системе нет: ${missing[*]}"
        exit 1
    fi
    if [[ ! -x "$SCRIPT_DIR/get_cloud_user.sh" ]]; then
        log_error "нет $SCRIPT_DIR/get_cloud_user.sh или он не исполняемый"
        exit 1
    fi
    if [[ ! -f "$DESKTOP_SRC" ]]; then
        log_error "нет $DESKTOP_SRC — пакет vino не установлен"
        exit 1
    fi
}

# Те же 40 попыток по 3 секунды, что у соседей: гонка с cloud-init реальна.
resolve_user(){
    local user attempts=0 max_attempts=40
    while true; do
        if user="$("$SCRIPT_DIR/get_cloud_user.sh" 2>/dev/null || true)" && [[ -n "$user" ]]; then
            if id "$user" >/dev/null 2>&1; then
                echo "$user"
                return 0
            fi
        fi
        attempts=$(( attempts + 1 ))
        if (( attempts >= max_attempts )); then
            log_error "не дождался пользователя cloud-init за ${max_attempts} попыток"
            exit 1
        fi
        log_info "жду пользователя cloud-init (попытка ${attempts}/${max_attempts})"
        sleep 3
    done
}

# gsettings от имени пользователя и БЕЗ его сессии.
#
# dconf пишет через свою службу на шине сеанса, а сеанса на этом этапе
# ещё нет (юнит стоит до дисплей-менеджера). `dbus-run-session` поднимает
# временную шину на время одной команды — записи всё равно уходят
# в ~/.config/dconf/user, то есть туда, откуда их прочтёт будущая сессия.
#
# HOME задаётся ЯВНО: `runuser` без `-l` окружение не переопределяет, и с
# HOME=/root настройки уехали бы в dconf рута — молча и мимо цели.
gset(){
    local key="$1" value="$2" shown="${3:-$2}"
    if runuser -u "$CLOUD_USER" -- \
        env HOME="$USER_HOME" dbus-run-session -- \
        gsettings set org.gnome.Vino "$key" "$value"; then
        log_info "org.gnome.Vino $key = $shown"
    else
        log_error "не удалось выставить org.gnome.Vino $key"
        exit 1
    fi
}

apply_settings(){
    # Подтверждение подключения человеком за монитором. На безголовой плате
    # подтверждать некому, и включённый ключ означает, что не подключится
    # никто и никогда, — при этом сервер слушает порт и выглядит рабочим.
    gset prompt-enabled false

    gset require-encryption "$VINO_ENCRYPTION"

    if [[ -n "$VINO_PASSWORD_FILE" && -r "$VINO_PASSWORD_FILE" ]]; then
        gset authentication-methods "['vnc']"
        # Значение в журнал не печатаем: это пароль, пусть и в base64.
        gset vnc-password "'$(cat "$VINO_PASSWORD_FILE")'" "(скрыто)"
    else
        gset authentication-methods "['none']"
        log_warn "пароль не задан: аутентификации не будет вовсе"
    fi

    # Куда слушать. Пустая строка = все интерфейсы (описание ключа
    # network-interface: «If not set, the server will listen on all network
    # interfaces»), 'lo' = только петля.
    if [[ "$VINO_LISTEN" == "localhost" ]]; then
        gset network-interface "'lo'"
    else
        gset network-interface "''"
        log_warn "слушаю ВСЕ интерфейсы (VINO_LISTEN=${VINO_LISTEN})"
        [[ -n "$VINO_PASSWORD_FILE" ]] || \
            log_warn "и без пароля — рабочий стол получит кто угодно в этой сети"
    fi

    # Порт. 5900 — умолчание самого vino, и включать ради него
    # use-alternative-port незачем: ключ существует именно для «другого» порта.
    if (( VINO_PORT == 5900 )); then
        gset use-alternative-port false
    else
        gset alternative-port "uint16 ${VINO_PORT}"
        gset use-alternative-port true
    fi
}

enable_autostart(){
    local autostart_dir="$USER_HOME/.config/autostart"
    local target="$autostart_dir/vino-server.desktop"
    # Основная группа берётся у самого пользователя, а не предполагается
    # одноимённой. Одноимённая она у useradd с USERGROUPS_ENAB=yes, то есть
    # обычно, — но cloud-init умеет `primary_group: users`, и тогда
    # `-g "$CLOUD_USER"` отказал бы «invalid group» уже на плате.
    local group
    group="$(id -gn "$CLOUD_USER")"

    install -d -o "$CLOUD_USER" -g "$group" -m 0755 "$USER_HOME/.config"
    install -d -o "$CLOUD_USER" -g "$group" -m 0755 "$autostart_dir"

    # Копия штатного файла плюс ключ, которым GNOME/XFCE/LXDE различают
    # включённый автозапуск. Именно копия — путь к бинарю зависит от выпуска.
    {
        cat "$DESKTOP_SRC"
        echo "X-GNOME-Autostart-enabled=true"
    } > "$target"
    chown "$CLOUD_USER:$group" "$target"
    chmod 0644 "$target"
    log_info "автозапуск: $target"
}

main(){
    check_prereqs

    CLOUD_USER="$(resolve_user)"
    USER_HOME="$(getent passwd "$CLOUD_USER" | cut -d: -f6)"
    if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
        log_error "у пользователя '$CLOUD_USER' нет домашнего каталога ($USER_HOME)"
        exit 1
    fi
    log_info "пользователь cloud-init: $CLOUD_USER ($USER_HOME)"

    apply_settings
    enable_autostart

    if [[ "$VINO_LISTEN" == "localhost" ]]; then
        log_info "vino поднимется вместе с сессией на 127.0.0.1:${VINO_PORT}"
        log_info "доступ: ssh -L ${VINO_PORT}:localhost:${VINO_PORT} ${CLOUD_USER}@<адрес>"
    else
        log_info "vino поднимется вместе с сессией на 0.0.0.0:${VINO_PORT}"
    fi
    log_info "готово"
}

main "$@"
