#!/usr/bin/env bash
# Тесты расширения can-usb — то, что проверяется без платы: барьеры (релиз,
# плата, дерево модулей, ядро Sensing, заголовки), потоковое скачивание
# исходников со сверкой sha256, раскладка сборки, сверка vermagic и установка
# с depmod на подставных make/modinfo/strip/depmod/modprobe, закрепления
# и порядок шагов в install.sh. Живая сборка — на плате (README, «Проверка»).
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
X="$HERE/../extensions/debian/can-usb"
fails=0; total=0
ok()  { total=$((total+1)); echo "  ok   $1"; }
bad() { total=$((total+1)); fails=$((fails+1)); echo "  FAIL $1"; }
check()   { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
refuses() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$n (не отказал)"; else ok "$n"; fi; }
says()    { local n="$1" pat="$2" out; shift 2; out="$("$@" 2>&1)"; if grep -qF -- "$pat" <<<"$out"; then ok "$n"; else bad "$n (нет «$pat»)"; fi; }
T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT

KV=5.15.148-tegra
DTB=tegra234-p3737-0000+p3701-0000-nv.dtb
# Run a function from canusb.sh in a clean shell against root $1, fakes first in PATH.
cu() { local root="$1"; shift; PATH="$T/bin:$PATH" CANUSB_ROOT="$root" bash -c 'set -uo pipefail; . "$0/canusb.sh"; "$@"' "$X" "$@"; }
sha() { sha256sum "$1" | cut -d' ' -f1; }
release_file() { mkdir -p "$1/etc"; printf '%s\n' "$2" > "$1/etc/nv_tegra_release"; }
board() { release_file "$1" "$2"; mkdir -p "$1/boot/dtb"; : > "$1/boot/dtb/kernel_$DTB"; }

echo "== релиз и плата =="
R3643='# R36 (release), REVISION: 4.3, GCID: 38968081, BOARD: generic, EABI: aarch64, DATE: Wed Jan  8 01:49:37 UTC 2025'
board "$T/b1" "$R3643"
board "$T/b2" '# R36 (release), REVISION: 4.4, GCID: 41062509, BOARD: generic, EABI: aarch64'
release_file "$T/b3" "$R3643"
check   "AGX Orin, 36.4.3 — проходит"          cu "$T/b1" canusb_gate_board 36.4.3 "$DTB"
refuses "36.4.4 — отказ"                       cu "$T/b2" canusb_gate_board 36.4.3 "$DTB"
refuses "нет DTB AGX Orin — отказ"             cu "$T/b3" canusb_gate_board 36.4.3 "$DTB"
refuses "нет nv_tegra_release — отказ"         cu "$T/none" canusb_gate_board 36.4.3 "$DTB"

echo "== ядро по /lib/modules образа =="
mkdir -p "$T/k1/lib/modules/$KV" "$T/k1/lib/modules/5.15.0-191-generic"
mkdir -p "$T/k2/lib/modules/$KV" "$T/k2/lib/modules/5.10.216-tegra"
mkdir -p "$T/k3/lib/modules/5.10.216-tegra" "$T/k4/lib/modules"
check   "одно ядро L4T $KV (+generic) — проходит"  cu "$T/k1" canusb_gate_kernel_tree "$KV"
says    "…generic назван и не используется"      "не используются: 5.15.0-191-generic" cu "$T/k1" canusb_gate_kernel_tree "$KV"
refuses "два ядра L4T — отказ"                   cu "$T/k2" canusb_gate_kernel_tree "$KV"
refuses "другое ядро L4T — отказ"                cu "$T/k3" canusb_gate_kernel_tree "$KV"
refuses "ядер нет — отказ"                       cu "$T/k4" canusb_gate_kernel_tree "$KV"

echo "== ядро Sensing на /boot/Image =="
image() { mkdir -p "$1/boot"; printf 'ARM64\0Linux version %s (%s) #1 SMP PREEMPT\0' "$2" "$3" > "$1/boot/Image"; }
image "$T/s1" "$KV" sensing; printf 'stock' > "$T/s1/boot/Image.backup"
SENS="$(sha "$T/s1/boot/Image")"
image "$T/s2" "$KV" stock; cp "$T/s2/boot/Image" "$T/s2/boot/Image.backup"
image "$T/s3" "$KV" stock
image "$T/s4" "$KV" sensing-rebuild; printf 'stock' > "$T/s4/boot/Image.backup"
image "$T/s5" 5.10.216-tegra sensing
check   "ядро Sensing с закреплённой суммой — проходит"  cu "$T/s1" canusb_gate_sensing_kernel "$KV" "$SENS"
refuses "штатное ядро (= Image.backup) — отказ"          cu "$T/s2" canusb_gate_sensing_kernel "$KV" "$SENS"
says    "…и названо, что sensing-gmsl2-camera раньше"    "sensing-gmsl2-camera должен стоять в VMFILE РАНЬШЕ" cu "$T/s2" canusb_gate_sensing_kernel "$KV" "$SENS"
says    "нет Image.backup — тоже порядок слоёв"          "РАНЬШЕ can-usb" cu "$T/s3" canusb_gate_sensing_kernel "$KV" "$SENS"
says    "другая сборка Sensing — отказ с причиной"       "неизвестной сборки" cu "$T/s4" canusb_gate_sensing_kernel "$KV" "$SENS"
refuses "другая версия ядра — отказ"                     cu "$T/s5" canusb_gate_sensing_kernel "$KV" "$SENS"
refuses "нет /boot/Image — отказ"                        cu "$T/none" canusb_gate_sensing_kernel "$KV" "$SENS"

echo "== заголовки ядра =="
headers() {
    local b="$1/lib/modules/$KV/build"
    mkdir -p "$b/include/config"
    echo 'all:' > "$b/Makefile"; echo 'CONFIG_MODVERSIONS=y' > "$b/.config"
    printf '0x1bd17b3e\tcan_change_mtu\tdrivers/net/can/dev/can-dev\tEXPORT_SYMBOL_GPL\t\n' > "$b/Module.symvers"
    echo "${2:-$KV}" > "$b/include/config/kernel.release"
}
headers "$T/h1"; HC="$(sha "$T/h1/lib/modules/$KV/build/.config")"; HS="$(sha "$T/h1/lib/modules/$KV/build/Module.symvers")"
headers "$T/h2"; rm "$T/h2/lib/modules/$KV/build/Module.symvers"
headers "$T/h3" 5.15.148-tegra-other
headers "$T/h4"; echo 'CONFIG_GCC_PLUGIN_RANDSTRUCT=y' >> "$T/h4/lib/modules/$KV/build/.config"
check   "сверенные .config и Module.symvers — проходит"  cu "$T/h1" canusb_gate_headers "$KV" "$HC" "$HS"
refuses "нет Module.symvers — отказ"                     cu "$T/h2" canusb_gate_headers "$KV" "$HC" "$HS"
refuses "kernel.release не тот — отказ"                  cu "$T/h3" canusb_gate_headers "$KV" "$HC" "$HS"
refuses ".config другой — отказ"                         cu "$T/h4" canusb_gate_headers "$KV" "$HC" "$HS"

echo "== исходники: потоковое скачивание и сверка =="
P=kernel/kernel-jammy-src/drivers/net/can
mkdir -p "$T/ks/$P/usb/peak_usb" "$T/ps/Linux_for_Tegra/source"
for f in usb/gs_usb.c usb/peak_usb/pcan_usb_core.c usb/peak_usb/pcan_usb_core.h usb/peak_usb/pcan_usb.c \
         usb/peak_usb/pcan_usb_pro.c usb/peak_usb/pcan_usb_pro.h usb/peak_usb/pcan_usb_fd.c slcan.c; do
    echo "/* $f */" > "$T/ks/$P/$f"
done
echo other > "$T/ks/$P/usb/Makefile"
tar -cjf "$T/ps/Linux_for_Tegra/source/kernel_src.tbz2" -C "$T/ks" kernel
tar -cjf "$T/public_sources.tbz2" -C "$T/ps" Linux_for_Tegra
PSUM="$(sha "$T/public_sources.tbz2")"
rm "$T/ks/$P/slcan.c"
tar -cjf "$T/ps/Linux_for_Tegra/source/kernel_src.tbz2" -C "$T/ks" kernel
tar -cjf "$T/short.tbz2" -C "$T/ps" Linux_for_Tegra
ZERO=0000000000000000000000000000000000000000000000000000000000000000
check   "сумма сошлась — исходники извлечены"     cu / canusb_fetch "file://$T/public_sources.tbz2" "$PSUM" "$T/f1"
check   "…ровно восемь файлов драйверов"          test "$(find "$T/f1/kernel" -type f | wc -l)" -eq 8
check   "…и это они"                              grep -qF 'usb/peak_usb/pcan_usb_fd.c' "$T/f1/$P/usb/peak_usb/pcan_usb_fd.c"
check   "…служебных файлов не осталось"           test "$(find "$T/f1" -maxdepth 1 -name '.sha*' | wc -l)" -eq 0
refuses "sha256 не та — отказ"                    cu / canusb_fetch "file://$T/public_sources.tbz2" "$ZERO" "$T/f2"
refuses "…и исходников нет"                       test -e "$T/f2/kernel"
refuses "в архиве нет slcan.c — отказ"            cu / canusb_fetch "file://$T/short.tbz2" "$PSUM" "$T/f3"
refuses "не скачалось — отказ"                    cu / canusb_fetch "file://$T/missing.tbz2" "$PSUM" "$T/f4"

echo "== раскладка сборки =="
check   "исходники и Kbuild разложены"            cu / canusb_prepare "$T/f1" "$X/Kbuild" "$T/bd"
check   "…peak_usb/ — подкаталогом"               test -f "$T/bd/peak_usb/pcan_usb_core.h" -a -f "$T/bd/gs_usb.c" -a -f "$T/bd/slcan.c"
check   "Kbuild собирает три модуля"              grep -qx 'obj-m := gs_usb.o peak_usb.o slcan.o' "$X/Kbuild"
check   "…peak_usb из четырёх объектов ядра 5.15" bash -c "tr -d '\\\\\n' < '$X/Kbuild' | grep -q 'peak_usb-y := peak_usb/pcan_usb_core.o peak_usb/pcan_usb.o *peak_usb/pcan_usb_pro.o peak_usb/pcan_usb_fd.o'"

echo "== сборка и сверка vermagic на подставных командах =="
# make writes FAKE_MAGIC into the three .ko (FAKE_MAKE_FAIL=1 fails, FAKE_SKIP
# names a module it does not build); modinfo -F vermagic prints a file's first
# line; strip is a no-op; depmod logs its args; modprobe --show-depends prints
# the path depmod "found" unless FAKE_MODPROBE_FAIL=1.
mkdir -p "$T/bin"
cat > "$T/bin/make" <<'FAKE'
#!/usr/bin/env bash
[ "${FAKE_MAKE_FAIL:-0}" = 1 ] && { echo "gs_usb.c:1: error: boom"; exit 2; }
for a; do case "$a" in M=*) m="${a#M=}";; esac; done
for k in gs_usb peak_usb slcan; do [ "$k" = "${FAKE_SKIP:-}" ] || echo "$FAKE_MAGIC" > "$m/$k.ko"; done
FAKE
cat > "$T/bin/modinfo" <<'FAKE'
#!/usr/bin/env bash
[ "$1" = -F ] && [ "$2" = vermagic ] && head -n1 "$3"
FAKE
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/bin/strip"
cat > "$T/bin/depmod" <<'FAKE'
#!/usr/bin/env bash
echo "$*" >> "$FAKE_LOG"
FAKE
cat > "$T/bin/modprobe" <<'FAKE'
#!/usr/bin/env bash
[ "${FAKE_MODPROBE_FAIL:-0}" = 1 ] && { echo "modprobe: FATAL: Module ${!#} not found"; exit 1; }
echo "insmod /lib/modules/$KV/updates/can-usb/${!#}.ko"
FAKE
chmod +x "$T/bin/"*
MAGIC="$KV SMP preempt mod_unload modversions aarch64"
mkdir -p "$T/r1/lib/modules/$KV/kernel/drivers/net/can/dev"
echo "$MAGIC" > "$T/r1/lib/modules/$KV/kernel/drivers/net/can/dev/can-dev.ko"
mkdir -p "$T/r2/lib/modules/$KV/kernel"
export KV FAKE_MAGIC="$MAGIC" FAKE_LOG="$T/depmod.log"
cu "$T/r1" canusb_prepare "$T/f1" "$X/Kbuild" "$T/bd1" >/dev/null 2>&1
check   "собрано, vermagic как у can-dev.ko"      cu "$T/r1" canusb_build "$KV" "$T/bd1" 2
for v in "FAKE_MAKE_FAIL=1" "FAKE_SKIP=slcan" "FAKE_MAGIC=5.15.148-tegra SMP preempt mod_unload aarch64"; do
    rm -f "$T/bd1"/*.ko
    refuses "отказ при ${v%%=*}=${v#*=}"         env "$v" bash -c "$(declare -f cu); T='$T' X='$X' cu '$T/r1' canusb_build '$KV' '$T/bd1' 2"
done
rm -f "$T/bd1"/*.ko
refuses "нет can-dev.ko для сверки — отказ"       cu "$T/r2" canusb_build "$KV" "$T/bd1" 2
cu "$T/r1" canusb_build "$KV" "$T/bd1" 2 >/dev/null 2>&1

echo "== установка и depmod =="
MD="/lib/modules/$KV/updates/can-usb"
check   "установлено, depmod прошёл"              cu "$T/r1" canusb_install "$KV" "$T/bd1" "$MD"
check   "…три модуля, права 0644"                 bash -c "for m in gs_usb peak_usb slcan; do [ \"\$(stat -c %a '$T/r1$MD/'\$m.ko)\" = 644 ] || exit 1; done"
check   "…depmod для ядра образа, не uname -r"    grep -qx -- "-b $T/r1 $KV" "$FAKE_LOG"
check   "повторная установка — снова успех"       cu "$T/r1" canusb_install "$KV" "$T/bd1" "$MD"
refuses "modprobe не разрешает модуль — отказ"    env FAKE_MODPROBE_FAIL=1 bash -c "$(declare -f cu); T='$T' X='$X' cu '$T/r1' canusb_install '$KV' '$T/bd1' '$MD'"
refuses "modprobe берёт чужой файл — отказ"       cu "$T/r1" canusb_install "$KV" "$T/bd1" /lib/modules/$KV/updates/other

echo "== install.sh: закрепления и порядок =="
I="$X/install.sh"
check   "закреплён релиз L4T 36.4.3"               grep -qx 'CANUSB_L4T=36.4.3' "$I"
check   "закреплено ядро 5.15.148-tegra"           grep -qx 'CANUSB_KERNEL=5.15.148-tegra' "$I"
check   "закреплён адрес исходников R36.4.3"       grep -qx 'CANUSB_SRC_URL=https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.3/sources/public_sources.tbz2' "$I"
check   "закреплена sha256 исходников"             grep -qx 'CANUSB_SRC_SHA256=2c177804679e3ed650dabec6fa958388579896f170570c6171a1b6c386669216' "$I"
check   "закреплена sha256 ядра Sensing"           grep -qx 'CANUSB_SENSING_IMAGE_SHA256=fb75806692bd7216916da985ed828f841cbf38b3e7207f124921b41fd84b8771' "$I"
check   "закреплены .config и Module.symvers"      bash -c "grep -qx 'CANUSB_HEADERS_CONFIG_SHA256=9f3129b2dd65e88c043fa09a7f0a3abd30c88891e029f3f1b6d976bed09459f2' '$I' && grep -qx 'CANUSB_HEADERS_SYMVERS_SHA256=bdbf119f6a3844aa7810fb22ed4c604f5608e9302033a81d27fa558314ce7f96' '$I'"
check   "модули — в updates/can-usb ядра образа"   grep -qx 'CANUSB_MODDIR="/lib/modules/$CANUSB_KERNEL/updates/can-usb"' "$I"
line() { grep -nE "$1" "$I" | head -1 | cut -d: -f1; }
check   "барьеры — до apt и сети"                  test "$(line '^canusb_gate_sensing_kernel ')" -lt "$(line 'apt_update_once \|\| exit')"
check   "…и до скачивания"                         test "$(line '^canusb_gate_sensing_kernel ')" -lt "$(line '^canusb_fetch ')"
check   "заголовки сверяются до сборки"            test "$(line '^canusb_gate_headers ')" -lt "$(line '^canusb_build ')"
check   "установка — после сборки"                 test "$(line '^canusb_build ')" -lt "$(line '^canusb_install ')"
refuses "uname -r в коде не используется"          bash -c "grep -hv '^[[:space:]]*#' '$I' '$X/canusb.sh' | grep -qF '\$(uname'"
refuses "автозагрузку не трогает"                  grep -qE 'modules-load\.d|CAN_MODULES_LOAD=' "$I" "$X/canusb.sh"

echo
echo "итого: $total, провалов: $fails"
(( fails == 0 ))
