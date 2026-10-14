#!/usr/bin/env bash
# NVIDIA driver of a pinned branch for the kernel(s) OF THE IMAGE.
#
# Runs inside virt-customize, i.e. inside the libguestfs appliance: `uname -r`
# is the appliance kernel, not the image kernel. Every kernel-specific step —
# headers, prebuilt modules, DKMS, initramfs, the final modinfo check — takes
# its kernel from /lib/modules + /boot of the image, never from uname.
#
# Parameters (environment, passed by EXTENSION as is):
#   NVIDIA_DRIVER_VERSION   driver branch, default 580
#   NVIDIA_KERNEL_MODULES   open | proprietary, default open
#                           (Blackwell — RTX 50xx — works ONLY with open)
#   NVIDIA_SOURCE           Ubuntu: archive | ppa, default archive;
#                           Debian: archive only (= NVIDIA CUDA repository)
#
# Sources, measured 2026-10-14:
#   Ubuntu 22.04/24.04  archive (restricted): nvidia-driver-<br>[-open] plus,
#                       when they match the image kernel, Canonical's prebuilt
#                       signed linux-modules-nvidia-<br>[-open]-<kernel>;
#                       otherwise DKMS against linux-headers-<kernel>.
#   Debian 12/13        NVIDIA CUDA repository (debian12 / debian13): Debian's
#                       own non-free carries only 535 (bookworm) and 550
#                       (trixie). The CUDA repository has 580 for debian12;
#                       debian13 starts at 590. A branch the repository does
#                       not publish is a loud error, never a fallback.
#
# No `ubuntu-drivers autoinstall` and no silent fallback to older branches:
# the image either gets exactly the requested branch or the build fails.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} $*"; }
die(){ log_error "$*"; exit 1; }

apt_retry(){
    local max=5 n=1 d
    while true; do
        if "$@"; then return 0; fi
        if (( n >= max )); then return 1; fi
        d=$(( n * 2 )); log_warn "apt не отработал, повтор через ${d}s ($n/$max)"
        sleep "$d"; n=$(( n + 1 ))
    done
}

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-q -y -o Dpkg::Options::=--force-confdef -o Dpkg::Options::=--force-confold)

# --- parameters ---------------------------------------------------------------
# Local names on purpose: defaults are never assigned to the exported ones.
BRANCH="${NVIDIA_DRIVER_VERSION:-580}"
MODULES="${NVIDIA_KERNEL_MODULES:-open}"
SOURCE="${NVIDIA_SOURCE:-archive}"

[[ "$BRANCH" =~ ^[0-9]{3,4}$ ]] \
    || die "NVIDIA_DRIVER_VERSION=$BRANCH: ожидается номер ветки драйвера (например, 580), а не полная версия"
case "$MODULES" in
    open) ;;
    proprietary)
        log_warn "NVIDIA_KERNEL_MODULES=proprietary: карты Blackwell (RTX 50xx, в т.ч. RTX 5060) и новее"
        log_warn "с закрытыми модулями НЕ работают — для них нужен open" ;;
    *) die "NVIDIA_KERNEL_MODULES=$MODULES: допустимо open или proprietary" ;;
esac
case "$SOURCE" in
    archive|ppa) ;;
    *) die "NVIDIA_SOURCE=$SOURCE: допустимо archive или ppa" ;;
esac

# --- system -------------------------------------------------------------------
# shellcheck disable=SC1091
. /etc/os-release
DISTRO_ID="${ID:-}"
DISTRO_VERSION="${VERSION_ID:-}"
ARCH="$(dpkg --print-architecture)"
[[ "$ARCH" == amd64 ]] || die "расширение nvidia рассчитано на amd64, а образ — $ARCH"

# --- kernels of the image -----------------------------------------------------
# A kernel counts when both its modules directory and its image are present:
# a bare /lib/modules/<v> (leftover of a removed kernel) cannot boot.
KERNELS=()
for d in /lib/modules/*/; do
    [[ -d "$d" ]] || continue
    k="${d%/}"; k="${k##*/}"
    [[ -e "/boot/vmlinuz-$k" || -e "/lib/modules/$k/vmlinuz" ]] || continue
    KERNELS+=("$k")
done
(( ${#KERNELS[@]} )) || die "в образе не найдено ядро: нет пары /lib/modules/<версия> + /boot/vmlinuz-<версия>"
log_info "система $DISTRO_ID $DISTRO_VERSION; ядро(а) образа: ${KERNELS[*]} (ядро appliance $(uname -r) не используется)"
log_info "ветка $BRANCH, модули $MODULES, источник $SOURCE"

ensure_tools(){
    local missing=()
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v gpg  >/dev/null 2>&1 || missing+=(gpg)
    [[ -e /etc/ssl/certs/ca-certificates.crt ]] || missing+=(ca-certificates)
    if (( ${#missing[@]} )); then
        apt_retry apt-get "${APT_OPTS[@]}" install --no-install-recommends "${missing[@]}"
    fi
    install -d -m 0755 /etc/apt/keyrings
}

# fetch_key URL FINGERPRINT DEST — the key is trusted only if the downloaded
# file holds exactly ONE primary key and its fingerprint is the one pinned
# here. DEST receives `gpg --export` of that key from a throwaway GNUPGHOME,
# never the downloaded file: a second key smuggled into the same file would
# otherwise become trusted by apt along with the pinned one.
fetch_key(){
    local url="$1" fpr="$2" dest="$3" tmp gh out pubs got
    tmp="$(mktemp)"; out="$(mktemp)"; gh="$(mktemp -d)"
    _fk_clean(){ GNUPGHOME="$gh" gpgconf --kill all >/dev/null 2>&1 || true; rm -f "$tmp" "$out"; rm -r -f -- "$gh"; }
    if ! curl -fsSL --retry 5 --retry-delay 2 "$url" -o "$tmp"; then
        _fk_clean; die "ключ не скачался: $url"
    fi
    if ! GNUPGHOME="$gh" gpg --batch --quiet --import "$tmp" >/dev/null 2>&1; then
        _fk_clean; die "ключ $url не импортируется gpg"
    fi
    pubs="$(GNUPGHOME="$gh" gpg --batch --with-colons --list-keys 2>/dev/null | awk -F: '$1=="pub"' | wc -l)"
    got="$(GNUPGHOME="$gh" gpg --batch --with-colons --list-keys 2>/dev/null \
        | awk -F: '$1=="pub" {p=1; next} p && $1=="fpr" {print $10; exit}')"
    if [[ "$pubs" != 1 ]]; then
        _fk_clean; die "в файле ключа $url — $pubs основных ключей, ожидался ровно один ($fpr)"
    fi
    if [[ "$got" != "$fpr" ]]; then
        _fk_clean; die "отпечаток ключа $url — [$got], ожидался [$fpr]"
    fi
    if ! GNUPGHOME="$gh" gpg --batch --armor --export "$fpr" > "$out" 2>/dev/null || [[ ! -s "$out" ]]; then
        _fk_clean; die "не удалось экспортировать ключ $fpr"
    fi
    install -m 0644 "$out" "$dest"
    _fk_clean
}

# source_present ERE — a non-commented one-line or deb822 entry already
# points at this repository. Adding a second entry with another Signed-By
# makes apt refuse the WHOLE source list (lesson of the docker extension).
source_present(){
    grep -rqsE "^[[:space:]]*deb[[:space:]].*$1" /etc/apt/sources.list /etc/apt/sources.list.d/ 2>/dev/null \
        || grep -rqsE "^[[:space:]]*URIs:.*$1" /etc/apt/sources.list.d/ 2>/dev/null
}

# dkms_install PKG... — install packages whose postinst builds the DKMS module.
# The compiler runs inside the libguestfs appliance, and bisquite starts it
# with 2 GB by default (virt-customize --memsize 2048): measured 2026-10-14,
# 590 for Debian 13's 6.12 kernel got cc1 OOM-killed there. Say so instead of
# a bare dpkg error.
dkms_install(){
    apt_retry apt-get "${APT_OPTS[@]}" install "$@" && return 0
    if dmesg 2>/dev/null | grep -q 'invoked oom-killer'; then
        die "сборку DKMS-модуля убил OOM в appliance сборки: дайте ему больше памяти — bs image build --memsize 6144 (по умолчанию 2048)"
    fi
    die "пакеты драйвера не установились: $* (журнал DKMS — /var/lib/dkms/nvidia/*/build/make.log)"
}

candidate(){ apt-cache policy "$1" 2>/dev/null | awk '/Candidate:/ && !f {print $2; f=1}'; }
have_pkg(){ local c; c="$(candidate "$1")"; [[ -n "$c" && "$c" != "(none)" ]]; }

headers_for_kernels(){
    local k
    HEADERS=()
    for k in "${KERNELS[@]}"; do
        have_pkg "linux-headers-$k" || die "нет пакета linux-headers-$k — DKMS не соберёт модуль под ядро образа"
        HEADERS+=("linux-headers-$k")
    done
}

# --- Ubuntu -------------------------------------------------------------------
PPA_FPR=2388FF3BE10A76F638F80723FCAE110B1118213C

setup_ppa(){
    local suite="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"
    if source_present 'ppa\.launchpad(content)?\.net/graphics-drivers/ppa'; then
        log_info "PPA graphics-drivers уже подключён в образе — свой не добавляю"
        return 0
    fi
    ensure_tools
    fetch_key "https://keyserver.ubuntu.com/pks/lookup?op=get&search=0x$PPA_FPR" \
        "$PPA_FPR" /etc/apt/keyrings/graphics-drivers-ppa.asc
    cat > /etc/apt/sources.list.d/graphics-drivers-ppa.sources <<EOF
Types: deb
URIs: https://ppa.launchpadcontent.net/graphics-drivers/ppa/ubuntu
Suites: $suite
Components: main
Signed-By: /etc/apt/keyrings/graphics-drivers-ppa.asc
EOF
    apt_retry apt-get "${APT_OPTS[@]}" update
}

# The prebuilt route is taken only when apt can install it WITHOUT pulling a
# new kernel or DKMS: the flavour meta (linux-modules-nvidia-<br>-generic) is
# what satisfies the driver's dependency on nvidia-dkms-*, and it follows the
# newest kernel of the archive. If the image kernel is older, the meta would
# drag a second kernel in — then DKMS against the image kernel is the honest
# choice.
ubuntu_prebuilt_set(){
    local sfx="$1" k flavour pkgs=() metas=() sim
    for k in "${KERNELS[@]}"; do
        if ! apt-cache show "linux-modules-nvidia-${BRANCH}${sfx}-$k" >/dev/null 2>&1; then
            log_info "предсобранного модуля под $k в архиве нет"
            return 1
        fi
        pkgs+=("linux-modules-nvidia-${BRANCH}${sfx}-$k")
        flavour="$(sed -E 's/^[0-9]+\.[0-9]+\.[0-9]+-[0-9]+-//' <<<"$k")"
        [[ " ${metas[*]} " == *" linux-modules-nvidia-${BRANCH}${sfx}-$flavour "* ]] \
            || metas+=("linux-modules-nvidia-${BRANCH}${sfx}-$flavour")
    done
    if ! sim="$(apt-get install -s -q "nvidia-driver-${BRANCH}${sfx}" "${pkgs[@]}" "${metas[@]}" 2>&1)"; then
        log_info "предсобранные модули не сходятся с драйвером по версии"
        return 1
    fi
    if grep -qE '^Inst (linux-image-|dkms |nvidia-dkms-)' <<<"$sim"; then
        log_info "предсобранный путь потянул бы новое ядро или DKMS: ядро образа не последнее в архиве"
        return 1
    fi
    PREBUILT=("${pkgs[@]}" "${metas[@]}")
}

install_ubuntu(){
    case "$DISTRO_VERSION" in
        22.04|24.04) ;;
        *) die "Ubuntu $DISTRO_VERSION не поддерживается: только 22.04 и 24.04" ;;
    esac
    local sfx="" driver
    [[ "$MODULES" == open ]] && sfx="-open"
    driver="nvidia-driver-${BRANCH}${sfx}"

    apt_retry apt-get "${APT_OPTS[@]}" update
    if [[ "$SOURCE" == ppa ]]; then setup_ppa; fi

    if ! have_pkg "$driver"; then
        if [[ "$SOURCE" == archive ]]; then
            die "в архиве Ubuntu $DISTRO_VERSION нет пакета $driver (нужен компонент restricted). Ветка из PPA graphics-drivers: NVIDIA_SOURCE=ppa"
        fi
        die "пакета $driver нет ни в архиве Ubuntu $DISTRO_VERSION, ни в PPA graphics-drivers"
    fi
    log_info "$driver: кандидат $(candidate "$driver")"

    PREBUILT=()
    if [[ "$SOURCE" == archive ]] && ubuntu_prebuilt_set "$sfx"; then
        log_info "ставлю предсобранные подписанные модули Canonical: ${PREBUILT[*]}"
        apt_retry apt-get "${APT_OPTS[@]}" install "${PREBUILT[@]}" "$driver"
        return 0
    fi

    headers_for_kernels
    log_info "DKMS: модуль собирается под ${KERNELS[*]}"
    # Headers first: the DKMS postinst builds for every kernel that has them.
    apt_retry apt-get "${APT_OPTS[@]}" install "${HEADERS[@]}"
    dkms_install "nvidia-dkms-${BRANCH}${sfx}" "$driver"
}

# --- Debian -------------------------------------------------------------------
# Each CUDA repository has its own signing key (measured 2026-10-14 against
# Release.gpg): debian12 — 3bf863cc.pub, debian13 — 8793F200.pub.
CUDA_KEY_DEBIAN12=(3bf863cc.pub EB693B3035CD5710E231E123A4B469963BF863CC)
CUDA_KEY_DEBIAN13=(8793F200.pub 02182E60104FCDC26EAE1B8597A5D4CB8793F200)

install_debian(){
    [[ "$SOURCE" == archive ]] \
        || die "NVIDIA_SOURCE=$SOURCE: PPA бывает только у Ubuntu; на Debian источник — репозиторий CUDA NVIDIA (archive)"
    local repo meta pin cand avail key=()
    case "$DISTRO_VERSION" in
        12) repo=debian12; key=("${CUDA_KEY_DEBIAN12[@]}") ;;
        13) repo=debian13; key=("${CUDA_KEY_DEBIAN13[@]}") ;;
        *) die "Debian $DISTRO_VERSION не поддерживается: только 12 и 13" ;;
    esac
    local base="https://developer.download.nvidia.com/compute/cuda/repos/$repo/x86_64"

    apt_retry apt-get "${APT_OPTS[@]}" update
    if source_present "developer\.download\.nvidia\.com/compute/cuda/repos/$repo/x86_64"; then
        log_info "репозиторий CUDA NVIDIA ($repo) уже подключён в образе — свой не добавляю"
    else
        ensure_tools
        fetch_key "$base/${key[0]}" "${key[1]}" /etc/apt/keyrings/nvidia-cuda.asc
        cat > /etc/apt/sources.list.d/nvidia-cuda.sources <<EOF
Types: deb
URIs: $base/
Suites: /
Signed-By: /etc/apt/keyrings/nvidia-cuda.asc
EOF
    fi
    apt_retry apt-get "${APT_OPTS[@]}" update

    pin="nvidia-driver-pinning-$BRANCH"
    if ! apt-cache show "$pin" >/dev/null 2>&1; then
        avail="$(apt-cache pkgnames nvidia-driver-pinning- 2>/dev/null | grep -E '^nvidia-driver-pinning-[0-9]+$' \
                 | sed 's/^nvidia-driver-pinning-//' | sort -n | tr '\n' ' ' || true)"
        die "ветки $BRANCH нет в репозитории CUDA NVIDIA для $repo; есть ветки: ${avail:-никаких}"
    fi
    # The pinning package is NVIDIA's own way to hold every driver package on
    # one branch (Pin-Priority 1000 on "<br>*"), for this install and for
    # every later apt upgrade on the device.
    apt_retry apt-get "${APT_OPTS[@]}" install "$pin"

    if [[ "$MODULES" == open ]]; then meta=nvidia-open; else meta=cuda-drivers; fi
    cand="$(candidate "$meta")"
    [[ "$cand" == "$BRANCH".* ]] || die "$meta после закрепления ветки $BRANCH: кандидат [$cand]"
    log_info "$meta: кандидат $cand"

    headers_for_kernels
    apt_retry apt-get "${APT_OPTS[@]}" install "${HEADERS[@]}"
    dkms_install "$meta"
}

# --- run ----------------------------------------------------------------------
case "$DISTRO_ID" in
    ubuntu) install_ubuntu ;;
    debian) install_debian ;;
    *) die "расширение nvidia рассчитано на ubuntu и debian, а здесь ID=$DISTRO_ID" ;;
esac

# The DKMS postinst builds for the kernels it finds, and in the appliance it
# also tries `uname -r`, which has no headers. Build for each image kernel
# explicitly; a no-op when the module is already built.
if command -v dkms >/dev/null 2>&1 && [[ "$(dkms status 2>/dev/null)" == *nvidia* ]]; then
    for k in "${KERNELS[@]}"; do
        dkms autoinstall -k "$k" || die "dkms не собрал модуль под $k"
    done
fi

# --- nouveau ------------------------------------------------------------------
log_info "блокирую nouveau"
cat > /etc/modprobe.d/blacklist-nouveau.conf <<'EOF'
# bisquite nvidia: nouveau and the NVIDIA driver cannot share a GPU
blacklist nouveau
options nouveau modeset=0
EOF

command -v update-initramfs >/dev/null 2>&1 || die "нет update-initramfs: blacklist nouveau не попадёт в initramfs"
for k in "${KERNELS[@]}"; do
    if [[ -e "/boot/initrd.img-$k" ]]; then
        update-initramfs -u -k "$k" || die "update-initramfs -u -k $k не отработал"
    else
        update-initramfs -c -k "$k" || die "update-initramfs -c -k $k не отработал"
    fi
done

# The initramfs trigger of the driver packages runs `update-initramfs -u`,
# which resolves the kernel by `uname -r` — the appliance — and leaves an
# initrd for a kernel the image does not have (measured: 23 MB in
# /boot/initrd.img-<appliance>). Drop it, but only when that kernel is truly
# absent from the image.
APPLIANCE_K="$(uname -r)"
if [[ ! -e "/boot/vmlinuz-$APPLIANCE_K" && ! -d "/lib/modules/$APPLIANCE_K" ]]; then
    for f in "/boot/initrd.img-$APPLIANCE_K" "/var/lib/initramfs-tools/$APPLIANCE_K"; do
        if [[ -f "$f" ]]; then
            log_info "убираю $f: initramfs ядра appliance, не образа"
            rm -f -- "$f"
        fi
    done
fi

# --- verification -------------------------------------------------------------
# The userspace library and the kernel module must be one version, or
# nvidia-smi answers "Driver/library version mismatch".
LIB="$(find /usr/lib/x86_64-linux-gnu /usr/lib64 -maxdepth 1 -name 'libnvidia-ml.so.*.*' 2>/dev/null | head -n1 || true)"
[[ -n "$LIB" ]] || die "libnvidia-ml.so.<версия> не найдена: пользовательская часть драйвера не установилась"
USER_VER="${LIB##*/libnvidia-ml.so.}"
[[ "$USER_VER" == "$BRANCH".* ]] || die "пользовательская часть драйвера $USER_VER, а запрошена ветка $BRANCH"

if [[ "$MODULES" == open ]]; then WANT_LICENSE="Dual MIT/GPL"; else WANT_LICENSE="NVIDIA"; fi
for k in "${KERNELS[@]}"; do
    depmod -a "$k"
    mod_ver="$(modinfo -k "$k" -F version nvidia 2>/dev/null || true)"
    [[ -n "$mod_ver" ]] || die "модуля nvidia под ядро образа $k нет (modinfo -k $k nvidia)"
    [[ "$mod_ver" == "$USER_VER" ]] || die "модуль nvidia под $k — $mod_ver, пользовательская часть — $USER_VER"
    lic="$(modinfo -k "$k" -F license nvidia)"
    [[ "$lic" == "$WANT_LICENSE" ]] || die "модуль nvidia под $k — лицензия [$lic], для $MODULES ожидалась [$WANT_LICENSE]"
    log_info "ядро $k: nvidia $mod_ver ($MODULES) — $(modinfo -k "$k" -n nvidia)"
done

log_info "драйвер NVIDIA $USER_VER установлен; nvidia-smi ответит после загрузки машины"
