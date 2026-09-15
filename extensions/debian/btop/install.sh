#!/usr/bin/env bash
# Поставить btop — монитор ресурсов (CPU, память, диски, сеть, процессы)
# обычным apt-пакетом из universe/multiverse, а где его нет (focal) —
# статической сборкой релиза upstream.
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

# НЕТ ПАКЕТА В РЕПОЗИТОРИИ — СТАТИЧЕСКИЙ БИНАРЬ РЕЛИЗА.
#
# В focal (Ubuntu 20.04 — образ Jetson Nano от Q-engineering) и в bullseye
# пакета btop нет вовсе. Вместо отказа — сборка musl из релиза upstream: она
# статическая и от glibc образа не зависит. Содержимое сверяется
# с закреплённым sha256; архитектура другая — отказ, а не угадывание.
# Кандидат apt — в переменную, а не `apt-cache … | grep -q`: pipefail и SIGPIPE.
BTOP_RELEASE=v1.4.4
declare -A BTOP_SHA256=(
    [aarch64]=e8845d3f69f6a32d00258a1f79c093970666ece3d05a430c7b24a16c56577bf5
    [x86_64]=fec7d1b59c671290a0f80d5a32617ea6d60412485fc04318fd194b9550ff6b49
)

install_static(){
    local machine sum work
    machine="$(uname -m)"
    sum="${BTOP_SHA256[$machine]:-}"
    if [[ -z "$sum" ]]; then
        log_error "нет пакета btop в apt и нет закреплённой сборки релиза под $machine"
        return 1
    fi
    work="$(mktemp -d /var/tmp/btop.XXXXXX)"
    # shellcheck disable=SC2064 # expand now: the variable is local
    trap "rm -rf '$work'" RETURN
    apt_retry curl -fsSL --max-time 300 -o "$work/btop.tbz" \
        "https://github.com/aristocratos/btop/releases/download/$BTOP_RELEASE/btop-$machine-linux-musl.tbz" || return 1
    echo "$sum  $work/btop.tbz" | sha256sum -c --quiet - || {
        log_error "контрольная сумма btop $BTOP_RELEASE ($machine) не совпала"
        return 1
    }
    tar -xjf "$work/btop.tbz" -C "$work" || return 1
    install -m 0755 "$work/btop/bin/btop" /usr/local/bin/btop || return 1
    /usr/local/bin/btop --version >/dev/null || { log_error "/usr/local/bin/btop не запускается"; return 1; }
    log_info "готово: btop $BTOP_RELEASE (статическая сборка musl) в /usr/local/bin"
}

CANDIDATE="$(apt-cache policy btop 2>/dev/null | awk '/Candidate:/{print $2}')"
if [[ -z "$CANDIDATE" || "$CANDIDATE" == "(none)" ]]; then
    log_warn "в репозиториях образа пакета btop нет — ставлю сборку релиза $BTOP_RELEASE"
    install_static || exit 1
    exit 0
fi

log_info "ставлю btop"
apt_retry apt-get install "${APT_OPTS[@]}" btop || {
    log_error "btop не установился"
    exit 1
}

log_info "готово: $(dpkg-query -W -f='${Version}' btop 2>/dev/null || echo '?')"
