#!/usr/bin/env bash
# Declaration for teleport-agent: /etc/bisquite/teleport/apps.d/code-server.conf
# from the current port. Only NAME and URI — who may open it is decided by the
# operator's env label, not here. Harmless without teleport-agent.
# configure.sh always serves TLS (mkcert), hence https; loopback works
# whatever CODE_SERVER_BIND says. Called by install.sh and configure.sh.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/bisquite-conf"
port="$(conf_get code-server CODE_SERVER_PORT)"
decl="${BISQUITE_CONF_ROOT:-}/etc/bisquite/teleport/apps.d/code-server.conf"
install -d -m 0755 "$(dirname "$decl")"
install -m 0644 /dev/null "$decl"
printf 'NAME=code-server\nURI=https://127.0.0.1:%s\n' "$port" > "$decl"
>&2 echo "code-server: объявлен для Teleport: apps.d/code-server.conf (https://127.0.0.1:${port})"
