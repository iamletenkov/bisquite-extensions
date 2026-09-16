#!/usr/bin/env bash
# Declaration for teleport-agent: /etc/bisquite/teleport/apps.d/code-server.conf
# from the current port. Only NAME and URI — who may open it is decided by the
# operator's env label, not here. Harmless without teleport-agent.
# configure.sh always serves TLS (mkcert), hence https; loopback works
# whatever CODE_SERVER_BIND says. Called by install.sh and configure.sh.
# ICON=laptop: a laptop with code on its screen, the closest the proxy's
# built-in icon set gets to a code editor. `mcpVscode` carries the real brand
# but is a "VS Code | tsh" badge from the MCP dialog, not a logo.
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/bisquite-conf"
port="$(conf_get code-server CODE_SERVER_PORT)"
decl="${BISQUITE_CONF_ROOT:-}/etc/bisquite/teleport/apps.d/code-server.conf"
install -d -m 0755 "$(dirname "$decl")"
install -m 0644 /dev/null "$decl"
printf 'NAME=code-server\nURI=https://127.0.0.1:%s\nICON=laptop\n' "$port" > "$decl"
>&2 echo "code-server: объявлен для Teleport: apps.d/code-server.conf (https://127.0.0.1:${port})"
