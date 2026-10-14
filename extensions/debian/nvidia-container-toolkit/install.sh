#!/usr/bin/env bash
# NVIDIA Container Toolkit for Docker: NVIDIA's apt repository with a pinned
# key, the toolkit (optionally of an exact version), and the `nvidia` runtime
# registered in /etc/docker/daemon.json WITHOUT touching default-runtime —
# containers stay on runc unless asked for `--runtime=nvidia` / `--gpus`.
#
# Parameters (environment, passed by EXTENSION as is):
#   NVIDIA_CTK_VERSION   exact toolkit version (1.17.8 or 1.17.8-1);
#                        empty — the newest in the repository
#
# Order matters and is checked here, not hoped for: Docker (capability
# container-runtime, extension `docker`) and the driver (gpu-driver-nvidia,
# extension `nvidia`) must be installed by earlier layers.
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

CTK_VERSION="${NVIDIA_CTK_VERSION:-}"
if [[ -n "$CTK_VERSION" && ! "$CTK_VERSION" =~ ^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.~+]+)?$ ]]; then
    die "NVIDIA_CTK_VERSION=$CTK_VERSION: ожидается версия вида 1.17.8 или 1.17.8-1"
fi

# shellcheck disable=SC1091
. /etc/os-release
case "${ID:-}" in
    debian|ubuntu) ;;
    *) die "расширение nvidia-container-toolkit рассчитано на debian и ubuntu, а здесь ID=${ID:-}" ;;
esac
ARCH="$(dpkg --print-architecture)"
[[ "$ARCH" == amd64 ]] || die "расширение рассчитано на amd64 (как и nvidia), а образ — $ARCH"

# --- earlier layers -----------------------------------------------------------
command -v dockerd >/dev/null 2>&1 \
    || die "Docker не установлен: поставьте EXTENSION docker раньше nvidia-container-toolkit"
if [[ "$(ldconfig -p 2>/dev/null)" != *libnvidia-ml.so.1* ]]; then
    die "драйвер NVIDIA не установлен (нет libnvidia-ml.so.1): поставьте EXTENSION nvidia раньше nvidia-container-toolkit"
fi

# --- repository ---------------------------------------------------------------
CTK_FPR=C95B321B61E88C1809C4F759DDCAE044F796ECB0
CTK_BASE=https://nvidia.github.io/libnvidia-container

# Another entry for the same URI with another Signed-By makes apt refuse the
# whole source list (lesson of the docker extension) — reuse an existing one.
if grep -rqsE "^[[:space:]]*deb[[:space:]].*nvidia\.github\.io/libnvidia-container" /etc/apt/sources.list /etc/apt/sources.list.d/ \
    || grep -rqsE "^[[:space:]]*URIs:.*nvidia\.github\.io/libnvidia-container" /etc/apt/sources.list.d/; then
    log_info "репозиторий libnvidia-container уже подключён в образе — свой не добавляю"
else
    missing=()
    command -v curl >/dev/null 2>&1 || missing+=(curl)
    command -v gpg  >/dev/null 2>&1 || missing+=(gpg)
    [[ -e /etc/ssl/certs/ca-certificates.crt ]] || missing+=(ca-certificates)
    if (( ${#missing[@]} )); then
        apt_retry apt-get "${APT_OPTS[@]}" update
        apt_retry apt-get "${APT_OPTS[@]}" install --no-install-recommends "${missing[@]}"
    fi
    install -d -m 0755 /etc/apt/keyrings
    # Trust exactly the pinned key: the file must hold ONE primary key with
    # the pinned fingerprint, and the keyring gets `gpg --export` of that key
    # from a throwaway GNUPGHOME, not the downloaded file — a second key in
    # the same file would otherwise become trusted by apt too.
    tmp="$(mktemp)"; out="$(mktemp)"; gh="$(mktemp -d)"
    ctk_clean(){ GNUPGHOME="$gh" gpgconf --kill all >/dev/null 2>&1 || true; rm -f "$tmp" "$out"; rm -r -f -- "$gh"; }
    curl -fsSL --retry 5 --retry-delay 2 "$CTK_BASE/gpgkey" -o "$tmp" \
        || { ctk_clean; die "ключ не скачался: $CTK_BASE/gpgkey"; }
    GNUPGHOME="$gh" gpg --batch --quiet --import "$tmp" >/dev/null 2>&1 \
        || { ctk_clean; die "ключ $CTK_BASE/gpgkey не импортируется gpg"; }
    pubs="$(GNUPGHOME="$gh" gpg --batch --with-colons --list-keys 2>/dev/null | awk -F: '$1=="pub"' | wc -l)"
    got="$(GNUPGHOME="$gh" gpg --batch --with-colons --list-keys 2>/dev/null \
        | awk -F: '$1=="pub" {p=1; next} p && $1=="fpr" {print $10; exit}')"
    [[ "$pubs" == 1 ]] \
        || { ctk_clean; die "в файле ключа $CTK_BASE/gpgkey — $pubs основных ключей, ожидался ровно один ($CTK_FPR)"; }
    [[ "$got" == "$CTK_FPR" ]] \
        || { ctk_clean; die "отпечаток ключа $CTK_BASE/gpgkey — [$got], ожидался [$CTK_FPR]"; }
    { GNUPGHOME="$gh" gpg --batch --armor --export "$CTK_FPR" > "$out" 2>/dev/null && [[ -s "$out" ]]; } \
        || { ctk_clean; die "не удалось экспортировать ключ $CTK_FPR"; }
    install -m 0644 "$out" /etc/apt/keyrings/nvidia-container-toolkit.asc
    ctk_clean
    cat > /etc/apt/sources.list.d/nvidia-container-toolkit.sources <<EOF
Types: deb
URIs: $CTK_BASE/stable/deb/$ARCH/
Suites: /
Signed-By: /etc/apt/keyrings/nvidia-container-toolkit.asc
EOF
fi
apt_retry apt-get "${APT_OPTS[@]}" update

# --- packages -----------------------------------------------------------------
PKGS=(nvidia-container-toolkit nvidia-container-toolkit-base libnvidia-container-tools libnvidia-container1)
if [[ -n "$CTK_VERSION" ]]; then
    avail="$(apt-cache madison nvidia-container-toolkit 2>/dev/null | awk -F'|' '{gsub(/ /,"",$2); print $2}')"
    full=""
    while read -r v; do
        if [[ "$v" == "$CTK_VERSION" || "$v" == "$CTK_VERSION"-* ]]; then full="$v"; break; fi
    done <<<"$avail"
    [[ -n "$full" ]] || die "nvidia-container-toolkit $CTK_VERSION нет в репозитории; есть: $(head -n5 <<<"$avail" | tr '\n' ' ')…"
    # All four are released in lockstep; pinning only the top one lets apt
    # pair it with a newer -base and fail on the exact dependency.
    PKGS=("${PKGS[@]/%/=$full}")
fi
log_info "ставлю ${PKGS[*]}"
apt_retry apt-get "${APT_OPTS[@]}" install "${PKGS[@]}"

# --- Docker runtime -----------------------------------------------------------
DAEMON_JSON=/etc/docker/daemon.json
default_runtime(){
    [[ -f "$DAEMON_JSON" ]] || { echo "<нет файла>"; return 0; }
    local v
    v="$(grep -oE '"default-runtime"[[:space:]]*:[[:space:]]*"[^"]*"' "$DAEMON_JSON" | sed -E 's/.*"([^"]*)"$/\1/' || true)"
    echo "${v:-<не задан>}"
}
before="$(default_runtime)"
# Edits the file only: dockerd is not running during the build and picks the
# runtime up on its first start. No --set-as-default, on purpose.
nvidia-ctk runtime configure --runtime=docker --config="$DAEMON_JSON"
after="$(default_runtime)"

grep -qE '"nvidia"[[:space:]]*:' "$DAEMON_JSON" || die "nvidia-ctk не добавил runtime nvidia в $DAEMON_JSON"
[[ "$before" == "$after" ]] || die "default-runtime изменился: было [$before], стало [$after]"
log_info "runtime nvidia зарегистрирован в $DAEMON_JSON; default-runtime: $after"
log_info "nvidia-container-toolkit $(dpkg-query -W -f='${Version}' nvidia-container-toolkit) установлен"
