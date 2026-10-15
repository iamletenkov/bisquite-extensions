# shellcheck shell=bash
# shellcheck disable=SC2034  # FW_PICK_WHY is read by the callers
# Which firewall backend a kernel can run. Sourced by install.sh (for every
# kernel of the image) and by configure.sh (for the running kernel), never
# executed. Only the module lists of the kernel are read — modules.dep and
# modules.builtin under /lib/modules/<version> — never `lsmod` or `uname -r`
# of the caller: at build time the caller is the appliance, not the robot.
#
#   nft       nf_tables + nft_ct: the table `inet bisquite`, rules *.nft.
#   iptables  iptables-legacy: ip_tables, iptable_filter, ip6_tables,
#             ip6table_filter, nf_conntrack, xt_conntrack, xt_tcpudp —
#             the chain BISQUITE-INPUT, rules *.rules / *.rules6.
#
# WHY LEGACY AND NOT iptables-nft. iptables-nft 1.8.7 (Ubuntu 22.04) does not
# turn `-m conntrack` into native nft: the rule is `match name conntrack`
# through nft_compat, the port range `match name udp` the same way, and every
# rule gets a `counter` expression (measured 2026-10-15, `nft --debug=netlink`).
# The stock L4T r36.4.3 kernel has neither nft_compat nor nft_counter, so on
# exactly the kernel this backend exists for iptables-nft cannot load the
# defaults; all seven legacy modules are there. Counter support is built into
# nf_tables on newer kernels (no nft_counter.ko on 6.1), so the module lists
# could not even tell whether iptables-nft would work.

FW_NFT_MODULES=(nf_tables nft_ct)
FW_IPT_MODULES=(ip_tables iptable_filter ip6_tables ip6table_filter nf_conntrack xt_conntrack xt_tcpudp)

# fw_kernel_has DIR MODULE: a loadable module (modules.dep) or built in.
fw_kernel_has(){
    local d="$1" re="/$2\.ko(\.[a-z]+)?"
    grep -qE "$re:" "$d/modules.dep" 2>/dev/null || grep -qE "$re\$" "$d/modules.builtin" 2>/dev/null
}

# fw_kernel_known DIR: there are module lists to judge by.
fw_kernel_known(){
    [[ -f "$1/modules.dep" || -f "$1/modules.builtin" ]]
}

# fw_missing DIR MODULE...: print the modules the kernel lacks (space-separated).
fw_missing(){
    local d="$1" m miss=()
    shift
    for m in "$@"; do fw_kernel_has "$d" "$m" || miss+=("$m"); done
    printf '%s' "${miss[*]}"
}

# fw_pick WANT DIR: print the backend for WANT (auto|nft|iptables) on the
# kernel in DIR and leave it in FW_PICK. rc=1 when the kernel cannot run it;
# FW_PICK_WHY then says why. Call it directly, not in $(…): the two variables
# would stay in the subshell.
FW_PICK=""
FW_PICK_WHY=""
fw_pick(){
    local want="$1" d="$2" nft_miss ipt_miss
    nft_miss="$(fw_missing "$d" "${FW_NFT_MODULES[@]}")"
    ipt_miss="$(fw_missing "$d" "${FW_IPT_MODULES[@]}")"
    FW_PICK=""
    FW_PICK_WHY=""
    case "$want" in
        nft)
            [[ -z "$nft_miss" ]] && FW_PICK=nft
            FW_PICK_WHY="FIREWALL_BACKEND=nft, а в ядре нет $nft_miss" ;;
        iptables)
            [[ -z "$ipt_miss" ]] && FW_PICK=iptables
            FW_PICK_WHY="FIREWALL_BACKEND=iptables, а в ядре нет $ipt_miss" ;;
        auto)
            if [[ -z "$nft_miss" ]]; then FW_PICK=nft
            elif [[ -z "$ipt_miss" ]]; then FW_PICK=iptables
            fi
            FW_PICK_WHY="ни один бэкенд: для nftables нет $nft_miss, для iptables нет $ipt_miss" ;;
        *)
            FW_PICK_WHY="FIREWALL_BACKEND=$want — ожидается auto, nft или iptables" ;;
    esac
    if [[ -n "$FW_PICK" ]]; then
        FW_PICK_WHY=""
        echo "$FW_PICK"
        return 0
    fi
    return 1
}
