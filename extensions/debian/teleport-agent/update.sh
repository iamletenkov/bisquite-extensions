#!/usr/bin/env bash
# Update the Teleport agent on a running robot: the package
# bisquite-teleport-agent of the pinned version (agent.sh), checked by its
# sha256 and installed with dpkg. Run from the extension directory — the
# unpacked archive
#
#   git archive <ref> extensions/debian/teleport-agent | gzip -n
#
# or the installed /opt/bisquite/teleport-agent — as root:
#
#   sudo bash <dir>/update.sh                          from the GitHub release
#   sudo AGENT_MIRROR=https://<portal>/dist/teleport bash <dir>/update.sh
#   sudo AGENT_DEB=./bisquite-teleport-agent_3.0.0_all.deb bash <dir>/update.sh
#
# A robot of teleport-agent 2.x moves onto the package here (its postinst:
# unit copies out of /etc/systemd/system, enablement kept, the CLI link
# /usr/local/sbin/bisquite-teleport → /usr/sbin/bisquite-teleport). The
# Teleport binary, the registration in /var/lib/teleport, the settings and
# the labels token are not touched; the agent is not restarted.
#
# BISQUITE_TELEPORT_ROOT — a scratch root for the tests.
set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="${BISQUITE_TELEPORT_ROOT:-}"
log(){ >&2 echo "teleport-agent update: $*"; }
die(){ log "ОШИБКА: $*"; exit 1; }
[[ -f "$SCRIPT_DIR/agent.sh" ]] || die "рядом нет agent.sh"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/agent.sh"

[[ -n "$ROOT" || "$(id -u)" -eq 0 ]] || die "нужен root (sudo)"
BIN="$ROOT/usr/local/bin/teleport"
if ! "$BIN" version >/dev/null 2>&1; then
    log "ВНИМАНИЕ: $BIN не отвечает на version — пакет ставится, но join без Teleport не пройдёт"
fi
previous="$(dpkg-query -W -f='${Version}' bisquite-teleport-agent 2>/dev/null)" || previous=""
if [[ -z "$previous" && -L "$ROOT/usr/local/sbin/bisquite-teleport" ]]; then
    previous="расширение 2.x"
fi
log "было: ${previous:-нет}, ставлю пакет ${AGENT_VERSION:-$(agent_default_version)}"

WORK="$(mktemp -d /var/tmp/teleport-agent.XXXXXX)"
trap 'rm -r -f -- "$WORK"' EXIT
deb="$(agent_fetch "$WORK" "$(dpkg --print-architecture)")" || die "пакет агента не получен — ничего не изменено"
agent_install "$deb" || die "пакет агента не установлен"
log "готово: $(basename "$deb"). Автоприменение меток — printf '%s' <токен> | sudo bisquite-teleport labels-enable URL=https://<портал>/robot-api/v1/labels"
