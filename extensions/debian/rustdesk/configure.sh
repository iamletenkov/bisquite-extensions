#!/usr/bin/env bash
# Render the server settings of the `rustdesk` domain into RustDesk2.toml of
# root (the service) and of every user with UID >= 1000. Every boot
# (configure-rustdesk.service, before rustdesk.service) and on demand
# (`bisquite-conf set rustdesk …` → hook → restart of that unit).
#
#   key                     RustDesk2.toml [options]
#   RUSTDESK_ID_SERVER      custom-rendezvous-server
#   RUSTDESK_RELAY_SERVER   relay-server
#   RUSTDESK_API_SERVER     api-server
#   RUSTDESK_KEY            key
#
# An empty key is not touched, unless this script wrote it before (state in
# /var/lib/bisquite/rustdesk/managed): then it is removed, and RustDesk falls
# back to its public default. All keys empty and never set — no file is
# created or changed. If a file changed and rustdesk.service runs, it is
# restarted (non-blocking: this script runs inside a unit ordered before it).
#
# ID, keys and password of the device live in RustDesk.toml — never touched here.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/bisquite-conf"

ROOT="${BISQUITE_CONF_ROOT:-}"
STATE_DIR="$ROOT/var/lib/bisquite/rustdesk"
STATE="$STATE_DIR/managed"
RENDER="$SCRIPT_DIR/render-toml.sh"

log(){ >&2 echo "rustdesk: $*"; }

conf_load rustdesk || exit 1

declare -A want=(
    [custom-rendezvous-server]="$RUSTDESK_ID_SERVER"
    [relay-server]="$RUSTDESK_RELAY_SERVER"
    [api-server]="$RUSTDESK_API_SERVER"
    [key]="$RUSTDESK_KEY"
)
declare -A managed=()
if [[ -f "$STATE" ]]; then
    while IFS= read -r n; do [[ -n "$n" ]] && managed[$n]=1; done < "$STATE"
fi

args=()
for n in custom-rendezvous-server relay-server api-server key; do
    if [[ -n "${want[$n]}" ]]; then
        args+=("$n=${want[$n]}")
    elif [[ -n "${managed[$n]:-}" ]]; then
        args+=("-$n")
    fi
done
if (( ${#args[@]} == 0 )); then
    log "настройки пусты — RustDesk2.toml не трогаю (публичные серверы RustDesk)"
    exit 0
fi

# Targets: root for the service, then every regular account with a home.
# UID 1000..65533, as lib/get_cloud_user.sh (65534 is nobody).
changed=0 rc=0
render_for(){
    local user="$1" home="$2" out
    local file="$home/.config/rustdesk/RustDesk2.toml"
    if [[ "$user" == root ]]; then
        out="$(bash "$RENDER" "$ROOT$file" "${args[@]}")" || return 1
    else
        # As the owner: a symlink in the home must not lead root anywhere.
        out="$(runuser -u "$user" -- bash "$RENDER" "$file" "${args[@]}")" || return 1
    fi
    if [[ "$out" == changed ]]; then
        log "$file ($user) обновлён"
        changed=1
    fi
}

# Accounts where RustDesk has not run yet (no RustDesk.toml): see the
# follow-up at the end.
first_run=0
render_for root /root || { log "/root/.config/rustdesk/RustDesk2.toml не записан"; rc=1; }
[[ -e "$ROOT/root/.config/rustdesk/RustDesk.toml" ]] || first_run=1
while IFS=: read -r name _ uid _ _ home _; do
    (( uid >= 1000 && uid < 65534 )) || continue
    [[ -n "$home" && -d "$ROOT$home" && "$home" != / ]] || continue
    render_for "$name" "$home" || { log "$home/.config/rustdesk/RustDesk2.toml ($name) не записан"; rc=1; }
    [[ -e "$ROOT$home/.config/rustdesk/RustDesk.toml" ]] || first_run=1
done < <(getent passwd)

install -d -m 0755 "$STATE_DIR"
for n in custom-rendezvous-server relay-server api-server key; do
    if [[ -n "${want[$n]}" ]]; then echo "$n"; fi
done > "$STATE.tmp"
mv -f "$STATE.tmp" "$STATE"

if (( changed )); then
    if systemctl is-active --quiet rustdesk.service 2>/dev/null; then
        systemctl --no-block restart rustdesk.service && log "rustdesk.service перезапускается с новыми настройками"
    else
        log "rustdesk.service не запущен — прочтёт настройки при старте"
    fi
else
    log "RustDesk2.toml уже соответствуют /etc/bisquite/rustdesk/config"
fi

# The first start of RustDesk on a machine (the service for root, the session
# process for a user) may write RustDesk2.toml back from its own state AFTER
# this render — seen on the first boot of a fresh image: the ID server gone
# from root's file, all four options from the user's, until the next boot.
# While some account has not run RustDesk yet, or this run had to restore
# something, check again a minute later — at most 10 times per chain. The
# render is idempotent; a restored value restarts the service, and RustDesk
# that already has its files keeps them.
step="${BISQUITE_RUSTDESK_FOLLOWUP:-0}"
[[ "$step" =~ ^[0-9]+$ ]] || step=0
if [[ -z "$ROOT" && -d /run/systemd/system ]] && (( (first_run || changed) && step < 10 )) \
    && command -v systemd-run >/dev/null 2>&1; then
    next=$((step + 1))
    systemd-run --quiet --no-block --on-active=60 \
        --unit="configure-rustdesk-followup-$next-$$" \
        --setenv=BISQUITE_RUSTDESK_FOLLOWUP="$next" \
        /bin/bash "$SCRIPT_DIR/configure.sh" >/dev/null 2>&1 \
        && log "повторная сверка через минуту (${next}/10): RustDesk ещё не запускался у всех или значения пришлось вернуть"
fi
exit "$rc"
