#!/bin/bash
# Шаг 14: прошить загрузчик пакетом из make build — без дерева BSP.
#
#     . profile.sh && load_profile agx-xavier 35.6.5
#     sudo -E ./14-flash-bootloader.sh
#
# НЕОБРАТИМО. Прежде чем трогать плату, пакет сверяется трижды: пара,
# сумма архива, суммы файлов загрузчика. Любое расхождение — отказ.
#
# ⚠️ Заливка пакетом НЕ ПРОВЕРЕНА на железе (спека): команда --flash-only
# взята из README_initrd_flash.txt, Workflow 7. Первый прогон — с монитором
# и консолью на плате.
set -uo pipefail

: "${OUT_DIR:?профиль не загружен}"
PKG="$OUT_DIR/bootloader.tar.gz"
MAN="$OUT_DIR/manifest.json"
FLASH_DIR="$OUT_DIR/.flash"
fail() { echo "ОТКАЗ: $*"; exit 1; }

[ -s "$PKG" ] || fail "нет $PKG — сначала make build"
[ -s "$MAN" ] || fail "нет $MAN — сначала make build"

python3 - "$MAN" "$JETSON" "$L4T" <<'PY' || exit 1
import json, sys
p = json.load(open(sys.argv[1]))["pair"]
if (p["jetson"], p["l4t"]) != (sys.argv[2], sys.argv[3]):
    sys.exit(f"ОТКАЗ: пакет от {p['jetson']}@{p['l4t']}, а просили {sys.argv[2]}@{sys.argv[3]}")
PY

want="$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["artifacts"]["bootloader.tar.gz"])' "$MAN")"
got="$(sha256sum "$PKG" | cut -d' ' -f1)"
[ "$want" = "$got" ] || fail "сумма архива не совпала с манифестом (ждали $want, вышло $got)"
echo "архив: сумма сошлась"

rm -rf -- "$FLASH_DIR"
mkdir -p "$FLASH_DIR"
tar -xzf "$PKG" -C "$FLASH_DIR" || fail "архив не распаковался"
MFI="$FLASH_DIR/mfi_$BOARD_TARGET"
[ -d "$MFI/tools/kernel_flash/images/internal" ] || fail "в архиве нет mfi_$BOARD_TARGET — пакет от другой платы?"
python3 - "$MAN" "$MFI/tools/kernel_flash/images/internal" <<'PY' || exit 1
import hashlib, json, sys
from pathlib import Path
want = json.load(open(sys.argv[1]))["bootloader_files"]
root = Path(sys.argv[2])
bad = [n for n, d in want.items()
       if not (root / n).is_file() or hashlib.sha256((root / n).read_bytes()).hexdigest() != d]
if bad:
    sys.exit("ОТКАЗ: файлы загрузчика не совпали с манифестом: " + ", ".join(bad))
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
n="$(lsusb | grep -c 'ID 0955:')"
[ "$n" -eq 1 ] || fail "в recovery ждали ровно одну плату NVIDIA (0955:), видно $n"

cat <<WARN

Будет прошит ЗАГРУЗЧИК платы $JETSON пакетом L4T $L4T.
$( [ "$BOOTLOADER_PACKAGE" = full ] && echo "Пакет полный: во внутреннюю eMMC запишется и rootfs (войти в неё нечем — учётки нет)." )
НЕОБРАТИМО. Во время заливки нельзя: выдёргивать кабель, снимать питание, жать Ctrl+C.
WARN
printf 'Введи "да" для запуска: '
read -r answer
[ "$answer" = "да" ] || { echo "Отменено — на плату ничего не записано."; exit 1; }

MODE=()
[ "$BOOTLOADER_PACKAGE" = qspi-only ] && MODE=(--qspi-only)
unset TMPDIR
export USER="${USER:-root}"
cd "$MFI" || exit 1
./tools/kernel_flash/l4t_initrd_flash.sh --flash-only --massflash 1 --network usb0 \
    ${MODE[@]+"${MODE[@]}"} 2>&1 | tee "$OUT_DIR/flash-bootloader.log"
exit "${PIPESTATUS[0]}"
