#!/usr/bin/env bash
# Тесты расширения firewall — то, что проверяется без ядра и без root:
# выбор бэкенда по спискам модулей ядра (backend.sh), выбор на загрузке
# (configure.sh backend), формат файлов *.rules/*.rules6 и сборка входа
# iptables-restore, запасной набор и единственный переход из INPUT — на
# подставных iptables-legacy*. Настоящие правила в настоящем ядре — прогоном
# в systemd-контейнере (README расширения, «Проверка»).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
X="$REPO/extensions/debian/firewall"
fails=0; total=0
ok()  { total=$((total+1)); echo "  ok   $1"; }
bad() { total=$((total+1)); fails=$((fails+1)); echo "  FAIL $1"; }
check()   { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
refuses() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$n (не отказал)"; else ok "$n"; fi; }
eq() { if [[ "$2" == "$3" ]]; then ok "$1"; else bad "$1: ждали [$2], получили [$3]"; fi; }
T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT

# kernel DIR MODULE...: a module tree whose modules.dep lists MODULE…;
# a module written as +name goes to modules.builtin instead.
kernel() {
    local d="$1" m
    shift
    mkdir -p "$d"
    : > "$d/modules.dep"; : > "$d/modules.builtin"; : > "$d/modules.order"
    for m in "$@"; do
        if [[ "$m" == +* ]]; then
            echo "kernel/net/netfilter/${m#+}.ko" >> "$d/modules.builtin"
        else
            echo "kernel/net/netfilter/$m.ko.zst: kernel/net/netfilter/x_tables.ko.zst" >> "$d/modules.dep"
        fi
    done
}
LEGACY=(ip_tables iptable_filter ip6_tables ip6table_filter nf_conntrack xt_conntrack xt_tcpudp)
# The stock L4T r36.4.3 kernel as measured: nf_tables and all legacy modules,
# no nft_ct, nft_compat, nft_counter.
kernel "$T/k/l4t" nf_tables "${LEGACY[@]}"
kernel "$T/k/full" nf_tables nft_ct nft_compat "${LEGACY[@]}"
kernel "$T/k/builtin" +nf_tables +nft_ct
kernel "$T/k/none" nf_tables nf_conntrack
kernel "$T/k/nov6" nf_tables ip_tables iptable_filter nf_conntrack xt_conntrack xt_tcpudp

pick() { bash -c '. "$0/backend.sh"; fw_pick "$1" "$2"' "$X" "$@" 2>/dev/null; }
why()  { bash -c '. "$0/backend.sh"; fw_pick "$1" "$2" >/dev/null; echo "$FW_PICK_WHY"' "$X" "$@"; }

echo "== backend.sh: выбор по спискам модулей =="
eq      "L4T: auto → iptables"                   iptables "$(pick auto "$T/k/l4t")"
refuses "L4T: nft — отказ"                       pick nft "$T/k/l4t"
check   "…и причина называет nft_ct"             bash -c "[[ \"\$1\" == *nft_ct* ]]" _ "$(why nft "$T/k/l4t")"
eq      "L4T: iptables → iptables"               iptables "$(pick iptables "$T/k/l4t")"
eq      "полное ядро: auto → nft"                nft "$(pick auto "$T/k/full")"
eq      "полное ядро: iptables → iptables"       iptables "$(pick iptables "$T/k/full")"
eq      "встроенные nf_tables, nft_ct → nft"     nft "$(pick auto "$T/k/builtin")"
refuses "встроенные nft, без legacy: iptables"   pick iptables "$T/k/builtin"
refuses "ни nft_ct, ни legacy — отказ"           pick auto "$T/k/none"
check   "…причина называет оба набора"           bash -c "[[ \"\$1\" == *nft_ct*ip_tables* ]]" _ "$(why auto "$T/k/none")"
refuses "без ip6_tables — iptables отказ"        pick auto "$T/k/nov6"
refuses "неизвестное значение — отказ"           pick pf "$T/k/full"
refuses "нет каталога ядра — отказ"              pick auto "$T/k/missing"

# Stage the extension the way the build lays it out: /opt/bisquite/firewall
# with lib/ linked in, a scratch root for /etc/bisquite and the fake tools.
ROOT="$T/root"
export BISQUITE_CONF_ROOT="$ROOT"
mkdir -p "$ROOT/opt/bisquite" "$ROOT/bin" "$ROOT/run"
cp -a "$X" "$ROOT/opt/bisquite/firewall"
ln -sfn "$REPO/lib" "$ROOT/opt/bisquite/firewall/lib"
S="$ROOT/opt/bisquite/firewall"
RD="$ROOT/etc/bisquite/firewall/rules.d"
mkdir -p "$RD"
cp "$X"/rules.d/10-defaults.* "$RD/"
bash -c 'set -euo pipefail; . "$1/lib/bisquite-conf"; conf_init firewall "$1/knobs" --env' _ "$S" 2>/dev/null \
    || bad "conf_init firewall"
setk() { bash -c '. "$1/lib/bisquite-conf"; shift; conf_set firewall "$@"' _ "$S" "$@" >/dev/null 2>&1 || bad "conf_set $*"; }

# Fake iptables-legacy*: the restore tools log their stdin, `--test` of input
# containing "nonsense" fails; iptables-legacy keeps the INPUT jump in a file.
cat > "$ROOT/bin/fake-ipt" <<'FAKE'
#!/usr/bin/env bash
me="${0##*/}"; log="$BISQUITE_CONF_ROOT/ipt.log"
case "$me" in
    *-restore)
        in="$(cat)"
        if [[ " $* " == *" --test "* ]]; then
            echo "$me test" >> "$log"
            grep -q nonsense <<<"$in" && { echo "$me: line 5 failed" >&2; exit 1; }
            exit 0
        fi
        grep -q nonsense <<<"$in" && exit 1
        printf '%s\n' "$in" > "$BISQUITE_CONF_ROOT/$me.loaded"
        echo "$me load" >> "$log" ;;
    *)
        jump="$BISQUITE_CONF_ROOT/$me.jump"
        echo "$me $*" >> "$log"
        case " $* " in
            *" -C INPUT "*) [[ -e "$jump" ]] ;;
            *" -I INPUT 1 "*) touch "$jump" ;;
            *) exit 0 ;;
        esac ;;
esac
FAKE
chmod +x "$ROOT/bin/fake-ipt"
for b in iptables-legacy ip6tables-legacy iptables-legacy-restore ip6tables-legacy-restore; do
    ln -s fake-ipt "$ROOT/bin/$b"
done
# configure.sh with the fakes first in PATH and no nft at all.
fw() {
    env PATH="$ROOT/bin:/usr/bin:/bin" BISQUITE_FIREWALL_RUN="$ROOT/run" \
        BISQUITE_FIREWALL_MODULES="$T/mods" bash "$S/configure.sh" "$@"
}
mods() { rm -rf "$T/mods"; mkdir -p "$T/mods"; [[ -z "${1:-}" ]] || cp -a "$T/k/$1" "$T/mods/$(uname -r)"; }

echo "== configure.sh backend: выбор на загрузке =="
mods l4t;  eq "ядро L4T, auto → iptables"          iptables "$(fw backend 2>/dev/null)"
mods full; eq "полное ядро, auto → nft"            nft "$(fw backend 2>/dev/null)"
setk FIREWALL_BACKEND=iptables
eq "полное ядро, FIREWALL_BACKEND=iptables"        iptables "$(fw backend 2>/dev/null)"
setk FIREWALL_BACKEND=nft
mods l4t;  eq "L4T, FIREWALL_BACKEND=nft — явное"  nft "$(fw backend 2>/dev/null)"
err="$(fw backend 2>&1 >/dev/null)"
check "…с записью в журнал о нехватке nft_ct"      grep -q nft_ct <<<"$err"
setk FIREWALL_BACKEND=auto
mods;      eq "нет списков модулей, нет записи → nft" nft "$(fw backend 2>/dev/null)"
mkdir -p "$ROOT/var/lib/bisquite/firewall"; echo iptables > "$ROOT/var/lib/bisquite/firewall/backend"
eq "нет списков модулей → бэкенд сборки"           iptables "$(fw backend 2>/dev/null)"
rm -f "$ROOT/var/lib/bisquite/firewall/backend"
mods l4t

echo "== файлы *.rules: формат и вход iptables-restore =="
rcof() { "$@" >/dev/null 2>&1; echo $?; }
eq "умолчания проходят check"                      0 "$(rcof fw check)"
V4="$ROOT/run/check.v4"; V6="$ROOT/run/check.v6"
eq "IPv4: первая строка *filter"                   '*filter' "$(head -1 "$V4")"
eq "IPv4: своя цепочка объявлена"                  ':BISQUITE-INPUT - [0:0]' "$(sed -n 2p "$V4")"
eq "IPv4: в конце DROP и COMMIT"                   $'-A BISQUITE-INPUT -j DROP\nCOMMIT' "$(tail -2 "$V4")"
check "IPv4: петля"                                grep -qx -- '-A BISQUITE-INPUT -i lo -j ACCEPT' "$V4"
check "IPv4: established,related"                  grep -qx -- '-A BISQUITE-INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT' "$V4"
check "IPv4: UDP 7400–32000 на 127.0.0.1"          grep -qx -- '-A BISQUITE-INPUT -d 127.0.0.1/32 -p udp -m udp --dport 7400:32000 -j ACCEPT' "$V4"
check "IPv6: обнаружение соседей"                  grep -qx -- '-A BISQUITE-INPUT -p ipv6-icmp -m icmp6 --icmpv6-type neighbour-solicitation -j ACCEPT' "$V6"
refuses "IPv6 не получает правил IPv4"             grep -q 127.0.0.1 "$V6"
eq "правила — только своей цепочки"                0 "$(grep -vE '^(\*filter|:BISQUITE-INPUT - \[0:0\]|-A BISQUITE-INPUT .*|COMMIT|# .*)$' "$V4" "$V6" | wc -l)"

printf '%s\n' '# ssh' '-p tcp --dport 22 -j ACCEPT' '  -A BISQUITE-INPUT -p icmp --icmp-type echo-request -j ACCEPT  ' > "$RD/50-ssh.rules"
eq "свой файл: краткая и полная форма"             0 "$(rcof fw check)"
check "…краткая получила префикс"                  grep -qx -- '-A BISQUITE-INPUT -p tcp --dport 22 -j ACCEPT' "$V4"
check "…полная — как есть"                         grep -qx -- '-A BISQUITE-INPUT -p icmp --icmp-type echo-request -j ACCEPT' "$V4"
check "…после умолчаний, до DROP"                  test "$(grep -n 'dport 22' "$V4" | cut -d: -f1)" -gt "$(grep -n -- '-i lo' "$V4" | cut -d: -f1)"
for bad_line in '-A INPUT -p tcp --dport 22 -j ACCEPT' '-I BISQUITE-INPUT 1 -j ACCEPT' '-F' '-P INPUT ACCEPT' \
                '-X DOCKER' '-N FOO' '*filter' 'COMMIT' ':FOO - [0:0]' '-t nat -A PREROUTING -j ACCEPT' \
                '--flush DOCKER-USER' '--append=INPUT -j ACCEPT' 'tcp dport 22 accept'; do
    printf '%s\n' "$bad_line" > "$RD/60-bad.rules"
    eq "отказ формата (rc 3): $bad_line"           3 "$(rcof fw check)"
done
err="$(fw check 2>&1)"
check "…причина называет файл и строку"            grep -q "60-bad.rules:1" <<<"$err"
rm -f "$RD/60-bad.rules"
printf '%s\n' '-p tcp --dport 22 -j ACCEPT' > "$RD/50-ssh.rules6"
eq "*.rules6 — в IPv6"                             0 "$(rcof fw check)"
check "…и только там"                              bash -c "grep -q 'dport 22' '$V6' && [ \$(grep -c 'dport 22' '$V4') -eq 1 ]"
rm -f "$RD/50-ssh.rules6"

echo "== apply: транзакция, переход из INPUT, запасной набор =="
rm -f "$ROOT"/ipt.log "$ROOT"/*.jump "$ROOT"/*.loaded
eq "apply (iptables) — успех"                      0 "$(rcof fw apply)"
eq "бэкенд записан"                                iptables "$(cat "$ROOT/run/backend")"
check "IPv4 загружен целиком"                      cmp "$ROOT/iptables-legacy-restore.loaded" "$ROOT/run/rules.v4"
check "IPv6 загружен целиком"                      cmp "$ROOT/ip6tables-legacy-restore.loaded" "$ROOT/run/rules.v6"
check "restore — с --noflush"                      grep -q -- '--noflush' "$S/configure.sh"
eq "переход вставлен по разу в v4 и v6"            2 "$(grep -c -- '-I INPUT 1 -j BISQUITE-INPUT' "$ROOT/ipt.log")"
check "сначала --test обоих, потом загрузка"       bash -c "grep -n . '$ROOT/ipt.log' | grep -m1 load | cut -d: -f1 | xargs -I{} test {} -gt 2"
: > "$ROOT/ipt.log"
eq "повторный apply — успех"                       0 "$(rcof fw apply)"
eq "…переход не дублируется"                       0 "$(grep -c -- '-I INPUT' "$ROOT/ipt.log")"
refuses "ничего не сбрасывается целиком (-F/-X без цепочки, -P)" grep -qE -- ' -(F|X|P)( |$)' "$ROOT/ipt.log"

printf '%s\n' '-p tcp --dport nonsense -j ACCEPT' > "$RD/70-broken.rules"
rm -f "$ROOT"/*.loaded
eq "битый файл — apply не успех"                   1 "$(rcof fw apply)"
check "…загружен запасной набор (v4)"              grep -qx -- '-A BISQUITE-INPUT -m conntrack --ctstate ESTABLISHED,RELATED -j ACCEPT' "$ROOT/iptables-legacy-restore.loaded"
check "…запасной: петля и DROP, без правил файлов" bash -c "grep -qx -- '-A BISQUITE-INPUT -i lo -j ACCEPT' '$ROOT/iptables-legacy-restore.loaded' && tail -2 '$ROOT/iptables-legacy-restore.loaded' | head -1 | grep -qx -- '-A BISQUITE-INPUT -j DROP' && ! grep -q 'dport 22' '$ROOT/iptables-legacy-restore.loaded'"
check "…и в IPv6"                                  test -s "$ROOT/ip6tables-legacy-restore.loaded"
rm -f "$RD/70-broken.rules" "$RD/50-ssh.rules"

setk FIREWALL_ENABLE=0
: > "$ROOT/ipt.log"
eq "FIREWALL_ENABLE=0 — apply успешен"             0 "$(rcof fw apply)"
refuses "…и ничего не загружает"                   grep -q 'load' "$ROOT/ipt.log"
setk FIREWALL_ENABLE=1

echo "== install.sh и манифест =="
I="$X/install.sh"
check "backend.sh и умолчания iptables в обязательных" grep -qE '^DEFAULTS=\(10-defaults\.nft 10-defaults\.rules 10-defaults\.rules6\)' "$I"
check "ставит nftables и iptables"                 grep -qE 'install .*nftables iptables' "$I"
check "выбор бэкенда — до apt"                     test "$(grep -n 'fw_pick ' "$I" | head -1 | cut -d: -f1)" -lt "$(grep -n 'apt-get install' "$I" | head -1 | cut -d: -f1)"
check "отказ формата *.rules роняет сборку"        grep -qE '^ +3\) log_error .*; exit 1 ;;' "$I"
check "knobs: FIREWALL_BACKEND auto|nft|iptables"  grep -qE '^FIREWALL_BACKEND +enum:auto,nft,iptables +auto ' "$X/knobs"
check "README: формат *.rules"                     grep -qF '*.rules6' "$X/README.md"

if command -v shellcheck >/dev/null 2>&1; then
    check "shellcheck -S warning" shellcheck -S warning -x "$X/install.sh" "$X/configure.sh" "$X/backend.sh" "$X/knobs.apply" "$0"
else
    echo "  SKIP shellcheck: нет в PATH"
fi

echo "проверок: $total, не прошло: $fails"
[ "$fails" -eq 0 ]
