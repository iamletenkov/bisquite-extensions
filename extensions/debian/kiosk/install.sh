#!/usr/bin/env bash
# Install Chromium for kiosk mode

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions (always write to stderr to avoid polluting stdout)
log_info() {
    >&2 echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    >&2 echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    >&2 echo -e "${RED}[ERROR]${NC} $*"
}

log_info "Starting kiosk extension installation..."

# Update package lists
log_info "Updating package lists..."
apt-get update || exit 1

# Install common dependencies
#
# x11-utils и xauth объявлены ЯВНО: обёртке нужен `xdpyinfo`, чтобы проверить
# кандидата в X authority, а лежит он в x11-utils — не в x11-xserver-utils,
# который даёт xset/xrandr/xhost. Прежний юнит звал xdpyinfo, не поставив его:
# работало лишь тогда, когда пакет приезжал прицепом за `xorg` от расширения
# десктопа, то есть зависело от порядка слоёв в VMFILE. Та же правка и по той
# же причине уже сделана у расширения x11vnc.
log_info "Installing common dependencies..."
apt-get install -y curl wget yq x11-xserver-utils x11-utils xauth dbus-x11 || exit 1

# Install Chromium
log_info "Installing Chromium browser..."
apt-get install -y chromium chromium-driver || exit 1
log_info "Chromium installed successfully"

# Install systemd unit files from extension directory if present
if [[ -f "/opt/vmsetup/kiosk/configure-kiosk.service" ]]; then
    install -m 0644 /opt/vmsetup/kiosk/configure-kiosk.service /etc/systemd/system/configure-kiosk.service || true
else
    log_warn "configure-kiosk.service not found in /opt/vmsetup/kiosk/"
fi

if [[ -f "/opt/vmsetup/kiosk/kiosk-chromium@.service" ]]; then
    install -m 0644 /opt/vmsetup/kiosk/kiosk-chromium@.service /etc/systemd/system/kiosk-chromium@.service || true
else
    log_warn "kiosk-chromium@.service not found in /opt/vmsetup/kiosk/"
fi

# Обёртка, которая ищет X authority в рантайме и запускает chromium.
if [[ -f "/opt/vmsetup/kiosk/run-kiosk.sh" ]]; then
    chmod +x /opt/vmsetup/kiosk/run-kiosk.sh || true
else
    log_error "run-kiosk.sh не найден рядом — kiosk-chromium@.service не запустится"
    exit 1
fi

# Reload systemd and enable configuration service
systemctl daemon-reload || true
systemctl enable configure-kiosk.service || true

log_info "Installation completed successfully!"
log_info "Kiosk extension is installed and ready to be configured"
log_info "Configuration will be handled by the configure-kiosk service"
