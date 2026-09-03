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

check_prereqs(){
  if ! command -v yq >/dev/null 2>&1; then
    log_error "yq is not installed"
    exit 1
  fi
  if [[ ! -x "$SCRIPT_DIR/get_cloud_user.sh" ]]; then
    log_error "get_cloud_user.sh not found or not executable at $SCRIPT_DIR/get_cloud_user.sh"
    exit 1
  fi
}

resolve_user(){
  local user
  local attempts=0
  local max_attempts=40

  # Wait up to 120s for cloud user to appear to avoid racing cloud-init
  while true; do
    if user="$("$SCRIPT_DIR/get_cloud_user.sh" 2>/dev/null || true)" && [[ -n "$user" ]]; then
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

configure_x11vnc_service(){
  local cloud_user="$1"

  # Порт, дисплей, пароль и адрес прослушивания сюда больше не читаются:
  # раньше их доставали из config.yaml и НИГДЕ не использовали — юнит
  # хардкодил свои значения. Теперь они приходят из VMFILE переменными
  # окружения, install.sh кладёт их в /etc/default/bisquite-x11vnc,
  # а юнит читает оттуда.
  systemctl enable "x11vnc@${cloud_user}.service" || true
  # Без `|| true`: отказ обязан быть виден. Раньше обе команды глушились,
  # и немой цикл рестарта из-за ненайденного authority выглядел как успех.
  if systemctl restart "x11vnc@${cloud_user}.service"; then
    log_info "x11vnc запущен для '$cloud_user'"
  else
    log_error "x11vnc не запустился для '$cloud_user' — смотрите journalctl -u x11vnc@${cloud_user}"
    exit 1
  fi
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
