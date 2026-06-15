#!/usr/bin/env bash
# Install chromium-kiosk and prepare auto-configuration service

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} $*"; }


log_info "Installing chromium-kiosk and dependencies..."
apt-get update || exit 1
apt-get install -y wget gnupg locales yq || exit 1

# Configure locale
log_info "Configuring locale..."
sed -i 's/# ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/' /etc/locale.gen
locale-gen ru_RU.UTF-8
update-locale LANG=ru_RU.UTF-8 LC_MESSAGES=POSIX

# Add Salamek repository and install chromium-kiosk
log_info "Adding Salamek repository..."
wget -O- https://repository.salamek.cz/deb/salamek.gpg | tee /usr/share/keyrings/salamek-archive-keyring.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/salamek-archive-keyring.gpg] https://repository.salamek.cz/deb/pub all main" | tee /etc/apt/sources.list.d/salamek.cz.list

log_info "Installing chromium-kiosk..."
apt-get update || exit 1
apt-get install -y chromium-kiosk || exit 1

# Install systemd unit from extension directory if present
if [[ -f "/opt/vmsetup/chromium-kiosk/configure-chromium-kiosk.service" ]]; then
  install -m 0644 /opt/vmsetup/chromium-kiosk/configure-chromium-kiosk.service /etc/systemd/system/configure-chromium-kiosk.service || true
else
  log_warn "configure-chromium-kiosk.service not found in /opt/vmsetup/chromium-kiosk/"
fi

# Enable configuration service
systemctl daemon-reload || true
systemctl enable configure-chromium-kiosk.service || true

log_info "chromium-kiosk extension installation completed"
