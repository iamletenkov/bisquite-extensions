#!/usr/bin/env bash
# Install x11vnc and prepare auto-configuration service

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} $*"; }


log_info "Installing x11vnc and dependencies..."
apt-get update || exit 1
apt-get install -y \
  x11vnc \
  yq || exit 1

# Install systemd unit template from extension directory if present
if [[ -f "/opt/vmsetup/x11vnc/x11vnc@.service" ]]; then
  install -m 0644 /opt/vmsetup/x11vnc/x11vnc@.service /etc/systemd/system/x11vnc@.service || true
else
  log_warn "x11vnc@.service not found in /opt/vmsetup/x11vnc/"
fi

# Install configure script systemd unit if present
if [[ -f "/opt/vmsetup/x11vnc/configure-x11vnc.service" ]]; then
  install -m 0644 /opt/vmsetup/x11vnc/configure-x11vnc.service /etc/systemd/system/configure-x11vnc.service || true
else
  log_warn "configure-x11vnc.service not found in /opt/vmsetup/x11vnc/"
fi

# Enable configuration service
systemctl daemon-reload || true
systemctl enable configure-x11vnc.service || true

log_info "x11vnc extension installation completed"
