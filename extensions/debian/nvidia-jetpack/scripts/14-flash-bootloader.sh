#!/bin/bash
# Шаг 14: прошить загрузчик пакетом из make build — без дерева BSP.
#
#     . profile.sh && load_profile agx-xavier 35.6.5
#     sudo -E ./14-flash-bootloader.sh
#
# НЕОБРАТИМО. Прежде чем трогать плату, пакет сверяется трижды: пара,
# сумма архива, суммы файлов загрузчика. Любое расхождение — отказ.
#
# The flashing tool comes from the board (BOOTLOADER_TOOL): initrd-flash on
# AGX (l4t_initrd_flash.sh --flash-only, README_initrd_flash.txt, Workflow 7),
# nvmassflashgen on Nano (the package's own nvmflash.sh, README_Massflash.txt).
# All checks before flashing are shared.
#
# ⚠️ Заливка пакетом НЕ ПРОВЕРЕНА на железе (спека). Первый прогон — с монитором
# и консолью на плате.
set -uo pipefail

: "${OUT_DIR:?профиль не загружен}"
PKG="$OUT_DIR/bootloader.tar.gz"
MAN="$OUT_DIR/manifest.json"
FLASH_DIR="$OUT_DIR/.flash"
fail() { echo "ОТКАЗ: $*"; exit 1; }
MANIFEST_PY="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/manifest.py"
export MANIFEST_PY

[ -s "$PKG" ] || fail "нет $PKG — сначала make build"
[ -s "$MAN" ] || fail "нет $MAN — сначала make build"

# Where the bootloader files sit inside the package, and whether files the
# manifest does not list are tolerated. The Nano package is flat and hashed
# whole (minus the build and flash logs), so an unlisted file there is a
# substitution, not clutter.
case "${BOOTLOADER_TOOL:-}" in
    initrd-flash)   hash_rel=tools/kernel_flash/images/internal; hash_mode=listed ;;
    nvmassflashgen) hash_rel=.; hash_mode=strict ;;
    *) fail "BOOTLOADER_TOOL=${BOOTLOADER_TOOL:-<пусто>}, ждали initrd-flash или nvmassflashgen" ;;
esac

# Пара сверяется ПОЛНОСТЬЮ — всеми полями, которые manifest.py записал в
# "pair", а не только (jetson, l4t). Offline-пакет EEPROM платы не читает:
# манифест — единственное место, где ревизия (BOARDID/FAB/BOARD_SKU/BOARDREV)
# вообще записана. Правка профиля без пересборки пакета (другой SKU модуля)
# иначе прошла бы молча. Сверка — до распаковки.
board_line="$(PYTHONDONTWRITEBYTECODE=1 python3 - "$MAN" <<'PY'
import json, os, sys
sys.path.insert(0, os.path.dirname(os.environ["MANIFEST_PY"]))
from manifest import PROFILE_KEYS
p = json.load(open(sys.argv[1]))["pair"]
if (p.get("jetson"), p.get("l4t")) != (os.environ.get("JETSON"), os.environ.get("L4T")):
    sys.exit(f"ОТКАЗ: пакет от {p.get('jetson')}@{p.get('l4t')}, а просили "
             f"{os.environ.get('JETSON')}@{os.environ.get('L4T')}")
bad = [f"{k.lower()}: в манифесте {p.get(k.lower())!r}, в профиле {os.environ.get(k)!r}"
       for k in PROFILE_KEYS if p.get(k.lower()) != os.environ.get(k)]
if bad:
    sys.exit("ОТКАЗ: пакет собран не под этот профиль — пересобери (make build):\n  "
             + "\n  ".join(bad))
print(" ".join(f"{k}={p[k]}" for k in
               ("board_target", "boardid", "fab", "board_sku", "boardrev", "bootloader_package")))
PY
)" || exit 1
echo "пара: сошлась с манифестом ($board_line)"

want="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["artifacts"]["bootloader.tar.gz"])' "$MAN")"
got="$(sha256sum "$PKG" | cut -d' ' -f1)"
[ "$want" = "$got" ] || fail "сумма архива не совпала с манифестом (ждали $want, вышло $got)"
echo "архив: сумма сошлась"

rm -rf -- "$FLASH_DIR"
mkdir -p "$FLASH_DIR"
# Распакованный пакет — до 12 ГБ от root. После DRY_RUN и отказа он не нужен
# никому; ловушка снимается только перед настоящей заливкой (см. ниже).
trap 'rm -rf -- "$FLASH_DIR"' EXIT
tar -xzf "$PKG" -C "$FLASH_DIR" || fail "архив не распаковался"
MFI="$FLASH_DIR/mfi_$BOARD_TARGET"
[ -d "$MFI/$hash_rel" ] || fail "в архиве нет mfi_$BOARD_TARGET/$hash_rel — пакет от другой платы?"
if [ "$BOOTLOADER_TOOL" = nvmassflashgen ] && [ ! -x "$MFI/nvmflash.sh" ]; then
    fail "в архиве нет исполняемого mfi_$BOARD_TARGET/nvmflash.sh"
fi
python3 - "$MAN" "$MFI/$hash_rel" "$hash_mode" <<'PY' || exit 1
import hashlib, json, sys
from pathlib import Path
want = json.load(open(sys.argv[1]))["bootloader_files"]
root = Path(sys.argv[2])
bad = [n for n, d in want.items()
       if not (root / n).is_file() or hashlib.sha256((root / n).read_bytes()).hexdigest() != d]
if bad:
    sys.exit("ОТКАЗ: файлы загрузчика не совпали с манифестом: " + ", ".join(bad))
if sys.argv[3] == "strict":
    # The same two exclusions as step 11: the build log and the flash logs.
    have = {"./" + p.relative_to(root).as_posix() for p in root.rglob("*") if p.is_file()}
    extra = sorted(n for n in have - set(want)
                   if n != "./mfi.log" and not n.startswith("./mfilogs/"))
    if extra:
        sys.exit("ОТКАЗ: в пакете файлы, которых нет в манифесте: " + ", ".join(extra))
print(f"файлы загрузчика: {len(want)} сошлись")
PY

if [ "${DRY_RUN:-0}" = 1 ]; then
    echo "DRY_RUN: проверки пройдены, прошивка не выполнялась"
    exit 0
fi

[ "$(id -u)" -eq 0 ] || fail "нужен root (sudo -E)"
host="$(lsb_release -rs 2>/dev/null || echo ?)"
case " ${FLASH_HOSTS:-} " in
    *" $host "*) ;;
    *) echo "ВНИМАНИЕ: хост Ubuntu $host, NVIDIA для L4T $L4T называет: ${FLASH_HOSTS:-?}" ;;
esac
# Exactly one NVIDIA device, and it must be THIS board in recovery: any other
# 0955: device would be a different SoC or a second board. For Nano the check
# carries double weight: nvmflash.sh flashes EVERY board in recovery at once.
# Checked again after «да» — a board plugged in while the question waits
# would otherwise be flashed too.
one_board() {
    local usb all mine
    usb="$(lsusb)"
    all="$(grep -c 'ID 0955:' <<<"$usb")"
    mine="$(grep -c "ID 0955:${RCM_USB_ID:?профиль без RCM_USB_ID} " <<<"$usb")"
    [ "$all" -eq 1 ] && [ "$mine" -eq 1 ] \
        || fail "в recovery ждали ровно одну плату 0955:$RCM_USB_ID ($JETSON), видно NVIDIA: $all, из них $JETSON: $mine"
}
one_board

cat <<WARN

Будет прошит ЗАГРУЗЧИК платы $JETSON пакетом L4T $L4T.
Плата по манифесту пакета: $board_line
$( [ "$BOOTLOADER_PACKAGE" = full ] && echo "Пакет полный: во внутреннюю eMMC запишется и rootfs (войти в неё нечем — учётки нет)." )
$( [ "$BOOTLOADER_TOOL" = nvmassflashgen ] && echo "nvmflash.sh шьёт ВСЕ платы в recovery разом — поэтому проверено, что она одна. Слотов A/B нет: прерванная заливка QSPI лечится только повторной заливкой в recovery." )
НЕОБРАТИМО. Во время заливки нельзя: выдёргивать кабель, снимать питание, жать Ctrl+C.
WARN
printf 'Введи "да" для запуска: '
read -r answer
[ "$answer" = "да" ] || { echo "Отменено — на плату ничего не записано."; exit 1; }
one_board

unset TMPDIR
export USER="${USER:-root}"
# После заливки дерево остаётся: заливка пакетом на железе не проверена,
# и журналы внутри него — единственные улики при сбое.
trap - EXIT
cd "$MFI" || exit 1
case "$BOOTLOADER_TOOL" in
    initrd-flash)
        MODE=()
        [ "$BOOTLOADER_PACKAGE" = qspi-only ] && MODE=(--qspi-only)
        ./tools/kernel_flash/l4t_initrd_flash.sh --flash-only --massflash 1 --network usb0 \
            ${MODE[@]+"${MODE[@]}"} 2>&1 | tee "$OUT_DIR/flash-bootloader.log"
        rc="${PIPESTATUS[0]}" ;;
    nvmassflashgen)
        # nvmflash.sh: 0 is success, 7 is "WITH FAILURES"; per-board logs go to
        # mfilogs/. A timestamped copy keeps the logs of earlier runs.
        ./nvmflash.sh 2>&1 | tee "$OUT_DIR/flash-bootloader.log"
        rc="${PIPESTATUS[0]}"
        if [ -d mfilogs ]; then
            cp -a mfilogs "$OUT_DIR/mfilogs-$(date +%Y%m%dT%H%M%S)"
        fi ;;
esac
exit "$rc"
