#!/usr/bin/env bash
# Declaration for teleport-agent: /etc/bisquite/teleport/apps.d/selkies.conf
# from the current settings. Only NAME and URI on the loopback — who may open
# the app is decided by the operator's env label, not here. Harmless without
# teleport-agent. Called by install.sh, configure.sh (every boot) and the
# apply hook, so a changed port reaches the declaration either way.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/bisquite-conf"
conf_load selkies

decl="${BISQUITE_CONF_ROOT:-}/etc/bisquite/teleport/apps.d/selkies.conf"
scheme=http
[[ "$SELKIES_ENABLE_HTTPS" == true ]] && scheme=https
# 127.0.0.1 works with SELKIES_ADDR=0.0.0.0 too; an address that does not
# include the loopback has nothing to declare.
case "$SELKIES_ADDR" in
    127.0.0.1|localhost|0.0.0.0|"127.0.0.1,::1"|"")
        install -d -m 0755 "$(dirname "$decl")"
        install -m 0644 /dev/null "$decl"
        printf 'NAME=selkies\nURI=%s://127.0.0.1:%s\n' "$scheme" "$SELKIES_PORT" > "$decl"
        >&2 echo "selkies: объявлен для Teleport: apps.d/selkies.conf (${scheme}://127.0.0.1:${SELKIES_PORT})"
        ;;
    *) rm -f "$decl" ;;
esac
