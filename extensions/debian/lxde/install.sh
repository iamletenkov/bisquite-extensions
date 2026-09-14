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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"


log_info "Installing LXDE and dependencies..."

apt-get update || exit 1
apt-get install -y \
  lxde \
  lightdm lightdm-gtk-greeter \
  xorg xinput \
  usbutils dbus-x11 || exit 1

# Браузер ставится ОТДЕЛЬНО и не обязателен.
#
# Пока `firefox-esr` стоял в общем списке с `|| exit 1`, отсутствие одного
# необязательного пакета роняло установку ВСЕГО десктопа — при том что ни
# lightdm, ни сессия LXDE от браузера не зависят. Ровно эта ошибка у соседа
# уже замерена: `gnome/install.sh:25-49`, jammy 2026-09-10,
# `E: Package 'chromium' has no installation candidate`. Имя пакета там
# другое, механизм отказа тот же; замера под сам `firefox-esr` мы не делали
# и выдумывать его не надо — довод держится на уже замеренном случае.
#
# Поэтому: перебираем известные имена, ставим первое доступное, и отсутствие
# всех — предупреждение, а не отказ. Порядок перебора — сначала настоящий
# пакет Debian, потом имя, под которым браузер живёт в Ubuntu (там это
# переходник на snap, и внутри appliance он вполне может не поставиться —
# это тоже промах, то есть предупреждение).
browser_installed=""
for browser in firefox-esr firefox; do
    if apt-get install -y "$browser" >/dev/null 2>&1; then
        browser_installed="$browser"
        break
    fi
done

if [[ -n "$browser_installed" ]]; then
    log_info "Browser installed: $browser_installed"
else
    log_warn "No firefox package available in this distribution"
    log_warn "LXDE session works without it; install a browser manually if needed"
fi

# Ensure Xorg configuration directory exists
mkdir -p /etc/X11/xorg.conf.d

# --- lightdm: сессия LXDE ---------------------------------------------------
#
# На сборке: имя пользователя здесь не нужно — сессию и приветствие задаёт
# шаблон, а автологин приходит ручкой ниже.
if [[ ! -f "$SCRIPT_DIR/lightdm.conf" ]]; then
  log_error "рядом нет lightdm.conf — lightdm не узнает, какую сессию запускать"
  exit 1
fi
install -D -m 0644 "$SCRIPT_DIR/lightdm.conf" /etc/lightdm/lightdm.conf
log_info "lightdm: сессия LXDE, автологин выключен до ручки"

# --- Ручки рабочего стола ----------------------------------------------------
#
# Автологин, автоблокировка и затемнение — ручки (bisquite-desktop, общий код
# lib/), по умолчанию выключены; включаются параметрами расширения или
# `bisquite-desktop set` на устройстве. Служба bisquite-desktop.service
# применяет их на каждой загрузке ДО lightdm. На железе xfce4/lxde с новым
# механизмом не проверялись — проверен gnome на Jetson AGX Orin (2026-09-14).
# Общий код приезжает не копией в каталоге расширения, а ссылкой lib на
# lib/ источника, которую ставит сборка (раскладка 2).
if [[ ! -x "$SCRIPT_DIR/lib/bisquite-desktop" ]]; then
  log_error "рядом нет lib/bisquite-desktop — ручек автологина и экрана не будет"
  exit 1
fi
apt-get install -y x11-xserver-utils dconf-cli || exit 1
"$SCRIPT_DIR/lib/bisquite-desktop" install "$SCRIPT_DIR" || exit 1

systemctl enable lightdm.service || true
systemctl set-default graphical.target || true

log_info "LXDE extension installation completed"
