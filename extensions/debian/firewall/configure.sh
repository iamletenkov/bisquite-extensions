#!/usr/bin/env bash
# bisquite host firewall: build the nftables table `inet bisquite` from
# /etc/bisquite/firewall/rules.d/*.nft and apply it in ONE nft transaction.
#
#   configure.sh apply   (ExecStart/ExecReload of bisquite-firewall.service)
#   configure.sh off     remove the table until the next apply/boot
#   configure.sh show    print the table as loaded in the kernel
#   configure.sh check   only check the files (nft -c), apply nothing
#
# Also /usr/local/sbin/bisquite-firewall (a link to this file).
#
# Why a table of our own and never `flush ruleset`: Docker keeps its NAT and
# forwarding chains in iptables-nft tables (ip filter, ip nat, ip6 …), and a
# flush of the whole ruleset would cut every container off until dockerd
# restarts. Our table only adds a base chain on the input hook: published
# ports go through prerouting DNAT and forward, which we do not touch.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/bisquite-conf" || exit 1

TABLE="inet bisquite"
RULES_DIR="${BISQUITE_CONF_ROOT:-}/etc/bisquite/firewall/rules.d"
RUN_DIR="${BISQUITE_FIREWALL_RUN:-/run/bisquite-firewall}"

log(){ >&2 echo "firewall: $*"; }

# The skeleton every apply starts from: the table is created (if absent),
# deleted and declared anew, so the transaction replaces it atomically.
skeleton(){
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
fallback(){
    skeleton
    cat <<EOF
add rule $TABLE input iif lo accept
add rule $TABLE input ct state established,related accept
EOF
}

render(){
    skeleton
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

do_off(){
    need_nft || return 1
    if nft list table inet bisquite >/dev/null 2>&1; then
        nft delete table inet bisquite || return 1
        log "таблица $TABLE снята — входящее не фильтруется (до следующей загрузки или apply)"
    else
        log "таблицы $TABLE нет — нечего снимать"
    fi
}

do_apply(){
    local enable out ruleset
    need_nft || return 1
    enable="$(conf_get firewall FIREWALL_ENABLE)" || return 1
    if [[ "$enable" != 1 ]]; then
        log "FIREWALL_ENABLE=$enable — файрвол выключен настройкой"
        do_off
        return
    fi
    install -d -m 0700 "$RUN_DIR" || return 1
    ruleset="$RUN_DIR/ruleset.nft"
    render > "$ruleset" || return 1
    if out="$(nft -f "$ruleset" 2>&1)"; then
        log "применено: $TABLE из $(grep -c '^include' "$ruleset") файл(ов) $RULES_DIR"
        return 0
    fi
    log "правила не загрузились — каталог $RULES_DIR не применён:"
    printf '%s\n' "$out" >&2
    if fallback > "$RUN_DIR/fallback.nft" && nft -f "$RUN_DIR/fallback.nft"; then
        log "загружен запасной набор: только петля и ответы (входящее закрыто); исправьте файл и sudo systemctl restart bisquite-firewall"
    else
        log "и запасной набор не загрузился — входящее НЕ фильтруется"
    fi
    return 1
}

do_check(){
    local ruleset out
    need_nft || return 1
    install -d -m 0700 "$RUN_DIR" || return 1
    ruleset="$RUN_DIR/check.nft"
    render > "$ruleset" || return 1
    if out="$(nft -c -f "$ruleset" 2>&1)"; then
        log "файлы $RULES_DIR корректны"
    else
        printf '%s\n' "$out" >&2
        return 1
    fi
}

case "${1:-}" in
    apply) do_apply ;;
    off) do_off ;;
    show) need_nft && nft list table inet bisquite ;;
    check) do_check ;;
    *) >&2 echo "usage: ${0##*/} apply|off|show|check"; exit 2 ;;
esac
