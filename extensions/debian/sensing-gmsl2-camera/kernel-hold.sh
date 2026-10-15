# shellcheck shell=bash
# Pin the L4T kernel packages so that apt never puts the stock NVIDIA kernel
# back over the Sensing one. Sourced by install.sh, never executed:
#
#   source "$SCRIPT_DIR/kernel-hold.sh"
#
# WHY. The NVIDIA repository of the image (repo.download.nvidia.com/jetson,
# suite r36.4) carries newer point releases of the same packages: the index of
# 2026-10-15 has nvidia-l4t-kernel 36.4.0, 36.4.3, 36.4.4 and 36.4.7. A plain
# `apt upgrade` on the robot would install 36.4.7 and with it:
#
#   nvidia-l4t-kernel              /boot/Image (stock, no Sensing drivers),
#                                  modules.dep (drops our depmod) and a postinst
#                                  that runs nv-update-extlinux;
#   nvidia-l4t-kernel-dtbs         /boot/dtb/kernel_*.dtb, the FDT of the
#                                  JetsonIO entry the camera overlay applies to;
#   nvidia-l4t-kernel-oot-modules  updates/.../tegra-camera.ko,
#                                  nvhost-nvcsi-t194.ko and the stock
#                                  max96712.ko — exactly the files we replace
#                                  or remove;
#   nvidia-l4t-initrd              /boot/initrd of both boot entries.
#
# Three more are held because they are tied to the kernel by an exact
# `Depends: nvidia-l4t-kernel (= …)` and are built against the stock one:
# nvidia-l4t-kernel-headers, nvidia-l4t-kernel-oot-headers (module builds
# against the wrong tree) and nvidia-l4t-display-kernel (nvidia.ko). apt would
# keep them back anyway; holding them says so instead of a "kept back" list.
#
# Only installed packages are held: `apt-mark hold` of an unknown package is a
# warning in dpkg, not a pin, and it would read as one. The caller's
# log_info/log_warn/log_error are used when defined.

SENSING_HOLD_PKGS=(
    nvidia-l4t-kernel
    nvidia-l4t-kernel-dtbs
    nvidia-l4t-kernel-oot-modules
    nvidia-l4t-initrd
    nvidia-l4t-kernel-headers
    nvidia-l4t-kernel-oot-headers
    nvidia-l4t-display-kernel
)

_kh_info(){ if declare -F log_info >/dev/null; then log_info "$@"; else >&2 echo "[INFO] $*"; fi; }
_kh_warn(){ if declare -F log_warn >/dev/null; then log_warn "$@"; else >&2 echo "[WARN] $*"; fi; }
_kh_error(){ if declare -F log_error >/dev/null; then log_error "$@"; else >&2 echo "[ERROR] $*"; fi; }

# Hold every installed package of SENSING_HOLD_PKGS and check that apt
# reports it held. rc=1 when apt-mark fails or a package is not held after it.
sensing_kernel_hold(){
    local p held=() absent=() missing=() shown
    for p in "${SENSING_HOLD_PKGS[@]}"; do
        if [[ "$(dpkg-query -W -f='${db:Status-Status}' "$p" 2>/dev/null)" == installed ]]; then
            held+=("$p")
        else
            absent+=("$p")
        fi
    done
    if (( ${#absent[@]} )); then
        _kh_warn "не установлены, закреплять нечего: ${absent[*]}"
    fi
    if (( ${#held[@]} == 0 )); then
        _kh_warn "ни одного пакета ядра L4T в dpkg — ядро образа apt не управляется, hold не нужен"
        return 0
    fi
    if ! apt-mark hold "${held[@]}" >/dev/null; then
        _kh_error "apt-mark hold ${held[*]} не прошёл — apt upgrade вернёт штатное ядро NVIDIA"
        return 1
    fi
    shown="$(apt-mark showhold 2>/dev/null)" || shown=""
    for p in "${held[@]}"; do
        grep -qxF "$p" <<<"$shown" || missing+=("$p")
    done
    if (( ${#missing[@]} )); then
        _kh_error "после apt-mark hold не закреплены: ${missing[*]}"
        return 1
    fi
    _kh_info "ядро закреплено (apt-mark hold): ${held[*]}"
}
