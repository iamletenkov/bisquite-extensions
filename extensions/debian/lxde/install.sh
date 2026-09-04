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
# yq: из репозитория, а при его отсутствии — статическим бинарём.
#
# ЗАЧЕМ. Пакета `yq` НЕТ в Ubuntu 20.04 focal — он появился в дистрибутивах
# позже. Замер 2026-09-04 на Jetson Nano: `apt-cache policy yq` пуст,
# и строка `apt-get install -y … yq` падала ЦЕЛИКОМ, унося с собой и curl,
# и wget, и всё расширение. Сборка воркстейшна Jetson умирала на девятом
# слое за 51 секунду, а сообщение об отказе тонуло в дампе builder.log.
#
# Версия прибита намеренно: `latest` означал бы, что тот же VMFILE завтра
# соберёт другой образ. Архитектура берётся у dpkg, а не угадывается.
ensure_yq() {
    if command -v yq >/dev/null 2>&1; then
        return 0
    fi
    if apt-get install -y yq >/dev/null 2>&1 && command -v yq >/dev/null 2>&1; then
        echo "[INFO] yq установлен из репозитория" >&2
        return 0
    fi
    local arch url
    arch="$(dpkg --print-architecture)"
    case "$arch" in
        arm64|amd64) ;;
        *) echo "[ERROR] yq: неизвестная архитектура $arch" >&2; return 1 ;;
    esac
    url="https://github.com/mikefarah/yq/releases/download/v4.45.1/yq_linux_${arch}"
    echo "[INFO] yq в репозитории отсутствует, качаю статический бинарь ($arch)" >&2
    if ! wget -nv -O /usr/local/bin/yq "$url"; then
        echo "[ERROR] yq не скачался: $url" >&2
        return 1
    fi
    chmod 0755 /usr/local/bin/yq
    # Полным путём: PATH гостевой оболочки virt-customize не содержит
    # /usr/local/bin, и голое `yq --version` дало бы 127.
    if ! /usr/local/bin/yq --version >/dev/null 2>&1; then
        echo "[ERROR] yq не запускается" >&2
        return 1
    fi
    echo "[INFO] yq установлен статическим бинарём" >&2
}

apt-get update || exit 1
apt-get install -y \
  lxde \
  lightdm lightdm-gtk-greeter \
  xorg xinput \
  firefox-esr \
  usbutils dbus-x11 || exit 1
ensure_yq || exit 1

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
