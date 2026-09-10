#!/usr/bin/env bash
# Станция прошивки NVIDIA Jetson (AGX Orin, JetPack 6.x / L4T 36.x).
# Ставится на amd64-образ Ubuntu 22.04: пакеты инструментария L4T, NFS-сервер,
# Регистрация binfmt для aarch64, udev-правило против USB-autosuspend
# и скрипты станции в /opt/nvidia-jetpack.
#
# Ничего не запускает: прошивку начинает оператор, руками, по README.

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

# Каталог расширения. В гостя он приезжает как /opt/vmsetup/nvidia-jetpack
# (и через EXTENSION, и через COPY_IN), но захардкоживать этот путь нельзя:
# скрипт обязан находить своё дерево относительно самого себя.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Куда раскладываются скрипты станции на живой системе.
TARGET_DIR="/opt/nvidia-jetpack"

# Пакеты инструментария L4T.
#
# Список выведен эмпирически, а не угадан: это все аргументы `command -v`
# из tools/kernel_flash/*.sh, tools/*.sh и flash.sh плюс то, что зовёт
# tegraflash.py через run_cpp_tool(). Каждая недостающая утилита стоила
# отдельного отказа посреди заливки — см. docs/specs 2026-09-10.
L4T_PACKAGES=(
    zstd                # распаковка BSP и образов
    cpp                 # препроцессор DTS, зовётся из tegraflash.py
    device-tree-compiler
    xmlstarlet          # разбор XML-конфигураций разделов
    libxml2-utils       # xmllint там же
    sshpass             # заливка rootfs по SSH без интерактивного пароля
    openssh-client
    abootimg            # разбор boot.img
    uuid-runtime        # uuidgen для идентификаторов разделов
    lz4
    cpio
    gdisk               # sgdisk по GPT целевого носителя
    parted
    binutils            # objcopy/strip в сборке recovery-образа
    qemu-user-static    # выполнение arm64-бинарей при кастомизации rootfs
    nfs-kernel-server   # l4t_initrd_flash.sh раздаёт rootfs по NFS
    python3-yaml
    bzip2
    wget
    curl
    v4l-utils           # проверка камер после прошивки
)

# Шаг 1: пакеты
install_packages() {
    log_info "Updating package lists..."
    apt_retry apt-get update

    log_info "Installing L4T flashing toolchain (${#L4T_PACKAGES[@]} packages)..."
    DEBIAN_FRONTEND=noninteractive apt_retry apt-get install -y \
        --no-install-recommends "${L4T_PACKAGES[@]}"

    log_info "L4T flashing toolchain installed"
}

# Шаг 2: NFS-сервер
#
# Именно enable, а не start: образ собирается в libguestfs-приложении, где
# systemd не работает вовсе, и start отказал бы всегда. enable — это offline
# расстановка симлинков, её достаточно: на живой системе сервис поднимется
# сам и приведёт за собой nfsdcld и rpc_pipefs, из-за отсутствия которых
# заливка из chroot ломалась пять раз подряд.
enable_nfs_server() {
    log_info "Enabling nfs-server for boot..."

    if ! command -v systemctl >/dev/null 2>&1; then
        log_warn "systemctl not found; enable nfs-server manually on first boot"
        return 0
    fi

    if systemctl enable nfs-server; then
        log_info "nfs-server enabled (will start on first boot)"
    else
        # Не отказ: сборка на этом шаге не портится, а оператор узнаёт,
        # что именно нужно доделать. Отказ здесь означал бы, что образ
        # не собирается из-за симлинка, который ставится одной командой.
        log_warn "Could not enable nfs-server; run 'systemctl enable --now nfs-server' on the station"
    fi
}

# Шаг 3: регистрация binfmt для aarch64
#
# Пакет qemu-user-static кладёт /usr/bin/qemu-aarch64-static, но САМ ПО СЕБЕ
# НЕ ОБЪЯВЛЯЕТ обработчик ядру. На Ubuntu регистрацию делает postinst, и
# только если установлен binfmt-support, — а внутри virt-customize это
# ненадёжно вдвойне: там нет работающего systemd, и результат регистрации
# может не дожить до образа.
#
# Замер 2026-09-11 на собранной станции: бинарь на месте, в
# /usr/lib/binfmt.d/ лежит только python3.10.conf, в /proc/sys/fs/binfmt_misc/
# тоже. То есть эмулятор есть, а выполнить arm64-бинарь нельзя — и
# 04-customize-rootfs.sh, который правит rootfs платы изнутри, отказал бы
# на станции, где всё остальное в порядке.
#
# Поэтому файл кладётся явно: systemd-binfmt читает /etc/binfmt.d на каждой
# загрузке, и регистрация не зависит ни от postinst, ни от наличия
# update-binfmts. Флаг F открывает интерпретатор в момент регистрации —
# без него qemu пришлось бы копировать внутрь каждого chroot.
install_binfmt_aarch64() {
    local conf_file="/etc/binfmt.d/qemu-aarch64.conf"
    local emulator="/usr/bin/qemu-aarch64-static"

    log_info "Registering aarch64 binfmt handler: $conf_file"

    if [[ ! -x "$emulator" ]]; then
        # Не отказ по тому же доводу, что и у nfs-server: образ собирается,
        # а оператор узнаёт, чего не хватает. Но сказать надо громко —
        # без эмулятора шаг 04 не сработает.
        log_warn "No $emulator — step 04 (customize rootfs) will fail; install qemu-user-static"
        return 0
    fi

    mkdir -p /etc/binfmt.d
    cat > "$conf_file" <<EOF
# NVIDIA Jetson: выполнение arm64-бинарей при кастомизации rootfs платы.
# Магия и маска — ELF aarch64 (EM_AARCH64 = 183 = 0xb7, little-endian).
# Регистрацию применяет systemd-binfmt на каждой загрузке.
:qemu-aarch64:M::\x7fELF\x02\x01\x01\x00\x00\x00\x00\x00\x00\x00\x00\x00\x02\x00\xb7\x00:\xff\xff\xff\xff\xff\xff\xff\x00\xff\xff\xff\xff\xff\xff\xff\xff\xfe\xff\xff\xff:$emulator:F
EOF
    chmod 644 "$conf_file"

    log_info "aarch64 binfmt registered (applies on next boot)"
    log_info "  check on the station: ls /proc/sys/fs/binfmt_misc/ | grep qemu-aarch64"
}

# Шаг 4: udev-правило против USB-autosuspend
#
# Правило по vendor, а не по product, намеренно: за один сеанс прошивки плата
# трижды меняет PID — 7020 (обычный режим) -> 7023 (APX) -> 7035 (initrd), —
# и вдобавок наблюдалась миграция с Bus 001 на Bus 002. Правило по product
# перестало бы действовать ровно в тот момент, когда идёт запись.
install_udev_rule() {
    local rule_file="/etc/udev/rules.d/99-jetson-usb.rules"

    log_info "Installing udev rule: $rule_file"

    mkdir -p /etc/udev/rules.d
    cat > "$rule_file" <<'EOF'
# NVIDIA Jetson: не усыплять USB-устройства платы во время прошивки.
# 0955 — vendor id NVIDIA. По product id правило писать нельзя: за сеанс
# прошивки плата меняет PID трижды (7020 -> 7023 APX -> 7035 initrd).
ACTION=="add", SUBSYSTEM=="usb", ATTR{idVendor}=="0955", TEST=="power/control", ATTR{power/control}="on"
EOF
    chmod 644 "$rule_file"

    log_info "udev rule installed (applies on next boot or udevadm trigger)"
}

# Шаг 5: скрипты станции
#
# Копируются в /opt/nvidia-jetpack и там просто лежат. Автозапуска нет
# намеренно: прошивка необратима для платы, и начинать её должен оператор.
install_station_scripts() {
    local source_dir="$SCRIPT_DIR/scripts"

    if [[ ! -d "$source_dir" ]]; then
        log_error "Directory not found: $source_dir"
        log_error "Extension is incomplete: station scripts are its whole point."
        log_error "Expected the extension tree (with scripts/) at: $SCRIPT_DIR"
        exit 1
    fi

    # Пустой каталог — тот же отказ по существу: станция без скриптов
    # прошить ничего не может, а узнать об этом на живой машине хуже,
    # чем на сборке.
    local scripts=()
    while IFS= read -r -d '' script; do
        scripts+=("$script")
    done < <(find "$source_dir" -maxdepth 1 -type f -name '*.sh' -print0)

    if (( ${#scripts[@]} == 0 )); then
        log_error "No *.sh files in $source_dir — nothing to install"
        exit 1
    fi

    log_info "Installing ${#scripts[@]} station scripts into $TARGET_DIR"
    mkdir -p "$TARGET_DIR"

    local script
    for script in "${scripts[@]}"; do
        install -m 0755 "$script" "$TARGET_DIR/$(basename "$script")"
        log_info "  $(basename "$script")"
    done

    # README кладётся рядом, но исполняемым не делается — это документация,
    # а не шаг прошивки.
    if [[ -f "$source_dir/README.md" ]]; then
        install -m 0644 "$source_dir/README.md" "$TARGET_DIR/README.md"
        log_info "  README.md"
    else
        log_warn "No $source_dir/README.md — flashing order will be undocumented on the station"
    fi
}

main() {
    log_info "Starting nvidia-jetpack flash station setup..."

    install_packages
    enable_nfs_server
    install_binfmt_aarch64
    install_udev_rule
    install_station_scripts

    log_info "nvidia-jetpack setup completed successfully"
    log_info "Scripts are in $TARGET_DIR; nothing runs automatically — see $TARGET_DIR/README.md"
}

main "$@"
