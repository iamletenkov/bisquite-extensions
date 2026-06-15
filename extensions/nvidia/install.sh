#!/usr/bin/env bash
# Скрипт установки драйверов NVIDIA для Debian 12/13 и Ubuntu 20.04/22.04/24.04

set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Функция логирования (всегда пишем в stderr, чтобы не засорять stdout при пайпинге)
log_info() {
    >&2 echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    >&2 echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    >&2 echo -e "${RED}[ERROR]${NC} $*"
}

# Функция для выполнения apt команд с retry логикой
apt_retry() {
    local max=5
    local n=1
    while true; do
        if "$@"; then
            return 0
        fi
        if (( n >= max )); then
            return 1
        fi
        local delay=$((n * 2))
        log_warn "apt command failed, retry in ${delay}s... ($n/$max)"
        sleep "$delay"
        n=$((n + 1))
    done
}

# Определение ОС
detect_os() {
    if ! command -v lsb_release >/dev/null 2>&1; then
        log_info "lsb_release not found, installing lsb-release..."
        apt_retry apt-get update
        apt_retry apt-get install -y --no-install-recommends lsb-release
    fi

    OS_ID=$(lsb_release -si)
    OS_VERSION=$(lsb_release -sr)
    OS_CODENAME=$(lsb_release -sc)

    log_info "Detected OS: $OS_ID $OS_VERSION ($OS_CODENAME)"
}

# Добавление репозиториев для Ubuntu
setup_ubuntu_repos() {
    local version="$1"
    local codename=""

    case "$version" in
        20.04) codename="focal" ;;
        22.04) codename="jammy" ;;
        24.04) codename="noble" ;;
        *) log_error "Unsupported Ubuntu version: $version"; exit 1 ;;
    esac

    log_info "Setting up repositories for Ubuntu $version ($codename)"

    # Проверяем, не добавлен ли уже репозиторий
    if grep -q "graphics-drivers/ppa" /etc/apt/sources.list.d/*.list 2>/dev/null; then
        log_info "Graphics-drivers PPA repository already configured"
        return 0
    fi

    log_info "Adding graphics-drivers PPA repository for Ubuntu $version"
    cat > /etc/apt/sources.list.d/graphics-drivers-ppa-${codename}.list <<EOF
deb http://ppa.launchpad.net/graphics-drivers/ppa/ubuntu ${codename} main
EOF

    # Добавляем ключ репозитория (современный способ)
    log_info "Adding PPA GPG key..."
    if command -v curl >/dev/null 2>&1 && command -v gpg >/dev/null 2>&1; then
        # Скачиваем ключ напрямую и добавляем в trusted.gpg.d
        if curl -fsSL https://keyserver.ubuntu.com/pks/lookup?op=get\&search=0x1118213C | gpg --dearmor > /etc/apt/trusted.gpg.d/graphics-drivers-ppa.gpg 2>/dev/null; then
            chmod 644 /etc/apt/trusted.gpg.d/graphics-drivers-ppa.gpg
            log_info "GPG key added successfully"
        else
            log_warn "Could not add GPG key via curl, apt will try to fetch it automatically"
        fi
    else
        log_warn "curl or gpg not found, apt will try to fetch GPG key automatically"
    fi
}

# Добавление репозиториев для Debian
setup_debian_repos() {
    local version="$1"
    local codename=""

    case "$version" in
        12) codename="bookworm" ;;
        13) codename="trixie" ;;
        *) log_error "Unsupported Debian version: $version"; exit 1 ;;
    esac

    log_info "Setting up repositories for Debian $version ($codename)"

    # Проверяем, добавлены ли уже contrib и non-free
    if grep -qE "(contrib|non-free)" /etc/apt/sources.list 2>/dev/null; then
        if grep -qE "contrib.*non-free.*non-free-firmware" /etc/apt/sources.list 2>/dev/null; then
            log_info "Contrib and non-free repositories already configured"
            return 0
        fi
    fi

    log_info "Adding contrib and non-free repositories for Debian $version"

    # Обновляем существующие строки в sources.list
    # Обрабатываем разные форматы строк (с http:// или https://, с комментариями и без)
    sed -i "s|deb\(-src\)\? http\(s\)\?://deb.debian.org/debian/ ${codename} main|& contrib non-free non-free-firmware|g" /etc/apt/sources.list
    sed -i "s|deb\(-src\)\? http\(s\)\?://deb.debian.org/debian/ ${codename}-updates main|& contrib non-free non-free-firmware|g" /etc/apt/sources.list
    sed -i "s|deb\(-src\)\? http\(s\)\?://security.debian.org/debian-security ${codename}-security main|& contrib non-free non-free-firmware|g" /etc/apt/sources.list

    # Если sed не нашёл строки (возможно другой формат), добавляем вручную
    if ! grep -qE "contrib.*non-free" /etc/apt/sources.list 2>/dev/null; then
        log_warn "Could not modify existing sources.list, adding new entries"
        {
            echo "deb http://deb.debian.org/debian ${codename} main contrib non-free non-free-firmware"
            echo "deb http://deb.debian.org/debian ${codename}-updates main contrib non-free non-free-firmware"
            echo "deb http://security.debian.org/debian-security ${codename}-security main contrib non-free non-free-firmware"
        } >> /etc/apt/sources.list
    fi
}

# Установка драйверов для Ubuntu
install_ubuntu_drivers() {
    local version="$1"
    log_info "Installing NVIDIA drivers for Ubuntu $version"

    # Проверяем наличие команды ubuntu-drivers и устанавливаем пакет, если команда отсутствует
    if ! command -v ubuntu-drivers >/dev/null 2>&1; then
        log_info "Command 'ubuntu-drivers' not found. Installing 'ubuntu-drivers-common'..."
        apt_retry apt-get install -y ubuntu-drivers-common
    fi

    log_info "Auto-detecting and installing recommended NVIDIA drivers..."
    DEBIAN_FRONTEND=noninteractive ubuntu-drivers autoinstall || {
        log_warn "ubuntu-drivers autoinstall failed, trying manual installation"
        apt_retry apt-get install -y nvidia-driver-535 || apt_retry apt-get install -y nvidia-driver-525 || apt_retry apt-get install -y nvidia-driver-470
    }
}

# Установка драйверов для Debian
install_debian_drivers() {
    local version="$1"
    log_info "Installing NVIDIA drivers for Debian $version"

    # Пытаемся установить nvidia-detect для определения подходящего драйвера (опционально)
    if apt_retry apt-get install -y nvidia-detect 2>/dev/null; then
        log_info "Detecting recommended NVIDIA driver..."
        if command -v nvidia-detect >/dev/null 2>&1; then
            nvidia-detect || true
        fi
    else
        log_warn "nvidia-detect not available, proceeding with default nvidia-driver installation"
    fi

    # Установка рекомендованных драйверов и необходимых пакетов для Debian
    log_info "Installing NVIDIA driver and required packages..."

    # В chroot окружении uname -r может вернуть ядро хоста (Proxmox),
    # поэтому используем метапакет linux-headers-amd64, который автоматически
    # установит заголовки для ядра гостевой системы
    log_info "Using linux-headers-amd64 meta-package for kernel headers"

    DEBIAN_FRONTEND=noninteractive apt_retry apt-get install -y \
        nvidia-driver \
        linux-headers-amd64 \
        build-essential \
        dkms
}

# Блокировка nouveau и обновление initramfs
blacklist_nouveau() {
    log_info "Blacklisting nouveau driver..."

    # Создаем файл блокировки nouveau
    cat > /etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
blacklist nouveau
options nouveau modeset=0
EOF

    # Также добавляем в blacklist.conf если он существует
    if [[ -f /etc/modprobe.d/blacklist.conf ]]; then
        if ! grep -q "blacklist nouveau" /etc/modprobe.d/blacklist.conf; then
            echo "blacklist nouveau" >> /etc/modprobe.d/blacklist.conf
        fi
    fi

    # Обновляем initramfs для применения блокировки
    log_info "Updating initramfs to apply nouveau blacklist..."
    if command -v update-initramfs >/dev/null 2>&1; then
        update-initramfs -u -k all || {
            log_warn "Failed to update initramfs, but continuing..."
        }
    elif command -v dracut >/dev/null 2>&1; then
        dracut --force || {
            log_warn "Failed to update initramfs with dracut, but continuing..."
        }
    else
        log_warn "No initramfs update tool found, nouveau may still load"
    fi

    log_info "Nouveau driver blacklisted successfully"
}

# Основная функция
main() {
    log_info "Starting NVIDIA drivers installation..."

    detect_os

    # Обновляем списки пакетов
    log_info "Updating package lists..."
    apt_retry apt-get update

    # Настройка репозиториев и установка драйверов в зависимости от ОС
    if [[ "$OS_ID" == "Ubuntu" ]]; then
        if [[ "$OS_VERSION" == "20.04" || "$OS_VERSION" == "22.04" || "$OS_VERSION" == "24.04" ]]; then
            setup_ubuntu_repos "$OS_VERSION"
            apt_retry apt-get update
            install_ubuntu_drivers "$OS_VERSION"
        else
            log_error "Supported Ubuntu versions: 20.04, 22.04, 24.04. Detected: $OS_VERSION"
            exit 1
        fi
    elif [[ "$OS_ID" == "Debian" ]]; then
        if [[ "$OS_VERSION" == "12" || "$OS_VERSION" == "13" ]]; then
            setup_debian_repos "$OS_VERSION"
            log_info "Updating package lists after repository configuration..."
            apt_retry apt-get update
            install_debian_drivers "$OS_VERSION"
        else
            log_error "Supported Debian versions: 12, 13. Detected: $OS_VERSION"
            exit 1
        fi
    else
        log_error "Unsupported OS: $OS_ID $OS_VERSION"
        exit 1
    fi

    # Блокируем nouveau после установки драйверов
    blacklist_nouveau

    log_info "NVIDIA drivers installation completed successfully"
    log_warn "Reboot required to apply changes and load NVIDIA drivers"
}

main "$@"
