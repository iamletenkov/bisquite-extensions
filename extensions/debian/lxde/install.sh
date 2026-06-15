#!/usr/bin/env bash
# Install LXDE desktop stack and prepare auto-configuration service

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} $*"; }


log_info "Installing LXDE and dependencies..."
apt-get update || exit 1
apt-get install -y \
  lxde \
  lightdm lightdm-gtk-greeter \
  xorg xinput \
  firefox-esr \
  usbutils dbus-x11 \
  yq || exit 1

# Ensure Xorg configuration directory exists
mkdir -p /etc/X11/xorg.conf.d

# Install systemd unit from extension directory if present
if [[ -f "/opt/vmsetup/lxde/configure-lxde.service" ]]; then
  install -m 0644 /opt/vmsetup/lxde/configure-lxde.service /etc/systemd/system/configure-lxde.service || true
else
  log_warn "configure-lxde.service not found in /opt/vmsetup/lxde/"
fi

# Enable LightDM and set graphical target as default
systemctl daemon-reload || true
systemctl enable lightdm.service || true
systemctl set-default graphical.target || true
systemctl enable configure-lxde.service || true

log_info "LXDE extension installation completed"
