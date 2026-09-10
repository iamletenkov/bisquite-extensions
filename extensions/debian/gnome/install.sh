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
  usbutils dbus-x11 || exit 1

# Браузер ставится ОТДЕЛЬНО и не обязателен.
#
# Имя пакета различается: в Debian это `chromium`, в Ubuntu его нет вовсе
# (замер 2026-09-10 на jammy: `E: Package 'chromium' has no installation
# candidate`), а есть `chromium-browser` — переходник на snap. Пока браузер
# стоял в общем списке с `|| exit 1`, установка ВСЕГО десктопа падала на
# Ubuntu из-за одного пакета, хотя ни gdm3, ни gnome-shell от него
# не зависят.
#
# Поэтому: перебираем известные имена, ставим первое доступное, и отсутствие
# любого — предупреждение, а не отказ. Сессия GNOME поднимется и без браузера.
browser_installed=""
for browser in chromium chromium-browser; do
    if apt-get install -y "$browser" >/dev/null 2>&1; then
        browser_installed="$browser"
        break
    fi
done

if [[ -n "$browser_installed" ]]; then
    log_info "Browser installed: $browser_installed"
else
    log_warn "No chromium package available in this distribution"
    log_warn "GNOME session works without it; install a browser manually if needed"
fi

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
