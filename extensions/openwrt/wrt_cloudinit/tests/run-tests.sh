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

[ "$fail" = 0 ] && { echo "ALL PASS"; exit 0; } || { echo "FAILURES"; exit 1; }
