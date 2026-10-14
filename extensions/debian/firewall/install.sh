#!/usr/bin/env bash
# Host firewall on nftables: our own table `inet bisquite`, rebuilt from
# /etc/bisquite/firewall/rules.d/*.nft on every boot by bisquite-firewall.service.
#
# Build phase: install nftables, lay down the default rules (only if the
# operator's copy is not there yet), register the `firewall` domain and
# enable the service. Nothing is loaded into the kernel here — the appliance
# kernel is not the robot's.
#
# Parameters (environment, from VMFILE) — the `firewall` domain, schema in knobs:
#   FIREWALL_ENABLE   1   0 — the image boots with the firewall off
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} firewall: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} firewall: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} firewall: $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for f in knobs knobs.apply configure.sh bisquite-firewall.service \
         rules.d/10-defaults.nft rules.d/README lib/bisquite-conf; do
    [[ -f "$SCRIPT_DIR/$f" ]] || { log_error "рядом нет $f — сборка не доставила каталог расширения целиком"; exit 1; }
done
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/bisquite-conf"

apt_retry(){
    local i
    for i in 1 2 3; do
        "$@" && return 0
        log_warn "попытка $i: $* — не удалась, повтор через 10 с"
        sleep 10
    done
    return 1
}

export DEBIAN_FRONTEND=noninteractive
apt_retry apt-get update -q || { log_error "apt-get update не прошёл"; exit 1; }
apt_retry apt-get install -y -q --no-install-recommends nftables \
    || { log_error "nftables не установился"; exit 1; }

conf_init firewall "$SCRIPT_DIR/knobs" --env || { log_error "/etc/bisquite/firewall/config не записан"; exit 1; }

# Rules: the defaults are the operator's file from now on. A re-install (a
# child image in a FROM chain) keeps an edited copy and says so.
RULES_DIR=/etc/bisquite/firewall/rules.d
install -d -m 0755 "$RULES_DIR"
install -m 0644 "$SCRIPT_DIR/rules.d/README" "$RULES_DIR/README"
if [[ ! -e "$RULES_DIR/10-defaults.nft" ]]; then
    install -m 0644 "$SCRIPT_DIR/rules.d/10-defaults.nft" "$RULES_DIR/10-defaults.nft"
elif ! cmp -s "$SCRIPT_DIR/rules.d/10-defaults.nft" "$RULES_DIR/10-defaults.nft"; then
    log_warn "$RULES_DIR/10-defaults.nft отличается от поставляемого — оставляю как есть"
fi

# The files are checked here, by the parser of the image's nft, so a typo
# fails the build rather than the robot's first boot. `nft -c` needs netlink;
# inside an appliance without nf_tables it may not have it — then a warning.
WORK="$(mktemp -d)"
trap 'rm -r -f -- "$WORK"' EXIT
if out="$(BISQUITE_FIREWALL_RUN="$WORK" "$SCRIPT_DIR/configure.sh" check 2>&1)"; then
    log_info "правила $RULES_DIR проверены (nft -c)"
else
    log_warn "nft -c не проверил правила здесь (ядро appliance без nf_tables?): ${out//$'\n'/ | }"
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
log_info "bisquite-firewall.service включён: FIREWALL_ENABLE=$(conf_get firewall FIREWALL_ENABLE), правила — $RULES_DIR/*.nft"
