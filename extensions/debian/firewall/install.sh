#!/usr/bin/env bash
# Host firewall: our own nftables table `inet bisquite` or, on kernels without
# nft_ct (stock L4T r36.4.3), our own iptables-legacy chain BISQUITE-INPUT —
# rebuilt from /etc/bisquite/firewall/rules.d/ on every boot by
# bisquite-firewall.service (configure.sh; the backend — backend.sh).
#
# Build phase: pick the backend for every kernel of the image (refuse when a
# kernel can run neither), install nftables and iptables, lay down the default
# rules of both backends (only if the operator's copy is not there yet),
# register the `firewall` domain and enable the service. Nothing is loaded
# into the kernel here — the appliance kernel is not the robot's.
#
# Parameters (environment, from VMFILE) — the `firewall` domain, schema in knobs:
#   FIREWALL_ENABLE    1     0 — the image boots with the firewall off
#   FIREWALL_BACKEND   auto  auto | nft | iptables
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} firewall: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} firewall: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} firewall: $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULTS=(10-defaults.nft 10-defaults.rules 10-defaults.rules6)
for f in knobs knobs.apply configure.sh backend.sh bisquite-firewall.service \
         "${DEFAULTS[@]/#/rules.d/}" rules.d/README lib/bisquite-conf; do
    [[ -f "$SCRIPT_DIR/$f" ]] || { log_error "рядом нет $f — сборка не доставила каталог расширения целиком"; exit 1; }
done
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/bisquite-conf"
# shellcheck source=backend.sh
source "$SCRIPT_DIR/backend.sh"

apt_retry(){
    local i
    for i in 1 2 3; do
        "$@" && return 0
        log_warn "попытка $i: $* — не удалась, повтор через 10 с"
        sleep 10
    done
    return 1
}

# Settings first: FIREWALL_BACKEND from VMFILE decides what the kernel check
# below demands. No network needed for this.
conf_init firewall "$SCRIPT_DIR/knobs" --env || { log_error "/etc/bisquite/firewall/config не записан"; exit 1; }
WANT="$(conf_get firewall FIREWALL_BACKEND)"

# --- the image kernel: which backend it can run -----------------------------
# Checked before apt: nothing to install if the kernel can run neither. Both
# rule sets (and both fallback sets of configure.sh) match conntrack state:
# nftables needs nf_tables + nft_ct, iptables-legacy needs ip_tables,
# iptable_filter, ip6_tables, ip6table_filter, nf_conntrack, xt_conntrack,
# xt_tcpudp — for the IMAGE kernel (/lib/modules/*, not the appliance's
# `uname -r`). The stock L4T r36 kernel (5.15.148-tegra) is built without
# CONFIG_NFT_CT but with all the legacy modules: auto gives iptables there.
# A kernel with neither is a refusal here, not a quiet open robot.
kernels=()
for d in /lib/modules/*/; do
    d="${d%/}"
    [[ -f "$d/modules.order" ]] && kernels+=("${d##*/}")
done
BUILD_BACKEND=""
if (( ${#kernels[@]} == 0 )); then
    log_warn "в образе нет ядра (/lib/modules/*/modules.order) — модули для него не проверены; бэкенд выберет загрузка (FIREWALL_BACKEND=$WANT)"
    [[ "$WANT" == auto ]] || BUILD_BACKEND="$WANT"
else
    krc=0
    picked=()
    for k in "${kernels[@]}"; do
        if fw_pick "$WANT" "/lib/modules/$k" >/dev/null; then
            log_info "$k: бэкенд $FW_PICK (FIREWALL_BACKEND=$WANT)"
            picked+=("$FW_PICK")
        else
            log_error "$k: $FW_PICK_WHY — правила (и запасной набор) на устройстве не загрузятся, входящее останется открытым"
            krc=1
        fi
    done
    (( krc == 0 )) || exit 1
    BUILD_BACKEND="${picked[0]}"
    for b in "${picked[@]}"; do
        [[ "$b" == "$BUILD_BACKEND" ]] || { BUILD_BACKEND=""; log_info "ядра образа требуют разных бэкендов — выбирает загрузка по своему ядру"; break; }
    done
fi

export DEBIAN_FRONTEND=noninteractive
apt_retry apt-get update -q || { log_error "apt-get update не прошёл"; exit 1; }
# Both tools whatever was picked: the backend is chosen again on every boot
# (a new kernel, FIREWALL_BACKEND changed with bisquite-conf).
apt_retry apt-get install -y -q --no-install-recommends nftables iptables \
    || { log_error "nftables или iptables не установился"; exit 1; }

# Rules: the defaults are the operator's files from now on. A re-install (a
# child image in a FROM chain) keeps an edited copy and says so.
RULES_DIR=/etc/bisquite/firewall/rules.d
install -d -m 0755 "$RULES_DIR"
install -m 0644 "$SCRIPT_DIR/rules.d/README" "$RULES_DIR/README"
for f in "${DEFAULTS[@]}"; do
    if [[ ! -e "$RULES_DIR/$f" ]]; then
        install -m 0644 "$SCRIPT_DIR/rules.d/$f" "$RULES_DIR/$f"
    elif ! cmp -s "$SCRIPT_DIR/rules.d/$f" "$RULES_DIR/$f"; then
        log_warn "$RULES_DIR/$f отличается от поставляемого — оставляю как есть"
    fi
done

# The files of BOTH backends are checked here, so a typo fails the build
# rather than the robot's first boot. The format of *.rules/*.rules6 needs no
# kernel — a break of it is a refusal. `nft -c` and `iptables-restore --test`
# need the kernel of the appliance, which may lack the modules — a warning.
WORK="$(mktemp -d)"
trap 'rm -r -f -- "$WORK"' EXIT
for b in nft iptables; do
    rc=0
    out="$(BISQUITE_FIREWALL_BACKEND="$b" BISQUITE_FIREWALL_RUN="$WORK" "$SCRIPT_DIR/configure.sh" check 2>&1)" || rc=$?
    case "$rc" in
        0) log_info "правила $b в $RULES_DIR проверены" ;;
        3) log_error "правила $b в $RULES_DIR: ${out//$'\n'/ | }"; exit 1 ;;
        *) log_warn "правила $b не проверены здесь (ядро appliance без модулей?): ${out//$'\n'/ | }" ;;
    esac
done

# What the build picked: boot uses it only when the running kernel has no
# module lists to judge by; otherwise it decides by that kernel.
install -d -m 0755 /var/lib/bisquite/firewall
if [[ -n "$BUILD_BACKEND" ]]; then
    printf '%s\n' "$BUILD_BACKEND" > /var/lib/bisquite/firewall/backend
else
    rm -f /var/lib/bisquite/firewall/backend
fi

install -m 0644 "$SCRIPT_DIR/bisquite-firewall.service" /etc/systemd/system/bisquite-firewall.service
install -d -m 0755 /usr/local/sbin
ln -sfn "$SCRIPT_DIR/configure.sh" /usr/local/sbin/bisquite-firewall

# nftables.service loads /etc/nftables.conf, which starts with `flush
# ruleset` — it would wipe Docker's chains as well. It is not ours to enable.
if systemctl is-enabled nftables.service >/dev/null 2>&1; then
    log_warn "nftables.service включён: его /etc/nftables.conf делает flush ruleset (снимет и цепочки Docker); bisquite-firewall стоит после него"
fi

systemctl daemon-reload 2>/dev/null || true
systemctl enable bisquite-firewall.service
log_info "bisquite-firewall.service включён: FIREWALL_ENABLE=$(conf_get firewall FIREWALL_ENABLE), FIREWALL_BACKEND=$WANT${BUILD_BACKEND:+ (ядро образа — $BUILD_BACKEND)}, правила — $RULES_DIR"
