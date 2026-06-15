#!/usr/bin/env bash
# Install GNOME desktop stack and prepare auto-configuration service

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} $*"; }


log_info "Installing GNOME and dependencies..."
apt-get update || exit 1
apt-get install -y \
  task-gnome-desktop \
  gdm3 gnome-shell gnome-session \
  xorg xinput dconf-cli \
  chromium \
  usbutils dbus-x11 \
  yq || exit 1

# Ensure Xorg configuration directory exists
mkdir -p /etc/X11/xorg.conf.d

# Install systemd unit from extension directory if present
if [[ -f "/opt/vmsetup/gnome/configure-gnome.service" ]]; then
  install -m 0644 /opt/vmsetup/gnome/configure-gnome.service /etc/systemd/system/configure-gnome.service || true
else
  log_warn "configure-gnome.service not found in /opt/vmsetup/gnome/"
fi

# Enable GDM and set graphical target as default
systemctl daemon-reload || true
systemctl enable gdm3.service || systemctl enable gdm.service || true
systemctl set-default graphical.target || true
systemctl enable configure-gnome.service || true

log_info "GNOME extension installation completed"
