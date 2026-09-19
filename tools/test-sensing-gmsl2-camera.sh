#!/usr/bin/env bash
# Тесты расширения sensing-gmsl2-camera — то, что проверяется без платы:
# опознание релиза L4T, скачивание оверлея камер со сверкой sha256, подмена
# libnvisppg.so через dpkg-divert на подменённом корне, закрепления в install.sh.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
X="$HERE/../extensions/debian/sensing-gmsl2-camera"
fails=0; total=0
ok()  { total=$((total+1)); echo "  ok   $1"; }
bad() { total=$((total+1)); fails=$((fails+1)); echo "  FAIL $1"; }
check()   { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
refuses() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$n (не отказал)"; else ok "$n"; fi; }
T="$(mktemp -d)"
trap 'rm -rf -- "$T"' EXIT

# Run a function from nvisppg.sh in a clean shell against root $1.
nv() { local root="$1"; shift; NVISPPG_ROOT="$root" bash -c 'set -uo pipefail; . "$0/nvisppg.sh"; "$@"' "$X" "$@"; }
release_file() { mkdir -p "$1/etc"; printf '%s\n' "$2" > "$1/etc/nv_tegra_release"; }

echo "== релиз L4T =="
release_file "$T/r3643" '# R36 (release), REVISION: 4.3, GCID: 38968081, BOARD: generic, EABI: aarch64, DATE: Wed Jan  8 01:49:37 UTC 2025'
release_file "$T/r3644" '# R36 (release), REVISION: 4.4, GCID: 41062509, BOARD: generic, EABI: aarch64'
release_file "$T/r3261" '# R32 (release), REVISION: 6.1, GCID: 27863751, BOARD: t210ref, EABI: aarch64'
release_file "$T/rbad"  'not a release line'
check   "36.4.3 из nv_tegra_release"   bash -c "[ \"\$(NVISPPG_ROOT='$T/r3643' bash -c '. \"$X/nvisppg.sh\"; nvisppg_l4t_release')\" = 36.4.3 ]"
check   "32.6.1 из nv_tegra_release"   bash -c "[ \"\$(NVISPPG_ROOT='$T/r3261' bash -c '. \"$X/nvisppg.sh\"; nvisppg_l4t_release')\" = 32.6.1 ]"
refuses "неразборчивая строка — отказ" nv "$T/rbad" nvisppg_l4t_release
check   "барьер: 36.4.3 проходит"      nv "$T/r3643" nvisppg_gate 36.4.3
refuses "барьер: 36.4.4 — отказ"       nv "$T/r3644" nvisppg_gate 36.4.3
refuses "барьер: 32.6.1 — отказ"       nv "$T/r3261" nvisppg_gate 36.4.3
refuses "барьер: файла нет — отказ"    nv "$T/none" nvisppg_gate 36.4.3

echo "== оверлей камер: скачивание и сверка =="
mkdir -p "$T/src/Linux_for_Tegra"
echo overlay-lib > "$T/src/Linux_for_Tegra/libnvisppg.so"
echo eula > "$T/src/Linux_for_Tegra/EULA-public.txt"
tar -cjf "$T/overlay.tbz2" -C "$T/src" Linux_for_Tegra
TBZ="$(sha256sum "$T/overlay.tbz2" | cut -d' ' -f1)"
LIBSUM="$(sha256sum "$T/src/Linux_for_Tegra/libnvisppg.so" | cut -d' ' -f1)"
ZERO=0000000000000000000000000000000000000000000000000000000000000000
mkdir -p "$T/f1" "$T/f2" "$T/f3" "$T/f4"
check   "сумма сошлась — библиотека извлечена"  nv / nvisppg_fetch "file://$T/overlay.tbz2" "$TBZ" "$LIBSUM" "$T/f1"
check   "…и это она"                            cmp "$T/f1/libnvisppg.so" "$T/src/Linux_for_Tegra/libnvisppg.so"
refuses "sha256 архива не та — отказ"           nv / nvisppg_fetch "file://$T/overlay.tbz2" "$ZERO" "$LIBSUM" "$T/f2"
refuses "…и библиотеки нет"                     test -e "$T/f2/libnvisppg.so"
refuses "sha256 библиотеки не та — отказ"       nv / nvisppg_fetch "file://$T/overlay.tbz2" "$TBZ" "$ZERO" "$T/f3"
refuses "не скачалось — отказ"                  nv / nvisppg_fetch "file://$T/missing.tbz2" "$TBZ" "$LIBSUM" "$T/f4"

echo "== подмена libnvisppg.so =="
STOCK="$(printf 'stock-lib\n' | sha256sum | cut -d' ' -f1)"
mkroot() {
    local r="$1"
    mkdir -p "$r/usr/lib/aarch64-linux-gnu/nvidia" "$r/var/lib/dpkg"
    ln -s nvidia "$r/usr/lib/aarch64-linux-gnu/tegra"
    printf '%s\n' "${2:-stock-lib}" > "$r/usr/lib/aarch64-linux-gnu/nvidia/libnvisppg.so"
    chmod 0644 "$r/usr/lib/aarch64-linux-gnu/nvidia/libnvisppg.so"
}
L=usr/lib/aarch64-linux-gnu/nvidia/libnvisppg.so
mkroot "$T/i1"
check   "штатная → оверлей"                     nv "$T/i1" nvisppg_install "$T/f1/libnvisppg.so" "$STOCK" "$LIBSUM"
check   "…на месте оверлей"                     cmp "$T/i1/$L" "$T/f1/libnvisppg.so"
check   "…штатная сохранена в .distrib"         grep -qx stock-lib "$T/i1/$L.distrib"
check   "…права 0644"                           test "$(stat -c %a "$T/i1/$L")" = 644
check   "…отведение записано в dpkg"            grep -qx "/$L.distrib" "$T/i1/var/lib/dpkg/diversions"
check   "повторный прогон — без изменений"      nv "$T/i1" nvisppg_install "$T/f1/libnvisppg.so" "$STOCK" "$LIBSUM"
check   "…оверлей и .distrib те же"             bash -c "cmp '$T/i1/$L' '$T/f1/libnvisppg.so' && grep -qx stock-lib '$T/i1/$L.distrib'"
mkroot "$T/i2" overlay-lib
check   "база до 2026-09-19 (уже оверлей)"      nv "$T/i2" nvisppg_install "$T/f1/libnvisppg.so" "$STOCK" "$LIBSUM"
check   "…отведение без переименования"         bash -c "grep -qx '/$L.distrib' '$T/i2/var/lib/dpkg/diversions' && [ ! -e '$T/i2/$L.distrib' ]"
mkroot "$T/i3" other-lib
refuses "неизвестная ревизия — отказ"           nv "$T/i3" nvisppg_install "$T/f1/libnvisppg.so" "$STOCK" "$LIBSUM"
check   "…файл не тронут"                       grep -qx other-lib "$T/i3/$L"
mkdir -p "$T/i4/usr/lib/aarch64-linux-gnu/nvidia"
refuses "библиотеки нет — отказ"                nv "$T/i4" nvisppg_install "$T/f1/libnvisppg.so" "$STOCK" "$LIBSUM"
mkroot "$T/i5"; rm "$T/i5/usr/lib/aarch64-linux-gnu/tegra"; mkdir -p "$T/i5/usr/lib/aarch64-linux-gnu/tegra"
printf 'stock-lib\n' > "$T/i5/usr/lib/aarch64-linux-gnu/tegra/libnvisppg.so"
refuses "tegra/ — не ссылка на nvidia/ — отказ" nv "$T/i5" nvisppg_install "$T/f1/libnvisppg.so" "$STOCK" "$LIBSUM"

if command -v shellcheck >/dev/null 2>&1; then
    check "shellcheck -S warning" shellcheck -S warning -x "$X/nvisppg.sh" "$0"
else
    echo "  SKIP shellcheck: нет в PATH"
fi

echo "проверок: $total, не прошло: $fails"
[ "$fails" -eq 0 ]
