#!/usr/bin/env bash
# Render /etc/modules-load.d/can.conf from CAN_MODULES_LOAD of the `can` domain.
#
# Called by install.sh (build) and by the knobs.apply hook (running machine).
# Prints "changed" on stdout when the file was written or removed, so the
# hook knows whether systemd-modules-load needs a rerun.
#
# BISQUITE_CONF_ROOT — a scratch root for the tests, as in lib/bisquite-conf.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/bisquite-conf"

ROOT="${BISQUITE_CONF_ROOT:-}"
TARGET="$ROOT/etc/modules-load.d/can.conf"

modules="$(conf_get can CAN_MODULES_LOAD)" || exit 1

if [[ -z "$modules" ]]; then
    if [[ -e "$TARGET" ]]; then
        rm -f "$TARGET"
        >&2 echo "can: CAN_MODULES_LOAD пуст — $TARGET удалён, модули CAN сами не грузятся"
        echo changed
    fi
    exit 0
fi

install -d -m 0755 "${TARGET%/*}"
tmp="$(mktemp "${TARGET%/*}/.can.conf.XXXXXX")"
trap 'rm -f "$tmp"' EXIT
{
    echo "# Положено расширением can из /etc/bisquite/can/config (CAN_MODULES_LOAD)."
    echo "# Править: sudo bisquite-conf set can CAN_MODULES_LOAD=\"can can_raw vcan\""
    for m in $modules; do echo "$m"; done
} > "$tmp"
chmod 0644 "$tmp"
if [[ -f "$TARGET" ]] && cmp -s "$tmp" "$TARGET"; then
    exit 0
fi
mv -f "$tmp" "$TARGET"
trap - EXIT
>&2 echo "can: $TARGET — $modules"
echo changed
