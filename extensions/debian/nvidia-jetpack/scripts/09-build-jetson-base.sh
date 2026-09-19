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
# --fresh сносит дерево пары и собирает заново: 03 необратим, и учётку,
# созданную прежним прогоном 04 без -U, снять нечем.
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

FRESH=0
case "${1:-}" in
    --fresh) FRESH=1 ;;
    "") ;;
    *) echo "использование: $0 [--fresh]"; exit 1 ;;
esac

STEPS=(
    "01-fetch-l4t.sh"
    "02-fetch-camera-drivers.sh"
    "03-prepare-bsp.sh"
    "04-customize-rootfs.sh -U"
    "11-package-bootloader.sh"
    "manifest:internal"
    "08-build-base-image.sh"
    "manifest:outer"
)
if [ "${DRY_RUN:-0}" = 1 ]; then
    printf '%s\n' "${STEPS[@]}"
    exit 0
fi

step() { echo; echo "=== $* ==="; }
fail() { echo; echo "ОТКАЗ: $*"; exit 1; }
[ "$(id -u)" -eq 0 ] || fail "нужен root (sudo -E, иначе профиль потеряется)"
echo "пара: $JETSON@$L4T   дерево: $LFT   результат: $OUT_DIR"

if [ "$FRESH" -eq 1 ] && [ -d "$LFT" ]; then
    step "--fresh: сношу дерево пары ($(du -sh "$LFT" | cut -f1))"
    rm -rf -- "$LFT"
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
        manifest:internal)
            step "внутренний манифест -> rootfs/opt/l4t-boot-firmware"
            python3 "$SCRIPT_DIR/manifest.py" internal \
                --bootloader-files "$OUT_DIR/bootloader-files.sha256" \
                --out "$LFT/rootfs/opt/l4t-boot-firmware/manifest.json" \
                || fail "внутренний манифест не записан" ;;
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
