#!/usr/bin/env bash
# System locale and keyboard layouts: system, console, Xorg/GDM and GNOME
# input-sources defaults. The work itself is apply.sh — the same script the
# knobs.apply hook runs on a working machine.
#
# Parameters (environment, from VMFILE) — the `locale` domain, schema in knobs:
#   LOCALE             en_US.UTF-8
#   KEYBOARD_LAYOUTS   us,ru
#   KEYBOARD_TOGGLE    (empty)      e.g. grp:alt_shift_toggle
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} locale: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} locale: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} locale: $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for f in knobs knobs.apply apply.sh lib/bisquite-conf; do
    [[ -f "$SCRIPT_DIR/$f" ]] || { log_error "рядом нет $f — сборка не доставила каталог расширения целиком"; exit 1; }
done
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/bisquite-conf"

apt_retry(){
    local i
    for i in 1 2 3; do
        "$@" && return 0
        log_warn "попытка $i: $* — не удалась, повтор через 10 с"
        sleep 10
    done
    return 1
}

export DEBIAN_FRONTEND=noninteractive
apt_retry apt-get update -q || { log_error "apt-get update не прошёл"; exit 1; }
# xkb-data — /usr/share/X11/xkb/symbols (проверка имён раскладок); console-setup —
# раскладка консоли из /etc/default/keyboard.
apt_retry apt-get install -y -q --no-install-recommends \
    locales keyboard-configuration console-setup xkb-data \
    || { log_error "пакеты локали не установились"; exit 1; }

conf_init locale "$SCRIPT_DIR/knobs" --env || { log_error "/etc/bisquite/locale/config не записан"; exit 1; }
"$SCRIPT_DIR/apply.sh" || { log_error "локаль и раскладки не применены"; exit 1; }
log_info "готово; на устройстве: sudo bisquite-conf set locale KEYBOARD_LAYOUTS=… (bisquite-conf show locale)"
