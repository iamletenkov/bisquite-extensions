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

# Install common dependencies
#
# x11-utils и xauth объявлены ЯВНО: обёртке нужен `xdpyinfo`, чтобы проверить
# кандидата в X authority, а лежит он в x11-utils — не в x11-xserver-utils,
# который даёт xset/xrandr/xhost. Прежний юнит звал xdpyinfo, не поставив его:
# работало лишь тогда, когда пакет приезжал прицепом за `xorg` от расширения
# десктопа, то есть зависело от порядка слоёв в VMFILE. Та же правка и по той
# же причине уже сделана у расширения x11vnc.
log_info "Installing common dependencies..."
apt-get install -y curl wget x11-xserver-utils x11-utils xauth dbus-x11 || exit 1
ensure_yq || exit 1

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
