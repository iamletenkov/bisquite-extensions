#!/usr/bin/env bash
# CAN bus: can-utils, iproute2, kernel modules for the IMAGE kernel and their
# autoload list (/etc/modules-load.d/can.conf).
#
# The kernel that matters is the one installed in the image (/lib/modules/*),
# not `uname -r`: inside the virt-customize appliance `uname -r` is the
# appliance's own kernel. Every module the robot needs is checked with
# `modinfo -k <image kernel>`; on Ubuntu the missing ones come from
# linux-modules-extra-<kernel>, on Debian they are part of linux-image and a
# miss is a refusal (a cloud kernel without CAN drivers).
#
# Parameters (environment, from VMFILE) — the `can` domain, schema in knobs:
#   CAN_MODULES_LOAD   "can can_raw vcan"   modules for autoload
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} can: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} can: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} can: $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for f in knobs knobs.apply render-modules-load.sh lib/bisquite-conf; do
    [[ -f "$SCRIPT_DIR/$f" ]] || { log_error "рядом нет $f — сборка не доставила каталог расширения целиком"; exit 1; }
done
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/bisquite-conf"

# Modules the robot's checklist asks for (modinfo -n vcan gs_usb peak_usb slcan)
# plus the core of the stack. The autoload list is checked on top of these.
REQUIRED_MODULES=(can can_raw can_dev vcan slcan gs_usb peak_usb)

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
apt_retry apt-get update -q || { log_error "apt-get update не прошёл"; exit 1; }
# kmod — modinfo для проверки ниже; в минимальных образах его может не быть.
apt_retry apt-get install -y -q --no-install-recommends can-utils iproute2 kmod \
    || { log_error "can-utils/iproute2 не установились"; exit 1; }

# Settings file first: the module list to check comes from it (VMFILE
# parameters are laid over the defaults through the schema check).
conf_init can "$SCRIPT_DIR/knobs" --env || { log_error "/etc/bisquite/can/config не записан"; exit 1; }
conf_load can

# --- kernels of the image ---------------------------------------------------
image_kernels(){
    local d
    for d in /lib/modules/*/; do
        d="${d%/}"
        # A kernel package always ships modules.order; a leftover directory
        # (an old kernel's DKMS output) does not.
        [[ -f "$d/modules.order" ]] && echo "${d##*/}"
    done
}
mapfile -t KERNELS < <(image_kernels | sort -V)
if (( ${#KERNELS[@]} == 0 )); then
    log_error "в образе нет ядра (/lib/modules/*/modules.order) — проверять модули CAN не на чем"
    exit 1
fi
log_info "ядра образа: ${KERNELS[*]} (uname -r appliance: $(uname -r) — не используется)"

# shellcheck disable=SC2206  # word splitting is the format of the knob
WANTED=("${REQUIRED_MODULES[@]}" $CAN_MODULES_LOAD)

missing_for(){
    local k="$1" m
    for m in "${WANTED[@]}"; do
        modinfo -k "$k" -n "$m" >/dev/null 2>&1 || echo "$m"
    done | sort -u
}

. /etc/os-release
rc=0
for k in "${KERNELS[@]}"; do
    mapfile -t miss < <(missing_for "$k")
    if (( ${#miss[@]} )) && [[ "${ID:-}" == ubuntu ]]; then
        log_info "$k: нет ${miss[*]} — ставлю linux-modules-extra-$k"
        apt_retry apt-get install -y -q --no-install-recommends "linux-modules-extra-$k" \
            || log_error "linux-modules-extra-$k не установился"
        mapfile -t miss < <(missing_for "$k")
    fi
    if (( ${#miss[@]} )); then
        log_error "$k: модулей ${miss[*]} нет (modinfo -k $k)"
        [[ "${ID:-}" == debian ]] && log_error "ядро Debian без драйверов CAN — облачное? нужен linux-image-amd64"
        rc=1
        continue
    fi
    log_info "$k: ${WANTED[*]} — есть"
done
(( rc == 0 )) || exit 1

# Ubuntu: a future kernel brings linux-modules-extra only through the generic
# metapackage. linux-image-virtual alone updates the kernel without them, and
# CAN would vanish after the first `apt upgrade` on the device.
if [[ "${ID:-}" == ubuntu ]] \
   && ! dpkg-query -W -f='${Status}\n' 'linux-image-generic*' 2>/dev/null | grep -q '^install ok installed'; then
    log_warn "метапакета linux-image-generic в образе нет: новое ядро на устройстве придёт без linux-modules-extra"
    log_warn "и без vcan/gs_usb/peak_usb/slcan; надёжнее база с linux-generic (INSTALL linux-image-extra-virtual)"
fi

"$SCRIPT_DIR/render-modules-load.sh" >/dev/null || { log_error "/etc/modules-load.d/can.conf не записан"; exit 1; }
log_info "автозагрузка: ${CAN_MODULES_LOAD:-(пусто)}; утилиты: $(command -v candump) $(command -v cansend)"
