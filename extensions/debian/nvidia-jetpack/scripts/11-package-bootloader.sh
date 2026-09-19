#!/bin/bash
# Шаг 11: пакет прошивки загрузчика по USB, собранный БЕЗ ПЛАТЫ (offline).
#
#     . profile.sh && load_profile agx-xavier 35.6.5
#     sudo -E ./11-package-bootloader.sh
#
# Значения, которые обычно читаются из EEPROM, подаются переменными
# BOARDID/FAB/BOARDSKU/BOARDREV — они измерены на наших платах и лежат в
# профиле. Архив берётся таким, каким его собирает NVIDIA: из него ничего
# не вырезается (спека, раздел про пакет загрузчика).
#
# The tool comes from the board (BOOTLOADER_TOOL):
#   initrd-flash    AGX: l4t_initrd_flash.sh --massflash (README_initrd_flash.txt);
#   nvmassflashgen  Nano (t210, R32): nvmassflashgen.sh (README_Massflash.txt).
#                   R32 for t210 has no tools/kernel_flash/ at all.
# Both end as $OUT_DIR/bootloader.tar.gz and $OUT_DIR/bootloader-files.sha256.
set -uo pipefail

: "${WORK:?профиль не загружен: . profile.sh && load_profile <плата> <релиз>}"
LFT="$WORK/Linux_for_Tegra"
OUT_DIR="${OUT_DIR:-$WORK/out}"

for v in BOARD_TARGET BOARDID FAB BOARD_SKU BOARDREV BOOTLOADER_PACKAGE BOOTLOADER_TOOL; do
    if [ -z "${!v:-}" ]; then
        echo "ОТКАЗ: $v пуст — значение платы профилем не объявлено"
        exit 1
    fi
done

case "$BOOTLOADER_TOOL" in
    initrd-flash)
        case "$BOOTLOADER_PACKAGE" in
            qspi-only) MODE=(--qspi-only) ;;
            full)      MODE=() ;;
            *) echo "ОТКАЗ: BOOTLOADER_PACKAGE=$BOOTLOADER_PACKAGE, ждали full или qspi-only"; exit 1 ;;
        esac
        CMD=(env BOARDID="$BOARDID" FAB="$FAB" BOARDSKU="$BOARD_SKU" BOARDREV="$BOARDREV"
             ./tools/kernel_flash/l4t_initrd_flash.sh --no-flash --massflash 1 --network usb0
             ${MODE[@]+"${MODE[@]}"} "$BOARD_TARGET" internal)
        TOOL=tools/kernel_flash/l4t_initrd_flash.sh
        ARCHIVE="mfi_$BOARD_TARGET.tar.gz" ;;
    nvmassflashgen)
        # Strictly jetson-nano-qspi: its layout is the SPI flash only with
        # NO_ROOTFS=1. The neighbours jetson-nano-qspi-sd and jetson-nano-devkit
        # carry <device type="sdcard"> with APP — a package built from them
        # would describe writing the SD card. This refusal guards against
        # someone "fixing" the name.
        if [ "${SOC:-}" != t210 ] || [ "$BOARD_TARGET" != jetson-nano-qspi ]; then
            echo "ОТКАЗ: nvmassflashgen собирает только t210 с целью jetson-nano-qspi"
            echo "       (SOC=${SOC:-?}, BOARD_TARGET=$BOARD_TARGET): у -qspi-sd и -devkit в разметке SD-карта"
            exit 1
        fi
        CMD=(env BOARDID="$BOARDID" BOARDSKU="$BOARD_SKU" FAB="$FAB" BOARDREV="$BOARDREV"
             FUSELEVEL=fuselevel_production ./nvmassflashgen.sh "$BOARD_TARGET" mmcblk0p1)
        TOOL=nvmassflashgen.sh
        ARCHIVE="mfi_$BOARD_TARGET.tbz2" ;;
    *)
        echo "ОТКАЗ: BOOTLOADER_TOOL=$BOOTLOADER_TOOL, ждали initrd-flash или nvmassflashgen"
        exit 1 ;;
esac

if [ "${DRY_RUN:-0}" = 1 ]; then
    echo "${CMD[*]}"
    exit 0
fi

[ "$(id -u)" -eq 0 ] || { echo "ОТКАЗ: нужен root (sudo -E)"; exit 1; }
[ -x "$LFT/$TOOL" ] || { echo "ОТКАЗ: нет $LFT/$TOOL — сначала 01 и 03"; exit 1; }

# Грабли шагов 03/05: TMPDIR оператора утекает в chroot, а без USER скрипты
# L4T ломаются раньше, чем помогают.
unset TMPDIR
export USER="${USER:-root}"

cd "$LFT" || exit 1
rm -rf -- "mfi_$BOARD_TARGET" "bootloader/mfi_$BOARD_TARGET" "$ARCHIVE"
if [ "$BOOTLOADER_TOOL" = nvmassflashgen ]; then
    # flash.sh copies nv_boot_control.conf to rootfs/etc; with an empty rootfs/
    # that makes a FILE named etc (flash.sh:2701-2702).
    [ -d rootfs/etc ] || rm -f -- rootfs/etc
    mkdir -p rootfs/etc
fi
"${CMD[@]}" || { echo "ОТКАЗ: $TOOL вернул $?"; exit 1; }
[ -s "$ARCHIVE" ] || { echo "ОТКАЗ: пакет $ARCHIVE не появился"; exit 1; }
mkdir -p "$OUT_DIR"

case "$BOOTLOADER_TOOL" in
    initrd-flash)
        IMG_DIR="mfi_$BOARD_TARGET/tools/kernel_flash/images/internal"
        [ -d "$IMG_DIR" ] || { echo "ОТКАЗ: в пакете нет $IMG_DIR"; exit 1; }
        mv -f "$ARCHIVE" "$OUT_DIR/bootloader.tar.gz"
        # Хеши двоичных файлов загрузчика — ими опознаётся пара. system.img* не
        # входит: это rootfs, который пакет несёт как следствие формата.
        ( cd "$IMG_DIR" && find . -type f ! -name 'system.img*' -print0 | sort -z | xargs -0 sha256sum ) \
            > "$OUT_DIR/bootloader-files.sha256" ;;
    nvmassflashgen)
        # Re-encode the stream instead of unpacking and re-packing: the tar
        # stream stays byte-identical — modes (+x on nvmflash.sh, tegrarcm…),
        # owners, links. Every board ships one artifact, bootloader.tar.gz.
        # gzip -n: no name and no timestamp in the gzip header.
        gz="$OUT_DIR/bootloader.tar.gz.tmp"
        bzip2 -dc "$ARCHIVE" | gzip -n > "$gz" \
            || { rm -f -- "$gz"; echo "ОТКАЗ: перекодирование $ARCHIVE не удалось"; exit 1; }
        cmp -s <(bzip2 -dc "$ARCHIVE") <(gzip -dc "$gz") \
            || { rm -f -- "$gz"; echo "ОТКАЗ: tar-поток после перекодирования не совпал с $ARCHIVE"; exit 1; }
        mv -f -- "$gz" "$OUT_DIR/bootloader.tar.gz"
        # Hashes are taken from what SHIPPED — a fresh unpack of the artifact —
        # not from bootloader/mfi_<target> that nvmassflashgen leaves in the tree.
        x="$(mktemp -d "$WORK/.mfi-hash.XXXXXX")" || exit 1
        trap 'rm -rf -- "$x"' EXIT
        tar -xzf "$OUT_DIR/bootloader.tar.gz" -C "$x" || { echo "ОТКАЗ: пакет не распаковался"; exit 1; }
        [ -x "$x/mfi_$BOARD_TARGET/nvmflash.sh" ] \
            || { echo "ОТКАЗ: в пакете нет исполняемого mfi_$BOARD_TARGET/nvmflash.sh"; exit 1; }
        # The hash root is the whole flat package minus two names: mfi.log (the
        # generator's build log, different on every build, never flashed) and
        # mfilogs/ (written by nvmflash.sh while flashing). Scripts and host
        # tools stay in: nvmflash.sh, nvaflash.sh, tegrarcm, tegradevflash run
        # as root and decide what lands in QSPI. Step 14 uses the same two names.
        ( cd "$x/mfi_$BOARD_TARGET" \
            && find . -type f ! -path ./mfi.log ! -path './mfilogs/*' -print0 | sort -z | xargs -0 sha256sum ) \
            > "$OUT_DIR/bootloader-files.sha256" \
            || { echo "ОТКАЗ: хеши файлов загрузчика не посчитались"; exit 1; } ;;
esac
[ -s "$OUT_DIR/bootloader-files.sha256" ] || { echo "ОТКАЗ: список файлов загрузчика пуст"; exit 1; }

echo "пакет  : $OUT_DIR/bootloader.tar.gz ($(du -h "$OUT_DIR/bootloader.tar.gz" | cut -f1))"
echo "файлов : $(wc -l < "$OUT_DIR/bootloader-files.sha256")"
