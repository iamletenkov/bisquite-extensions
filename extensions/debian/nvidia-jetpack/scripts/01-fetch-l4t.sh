#!/bin/bash
# Шаг 1: скачивание L4T — BSP, sample rootfs и оверлей QSPI. Умолчания — AGX Orin
# (JetPack 6.2, L4T 36.4.3); другая плата задаётся ПРОФИЛЕМ, а не правкой.
#
#     bash /opt/nvidia-jetpack/01-fetch-l4t.sh
#     WORK=/mnt/big/jetson bash /opt/nvidia-jetpack/01-fetch-l4t.sh
#     . /opt/nvidia-jetpack/profile.sh && load_profile agx-xavier 35.6.5
#     bash /opt/nvidia-jetpack/01-fetch-l4t.sh
#
# Качается ~2.4 GB. Скрипт идемпотентен: целые файлы повторно не качаются,
# оборванные — докачиваются.
#
# Root не нужен: пишем только в $WORK. Если каталога нет и создать его
# некому — скрипт скажет, какую команду выполнить под sudo, и остановится.

set -euo pipefail

WORK="${WORK:-/srv/jetson}"
DL="$WORK/downloads"

step() { echo; echo "=== $* ==="; }

# --------------------------------------------------------------- источники
#
# Оговорка про регистр, на которой легко потерять полчаса: на сервере имена
# файлов идут в НИЖНЕМ регистре (r36.4.3), а внутри release_sha_hashes.txt
# те же файлы перечислены с ЗАГЛАВНОЙ R (Jetson_Linux_R36.4.3_aarch64.tbz2).
# Поиск по имени в файле сумм поэтому не находит ничего, и «сумма не нашлась»
# читается как «сверять нечего». Сверяем по зашитым ниже эталонам; сам
# release_sha_hashes.txt качаем справочно, для глаз оператора.
BSP_URL="${BSP_URL:-https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.3/release/Jetson_Linux_r36.4.3_aarch64.tbz2}"
RFS_URL="${RFS_URL:-https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.3/release/Tegra_Linux_Sample-Root-Filesystem_r36.4.3_aarch64.tbz2}"
SHA_URL="${SHA_URL:-https://developer.nvidia.com/downloads/embedded/l4t/r36_release_v4.3/release/release_sha_hashes.txt}"

BSP_SHA1="${BSP_SHA1:-3eb3c5a19a417313383c3bce297e07274a237e36}"   # ~683 MB
RFS_SHA1="${RFS_SHA1:-0bdb4e655d48bdf7e7bd98d3b7b69480576bfd7e}"   # ~1.7 GB

# ОВЕРЛЕЙ НЕОБЯЗАТЕЛЕН, и пустая ссылка здесь — осмысленное значение:
# «этой плате оверлей не положен». У AGX Xavier нет QSPI (загрузчик лежит
# в eMMC модуля) — профиль обнуляет строку. The camera overlay is no longer
# fetched here: libnvisppg.so is the sensing-gmsl2-camera extension's job.
#
# РАСКРЫТИЕ ЧЕРЕЗ `-`, А НЕ `:-`, И ЭТО СУЩЕСТВЕННО: `${VAR:-умолчание}`
# подставляет умолчание и на ПУСТОЕ значение, то есть профиль, обнуливший
# ссылку, получил бы обратно оринский оверлей и скачал его молча.
OV_QSPI_URL="${OV_QSPI_URL-https://developer.nvidia.com/downloads/embedded/L4T/overlay_mb1bct_36.x.tbz2}"

# Что искать в оверлее QSPI, чтобы убедиться: скачан тот файл и тот модуль.
QSPI_OVERLAY_DTS="${QSPI_OVERLAY_DTS:-tegra234-mb1-bct-device-p3701-0000.dts}"
# Чем грепать справочный release_sha_hashes.txt на шаге 4.
SHA_GREP="${SHA_GREP:-Jetson_Linux_R?36\.4\.3|Sample-Root-Filesystem_R?36\.4\.3}"

# Where the pair's system comes from. vendor-image: a ready vendor image
# (Nano: Q-engineering) — NVIDIA's sample rootfs is not needed, the BSP is
# kept for the bootloader only (spec 2026-09-19-jetson-nano-mixed-pair.md).
ROOTFS_SOURCE="${ROOTFS_SOURCE:-nvidia-bsp}"

BSP_FILE=$(basename "$BSP_URL")
RFS_FILE=$(basename "$RFS_URL")
OV_QSPI_FILE=${OV_QSPI_URL:+$(basename "$OV_QSPI_URL")}
SHA_FILE=$(basename "$SHA_URL")

# ------------------------------------------------------------- подготовка
step "0. Рабочий каталог $WORK"
if ! mkdir -p "$DL" 2>/dev/null || [ ! -w "$DL" ]; then
    echo "ОСТАНОВ: не могу писать в $DL"
    echo "Заведи каталог под текущего пользователя:"
    echo "    sudo install -d -o \"\$(id -un)\" -g \"\$(id -gn)\" $WORK"
    exit 1
fi
echo "$DL — пишем сюда"
df -h "$WORK" | tail -1

# ------------------------------------------------------------- скачивание
#
# ГЛАВНАЯ ГРАБЛЯ ЭТОГО ШАГА. Решение «качать или нет» принимается ПО
# КОНТРОЛЬНОЙ СУММЕ, а не по факту существования файла. Оборванная закачка
# (пропал линк, ушёл в reset сервер NVIDIA) оставляет непустой файл, и
# проверка вида `[ -s "$f" ]` объявляет его готовым — распаковка падает
# через полчаса, уже на apply_binaries, и причина выглядит совсем иначе.
#
# Поэтому: всегда wget -c (докачка хвоста), потом сверка. Для файлов без
# зашитого эталона -c тоже полезен — wget сверяет размер с сервером и
# на целом файле честно говорит «nothing to do».
step "1. Скачивание в $DL (полный набор AGX Orin — ~2.4 GB)"
cd "$DL"

fetch() {
    local url=$1 want=${2:-} name
    name=$(basename "$url")
    printf '%-58s ' "$name"
    if [ -n "$want" ] && [ -f "$name" ] \
       && [ "$(sha1sum "$name" | cut -d' ' -f1)" = "$want" ]; then
        echo "уже целый (сумма сошлась)"
        return
    fi
    echo "качаю (wget -c — докачка, если файл был оборван)"
    wget -c -q --show-progress -O "$name" "$url"
}

fetch "$BSP_URL"     "$BSP_SHA1"
if [ "$ROOTFS_SOURCE" = vendor-image ]; then
    echo "sample rootfs                                              система — образ вендора, пропуск"
else
    fetch "$RFS_URL"     "$RFS_SHA1"
fi
if [ -n "$OV_QSPI_URL" ]; then
    fetch "$OV_QSPI_URL"
else
    echo "оверлей QSPI                                               профиль его не объявляет — пропуск"
fi
fetch "$SHA_URL"

# ---------------------------------------------------------------- сверка
step "2. Сверка SHA1 с эталонами"
fail=0
check_sha() {
    local name=$1 want=$2 got
    printf '%-58s ' "$name"
    got=$(sha1sum "$name" | cut -d' ' -f1)
    if [ "$got" = "$want" ]; then
        echo "OK"
    else
        echo "НЕ СОВПАЛА"
        echo "  ждали  : $want"
        echo "  вышло  : $got"
        echo "  размер : $(stat -c%s "$name") байт"
        fail=1
    fi
}
check_sha "$BSP_FILE" "$BSP_SHA1"
[ "$ROOTFS_SOURCE" = vendor-image ] || check_sha "$RFS_FILE" "$RFS_SHA1"

if [ "$fail" -ne 0 ]; then
    echo
    echo "ОСТАНОВ: контрольная сумма не сошлась, распаковывать нельзя."
    echo "Докачка уже отработала, значит файл не обрезан, а испорчен."
    echo "Удали его и запусти скрипт заново:"
    echo "    rm $DL/$BSP_FILE $DL/$RFS_FILE"
    exit 1
fi

# ------------------------------------------------- содержимое оверлея
#
# У оверлея эталонной суммы NVIDIA не публикует, поэтому целостность
# проверяем содержимым: битый tbz2 не перечислится (`tar tf` упадёт), а
# перечислившийся сверяем с тем, что мы от него ждём. Это же ловит подмену
# оверлея на другую ревизию — состав у них разный.
step "3. Состав оверлея QSPI"

if [ -z "$OV_QSPI_URL" ]; then
    echo "профиль оверлея не объявляет — проверять нечего"
fi

if [ -n "$OV_QSPI_URL" ]; then
echo "--- $OV_QSPI_FILE"
if ! qspi_list=$(tar tf "$OV_QSPI_FILE" 2>&1); then
    echo "$qspi_list"
    echo "ОСТАНОВ: архив не читается. Удали и перезапусти: rm $DL/$OV_QSPI_FILE"
    exit 1
fi
printf '%s\n' "$qspi_list"
# Умолчание — модуль p3701-0000 (AGX Orin Developer Kit, 32 GB). Оверлей чинит
# тайминги mb1; без этого dts прошивка QSPI бессмысленна. Имя ищется профилем
# ($QSPI_OVERLAY_DTS): у другого модуля dts называется иначе, и найденный
# «хоть какой-нибудь» означал бы оверлей от чужого железа.
if printf '%s\n' "$qspi_list" | grep -qF "$QSPI_OVERLAY_DTS"; then
    echo "OK: $QSPI_OVERLAY_DTS на месте"
else
    echo "ОСТАНОВ: в оверлее нет $QSPI_OVERLAY_DTS."
    echo "Либо скачался не тот файл, либо NVIDIA переложила состав оверлея."
    exit 1
fi
echo
fi

step "4. Справочно: суммы от NVIDIA"
# Имена внутри — с заглавной R, наши файлы на диске — с маленькой.
# Сверять по нему нечего, смотрим глазами.
grep -iE "$SHA_GREP" "$SHA_FILE" || true

step "ГОТОВО"
ls -lh "$DL"
echo
echo "Дальше — 03-prepare-bsp.sh (распаковка и apply_binaries)."
