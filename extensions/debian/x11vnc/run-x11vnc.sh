#!/usr/bin/env bash
# Start x11vnc for a session, resolving the X authority at runtime.
#
# WHY A WRAPPER AND NOT A PATH IN THE UNIT. The unit used to hardcode
#
#     -auth /var/run/lightdm/%i/:0
#
# and that path does not exist under ANY display manager. It is a splice of
# two different LightDM schemes (measured 2026-09-03 against lightdm sources,
# 1.2 through 1.32 — unchanged throughout):
#
#   * src/x-server-local.c, write_authority_file() → <run-dir>/root/:0.
#     That is the X SERVER's authority: directory `root`, owner root, 0600.
#     A `User=%i` unit cannot read it. This is where the `:0` filename came
#     from.
#   * src/session.c → the USER's authority is ~/.Xauthority by default, and
#     <run-dir>/<user>/xauthority only when user-authority-in-system-dir=true.
#     Debian ships that setting commented out, i.e. false.
#
# So the old unit was broken for xfce4 and lxde too, not just for GNOME —
# and it failed silently: XOpenDisplay fails, Restart=on-failure fires every
# five seconds forever, nothing ever listens on the port.
#
# Under GDM the file is somewhere else again — /run/user/<uid>/gdm/Xauthority
# (gdm/daemon/gdm-x-session.c, same in gdm 43/46/48).
#
# ЗАМЕРЕНО НА ЖИВОЙ ВМ (debian 12, 2026-09-03), оба дисплей-менеджера подряд
# на одной машине — сначала GDM, потом LightDM после переключения симлинка
# display-manager.service:
#
#                        GDM                        LightDM
#   Xorg -auth           /run/user/1000/gdm/…       /var/run/lightdm/root/:0
#   authority юзера      то же                      /home/check/.Xauthority
#   /var/run/lightdm/<user>/:0   нет                НЕТ  ← старый путь юнита
#   выбор обёртки        кандидат 2                 кандидат 1
#   NRestarts            0                          0
#
# Каталог `root` под LightDM существует — это authority X-СЕРВЕРА, 0600 root.
# Каталога с именем пользователя нет ни под одним менеджером. Склейка
# подтверждена: юнит был сломан и под GNOME, и под Xfce.
#
# WHY NOT `-auth guess`. It looks like the answer, but its FINDDISPLAY script
# (extracted from the binary) globs only ~/.Xauthority, /tmp/.gdm*,
# /tmp/.Xauth*, /var/run/gdm*/auth-for-*/database and auth-cookie-*. The
# GDM >= 42 path is not in that list, and auth-for-* is the legacy layout that
# modern GDM does not use. `man x11vnc` also warns FINDDISPLAY can hang
# forever on xdpyinfo when a greeter holds the server — exactly the broken
# autologin case.
#
# Это тоже замерено, а не выведено. На той же ВМ под GDM:
#
#     $ sudo -u check x11vnc -findauth
#     xauth:  file /home/check/.Xauthority does not exist
#     XAUTHORITY=
#
# Пусто. `-auth guess` под GDM не находит ничего, то есть обёртка обязательна,
# а не сделана про запас.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} x11vnc: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} x11vnc: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} x11vnc: $*"; }

USERNAME="${1:?usage: run-x11vnc.sh <user>}"
UID_OF_USER="$(id -u "$USERNAME")"

# Параметры приходят из EnvironmentFile, который пишет install.sh из
# переменных окружения VMFILE. Умолчания те же, что были зашиты в юните,
# кроме прослушиваемого адреса — см. ниже.
PORT="${X11VNC_PORT:-5900}"
DISPLAY_NUM="${X11VNC_DISPLAY:-:0}"
PASSFILE="${X11VNC_PASSFILE:-}"
LISTEN="${X11VNC_LISTEN:-localhost}"

# Wayland: x11vnc обслуживает X11 и на Wayland-сессии бесполезен.
#
# Собственная защита x11vnc здесь НЕ сработает: она смотрит на
# $WAYLAND_DISPLAY, а в окружении системного юнита этой переменной нет.
# И проверять наличие сокета /tmp/.X11-unix/X0 тоже нельзя — под Wayland
# его создаёт mutter для Xwayland, он там есть. Спрашиваем тип сессии.
session_type() {
    local sid
    sid="$(loginctl list-sessions --no-legend 2>/dev/null \
        | awk -v u="$USERNAME" '$3 == u {print $1; exit}')" || true
    [[ -n "$sid" ]] || return 1
    loginctl show-session "$sid" -p Type --value 2>/dev/null || true
}

stype="$(session_type || true)"
if [[ "$stype" == "wayland" ]]; then
    log_error "сессия пользователя '$USERNAME' работает на Wayland, а x11vnc обслуживает X11"
    log_error "включите Xorg у дисплей-менеджера (расширение gnome пишет WaylandEnable=false)"
    exit 1
fi

# Кандидаты в порядке убывания надёжности. У каждого — источник, откуда
# известен путь, чтобы следующий читатель не гадал.
candidates=()
[[ -n "${XAUTHORITY:-}" ]] && candidates+=("$XAUTHORITY")
candidates+=(
    "$(getent passwd "$USERNAME" | cut -d: -f6)/.Xauthority"  # LightDM, session.c
    "/run/user/${UID_OF_USER}/gdm/Xauthority"                 # GDM >= 42, gdm-x-session.c
    "/run/lightdm/${USERNAME}/xauthority"                     # LightDM, user-authority-in-system-dir=true
)
# Xorg получает -auth от того, кто его запустил; если файл читается нашим
# пользователем, он подойдёт.
xorg_pid="$(pgrep -x Xorg | head -1 || true)"
if [[ -n "$xorg_pid" && -r "/proc/$xorg_pid/cmdline" ]]; then
    xorg_auth="$(tr '\0' '\n' < "/proc/$xorg_pid/cmdline" \
        | awk '/^-auth$/{getline; print; exit}' || true)"
    [[ -n "$xorg_auth" ]] && candidates+=("$xorg_auth")
fi
# Legacy-раскладка GDM — последней: на современных сборках её нет.
for legacy in /run/gdm3/auth-for-"$USERNAME"-*/database; do
    [[ -e "$legacy" ]] && candidates+=("$legacy")
done

AUTH=""
for candidate in "${candidates[@]}"; do
    [[ -r "$candidate" ]] || continue
    if env XAUTHORITY="$candidate" xdpyinfo -display "$DISPLAY_NUM" >/dev/null 2>&1; then
        AUTH="$candidate"
        break
    fi
done

if [[ -z "$AUTH" ]]; then
    # Громкий отказ вместо немого цикла рестарта. Перечисляем ВСЁ, что
    # проверили: без этого следующий читатель journal видит только
    # «XOpenDisplay failed» и не знает, где искать.
    log_error "не нашёл X authority для '$USERNAME' на дисплее $DISPLAY_NUM"
    log_error "проверены пути:"
    for candidate in "${candidates[@]}"; do
        log_error "  $candidate $( [[ -r "$candidate" ]] && echo '(есть, но xdpyinfo не прошёл)' || echo '(нет)' )"
    done
    exit 1
fi
log_info "authority: $AUTH"

args=(
    -display "$DISPLAY_NUM"
    -auth "$AUTH"
    -forever -loop -noxdamage -repeat -shared
    -rfbport "$PORT"
)

# Слушать только петлю — умолчание, и это СМЕНА поведения.
#
# Раньше сервер поднимался на всех интерфейсах без пароля, а compose-примеры
# ставят `firewall: false`. Позиция проекта на этот счёт записана в
# examples/build/ubuntu1804/README.md: только loopback, доступ через
# SSH-туннель. Расширение с ней расходилось.
if [[ "$LISTEN" == "localhost" ]]; then
    args+=(-localhost)
else
    log_warn "слушаю ВСЕ интерфейсы (X11VNC_LISTEN=$LISTEN)"
    [[ -z "$PASSFILE" ]] && log_warn "и БЕЗ ПАРОЛЯ — кто угодно в сети получит рабочий стол"
fi

if [[ -n "$PASSFILE" && -r "$PASSFILE" ]]; then
    args+=(-rfbauth "$PASSFILE")
    log_info "пароль из $PASSFILE"
else
    args+=(-nopw)
fi

exec /usr/bin/x11vnc "${args[@]}"
