#!/usr/bin/env bash
# Configure GDM autologin from cloud-init user at boot (idempotent)

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info(){ echo -e "${GREEN}[INFO]${NC} $*" >&2; }
log_warn(){ echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error(){ echo -e "${RED}[ERROR]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
TEMPLATE="$SCRIPT_DIR/daemon.conf"

TARGET="/etc/gdm3/daemon.conf"

check_prereqs(){
  if ! command -v yq >/dev/null 2>&1; then
    log_error "yq is not installed"
    exit 1
  fi
  if [[ ! -x "$SCRIPT_DIR/get_cloud_user.sh" ]]; then
    log_error "get_cloud_user.sh not found or not executable at $SCRIPT_DIR/get_cloud_user.sh"
    exit 1
  fi
  if [[ ! -f "$TEMPLATE" ]]; then
    log_error "Template daemon.conf not found at $TEMPLATE"
    exit 1
  fi
}

resolve_user(){
  local user
  local attempts=0
  local max_attempts=40

  # Wait up to 120s for cloud user to appear to avoid racing cloud-init
  while true; do
    if user="$($SCRIPT_DIR/get_cloud_user.sh 2>/dev/null || true)" && [[ -n "$user" ]]; then
      if id "$user" >/dev/null 2>&1; then
        log_info "Found user from cloud-init: $user"
        echo "$user"
        return 0
      fi
    fi

    attempts=$((attempts+1))
    if (( attempts >= max_attempts )); then
      log_error "Timeout waiting for cloud-init user to be created"
      exit 1
    fi

    log_info "Waiting for cloud-init user (attempt $attempts/$max_attempts)..."
    sleep 3
  done
}


write_daemon_conf(){
  local cloud_user="$1"
  local tmp="/tmp/daemon.conf.gnome.$$"

  if [[ ! -f "$TEMPLATE" ]]; then
    log_error "Template not found: $TEMPLATE"
    exit 1
  fi

  # Copy template and substitute USER placeholder (using | as delimiter to avoid issues with /)
  sed "s|USER|${cloud_user}|g" "$TEMPLATE" > "$tmp"

  # Install to target location
  install -D -m 0644 "$tmp" "$TARGET"
  rm -f "$tmp"

  log_info "Created $TARGET with autologin for user '$cloud_user'"
}

restart_gdm(){
  systemctl try-restart gdm3.service || systemctl try-restart gdm.service || true
}

disable_power_saving(){
  local cloud_user="$1"
  if [[ -x "$SCRIPT_DIR/disable_powersave.sh" ]]; then
    log_info "Disabling power saving features for user '$cloud_user'"
    "$SCRIPT_DIR/disable_powersave.sh" "$cloud_user" || log_warn "Failed to disable power saving"
  else
    log_warn "disable_powersave.sh not found or not executable"
  fi
}

main(){
  check_prereqs
  local user
  user=$(resolve_user)

  log_info "Configuring GDM autologin for user '$user'"
  write_daemon_conf "$user"
  restart_gdm
  disable_power_saving "$user"
  log_info "GDM reloaded with autologin for '$user'"
}

main "$@"
