#!/bin/sh
# Тест-харнесс wrt.cloudinit — гоняется на билд-хосте (POSIX sh + awk).
set -u
HERE=$(cd "$(dirname "$0")" && pwd)
ROOT=$(cd "$HERE/.." && pwd)
LIB="$ROOT/lib"
FIX="$HERE/fixtures"
fail=0

pass(){ printf 'ok   - %s\n' "$1"; }
die(){ printf 'FAIL - %s\n' "$1"; fail=1; }
assert_eq(){ # desc expected actual
	if [ "$2" = "$3" ]; then pass "$1"; else
		die "$1"
		printf '       expected: [%s]\n       actual:   [%s]\n' "$2" "$3"
	fi
}

# --- source lib ---
# shellcheck disable=SC1090
for f in "$LIB"/*.sh; do . "$f"; done

# --- lint ---
for f in "$LIB"/*.sh; do
	shellcheck -s dash "$f" || die "shellcheck $f"
done
shellcheck -s dash -e SC1090,SC1091,SC2034 "$ROOT/wrt.cloudinit" || die "shellcheck wrt.cloudinit"
sh -n "$ROOT/wrt.cloudinit" || die "sh -n wrt.cloudinit"

# --- parse_netcfg ---
assert_eq "parse_netcfg wan-dhcp-lan-static" \
"eth0|dhcp|||
eth1|static|192.168.51.1|255.255.255.0|" \
"$(parse_netcfg "$FIX/wan-dhcp-lan-static/network-config")"

assert_eq "parse_netcfg wan-static-lan-static" \
"eth0|static|192.168.31.137|255.255.255.0|192.168.31.1
eth1|static|192.168.51.1|255.255.255.0|" \
"$(parse_netcfg "$FIX/wan-static-lan-static/network-config")"

assert_eq "parse_netcfg multi-lan" \
"eth0|dhcp|||
eth1|static|192.168.51.1|255.255.255.0|
eth2|static|192.168.52.1|255.255.255.0|" \
"$(parse_netcfg "$FIX/multi-lan/network-config")"

# --- формат bisquite: стандартный cloud-init ------------------------------
# Фикстура снята с настоящего `CloudInitGenerator`, а не написана руками:
# иначе тест проверял бы представление автора о формате, а не сам формат.
BSW="$FIX/bisquite-device-write"

assert_eq "netcfg_version: bisquite → 2" "2" "$(netcfg_version "$BSW/network-config")"
assert_eq "netcfg_version: proxmox → 1" "1" \
"$(netcfg_version "$FIX/wan-static-lan-static/network-config")"

assert_eq "parse_netcfg_any v2 (bisquite)" \
"eth0|dhcp|||
eth1|static|192.168.51.1|255.255.255.0|192.168.51.254" \
"$(parse_netcfg_any "$BSW/network-config")"

# Контроль: v1 через тот же вход разбирается по-прежнему — значит поддержка
# Proxmox не потеряна.
assert_eq "parse_netcfg_any v1 (proxmox, контроль)" \
"eth0|static|192.168.31.137|255.255.255.0|192.168.31.1
eth1|static|192.168.51.1|255.255.255.0|" \
"$(parse_netcfg_any "$FIX/wan-static-lan-static/network-config")"

assert_eq "parse_users: имя и готовый хеш" "ops" \
"$(parse_users "$BSW/user-data" | cut -d'|' -f1)"

case "$(parse_users "$BSW/user-data" | cut -d'|' -f2)" in
	\$6\$*) pass "parse_users: хеш в формате sha512-crypt" ;;
	*)      die  "parse_users: хеш не распознан" ;;
esac

# Контроль: у сида Proxmox списка users нет — парсер обязан молчать, а не
# выдумывать пользователя.
assert_eq "parse_users: proxmox → пусто" "" \
"$(parse_users "$FIX/wan-static-lan-static/meta-data")"

assert_eq "parse_ssh_keys: оба ключа" \
"ssh-ed25519 AAAAC3Nz probe@host
ssh-rsa AAAAB3Nza second@host" \
"$(parse_ssh_keys "$BSW/user-data" ops)"

assert_eq "parse_ssh_keys: чужой пользователь → пусто" "" \
"$(parse_ssh_keys "$BSW/user-data" nobody)"

# --- read_dns ---
assert_eq "read_dns wan-dhcp-lan-static" "1.1.1.1|lan" \
"$(read_dns "$FIX/wan-dhcp-lan-static/network-config")"
assert_eq "read_dns wan-static-lan-static" "8.8.8.8|" \
"$(read_dns "$FIX/wan-static-lan-static/network-config")"
assert_eq "read_dns multi-lan (none)" "|" \
"$(read_dns "$FIX/multi-lan/network-config")"

# --- get_seed_instance_id ---
assert_eq "instance-id wan-dhcp-lan-static" "bisquite-a1b2c3d4" \
"$(get_seed_instance_id "$FIX/wan-dhcp-lan-static/meta-data")"
assert_eq "instance-id multi-lan" "bisquite-cafe1234" \
"$(get_seed_instance_id "$FIX/multi-lan/meta-data")"

# --- validate_netcfg ---
if validate_netcfg "$FIX/multi-lan/network-config"; then pass "validate ok"; else die "validate ok"; fi
emptyf="$(mktemp)"; printf 'version: 1\nconfig: []\n' > "$emptyf"
if validate_netcfg "$emptyf"; then die "validate empty → fail"; else pass "validate empty → fail"; fi
rm -f "$emptyf"

# --- state.sh ---
TMP=$(mktemp -d)
WRT_STATE_DIR="$TMP/state"
if already_provisioned "x1"; then die "state: empty → not provisioned"; else pass "state: empty → not provisioned"; fi
if mark_provisioned "x1"; then pass "state: mark ok"; else die "state: mark ok"; fi
if already_provisioned "x1"; then pass "state: same id → provisioned"; else die "state: same id → provisioned"; fi
if already_provisioned "x2"; then die "state: diff id → not provisioned"; else pass "state: diff id → not provisioned"; fi
if already_provisioned ""; then die "state: empty id arg → not provisioned"; else pass "state: empty id arg → not provisioned"; fi
rm -rf "$TMP"
unset WRT_STATE_DIR

[ "$fail" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "FAILURES"; exit 1; }
