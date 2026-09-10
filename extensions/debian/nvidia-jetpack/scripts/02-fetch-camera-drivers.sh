#!/bin/bash
# Шаг 2: драйверы камер Sensing SG8A-AGON-G2Y-A1 под JetPack 6.2 (L4T 36.4.3).
#
#     bash /opt/nvidia-jetpack/02-fetch-camera-drivers.sh
#
# Идемпотентен: уже склонированный репозиторий подтягивается git pull.
# Root не нужен — пишем только в $WORK.
#
# Что за железо: плата-адаптер SG8A-AGON-G2Y-A1 (8 портов GMSL2) и камеры
# на сенсоре AR0233. Тонкость, на которой легко выбрать не тот пункт:
# в меню quick_bring_up.sh модель называется "SG2-AR0233-5300-GMSL2", хотя
# наши камеры маркированы -5200-. Средняя цифра — модель ISP, а не сенсора;
# выбирать надо пункт с AR0233, расхождение в 5200/5300 ожидаемо.
#
# Про соседние ветки: в репозитории лежат также JetPack6.2.1 (L4T 36.4.4)
# и JetPack7.2.1. Переход на них — отдельная задача: другой L4T тянет за
# собой другой BSP в 01-fetch-l4t.sh и другую пару Image/DTB. Не смешивать.

set -euo pipefail

WORK="${WORK:-/srv/jetson}"
REPO_URL=https://github.com/SENSING-Technology/nvidia-jetson-camera-drivers
DEST="$WORK/camera-drivers"

# Путь внутри репозитория. В именах есть пробелы — все обращения к нему
# обязаны быть в кавычках, иначе ломается молча и не там, где заметно.
JETPACK_DIR="Jetson AGX Orin Devkit/SG8A-AGON-G2Y-A1/JetPack6.2"
TARGET_REL="$JETPACK_DIR/SG8A_AGON_G2Y_A1_AGX_Orin_YUV_JP6.2_L4TR36.4.3"

step() { echo; echo "=== $* ==="; }

command -v git >/dev/null 2>&1 || { echo "ОСТАНОВ: нет git"; exit 1; }

step "0. Рабочий каталог $WORK"
if ! mkdir -p "$WORK" 2>/dev/null || [ ! -w "$WORK" ]; then
    echo "ОСТАНОВ: не могу писать в $WORK"
    echo "    sudo install -d -o \"\$(id -un)\" -g \"\$(id -gn)\" $WORK"
    exit 1
fi

step "1. Репозиторий Sensing -> $DEST"
if [ -d "$DEST/.git" ]; then
    echo "уже склонирован, обновляю"
    # --ff-only: локальных правок в этом дереве быть не должно, и если
    # они появились — лучше громкий отказ, чем молчаливый merge-коммит
    # в чужом репозитории.
    git -C "$DEST" pull --ff-only
elif [ -e "$DEST" ]; then
    echo "ОСТАНОВ: $DEST существует, но это не git-репозиторий."
    echo "Убери его и запусти скрипт заново: rm -rf $DEST"
    exit 1
else
    # --depth 1: в репозитории лежат собранные Image и DTB под несколько
    # версий JetPack, полная история тянет лишние гигабайты, а нужна нам
    # ровно одна ревизия — текущая.
    git clone --depth 1 "$REPO_URL" "$DEST"
fi
echo "HEAD: $(git -C "$DEST" log -1 --format='%h %ad %s' --date=short)"

step "2. Проверка целевого каталога"
TARGET="$DEST/$TARGET_REL"
if [ ! -d "$TARGET" ] || [ ! -f "$TARGET/quick_bring_up.sh" ]; then
    echo "ОСТАНОВ: не нашёл драйверы под нашу плату."
    echo "  ждали каталог : $TARGET_REL"
    echo "  и в нём файл  : quick_bring_up.sh"
    echo
    echo "Структура репозитория у Sensing меняется между релизами —"
    echo "смотри, что реально лежит рядом, и правь TARGET_REL в скрипте."
    echo
    if [ -d "$DEST/$JETPACK_DIR" ]; then
        echo "Содержимое \"$JETPACK_DIR\":"
        ls -1 "$DEST/$JETPACK_DIR" | sed 's/^/    /'
    elif [ -d "$DEST/Jetson AGX Orin Devkit/SG8A-AGON-G2Y-A1" ]; then
        echo "Каталога \"$JETPACK_DIR\" нет. Рядом лежат:"
        ls -1 "$DEST/Jetson AGX Orin Devkit/SG8A-AGON-G2Y-A1" | sed 's/^/    /'
    elif [ -d "$DEST/Jetson AGX Orin Devkit" ]; then
        echo "Каталога SG8A-AGON-G2Y-A1 нет. Рядом лежат:"
        ls -1 "$DEST/Jetson AGX Orin Devkit" | sed 's/^/    /'
    else
        echo "Верхний уровень репозитория:"
        ls -1 "$DEST" | sed 's/^/    /'
    fi
    exit 1
fi
echo "OK: $TARGET_REL"

step "3. Что лежит в пакете драйверов"
ls -1 "$TARGET" | sed 's/^/    /'
echo
echo "размер: $(du -sh "$TARGET" | cut -f1)"

step "ГОТОВО"
echo "Пакет драйверов: $TARGET"
echo
echo "Он не ставится сейчас: 04-customize-rootfs.sh кладёт его внутрь"
echo "rootfs (в /opt/sensing), чтобы на плате он был сразу и без сети."
echo "Дальше — 03-prepare-bsp.sh."
