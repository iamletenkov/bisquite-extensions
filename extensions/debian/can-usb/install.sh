#!/usr/bin/env bash
# USB/serial CAN adapter modules (gs_usb, peak_usb, slcan) for the Sensing
# kernel of Jetson AGX Orin on L4T 36.4.3.
#
# WHY. The Sensing kernel (5.15.148-tegra, laid over /boot/Image by
# sensing-gmsl2-camera) is built without CONFIG_CAN_GS_USB, CONFIG_CAN_PEAK_USB
# and CONFIG_CAN_SLCAN, and no package brings them. The robot checklist asks
# for `modinfo -n gs_usb peak_usb slcan`.
#
# WHY NVIDIA SOURCES. Sensing publishes the kernel binary only. The modules
# are built from the kernel sources of the same L4T release from NVIDIA
# (public_sources.tbz2 -> kernel_src.tbz2, kernel-jammy-src 5.15.148), as
# external modules against the kernel-headers tree of the IMAGE. Measured on
# the live board 2026-10-15: /proc/config.gz of the Sensing kernel and .config
# of nvidia-l4t-kernel-headers 36.4.3 differ only in the compiler lines
# (Buildroot gcc 11.3 vs Ubuntu gcc 11.4, CONFIG_GCC_PLUGINS=y with every
# plugin off), so symbol CRCs and struct layouts are the same; the three
# modules built this way load into the running Sensing kernel without a
# version complaint. The pins below tie the build to exactly that pair.
#
# WHY BUILD PHASE. Modules are baked into the image so that the fleet is
# identical; firstboot would need the network and a compiler on every robot.
#
# ORDER. After sensing-gmsl2-camera: the check below refuses on the stock
# NVIDIA /boot/Image. The kernel is never taken from `uname -r` (inside
# virt-customize that is the appliance's kernel) but from /lib/modules and
# /boot of the image.
#
# Parameters: none. Autoload is not touched: udev loads the module when the
# adapter is plugged in (modalias), CAN_MODULES_LOAD of `can` stays as is.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} can-usb: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} can-usb: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} can-usb: $*"; }

# Pins. Not parameters: another value means another check on a live board.
CANUSB_L4T=36.4.3
CANUSB_KERNEL=5.15.148-tegra
CANUSB_BOARD_DTB=tegra234-p3737-0000+p3701-0000-nv.dtb
# Jetson Linux R36.4.3 public sources (226 034 384 bytes, measured 2026-10-15).
CANUSB_SRC_URL=https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.3/sources/public_sources.tbz2
CANUSB_SRC_SHA256=2c177804679e3ed650dabec6fa958388579896f170570c6171a1b6c386669216
# /boot/Image of the Sensing package SG8A_AGON_G2Y_A1_AGX_Orin_GMSL2x8_JP6.2_L4TR36.4.3
# (git blob f9e5c71d of SENSING-Technology/nvidia-jetson-camera-drivers,
# "Linux version 5.15.148-tegra ... Sat Mar 21 14:24:08 CST 2026").
CANUSB_SENSING_IMAGE_SHA256=fb75806692bd7216916da985ed828f841cbf38b3e7207f124921b41fd84b8771
# nvidia-l4t-kernel-headers 5.15.148-tegra-36.4.3-20250107174145.
CANUSB_HEADERS_CONFIG_SHA256=9f3129b2dd65e88c043fa09a7f0a3abd30c88891e029f3f1b6d976bed09459f2
CANUSB_HEADERS_SYMVERS_SHA256=bdbf119f6a3844aa7810fb22ed4c604f5608e9302033a81d27fa558314ce7f96
CANUSB_MODDIR="/lib/modules/$CANUSB_KERNEL/updates/can-usb"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for f in canusb.sh Kbuild; do
    [[ -f "$SCRIPT_DIR/$f" ]] || { log_error "рядом нет $f — сборка не доставила каталог расширения целиком"; exit 1; }
done
# shellcheck source=canusb.sh
source "$SCRIPT_DIR/canusb.sh"

# --- 1. Board, release, kernel: before any network ---------------------------
canusb_gate_board "$CANUSB_L4T" "$CANUSB_BOARD_DTB" || exit 1
canusb_gate_kernel_tree "$CANUSB_KERNEL" || exit 1
canusb_gate_sensing_kernel "$CANUSB_KERNEL" "$CANUSB_SENSING_IMAGE_SHA256" || exit 1

apt_retry(){
    local i
    for i in 1 2 3; do
        "$@" && return 0
        log_warn "попытка $i: $* — не удалась, повтор через 10 с"
        sleep 10
    done
    return 1
}
export DEBIAN_FRONTEND=noninteractive
APT_UPDATED=0
apt_update_once(){
    (( APT_UPDATED )) && return 0
    apt_retry apt-get update -q || { log_error "apt-get update не прошёл"; return 1; }
    APT_UPDATED=1
}

# --- 2. Kernel headers of the image --------------------------------------------
# The base image of the release matrix carries nvidia-l4t-kernel-headers; a base
# without them gets the version of the installed nvidia-l4t-kernel, held like
# the rest of the kernel (sensing-gmsl2-camera holds only what was installed).
if [[ ! -f "/lib/modules/$CANUSB_KERNEL/build/Makefile" ]]; then
    kver="$(dpkg-query -W -f='${Version}' nvidia-l4t-kernel 2>/dev/null)" || kver=""
    if [[ -z "$kver" ]]; then
        log_error "нет ни заголовков ядра, ни пакета nvidia-l4t-kernel — ставить заголовки не к чему"
        exit 1
    fi
    log_info "заголовков ядра нет — ставлю nvidia-l4t-kernel-headers=$kver"
    apt_update_once || exit 1
    apt_retry apt-get install -y -q --no-install-recommends "nvidia-l4t-kernel-headers=$kver" \
        || { log_error "nvidia-l4t-kernel-headers=$kver не установился"; exit 1; }
    apt-mark hold nvidia-l4t-kernel-headers >/dev/null \
        || { log_error "apt-mark hold nvidia-l4t-kernel-headers не прошёл"; exit 1; }
fi
canusb_gate_headers "$CANUSB_KERNEL" "$CANUSB_HEADERS_CONFIG_SHA256" "$CANUSB_HEADERS_SYMVERS_SHA256" || exit 1

# --- 3. Toolchain ---------------------------------------------------------------
# gcc of jammy is the one the headers name (CONFIG_CC_VERSION_TEXT gcc 11.4).
missing=()
for c in gcc make curl bzip2 strip modinfo depmod modprobe; do
    command -v "$c" >/dev/null 2>&1 || missing+=("$c")
done
if (( ${#missing[@]} )); then
    log_info "нет ${missing[*]} — ставлю инструменты сборки"
    apt_update_once || exit 1
    apt_retry apt-get install -y -q --no-install-recommends gcc make libc6-dev binutils curl bzip2 kmod \
        || { log_error "инструменты сборки не установились"; exit 1; }
fi

# --- 4. Sources, build, install ------------------------------------------------
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT
log_info "качаю исходники Jetson Linux $CANUSB_L4T: $CANUSB_SRC_URL"
canusb_fetch "$CANUSB_SRC_URL" "$CANUSB_SRC_SHA256" "$WORKDIR/src" || exit 1
canusb_prepare "$WORKDIR/src" "$SCRIPT_DIR/Kbuild" "$WORKDIR/build" || exit 1
canusb_build "$CANUSB_KERNEL" "$WORKDIR/build" "$(nproc)" || exit 1
canusb_install "$CANUSB_KERNEL" "$WORKDIR/build" "$CANUSB_MODDIR" || exit 1

log_info "готово: ${CANUSB_MODULES[*]} в $CANUSB_MODDIR; грузятся udev при подключении адаптера"
log_info "проверка на устройстве: modinfo -n gs_usb peak_usb slcan"
