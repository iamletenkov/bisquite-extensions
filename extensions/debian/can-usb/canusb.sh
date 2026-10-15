# shellcheck shell=bash
# Functions of the can-usb extension. Sourced by install.sh, never executed:
#
#   source "$SCRIPT_DIR/canusb.sh"
#
# The pinned values (release, kernel, URL, sums) live in install.sh and come
# in as arguments, so that tools/test-can-usb.sh can feed fixtures.
# CANUSB_ROOT is a test root, empty in the guest. The caller's
# log_info/log_warn/log_error are used when defined.

CANUSB_ROOT="${CANUSB_ROOT:-}"

# Sources of the three drivers inside kernel_src.tbz2 of public_sources.
CANUSB_SRC_PREFIX=kernel/kernel-jammy-src/drivers/net/can
CANUSB_SRC_FILES=(
    usb/gs_usb.c
    usb/peak_usb/pcan_usb_core.c
    usb/peak_usb/pcan_usb_core.h
    usb/peak_usb/pcan_usb.c
    usb/peak_usb/pcan_usb_pro.c
    usb/peak_usb/pcan_usb_pro.h
    usb/peak_usb/pcan_usb_fd.c
    slcan.c
)
CANUSB_MODULES=(gs_usb peak_usb slcan)

_cu_info(){ if declare -F log_info >/dev/null; then log_info "$@"; else >&2 echo "[INFO] $*"; fi; }
_cu_warn(){ if declare -F log_warn >/dev/null; then log_warn "$@"; else >&2 echo "[WARN] $*"; fi; }
_cu_error(){ if declare -F log_error >/dev/null; then log_error "$@"; else >&2 echo "[ERROR] $*"; fi; }

_cu_sha(){ sha256sum "$1" | cut -d' ' -f1; }

# Print the L4T release: `# R36 (release), REVISION: 4.3, ...` -> 36.4.3.
canusb_l4t_release(){
    local file="$CANUSB_ROOT/etc/nv_tegra_release" line
    [[ -f "$file" ]] || return 1
    line="$(head -n 1 "$file")"
    [[ "$line" =~ ^#\ R([0-9]+)\ .*REVISION:\ ([0-9]+\.[0-9]+) ]] || return 1
    printf '%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

# Refuse unless the image is L4T WANT on the board whose DTB is BOARD_DTB.
canusb_gate_board(){
    local want="$1" board_dtb="$2" got
    if ! got="$(canusb_l4t_release)"; then
        _cu_error "нет /etc/nv_tegra_release или он неразборчив — это не образ Jetson (L4T)"
        return 1
    fi
    if [[ "$got" != "$want" ]]; then
        _cu_error "в образе L4T $got, а расширение закреплено на $want:"
        _cu_error "исходники, заголовки и ядро Sensing сверены для одного релиза"
        return 1
    fi
    if [[ ! -f "$CANUSB_ROOT/boot/dtb/kernel_$board_dtb" ]]; then
        _cu_error "нет /boot/dtb/kernel_$board_dtb — расширение только для AGX Orin Devkit"
        _cu_error "(ядро Sensing, под которое собираются модули, есть только для неё)"
        return 1
    fi
    _cu_info "L4T $got, плата AGX Orin ($board_dtb)"
}

# Refuse unless /lib/modules of the IMAGE has exactly one L4T kernel and it is
# WANT. `uname -r` inside virt-customize is the appliance's kernel, not ours.
# Non-tegra kernels (a generic Ubuntu one next to L4T) are listed, not used.
canusb_gate_kernel_tree(){
    local want="$1" d name tegra=() other=()
    for d in "$CANUSB_ROOT"/lib/modules/*/; do
        [[ -d "$d" ]] || continue
        name="$(basename "$d")"
        if [[ "$name" == *-tegra ]]; then tegra+=("$name"); else other+=("$name"); fi
    done
    (( ${#other[@]} )) && _cu_info "ядра образа не L4T, не используются: ${other[*]}"
    if (( ${#tegra[@]} != 1 )) || [[ "${tegra[0]}" != "$want" ]]; then
        _cu_error "ядра L4T в /lib/modules образа: ${tegra[*]:-нет ни одного}; нужно ровно $want"
        return 1
    fi
    _cu_info "ядро образа: $want (по /lib/modules; uname -r appliance не используется)"
}

# Refuse unless /boot/Image is the Sensing kernel the modules were checked
# against: version string KV and sha256 IMAGE_SHA. The two messages differ
# on purpose: "stock kernel" means the layer order in VMFILE is wrong,
# "unknown kernel" means Sensing published another build.
canusb_gate_sensing_kernel(){
    local kv="$1" image_sha="$2"
    local image="$CANUSB_ROOT/boot/Image" backup="$CANUSB_ROOT/boot/Image.backup" got ver
    if [[ ! -f "$image" ]]; then
        _cu_error "нет /boot/Image — ядра в образе нет"
        return 1
    fi
    ver="$(grep -aom1 'Linux version [^ ]*' "$image" | awk '{print $3}')" || ver=""
    if [[ "$ver" != "$kv" ]]; then
        _cu_error "/boot/Image — ядро '${ver:-не опознано}', а модули собираются для $kv"
        return 1
    fi
    got="$(_cu_sha "$image")"
    if [[ "$got" == "$image_sha" ]]; then
        _cu_info "/boot/Image — ядро Sensing $kv (sha256 $got)"
        return 0
    fi
    if [[ ! -f "$backup" ]] || [[ "$got" == "$(_cu_sha "$backup")" ]]; then
        _cu_error "/boot/Image — штатное ядро NVIDIA, а не ядро Sensing:"
        _cu_error "EXTENSION sensing-gmsl2-camera должен стоять в VMFILE РАНЬШЕ can-usb"
        return 1
    fi
    _cu_error "/boot/Image — ядро $kv неизвестной сборки (sha256 $got, проверена $image_sha):"
    _cu_error "совместимость символов модулей сверена только с той сборкой ядра Sensing;"
    _cu_error "новая сборка — новая сверка и новая сумма в install.sh"
    return 1
}

# Refuse unless the build tree of KV is the NVIDIA kernel-headers tree whose
# .config and Module.symvers were compared with the Sensing kernel.
canusb_gate_headers(){
    local kv="$1" config_sha="$2" symvers_sha="$3"
    local kdir="$CANUSB_ROOT/lib/modules/$kv/build" f got want
    for f in Makefile .config Module.symvers include/config/kernel.release; do
        if [[ ! -f "$kdir/$f" ]]; then
            _cu_error "нет /lib/modules/$kv/build/$f — заголовков ядра нет (nvidia-l4t-kernel-headers)"
            return 1
        fi
    done
    got="$(cat "$kdir/include/config/kernel.release")"
    if [[ "$got" != "$kv" ]]; then
        _cu_error "заголовки для ядра $got, а не $kv"
        return 1
    fi
    for f in .config Module.symvers; do
        got="$(_cu_sha "$kdir/$f")"
        if [[ "$f" == .config ]]; then want="$config_sha"; else want="$symvers_sha"; fi
        if [[ "$got" != "$want" ]]; then
            _cu_error "sha256 $f заголовков $got, сверялась $want:"
            _cu_error "это не nvidia-l4t-kernel-headers 36.4.3 — сверки с ядром Sensing для него нет"
            return 1
        fi
    done
    _cu_info "заголовки ядра: .config и Module.symvers — те, что сверены с ядром Sensing"
}

# Download public_sources.tbz2 from URL as a stream, extract only the driver
# sources into OUT and check the archive against SHA. The archive (220 MB) is
# never stored: the guest disk is small by design. Sources extracted from an
# archive whose sum does not match are removed before the refusal.
canusb_fetch(){
    local url="$1" sha="$2" out="$3" fifo got hashpid f members=()
    for f in "${CANUSB_SRC_FILES[@]}"; do members+=("$CANUSB_SRC_PREFIX/$f"); done
    mkdir -p "$out" || return 1
    fifo="$(mktemp -u "$out/.sha.XXXXXX")"
    mkfifo "$fifo" || return 1
    sha256sum < "$fifo" > "$fifo.sum" &
    hashpid=$!
    if ! curl -fsSL --retry 3 --max-time 1800 "$url" | tee "$fifo" \
            | tar -xjOf - Linux_for_Tegra/source/kernel_src.tbz2 \
            | tar -xjf - -C "$out" "${members[@]}"; then
        wait "$hashpid" 2>/dev/null
        rm -f "$fifo" "$fifo.sum"; rm -rf "${out:?}/kernel"
        _cu_error "исходники не скачались или в архиве нет драйверов CAN: $url"
        return 1
    fi
    wait "$hashpid"
    got="$(cut -d' ' -f1 "$fifo.sum")"
    rm -f "$fifo" "$fifo.sum"
    if [[ "$got" != "$sha" ]]; then
        rm -rf "${out:?}/kernel"
        _cu_error "sha256 public_sources.tbz2 $got, закреплена $sha — NVIDIA подменила файл?"
        return 1
    fi
    _cu_info "исходники драйверов из public_sources.tbz2 (sha256 сошлась)"
}

# Lay out the build directory DIR: sources from SRC (the fetch output) plus
# our Kbuild. The kernel's own Makefiles are not used: they gate every driver
# on a CONFIG_ symbol that this kernel does not set.
canusb_prepare(){
    local src="$1/$CANUSB_SRC_PREFIX" kbuild="$2" dir="$3" f
    mkdir -p "$dir/peak_usb" || return 1
    for f in "${CANUSB_SRC_FILES[@]}"; do
        case "$f" in
            usb/peak_usb/*) cp "$src/$f" "$dir/peak_usb/" || return 1 ;;
            *)              cp "$src/$f" "$dir/" || return 1 ;;
        esac
    done
    cp "$kbuild" "$dir/Kbuild"
}

# Build the modules in DIR against the kernel tree of KV and check them:
# every module is there, and its vermagic equals that of the stock can-dev.ko
# (the module that is known to load into this kernel and that two of ours
# depend on).
canusb_build(){
    local kv="$1" dir="$2" jobs="$3" m ref want got
    local kdir="$CANUSB_ROOT/lib/modules/$kv/build"
    if ! make -C "$kdir" M="$dir" -j"$jobs" modules >"$dir/build.log" 2>&1; then
        tail -n 30 "$dir/build.log" >&2
        _cu_error "сборка модулей не прошла (полный журнал: $dir/build.log)"
        return 1
    fi
    ref="$(find "$CANUSB_ROOT/lib/modules/$kv/kernel" -name 'can-dev.ko*' -print -quit 2>/dev/null)"
    if [[ -z "$ref" ]]; then
        _cu_error "в /lib/modules/$kv/kernel нет can-dev.ko — не с чем сверить vermagic"
        return 1
    fi
    want="$(modinfo -F vermagic "$ref")"
    for m in "${CANUSB_MODULES[@]}"; do
        if [[ ! -f "$dir/$m.ko" ]]; then
            _cu_error "после сборки нет $m.ko"
            return 1
        fi
        got="$(modinfo -F vermagic "$dir/$m.ko")"
        if [[ "$got" != "$want" ]]; then
            _cu_error "vermagic $m.ko '$got', у can-dev.ko ядра '$want'"
            return 1
        fi
    done
    _cu_info "собраны ${CANUSB_MODULES[*]}; vermagic '$want'"
}

# Install the built modules into MODDIR of KV (stripped of debug info) and run
# depmod for that kernel. A module that depmod cannot resolve is a refusal.
canusb_install(){
    local kv="$1" dir="$2" moddir="$3" m deps
    install -d "$CANUSB_ROOT$moddir" || return 1
    for m in "${CANUSB_MODULES[@]}"; do
        install -m 0644 "$dir/$m.ko" "$CANUSB_ROOT$moddir/$m.ko" || return 1
        strip --strip-debug "$CANUSB_ROOT$moddir/$m.ko" || return 1
    done
    if [[ -n "$CANUSB_ROOT" ]]; then
        depmod -b "$CANUSB_ROOT" "$kv" || { _cu_error "depmod $kv не отработал"; return 1; }
    else
        depmod "$kv" || { _cu_error "depmod $kv не отработал"; return 1; }
    fi
    for m in "${CANUSB_MODULES[@]}"; do
        if ! deps="$(modprobe ${CANUSB_ROOT:+-d "$CANUSB_ROOT"} -S "$kv" --show-depends "$m" 2>&1)"; then
            _cu_error "modprobe не разрешает $m для $kv: $deps"
            return 1
        fi
        if ! grep -qF "$moddir/$m.ko" <<<"$deps"; then
            _cu_error "modprobe $m для $kv берёт не наш файл: $deps"
            return 1
        fi
    done
    _cu_info "модули в $moddir, depmod $kv прошёл"
}
