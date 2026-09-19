#!/bin/bash
# Шаг 9: одна команда от сырого BSP до артефактов пары.
#
#     . scripts/profile.sh && load_profile agx-xavier 35.6.5
#     sudo -E scripts/09-build-jetson-base.sh [--fresh]
#
# Результат — $OUT_DIR: system.qcow2, bootloader.tar.gz, manifest.json.
# В хранилище bisquite ничего не регистрируется: результат — файлы
# (спека 2026-09-19-jetson-build-and-bootloader.md).
#
# ПОРЯДОК НЕСУЩИЙ. Пакет загрузчика (11) собирается ДО образа (08): внутренний
# манифест несёт хеши файлов загрузчика и должен попасть в rootfs раньше, чем
# из него соберётся qcow2. В архив загрузчика Xavier rootfs уже упакован без
# манифеста — это нормально: тот rootfs — следствие формата пакета, а не система.
#
# The sequence depends on where the system half comes from (ROOTFS_SOURCE):
#   nvidia-bsp    01 -> 03 -> 04 -U -> 11 -> manifest into rootfs -> 08 -> outer
#   vendor-image  01 (BSP only) -> 03 (BSP tree only) -> 11 -> vendor image
#                 fetched and checked -> qcow2.tmp -> manifest into it and the
#                 working name -> outer (spec 2026-09-19-jetson-nano-mixed-pair.md)
#
# --fresh сносит дерево пары и собирает заново: 03 необратим, и учётку,
# созданную прежним прогоном 04 без -U, снять нечем. It also removes the vendor
# image's raw and an unfinished qcow2.tmp — never the downloads cache.
set -uo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
: "${WORK:?профиль не загружен: . profile.sh && load_profile <плата> <релиз>}"
: "${OUT_DIR:?профиль не загружен}"
LFT="$WORK/Linux_for_Tegra"
# Результат пары — ровно $OUT_DIR: манифест хеширует $OUT_DIR/system.qcow2,
# chown отдаёт $OUT_DIR. Унаследованный OUT_QCOW2 (из старой оболочки
# станции) отправил бы qcow2 в другое место, а манифест захешировал бы
# qcow2 ПРОШЛОЙ сборки, оставшийся в $OUT_DIR, — поэтому отказ, а не догадка.
[ "${OUT_QCOW2:-}" = "$OUT_DIR/system.qcow2" ] || {
    echo "ОТКАЗ: OUT_QCOW2=${OUT_QCOW2:-<пусто>}, а результат пары — $OUT_DIR/system.qcow2"
    echo "       (унаследован из окружения? unset OUT_QCOW2 и загрузи профиль заново)"
    exit 1
}
# shellcheck source=/dev/null
. "$SCRIPT_DIR/vendor-image.sh"

FRESH=0
case "${1:-}" in
    --fresh) FRESH=1 ;;
    "") ;;
    *) echo "использование: $0 [--fresh]"; exit 1 ;;
esac

case "${ROOTFS_SOURCE:-}" in
    nvidia-bsp)
        STEPS=(
            "01-fetch-l4t.sh"
            "03-prepare-bsp.sh"
            "04-customize-rootfs.sh -U"
            "11-package-bootloader.sh"
            "manifest:internal"
            "08-build-base-image.sh"
            "manifest:outer"
        ) ;;
    vendor-image)
        STEPS=(
            "01-fetch-l4t.sh"
            "03-prepare-bsp.sh"
            "11-package-bootloader.sh"
            "vendor:fetch"
            "vendor:qcow2"
            "manifest:internal"
            "manifest:outer"
        ) ;;
    *)
        echo "ОТКАЗ: ROOTFS_SOURCE=${ROOTFS_SOURCE:-<пусто>}, ждали nvidia-bsp или vendor-image"
        exit 1 ;;
esac
# What --fresh removes. The downloads cache stays: the vendor image alone is 8.7 GB.
FRESH_PATHS=("$LFT" "$(_vi_raw)" "$(_vi_tmp)")

if [ "${DRY_RUN:-0}" = 1 ]; then
    printf '%s\n' "${STEPS[@]}"
    if [ "$FRESH" -eq 1 ]; then
        printf 'сносится: %s\n' "${FRESH_PATHS[@]}"
    fi
    exit 0
fi

step() { echo; echo "=== $* ==="; }
fail() { echo; echo "ОТКАЗ: $*"; exit 1; }
[ "$(id -u)" -eq 0 ] || fail "нужен root (sudo -E, иначе профиль потеряется)"
echo "пара: $JETSON@$L4T   система: $ROOTFS_SOURCE $ROOTFS_L4T   дерево: $LFT   результат: $OUT_DIR"

if [ "$FRESH" -eq 1 ]; then
    step "--fresh: сношу дерево пары и промежуточные файлы (кеш загрузок остаётся)"
    for p in "${FRESH_PATHS[@]}"; do
        [ -e "$p" ] || continue
        echo "  $p ($(du -sh "$p" | cut -f1))"
        rm -rf -- "$p"
    done
fi

for s in "${STEPS[@]}"; do
    case "$s" in
        03-prepare-bsp.sh)
            step "$s"
            if [ -e "$LFT/rootfs/.applied-binaries" ]; then
                echo "apply_binaries уже накатан — пропуск (заново: --fresh)"
            else
                "$SCRIPT_DIR/03-prepare-bsp.sh" || fail "03 вернул $?"
            fi ;;
        vendor:fetch)
            step "образ вендора -> $WORK/downloads (кеш), сверка sha256"
            vendor_fetch || fail "образ вендора не получен" ;;
        vendor:qcow2)
            step "образ вендора -> $(_vi_tmp)"
            vendor_to_qcow2 || fail "qcow2 из образа вендора не собран" ;;
        manifest:internal)
            if [ "$ROOTFS_SOURCE" = vendor-image ]; then
                step "внутренний манифест -> system.qcow2:/opt/l4t-boot-firmware"
                vendor_put_manifest || fail "внутренний манифест не записан"
            else
                step "внутренний манифест -> rootfs/opt/l4t-boot-firmware"
                python3 "$SCRIPT_DIR/manifest.py" internal \
                    --bootloader-files "$OUT_DIR/bootloader-files.sha256" \
                    --out "$LFT/rootfs/opt/l4t-boot-firmware/manifest.json" \
                    || fail "внутренний манифест не записан"
            fi ;;
        manifest:outer)
            step "внешний манифест -> $OUT_DIR/manifest.json"
            python3 "$SCRIPT_DIR/manifest.py" outer \
                --bootloader-files "$OUT_DIR/bootloader-files.sha256" \
                --out "$OUT_DIR/manifest.json" \
                --artifact "$OUT_DIR/system.qcow2" \
                --artifact "$OUT_DIR/bootloader.tar.gz" \
                || fail "внешний манифест не записан" ;;
        *)
            step "$s"
            # shellcheck disable=SC2086  # "04-customize-rootfs.sh -U": имя и ключ
            "$SCRIPT_DIR/"$s || fail "$s вернул $?" ;;
    esac
done

# Артефакты отдаются человеку, а не root'у. OUT_OWNER задаёт Makefile
# (владелец клона); SUDO_UID — запасной путь при ручном запуске. Одного SUDO_UID
# мало: при `sudo -E make` внутренний sudo от root выставляет его в 0.
owner="${OUT_OWNER:-}"
if [ -z "$owner" ] && [ -n "${SUDO_UID:-}" ]; then
    owner="$SUDO_UID:${SUDO_GID:-$SUDO_UID}"
fi
if [ -n "$owner" ]; then
    chown -R "$owner" "$OUT_DIR"
fi

step "ГОТОВО"
ls -lh "$OUT_DIR"
