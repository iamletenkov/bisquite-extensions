#!/bin/bash
# Шаг 11: пакет прошивки загрузчика по USB — штатный massflash NVIDIA,
# собранный БЕЗ ПЛАТЫ (offline-режим, README_initrd_flash.txt в BSP).
#
#     . profile.sh && load_profile agx-xavier 35.6.5
#     sudo -E ./11-package-bootloader.sh
#
# Значения, которые обычно читаются из EEPROM, подаются переменными
# BOARDID/FAB/BOARDSKU/BOARDREV — они измерены на наших платах и лежат в
# профиле. Архив берётся таким, каким его собирает NVIDIA: из него ничего
# не вырезается (спека, раздел про пакет загрузчика).
set -uo pipefail

: "${WORK:?профиль не загружен: . profile.sh && load_profile <плата> <релиз>}"
LFT="$WORK/Linux_for_Tegra"
OUT_DIR="${OUT_DIR:-$WORK/out}"

for v in BOARD_TARGET BOARDID FAB BOARD_SKU BOARDREV BOOTLOADER_PACKAGE; do
    if [ -z "${!v:-}" ]; then
        echo "ОТКАЗ: $v пуст — значение платы профилем не объявлено"
        exit 1
    fi
done

case "$BOOTLOADER_PACKAGE" in
    qspi-only) MODE=(--qspi-only) ;;
    full)      MODE=() ;;
    *) echo "ОТКАЗ: BOOTLOADER_PACKAGE=$BOOTLOADER_PACKAGE, ждали full или qspi-only"; exit 1 ;;
esac

CMD=(env BOARDID="$BOARDID" FAB="$FAB" BOARDSKU="$BOARD_SKU" BOARDREV="$BOARDREV"
     ./tools/kernel_flash/l4t_initrd_flash.sh --no-flash --massflash 1 --network usb0
     ${MODE[@]+"${MODE[@]}"} "$BOARD_TARGET" internal)

if [ "${DRY_RUN:-0}" = 1 ]; then
    echo "${CMD[*]}"
    exit 0
fi

[ "$(id -u)" -eq 0 ] || { echo "ОТКАЗ: нужен root (sudo -E)"; exit 1; }
[ -x "$LFT/tools/kernel_flash/l4t_initrd_flash.sh" ] \
    || { echo "ОТКАЗ: нет дерева $LFT — сначала 01 и 03"; exit 1; }

# Грабли шагов 03/05: TMPDIR оператора утекает в chroot, а без USER скрипты
# L4T ломаются раньше, чем помогают.
unset TMPDIR
export USER="${USER:-root}"

cd "$LFT" || exit 1
rm -rf -- "mfi_$BOARD_TARGET" "mfi_$BOARD_TARGET.tar.gz"
"${CMD[@]}" || { echo "ОТКАЗ: l4t_initrd_flash.sh вернул $?"; exit 1; }
[ -s "mfi_$BOARD_TARGET.tar.gz" ] || { echo "ОТКАЗ: пакет mfi_$BOARD_TARGET.tar.gz не появился"; exit 1; }

IMG_DIR="mfi_$BOARD_TARGET/tools/kernel_flash/images/internal"
[ -d "$IMG_DIR" ] || { echo "ОТКАЗ: в пакете нет $IMG_DIR"; exit 1; }

mkdir -p "$OUT_DIR"
mv -f "mfi_$BOARD_TARGET.tar.gz" "$OUT_DIR/bootloader.tar.gz"
# Хеши двоичных файлов загрузчика — ими опознаётся пара. system.img* не
# входит: это rootfs, который пакет несёт как следствие формата.
( cd "$IMG_DIR" && find . -type f ! -name 'system.img*' -print0 | sort -z | xargs -0 sha256sum ) \
    > "$OUT_DIR/bootloader-files.sha256"
[ -s "$OUT_DIR/bootloader-files.sha256" ] || { echo "ОТКАЗ: список файлов загрузчика пуст"; exit 1; }

echo "пакет  : $OUT_DIR/bootloader.tar.gz ($(du -h "$OUT_DIR/bootloader.tar.gz" | cut -f1))"
echo "файлов : $(wc -l < "$OUT_DIR/bootloader-files.sha256")"
