#!/usr/bin/env bash
# Configure x11vnc from cloud-init user at boot (idempotent)

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info(){ echo -e "${GREEN}[INFO]${NC} $*" >&2; }
log_warn(){ echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error(){ echo -e "${RED}[ERROR]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_YAML="$SCRIPT_DIR/config.yaml"

check_prereqs(){
  if ! command -v yq >/dev/null 2>&1; then
    log_error "yq is not installed"
    exit 1
  fi
  if [[ ! -x "$SCRIPT_DIR/get_cloud_user.sh" ]]; then
    log_error "get_cloud_user.sh not found or not executable at $SCRIPT_DIR/get_cloud_user.sh"
    exit 1
  fi
  if [[ ! -f "$CONFIG_YAML" ]]; then
    log_error "Config file not found at $CONFIG_YAML"
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

read_config(){
  local key="$1"
  local value
  value=$(yq -r ".$key // empty" "$CONFIG_YAML" 2>/dev/null || echo "")
  echo "$value"
}

configure_x11vnc_service(){
  local cloud_user="$1"

  # Read configuration from YAML
  local port display password
  port=$(read_config "PORT")
  display=$(read_config "DISPLAY")
  password=$(read_config "PASSWORD")

  # Set defaults if not specified
  port="${port:-5900}"
  display="${display:-:0}"

  log_info "Configuring x11vnc for user '$cloud_user' on display $display:$port"

  # Enable and start x11vnc service for user
  systemctl enable "x11vnc@${cloud_user}.service" || true
  systemctl restart "x11vnc@${cloud_user}.service" || true

  log_info "x11vnc service enabled and started for user '$cloud_user'"
}

main(){
  check_prereqs
  local user
  user=$(resolve_user)

  log_info "Configuring x11vnc for user '$user'"
  configure_x11vnc_service "$user"
  log_info "x11vnc configuration completed for '$user'"
}

main "$@"
