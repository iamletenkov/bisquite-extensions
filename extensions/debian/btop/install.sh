#!/usr/bin/env bash
# Поставить btop — монитор ресурсов (CPU, память, диски, сеть, процессы)
# обычным apt-пакетом из universe/multiverse.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} btop: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} btop: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} btop: $*"; }

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
APT_OPTS=(-q -y -o Dpkg::Options::=--force-confnew)

log_info "apt-get update"
apt_retry apt-get update -q || exit 1

log_info "ставлю btop"
apt_retry apt-get install "${APT_OPTS[@]}" btop || {
    log_error "btop не установился"
    exit 1
}

log_info "готово: $(dpkg-query -W -f='${Version}' btop 2>/dev/null || echo '?')"
