#!/usr/bin/env bash
# Configure Docker access for cloud-init user at boot (idempotent)

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} $*"; }

resolve_user() {
  if command -v cloud-init >/dev/null 2>&1 && command -v yq >/dev/null 2>&1; then
    local ud
    if ! ud=$(cloud-init query userdata 2>/dev/null); then
      if [[ -f "/var/lib/cloud/instance/user-data.txt" ]]; then
        ud=$(cat /var/lib/cloud/instance/user-data.txt 2>/dev/null || echo "")
      else
        echo ""; return 0
      fi
    fi
    local u
    u=$(echo "$ud" | env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" TERM=dumb yq -r '.user // empty' 2>/dev/null || true)
    if [[ -z "$u" ]]; then
      u=$(echo "$ud" | env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" TERM=dumb yq -r '.users[0].name // empty' 2>/dev/null || true)
    fi
    echo "$u"; return 0
  fi
  echo ""; return 0
}

main(){
  if ! command -v docker >/dev/null 2>&1; then
    log_error "docker is not installed"
    exit 1
  fi
  local user
  user=$(resolve_user)
  if [[ -z "$user" ]]; then
    log_info "cloud-init user not found, nothing to configure"
    exit 0
  fi
  if ! id "$user" >/dev/null 2>&1; then
    log_warn "user '$user' not exists yet"
    exit 0
  fi
  if groups "$user" | grep -q '\bdocker\b'; then
    log_info "user '$user' already has docker group"
    exit 0
  fi
  usermod -aG docker "$user"
  log_info "user '$user' added to docker group"
}
main "$@"
