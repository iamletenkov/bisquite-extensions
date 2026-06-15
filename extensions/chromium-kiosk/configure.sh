#!/usr/bin/env bash
# Configure chromium-kiosk from config.yaml before display manager starts (idempotent)

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info(){ echo -e "${GREEN}[INFO]${NC} $*" >&2; }
log_warn(){ echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error(){ echo -e "${RED}[ERROR]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_CONFIG="$SCRIPT_DIR/config.yaml"
TARGET_CONFIG="/etc/chromium-kiosk/config.yml"

check_prereqs(){
  if [[ ! -f "$SOURCE_CONFIG" ]]; then
    log_error "Source config not found at $SOURCE_CONFIG"
    exit 1
  fi
}

copy_config(){
  local target_dir
  target_dir="$(dirname "$TARGET_CONFIG")"

  # Ensure target directory exists
  if [[ ! -d "$target_dir" ]]; then
    log_info "Creating directory $target_dir"
    mkdir -p "$target_dir"
  fi

  # Copy configuration file
  log_info "Copying configuration from $SOURCE_CONFIG to $TARGET_CONFIG"
  install -m 0644 "$SOURCE_CONFIG" "$TARGET_CONFIG"

  log_info "Configuration file copied successfully"
}

main(){
  check_prereqs

  log_info "Configuring chromium-kiosk"
  copy_config
  log_info "chromium-kiosk configuration completed"
}

main "$@"
