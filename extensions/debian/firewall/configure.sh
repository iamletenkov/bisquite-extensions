#!/usr/bin/env bash
# bisquite host firewall, two backends with the same default rules:
#
#   nft       nftables table `inet bisquite`, built from
#             /etc/bisquite/firewall/rules.d/*.nft in ONE nft transaction;
#   iptables  iptables-legacy chain BISQUITE-INPUT (table filter, IPv4 and
#             IPv6), built from rules.d/*.rules and *.rules6 in one
#             iptables-restore transaction per family, plus a single jump
#             first in INPUT. For kernels without nft_ct (stock L4T r36.4.3).
#
# The backend is chosen on every apply: FIREWALL_BACKEND=auto|nft|iptables;
# auto — nft when the running kernel has nf_tables and nft_ct, otherwise
# iptables when it has the legacy modules (backend.sh).
#
#   configure.sh apply    (ExecStart/ExecReload of bisquite-firewall.service)
#   configure.sh off      remove our table/chains until the next apply/boot
#   configure.sh show     the backend and our rules as loaded in the kernel
#   configure.sh check    only check the files, apply nothing
#   configure.sh backend  print the backend apply would use
#
# Also /usr/local/sbin/bisquite-firewall (a link to this file).
#
# Why a table/chain of our own and never `flush ruleset` or `iptables -F`:
# Docker keeps its chains (DOCKER, DOCKER-USER, FORWARD, nat) in the same
# kernel, and a flush would cut every container off until dockerd restarts.
# We only filter the input hook: published ports go through prerouting DNAT
# and forward, which we do not touch.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/bisquite-conf" || exit 1
# shellcheck source=backend.sh
source "$SCRIPT_DIR/backend.sh" || exit 1

TABLE="inet bisquite"
CHAIN="BISQUITE-INPUT"
RULES_DIR="${BISQUITE_CONF_ROOT:-}/etc/bisquite/firewall/rules.d"
RUN_DIR="${BISQUITE_FIREWALL_RUN:-/run/bisquite-firewall}"
# The backend picked at build time: used only when the running kernel has no
# module lists to judge by (a container, a kernel without /lib/modules).
BUILD_BACKEND_FILE="${BISQUITE_CONF_ROOT:-}/var/lib/bisquite/firewall/backend"
MODULES_ROOT="${BISQUITE_FIREWALL_MODULES:-/lib/modules}"
IPT4=(iptables-legacy -w)
IPT6=(ip6tables-legacy -w)
RESTORE4=(iptables-legacy-restore -w --noflush)
RESTORE6=(ip6tables-legacy-restore -w --noflush)

log(){ >&2 echo "firewall: $*"; }

# ---------------------------------------------------------------- backend --

# Print the backend to use. BISQUITE_FIREWALL_BACKEND (install.sh) overrides
# everything. An explicit FIREWALL_BACKEND is honoured even when the kernel
# looks short of modules — the operator said so; it is logged.
resolve_backend(){
    local want dir build
    if [[ -n "${BISQUITE_FIREWALL_BACKEND:-}" ]]; then
        echo "$BISQUITE_FIREWALL_BACKEND"
        return 0
    fi
    want="$(conf_get firewall FIREWALL_BACKEND 2>/dev/null)" || want=auto
    [[ -n "$want" ]] || want=auto
    build="$(cat "$BUILD_BACKEND_FILE" 2>/dev/null)" || build=""
    [[ "$build" == nft || "$build" == iptables ]] || build=""
    dir="$MODULES_ROOT/$(uname -r)"
    if ! fw_kernel_known "$dir"; then
        if [[ "$want" != auto ]]; then
            echo "$want"
        else
            log "у ядра $(uname -r) нет списков модулей ($dir) — бэкенд ${build:-nft}${build:+ (выбран при сборке)}"
            echo "${build:-nft}"
        fi
        return 0
    fi
    fw_pick "$want" "$dir" && return 0
    log "ядро $(uname -r): $FW_PICK_WHY"
    if [[ "$want" != auto ]]; then
        log "FIREWALL_BACKEND=$want задан явно — пробую его"
        echo "$want"
    else
        log "пробую бэкенд ${build:-nft}: правила, скорее всего, не загрузятся"
        echo "${build:-nft}"
    fi
}

# -------------------------------------------------------------- nftables ---

# The skeleton every apply starts from: the table is created (if absent),
# deleted and declared anew, so the transaction replaces it atomically.
nft_skeleton(){
    cat <<EOF
table $TABLE
delete table $TABLE
table $TABLE {
    chain input {
        type filter hook input priority filter; policy drop;
    }
    chain output {
        type filter hook output priority filter; policy accept;
    }
}
EOF
}

# Without the files: loopback and replies only. Used when the files do not
# load — closed rather than open.
nft_fallback(){
    nft_skeleton
    cat <<EOF
add rule $TABLE input iif lo accept
add rule $TABLE input ct state established,related accept
EOF
}

nft_render(){
    nft_skeleton
    local f
    shopt -s nullglob
    for f in "$RULES_DIR"/*.nft; do
        # Absolute include of each file, not a glob: the order is ours
        # (C collation, as ls), and the file name shows up in nft errors.
        printf 'include "%s"\n' "$f"
    done
    shopt -u nullglob
}

need_nft(){
    command -v nft >/dev/null 2>&1 && return 0
    log "нет nft (пакет nftables) — правила не применить"
    return 1
}

nft_present(){
    command -v nft >/dev/null 2>&1 && nft list table inet bisquite >/dev/null 2>&1
}

nft_off(){
    nft_present || return 0
    nft delete table inet bisquite || return 1
    log "таблица $TABLE снята"
}

nft_apply(){
    local out ruleset
    need_nft || return 1
    ruleset="$RUN_DIR/ruleset.nft"
    nft_render > "$ruleset" || return 1
    if out="$(nft -f "$ruleset" 2>&1)"; then
        log "применено (nftables): $TABLE из $(grep -c '^include' "$ruleset") файл(ов) $RULES_DIR/*.nft"
        return 0
    fi
    log "правила не загрузились — каталог $RULES_DIR не применён:"
    printf '%s\n' "$out" >&2
    if nft_fallback > "$RUN_DIR/fallback.nft" && nft -f "$RUN_DIR/fallback.nft"; then
        log "загружен запасной набор: только петля и ответы (входящее закрыто); исправьте файл и sudo systemctl restart bisquite-firewall"
    else
        log "и запасной набор не загрузился — входящее НЕ фильтруется"
    fi
    return 1
}

nft_check(){
    local ruleset out
    need_nft || return 1
    ruleset="$RUN_DIR/check.nft"
    nft_render > "$ruleset" || return 1
    if out="$(nft -c -f "$ruleset" 2>&1)"; then
        log "файлы $RULES_DIR/*.nft корректны"
    else
        printf '%s\n' "$out" >&2
        return 1
    fi
}

# -------------------------------------------------------------- iptables ---

need_ipt(){
    local b
    for b in iptables-legacy ip6tables-legacy iptables-legacy-restore ip6tables-legacy-restore; do
        command -v "$b" >/dev/null 2>&1 && continue
        log "нет $b (пакет iptables) — правила не применить"
        return 1
    done
}

# ipt_file FILE: print FILE as rules of our chain. A rule is either
# `-A BISQUITE-INPUT …` or the short form `…` (the prefix is added). Anything
# that names another chain, a table, a policy or a flush is refused: the
# files must not be able to touch Docker's or anyone else's chains.
ipt_file(){
    local f="$1" n=0 line first
    while IFS= read -r line || [[ -n "$line" ]]; do
        n=$((n + 1))
        line="${line#"${line%%[![:space:]]*}"}"
        line="${line%"${line##*[![:space:]]}"}"
        [[ -z "$line" || "$line" == \#* ]] && continue
        if [[ "$line" == "-A $CHAIN "* ]]; then
            printf '%s\n' "$line"
            continue
        fi
        first="${line%%[[:space:]]*}"
        case "$first" in
            -A|-I|-D|-R|-F|-X|-P|-N|-Z|-E|-L|-S|-t|--append*|--insert*|--delete*|--replace*|--flush*|--policy*|--new-chain*|--zero*|--rename-chain*|--list*|--table*)
                log "$f:$n: только правила цепочки $CHAIN (\`-A $CHAIN …\` или без префикса), не $first"
                return 1 ;;
            -*)
                printf -- '-A %s %s\n' "$CHAIN" "$line" ;;
            *)
                log "$f:$n: ожидается правило iptables (например \`-p tcp --dport 22 -j ACCEPT\`), а не «$line»"
                return 1 ;;
        esac
    done < "$f"
}

# ipt_render EXT: the restore input for one family from rules.d/*.EXT.
# Declaring the chain in --noflush mode empties it, so the transaction
# replaces our chain and nothing else; DROP closes it like policy drop.
ipt_render(){
    local ext="$1" f files=()
    shopt -s nullglob
    files=("$RULES_DIR"/*."$ext")
    shopt -u nullglob
    echo "*filter"
    echo ":$CHAIN - [0:0]"
    for f in "${files[@]}"; do
        echo "# $f"
        ipt_file "$f" || return 1
    done
    echo "-A $CHAIN -j DROP"
    echo "COMMIT"
}

ipt_fallback(){
    cat <<EOF
*filter
:$CHAIN - [0:0]
-A $CHAIN -i lo -j ACCEPT
-A $CHAIN -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT
-A $CHAIN -j DROP
COMMIT
EOF
}

# ipt_jump CMD...: exactly one jump INPUT -> our chain, first in INPUT.
ipt_jump(){
    "$@" -C INPUT -j "$CHAIN" 2>/dev/null && return 0
    "$@" -I INPUT 1 -j "$CHAIN"
}

ipt_load(){  # <v4 file> <v6 file>: both families, then both jumps
    "${RESTORE4[@]}" < "$1" || return 1
    "${RESTORE6[@]}" < "$2" || return 1
    ipt_jump "${IPT4[@]}" || return 1
    ipt_jump "${IPT6[@]}" || return 1
}

# ipt_present NAMES CMD...: our chain exists. Asked only when the legacy
# filter table is already loaded (/proc/net/ip{,6}_tables_names): a bare
# `iptables-legacy -L` would load ip_tables on an nftables host, and
# iptables-nft would then warn about legacy tables on every listing.
ipt_present(){
    local names="$1"
    shift
    grep -qx filter "/proc/net/$names" 2>/dev/null || return 1
    "$@" -n -L "$CHAIN" >/dev/null 2>&1
}

ipt_off_family(){  # NAMES CMD...
    ipt_present "$@" || return 0
    shift
    while "$@" -D INPUT -j "$CHAIN" 2>/dev/null; do :; done
    "$@" -F "$CHAIN" && "$@" -X "$CHAIN"
}

ipt_off(){
    command -v iptables-legacy >/dev/null 2>&1 || return 0
    local rc=0 was=0
    if ipt_present ip_tables_names "${IPT4[@]}" || ipt_present ip6_tables_names "${IPT6[@]}"; then
        was=1
    fi
    ipt_off_family ip_tables_names "${IPT4[@]}" || rc=1
    ipt_off_family ip6_tables_names "${IPT6[@]}" || rc=1
    (( was && rc == 0 )) && log "цепочки $CHAIN (IPv4, IPv6) сняты"
    return "$rc"
}

ipt_apply(){
    local v4="$RUN_DIR/rules.v4" v6="$RUN_DIR/rules.v6" out=""
    need_ipt || return 1
    if ipt_render rules > "$v4" && ipt_render rules6 > "$v6" \
        && out="$("${RESTORE4[@]}" --test < "$v4" 2>&1 && "${RESTORE6[@]}" --test < "$v6" 2>&1)" \
        && out="$(ipt_load "$v4" "$v6" 2>&1)"; then
        log "применено (iptables): $CHAIN из $(grep -c '^# /' "$v4") файл(ов) *.rules и $(grep -c '^# /' "$v6") *.rules6 в $RULES_DIR"
        return 0
    fi
    log "правила не загрузились — каталог $RULES_DIR не применён:"
    [[ -n "$out" ]] && printf '%s\n' "$out" >&2
    if ipt_fallback > "$RUN_DIR/fallback.v4" && cp "$RUN_DIR/fallback.v4" "$RUN_DIR/fallback.v6" \
        && ipt_load "$RUN_DIR/fallback.v4" "$RUN_DIR/fallback.v6"; then
        log "загружен запасной набор: только петля и ответы (входящее закрыто); исправьте файл и sudo systemctl restart bisquite-firewall"
    else
        log "и запасной набор не загрузился — входящее НЕ фильтруется"
    fi
    return 1
}

# rc 3 — a file breaks the format (no kernel needed: install.sh fails the
# build); rc 1 — the restore test itself did not pass (may be the appliance).
ipt_check(){
    local v4="$RUN_DIR/check.v4" v6="$RUN_DIR/check.v6" out
    ipt_render rules > "$v4" || return 3
    ipt_render rules6 > "$v6" || return 3
    need_ipt || return 1
    if out="$("${RESTORE4[@]}" --test < "$v4" 2>&1 && "${RESTORE6[@]}" --test < "$v6" 2>&1)"; then
        log "файлы $RULES_DIR/*.rules, *.rules6 корректны"
    else
        printf '%s\n' "$out" >&2
        return 1
    fi
}

# ------------------------------------------------------------------ verbs --

do_off(){
    local rc=0
    nft_off || rc=1
    ipt_off || rc=1
    (( rc == 0 )) && log "входящее не фильтруется (до следующей загрузки или apply)"
    return "$rc"
}

do_apply(){
    local enable backend
    enable="$(conf_get firewall FIREWALL_ENABLE)" || return 1
    if [[ "$enable" != 1 ]]; then
        log "FIREWALL_ENABLE=$enable — файрвол выключен настройкой"
        do_off
        return
    fi
    backend="$(resolve_backend)" || return 1
    install -d -m 0700 "$RUN_DIR" || return 1
    printf '%s\n' "$backend" > "$RUN_DIR/backend"
    # The other backend's leftovers (a changed FIREWALL_BACKEND, a new
    # kernel) go only after ours is in place: no window with neither.
    case "$backend" in
        nft) nft_apply || return 1; ipt_off ;;
        iptables) ipt_apply || return 1; nft_off ;;
        *) log "бэкенд «$backend» неизвестен — ожидается nft или iptables"; return 1 ;;
    esac
}

do_check(){
    local backend
    backend="$(resolve_backend)" || return 1
    install -d -m 0700 "$RUN_DIR" || return 1
    case "$backend" in
        nft) nft_check ;;
        iptables) ipt_check ;;
        *) log "бэкенд «$backend» неизвестен"; return 1 ;;
    esac
}

do_show(){
    local b
    b="$(cat "$RUN_DIR/backend" 2>/dev/null)" || b="(apply ещё не было)"
    echo "# бэкенд: $b"
    nft_present && nft list table inet bisquite
    if command -v iptables-legacy >/dev/null 2>&1; then
        if ipt_present ip_tables_names "${IPT4[@]}"; then
            echo "# iptables-legacy, IPv4"; "${IPT4[@]}" -S INPUT; "${IPT4[@]}" -S "$CHAIN"
        fi
        if ipt_present ip6_tables_names "${IPT6[@]}"; then
            echo "# ip6tables-legacy, IPv6"; "${IPT6[@]}" -S INPUT; "${IPT6[@]}" -S "$CHAIN"
        fi
    fi
    return 0
}

case "${1:-}" in
    apply) do_apply ;;
    off) do_off ;;
    show) do_show ;;
    check) do_check ;;
    backend) resolve_backend ;;
    *) >&2 echo "usage: ${0##*/} apply|off|show|check|backend"; exit 2 ;;
esac
