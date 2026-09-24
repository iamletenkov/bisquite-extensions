#!/usr/bin/env bash
# Tests for l4t-kernel-kvm — what can be checked without a board or an
# appliance: rewriting `root=` to `root=PARTUUID=<P>` in every APPEND line of
# extlinux.conf, the refusals, idempotency, the partition number cross-check,
# and (a scanner, not a behaviour test) the position of step 1v in install.sh.
#
# NOT checked here: kvm_root_partition itself (st_dev of / -> node in /dev ->
# blkid). It needs a real block device under /; the probe on an overlay of the
# base image (plan 2026-09-24, task 9) and the live build are its only checks.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
X="$HERE/../extensions/debian/l4t-kernel-kvm"
fails=0; total=0
ok()  { total=$((total+1)); echo "  ok   $1"; }
bad() { total=$((total+1)); fails=$((fails+1)); echo "  FAIL $1"; }
check()   { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
refuses() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$n (не отказал)"; else ok "$n"; fi; }
T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT

# Run a function from extlinux-root.sh in a clean shell.
er() { bash -c 'set -uo pipefail; . "$0/extlinux-root.sh"; "$@"' "$X" "$@"; }

P=817d4355-fa85-4e38-903f-ea68b2e685ff
OTHER=11111111-2222-3333-4444-555555555555
# The vendor line as on Nano B (Q-engineering base), only `root=` varies.
tail_tokens='rw rootwait rootfstype=ext4 console=ttyS0,115200n8 console=tty0 fbcon=map:0 net.ifnames=0'

# conf FILE ROOT_TOKEN — a one-entry extlinux.conf in the vendor layout.
conf() {
    printf '%s\n' \
        'TIMEOUT 30' \
        'DEFAULT primary' \
        '' \
        'MENU TITLE L4T boot options' \
        '' \
        'LABEL primary' \
        '      MENU LABEL primary kernel' \
        '      LINUX /boot/Image' \
        '      INITRD /boot/initrd' \
        "      APPEND \${cbootargs} quiet $2 $tail_tokens" \
        '' \
        '# APPEND root=/dev/mmcblk0p1' > "$1"
}
# conf2 FILE ROOT_TOKEN — primary plus a kvm entry, as after 1.2.0.
conf2() {
    conf "$1" "$2"
    printf '%s\n' \
        '' \
        'LABEL kvm' \
        '      MENU LABEL kvm kernel (tegra-kvm, собрано bisquite)' \
        '      LINUX /boot/Image.kvm' \
        '      INITRD /boot/initrd' \
        "      APPEND \${cbootargs} quiet $2 $tail_tokens" >> "$1"
}
appends() { grep -E '^[[:space:]]*APPEND[[:space:]]' "$1"; }
same_file() { cmp -s "$1" "$2"; }

echo "== переписывание root= =="
# 1. primary with a device path -> PARTUUID, other tokens in place and order.
conf "$T/c1" root=/dev/mmcblk0p1
er kvm_rewrite_root "$T/c1" "$P" >/dev/null 2>&1
check   "1. /dev/mmcblk0p1 → PARTUUID, прочие токены на месте" \
        grep -qxF "      APPEND \${cbootargs} quiet root=PARTUUID=$P $tail_tokens" "$T/c1"
check   "1. …ни в одной строке APPEND не осталось root=/dev" \
        bash -c "! grep -E '^[[:space:]]*APPEND[[:space:]]' '$T/c1' | grep -q 'root=/dev'"

# 2. Two entries — both rewritten.
conf2 "$T/c2" root=/dev/mmcblk0p1
er kvm_rewrite_root "$T/c2" "$P" >/dev/null 2>&1
check   "2. переписаны обе записи (primary и kvm)" \
        test "$(appends "$T/c2" | grep -c "root=PARTUUID=$P ")" -eq 2

# 3. Second run — byte for byte the same.
cp "$T/c2" "$T/c2.first"
check   "3. повторный прогон проходит"         er kvm_rewrite_root "$T/c2" "$P"
check   "3. …файл байт в байт тот же"          same_file "$T/c2" "$T/c2.first"

# 4. Already root=PARTUUID=<P> — file untouched.
conf2 "$T/c4" "root=PARTUUID=$P"; cp "$T/c4" "$T/c4.orig"
check   "4. уже root=PARTUUID=<P> — проходит"  er kvm_rewrite_root "$T/c4" "$P"
check   "4. …файл не изменён"                  same_file "$T/c4" "$T/c4.orig"

echo "== отказы =="
# 5. Foreign PARTUUID.
conf2 "$T/c5" "root=PARTUUID=$OTHER"; cp "$T/c5" "$T/c5.orig"
refuses "5. root=PARTUUID=<другой> — отказ"    er kvm_rewrite_root "$T/c5" "$P"
check   "5. …файл не изменён"                  same_file "$T/c5" "$T/c5.orig"

# 6. APPEND without root=.
conf "$T/c6" ''; cp "$T/c6" "$T/c6.orig"
refuses "6. APPEND без root= — отказ"          er kvm_rewrite_root "$T/c6" "$P"
check   "6. …файл не изменён"                  same_file "$T/c6" "$T/c6.orig"
# …and a mixed file: one good entry does not let the bad one through.
conf "$T/c6b" root=/dev/mmcblk0p1
printf '%s\n' '' 'LABEL kvm' '      APPEND ${cbootargs} quiet rw' >> "$T/c6b"
cp "$T/c6b" "$T/c6b.orig"
refuses "6. одна запись без root= при годной другой — отказ" er kvm_rewrite_root "$T/c6b" "$P"
check   "6. …и годная запись тоже не переписана" same_file "$T/c6b" "$T/c6b.orig"
printf '%s\n' 'TIMEOUT 30' 'LABEL primary' '      LINUX /boot/Image' > "$T/c6c"
refuses "6. ни одной строки APPEND — отказ"    er kvm_rewrite_root "$T/c6c" "$P"

# 7. Two root= in one line.
conf "$T/c7" "root=/dev/mmcblk0p1 root=/dev/sda1"; cp "$T/c7" "$T/c7.orig"
refuses "7. два root= в строке — отказ"        er kvm_rewrite_root "$T/c7" "$P"
check   "7. …файл не изменён"                  same_file "$T/c7" "$T/c7.orig"

# 8. root=UUID=… (and other forms nobody decided on).
conf "$T/c8" root=UUID=0b7e2a9c-3f1d-4c55-9a0e-2b1d7c9e4f10; cp "$T/c8" "$T/c8.orig"
refuses "8. root=UUID=… — отказ"               er kvm_rewrite_root "$T/c8" "$P"
check   "8. …файл не изменён"                  same_file "$T/c8" "$T/c8.orig"
conf "$T/c8b" root=LABEL=APP
refuses "8. root=LABEL=… — отказ"              er kvm_rewrite_root "$T/c8b" "$P"

# 9. PARTUUID empty or malformed.
conf "$T/c9" root=/dev/mmcblk0p1; cp "$T/c9" "$T/c9.orig"
refuses "9. PARTUUID пустой — отказ"           er kvm_rewrite_root "$T/c9" ""
refuses "9. PARTUUID не по форме — отказ"      er kvm_rewrite_root "$T/c9" 817d4355-fa85
refuses "9. PARTUUID MBR-формы — отказ"        er kvm_rewrite_root "$T/c9" 4ec8ea53-01
refuses "9. PARTUUID заглавными — отказ"       er kvm_rewrite_root "$T/c9" "${P^^}"
check   "9. …файл не изменён"                  same_file "$T/c9" "$T/c9.orig"

echo "== что не трогается =="
# 10. Non-APPEND lines (commented APPEND, MENU LABEL) intact; indent kept.
conf2 "$T/c10" root=/dev/mmcblk0p1
printf '%s\n' '	APPEND root=/dev/mmcblk0p1 rw' >> "$T/c10"
er kvm_rewrite_root "$T/c10" "$P" >/dev/null 2>&1
check   "10. закомментированная '# APPEND root=/dev/…' не тронута" \
        grep -qx '# APPEND root=/dev/mmcblk0p1' "$T/c10"
conf2 "$T/c10ref" root=/dev/mmcblk0p1
printf '%s\n' '	APPEND root=/dev/mmcblk0p1 rw' >> "$T/c10ref"
check   "10. строки, кроме APPEND, те же, что до правки" bash -c "
        diff <(grep -vE '^[[:space:]]*APPEND[[:space:]]' '$T/c10ref') \
             <(grep -vE '^[[:space:]]*APPEND[[:space:]]' '$T/c10')"
check   "10. MENU LABEL не тронут"             grep -qxF '      MENU LABEL kvm kernel (tegra-kvm, собрано bisquite)' "$T/c10"
check   "10. отступ APPEND сохранён (пробелы)" grep -qE "^      APPEND .*root=PARTUUID=$P" "$T/c10"
check   "10. отступ APPEND сохранён (табуляция)" grep -qxF "	APPEND root=PARTUUID=$P rw" "$T/c10"

# 11. rootwait, rootfstype=, nfsroot= are not root=.
conf "$T/c11" "nfsroot=192.168.0.1:/srv/nfs root=/dev/mmcblk0p1"
er kvm_rewrite_root "$T/c11" "$P" >/dev/null 2>&1
check   "11. rootwait, rootfstype=ext4, nfsroot=… не тронуты" \
        grep -qxF "      APPEND \${cbootargs} quiet nfsroot=192.168.0.1:/srv/nfs root=PARTUUID=$P $tail_tokens" "$T/c11"

echo "== проверка без записи (шаг 1в) =="
# 12. Partition number cross-check.
conf2 "$T/c12" root=/dev/mmcblk0p1; cp "$T/c12" "$T/c12.orig"
check   "12. /dev/mmcblk0p1 при разделе 1 — проходит"  er kvm_check_extlinux_roots "$T/c12" "$P" 1
refuses "12. /dev/mmcblk0p1 при разделе 2 — отказ"     er kvm_check_extlinux_roots "$T/c12" "$P" 2
conf "$T/c12b" root=/dev/mmcblk0p2
refuses "12. /dev/mmcblk0p2 при разделе 1 — отказ"     er kvm_check_extlinux_roots "$T/c12b" "$P" 1
conf "$T/c12c" root=/dev/sda1
check   "12. /dev/sda1 при разделе 1 — проходит"       er kvm_check_extlinux_roots "$T/c12c" "$P" 1
refuses "12. /dev/sda1 при разделе 3 — отказ"          er kvm_check_extlinux_roots "$T/c12c" "$P" 3
conf "$T/c12d" "root=PARTUUID=$P"
check   "12. уже PARTUUID — номер сверять не с чем"    er kvm_check_extlinux_roots "$T/c12d" "$P" 7
refuses "12. номер раздела не число — отказ"           er kvm_check_extlinux_roots "$T/c12" "$P" x
check   "12. …проверка файл не тронула"                same_file "$T/c12" "$T/c12.orig"

# 13. Check-only mode refuses on the same inputs as the write, and never writes.
for c in c5 c6 c6b c6c c7 c8 c8b; do
    cp "$T/$c" "$T/$c.chk"
    refuses "13. проверка отказывает там же, где запись ($c)" \
            er kvm_check_extlinux_roots "$T/$c.chk" "$P" 1
    check   "13. …и файл не тронут ($c)"       same_file "$T/$c" "$T/$c.chk"
done
refuses "13. проверка: PARTUUID не по форме — отказ" er kvm_check_extlinux_roots "$T/c12" 817d4355-fa85 1
refuses "13. проверка: файла нет — отказ"      er kvm_check_extlinux_roots "$T/none" "$P" 1
refuses "13. запись: файла нет — отказ"        er kvm_rewrite_root "$T/none" "$P"
conf "$T/c13" root=/dev/mmcblk0p1; cp "$T/c13" "$T/c13.orig"
check   "13. проверка на годном входе проходит" er kvm_check_extlinux_roots "$T/c13" "$P" 1
check   "13. …и ничего не пишет"               same_file "$T/c13" "$T/c13.orig"
check   "13. отказ проверки говорит на stderr" bash -c "
        out=\$(bash -c '. \"\$0/extlinux-root.sh\"; kvm_check_extlinux_roots \"\$1\" \"\$2\" 1' '$X' '$T/c5' '$P' 2>/dev/null)
        err=\$(bash -c '. \"\$0/extlinux-root.sh\"; kvm_check_extlinux_roots \"\$1\" \"\$2\" 1' '$X' '$T/c5' '$P' 2>&1 >/dev/null)
        [ -z \"\$out\" ] && [ -n \"\$err\" ]"

echo "== install.sh: порядок (сканер) =="
I="$X/install.sh"
line() { grep -nE "$1" "$I" | head -1 | cut -d: -f1; }
check   "14. помощник подключается относительно install.sh" \
        grep -qE '^\. "\$HERE/extlinux-root\.sh"' "$I"
check   "14. шаг 1в стоит раньше первого apt-get" \
        test "$(line '^[^#]*kvm_check_extlinux_roots ')" -lt "$(line '^[^#]*apt-get ')"
check   "14. определение раздела — раньше первого apt-get" \
        test "$(line '^[^#]*kvm_root_partition')" -lt "$(line '^[^#]*apt-get ')"
check   "14. переписывание — после бэкапа before-kvm" \
        test "$(line '^cp -a "\$EXTLINUX" "\$\{EXTLINUX\}\.before-kvm"')" -lt "$(line '^[^#]*kvm_rewrite_root ')"
last_line() { grep -nE "$1" "$I" | tail -1 | cut -d: -f1; }
check   "14. APPEND перечитывается после переписывания" \
        test "$(line '^[^#]*kvm_rewrite_root ')" -lt "$(last_line '^[[:space:]]*APPEND_LINE=')"
check   "14. heredoc записи kvm — после переписывания" \
        test "$(line '^[^#]*kvm_rewrite_root ')" -lt "$(line '^cat >> "\$EXTLINUX" <<EXTEOF')"

if command -v shellcheck >/dev/null 2>&1; then
    check "shellcheck -S warning" shellcheck -S warning -x "$X/install.sh" "$X/extlinux-root.sh" "$0"
else
    echo "  SKIP shellcheck: нет в PATH"
fi

echo "проверок: $total, не прошло: $fails"
[ "$fails" -eq 0 ]
