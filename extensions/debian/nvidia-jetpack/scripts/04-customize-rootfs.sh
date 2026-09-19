#!/bin/bash
# Шаг 4: подготовка rootfs Jetson ДО генерации system.img.
#
#     sudo /opt/nvidia-jetpack/04-customize-rootfs.sh -u jetson -p 'пароль' [-n orin]
#
# Правка Linux_for_Tegra/rootfs/ перед сборкой образа официально поддерживается
# NVIDIA — это штатный способ внести в систему то, что иначе пришлось бы
# доставлять на уже прошитой плате, с монитором, клавиатурой и сетью.
#
# Порядок в цепочке: 03 распаковал BSP и накатил apply_binaries, здесь дерево
# доводится до готовности, 05 превращает его в system.img. Запускать после 05
# бессмысленно: образ уже собран, правка дерева в него не попадёт.
#
# Работаем НАТИВНО, на самой станции (Ubuntu 22.04). Никакого промежуточного
# chroot в jammy тут нет и быть не должно — станция и есть jammy. Единственный
# chroot — в целевой arm64-rootfs через qemu-aarch64-static.

set -uo pipefail

WORK="${WORK:-/srv/jetson}"
LFT="$WORK/Linux_for_Tegra"
ROOTFS="$LFT/rootfs"
# Cameras are not the base image's business any more: the Sensing drivers
# and the camera packages come from the sensing-gmsl2-camera extension
# (owner's decision 2026-09-18, spec 2026-09-18-jetson-release-matrix.md).
# This step only readies the tree.

step() { echo; echo "=== $* ==="; }

usage() {
    cat <<'USAGE'
Использование:
  04-customize-rootfs.sh -u ПОЛЬЗОВАТЕЛЬ -p ПАРОЛЬ [-n ИМЯ_ХОСТА]

  -u   имя пользователя, создаваемого в системе платы
  -p   его пароль
  -n   имя хоста платы (необязательно; по умолчанию — как решит L4T)
  -U   НЕ создавать пользователя вовсе — в системе остаётся только root.
       Несовместим с -u/-p. Для образов, куда учётку кладёт cloud-init
       при записи (bs device write), а не вендорский скрипт при сборке:
       базовый образ флота не должен нести ничьи конкретные креды.

Ровно одно из двух: либо -u и -p ВМЕСТЕ (обязательны друг с другом),
либо -U одна. Умолчаний у -u и -p нет намеренно: пароль, зашитый в скрипт,
попал бы в репозиторий и оттуда в каждый собранный образ. Учётные данные
задаёт оператор в момент сборки конкретной платы; для образа, который
разойдётся на флот, это -U.

Обход oem-config (мастера первичной настройки) происходит в ОБОИХ режимах
одинаково: он не привязан к созданию пользователя, это отдельный симлинк
default.target -> nv-oem-config.target, который снимается независимо.

Переменные окружения:
  WORK        рабочий каталог станции (умолчание /srv/jetson)
USAGE
}

USER_NAME=""
PASSWORD=""
HOSTNAME_ARG=""
SKIP_USER=0

while getopts ":u:p:n:Uh" opt; do
    case "$opt" in
        u) USER_NAME="$OPTARG" ;;
        p) PASSWORD="$OPTARG" ;;
        n) HOSTNAME_ARG="$OPTARG" ;;
        U) SKIP_USER=1 ;;
        h) usage; exit 0 ;;
        :) echo "ОШИБКА: у -$OPTARG нет значения"; echo; usage; exit 1 ;;
        \?) echo "ОШИБКА: неизвестный ключ -$OPTARG"; echo; usage; exit 1 ;;
    esac
done

if [ "$SKIP_USER" -eq 1 ]; then
    if [ -n "$USER_NAME" ] || [ -n "$PASSWORD" ]; then
        echo "ОШИБКА: -U несовместим с -u/-p — либо учётка, либо её нет."
        echo
        usage
        exit 1
    fi
elif [ -z "$USER_NAME" ] || [ -z "$PASSWORD" ]; then
    echo "ОШИБКА: -u и -p обязательны (или используй -U, чтобы не создавать"
    echo "  пользователя вовсе)."
    echo
    usage
    exit 1
fi

[ "$(id -u)" -eq 0 ] || { echo "Нужен root"; exit 1; }

step "0. Проверка дерева BSP"
[ -d "$LFT" ] || { echo "ОСТАНОВ: нет $LFT — сначала 03-prepare-bsp.sh"; exit 1; }
[ -x "$ROOTFS/bin/bash" ] || { echo "ОСТАНОВ: rootfs не распакован — сначала 03-prepare-bsp.sh"; exit 1; }
[ -e "$ROOTFS/.applied-binaries" ] || {
    echo "ОСТАНОВ: apply_binaries.sh не накатан на это дерево."
    echo "Кастомизировать rootfs до него бессмысленно: он перезапишет часть файлов."
    exit 1
}
# Бинд-монтирование хостового /dev в целевой rootfs — то, чего здесь быть
# не должно: ниже стоит rm узла /dev/null, и поверх смонтированного /dev
# он снёс бы его у СТАНЦИИ.
if mountpoint -q "$ROOTFS/dev" 2>/dev/null; then
    echo "ОСТАНОВ: $ROOTFS/dev смонтирован. Отмонтируй его: umount $ROOTFS/dev"
    exit 1
fi
echo "OK: $LFT"

# --------------------------------------------------------------------------
step "1. Пользователь и отключение oem-config"
# l4t_create_default_user.sh делает ДВЕ вещи, и вторая важнее первой:
# создаёт пользователя И снимает мастер первичной настройки (oem-config).
# Без него плата на первой загрузке останавливается на экране «выберите язык
# и часовой пояс» и ждёт человека с монитором и клавиатурой — то есть
# заливка вслепую, «прошил и поставил на полку», не работает вовсе.
# Ключ -a включает автологин созданного пользователя.
cd "$LFT" || exit 1

if [ "$SKIP_USER" -eq 1 ]; then
    # Пользователя не создаём вовсе — но oem-config снять всё равно надо,
    # иначе первая загрузка встанет на мастер настройки без сети и монитора.
    # l4t_create_default_user.sh делает это строкой
    # `rm -f etc/systemd/system/default.target` как ПОБОЧНЫЙ эффект создания
    # учётки; здесь та же строка — ЕДИНСТВЕННОЕ, что нам от него нужно.
    NON_ROOT=$(awk -F: '$3 >= 1000 && $3 != 65534 {print $1}' "$ROOTFS/etc/passwd" 2>/dev/null)
    if [ -n "$NON_ROOT" ]; then
        echo "ПРЕДУПРЕЖДЕНИЕ: -U просили, но в дереве уже есть учётка(и): $NON_ROOT"
        echo "  -U их не удаляет — дерево не чистое. Начни заново с 03-prepare-bsp.sh,"
        echo "  если нужен образ ровно с одним root."
    else
        echo "пользователя не создаю (-U) — в системе останется только root"
    fi
    rm -f "$ROOTFS/etc/systemd/system/default.target"
elif grep -q "^${USER_NAME}:" "$ROOTFS/etc/passwd" 2>/dev/null; then
    echo "пользователь '$USER_NAME' в rootfs уже есть — повторно не создаю"
    echo "(если нужен другой пароль — начни дерево заново с 03-prepare-bsp.sh)"
else
    CREATE_ARGS=(-u "$USER_NAME" -p "$PASSWORD" -a)
    [ -n "$HOSTNAME_ARG" ] && CREATE_ARGS+=(-n "$HOSTNAME_ARG")
    # --accept-license есть не во всех версиях BSP; без него скрипт в части
    # выпусков останавливается на подтверждении лицензии и ждёт ввода,
    # то есть автоматический прогон подвисает. Добавляем, только если ключ
    # реально объявлен в этом BSP, а не «на всякий случай».
    if grep -q -- '--accept-license' tools/l4t_create_default_user.sh 2>/dev/null; then
        CREATE_ARGS+=(--accept-license)
    fi
    echo "запускаю: tools/l4t_create_default_user.sh -u $USER_NAME -p *** ${CREATE_ARGS[*]:4}"
    ./tools/l4t_create_default_user.sh "${CREATE_ARGS[@]}"
    rc=$?
    if [ "$rc" -ne 0 ]; then
        echo "ОСТАНОВ: l4t_create_default_user.sh вернул $rc"
        exit 1
    fi
    grep -q "^${USER_NAME}:" "$ROOTFS/etc/passwd" \
        || { echo "ОСТАНОВ: скрипт отработал, но пользователя в rootfs/etc/passwd нет"; exit 1; }
    echo "пользователь '$USER_NAME' создан"
fi

# Проверяем результат по факту, а не по имени файла-маркера: имена юнитов
# oem-config между выпусками L4T менялись, а вопрос всегда один — взведён ли
# мастер первичной настройки.
#
# Факт — это ОДИН симлинк: /etc/systemd/system/default.target ->
# nv-oem-config.target, он перекрывает штатный
# /lib/systemd/system/default.target -> graphical.target. Именно его снимает
# tools/l4t_create_default_user.sh («remove default.target symlink to bypass
# oem config setup»). А сами юниты nv-oem-config.* лежат в rootfs ВСЕГДА,
# поэтому прежний поиск по имени (`find -name '*oem-config*'`) давал ложную
# тревогу на каждом прогоне: файлы есть, а мастер не взведён — проверено
# 2026-09-11 на прошитой плате (default.target отсутствует,
# `systemctl get-default` = graphical.target, nv-oem-config.service inactive).
OEM_LEFT=""
OEM_DEFAULT_TARGET="$ROOTFS/etc/systemd/system/default.target"
if [ -L "$OEM_DEFAULT_TARGET" ]; then
    # readlink БЕЗ -f: цель симлинка абсолютна внутри дерева платы
    # (/lib/systemd/system/nv-oem-config.target), и -f разрешал бы её
    # по корню СТАНЦИИ, то есть смотрел бы не туда.
    OEM_TARGET_LINK="$(readlink "$OEM_DEFAULT_TARGET")"
    case "$(basename "$OEM_TARGET_LINK")" in
        *oem-config*) OEM_LEFT="default.target -> $OEM_TARGET_LINK" ;;
    esac
elif [ -e "$OEM_DEFAULT_TARGET" ]; then
    # Не симлинк, а подложенный файл юнита — такое же переопределение
    # штатного default.target, поэтому смотрим в содержимое.
    if grep -q 'oem-config' "$OEM_DEFAULT_TARGET" 2>/dev/null; then
        OEM_LEFT="default.target (файл юнита, ссылается на oem-config)"
    fi
fi

if [ -n "$OEM_LEFT" ]; then
    echo "ПРЕДУПРЕЖДЕНИЕ: мастер первичной настройки взведён — $OEM_LEFT"
    echo "Первая загрузка потребует монитор и клавиатуру."
    echo "Поправить: rm -f $OEM_DEFAULT_TARGET"
elif [ -e "$OEM_DEFAULT_TARGET" ] || [ -L "$OEM_DEFAULT_TARGET" ]; then
    echo "oem-config не взведён: default.target ведёт не на него" \
         "($(readlink "$OEM_DEFAULT_TARGET" 2>/dev/null || echo 'файл юнита'))"
else
    echo "oem-config не взведён: /etc/systemd/system/default.target нет,"
    echo "  значит действует штатный /lib/systemd/system/default.target -> graphical.target"
fi

# --------------------------------------------------------------------------
step "2. Две правки дерева, без которых не работает apt"
# Нужны ВСЕГДА: каждая ломает apt и в chroot, и в слоях bisquite поверх
# образа, и потом на самой плате.

# (а) /dev/null. В распакованном sample rootfs это обычный пустой файл
# с правами 644, а не символьное устройство. apt-key работает от
# непривилегированного пользователя _apt, пишет в /dev/null и получает
# Permission denied, а наружу это выходит ЛОЖНЫМ сообщением
# «E: gpgv, gpgv2 or gpgv1 required for verification, but neither seems
# installed» — при том, что /usr/bin/gpgv в дереве есть. Подписи в итоге
# не проверяются, apt-get update падает (замер 2026-09-11).
#
# Узел остаётся в дереве: /dev/null есть в любом нормальном rootfs, на
# загруженной плате он всё равно перекрыт devtmpfs, а снять его значило бы
# вернуть в дерево тот самый битый файл-заглушку — и следующий chroot
# (ручная правка оператором) наступил бы на то же место.
mkdir -p "$ROOTFS/dev"
if [ -c "$ROOTFS/dev/null" ]; then
    echo "/dev/null в rootfs: символьное устройство — как надо"
else
    rm -f "$ROOTFS/dev/null"
    if mknod -m 666 "$ROOTFS/dev/null" c 1 3; then
        echo "/dev/null в rootfs: создан узел c 1 3 (был обычный файл — из-за него apt-key ломал проверку подписей)"
    else
        # Узел не создался (root есть — значит дело в файловой системе дерева).
        # Возвращаем пустой файл: дерево остаётся ровно таким, каким было,
        # и в chroot «>/dev/null» хотя бы не отказывает с «нет такого файла».
        : > "$ROOTFS/dev/null" 2>/dev/null || true
        chmod 666 "$ROOTFS/dev/null" 2>/dev/null || true
        echo "ПРЕДУПРЕЖДЕНИЕ: не удалось создать узел $ROOTFS/dev/null —"
        echo "  apt в chroot будет ложно жаловаться на отсутствие gpgv"
    fi
fi

# (б) <SOC> в источнике apt NVIDIA. В
# /etc/apt/sources.list.d/nvidia-l4t-apt-source.list лежит буквальный шаблон
# «jetson/<SOC>»: подстановку делает postinst пакета nvidia-l4t-apt-source,
# а под qemu он до неё не доходит. Итог — apt возвращает 100 («does not have
# a Release file»), и первый же `apt-get update` падает: в chroot, в слое
# bisquite поверх образа, на плате (замер 2026-09-11).
#
# Значение берём из самого postinst, а не хардкодим: t234 — это Tegra234,
# то есть именно Orin, а расширение называется nvidia-jetpack, и на другой
# плате (Xavier — t194, TX2 — t186) верным было бы другое. postinst лежит
# в этом же дереве и является тем самым кодом NVIDIA, который должен был
# отработать, — поэтому он и есть источник истины. Фолбэк t234 стоит потому,
# что умолчания шагов 01-03 без профиля — AGX Orin на JetPack 6.2.
NV_APT_LIST="$ROOTFS/etc/apt/sources.list.d/nvidia-l4t-apt-source.list"
if [ -f "$NV_APT_LIST" ] && grep -q '<SOC>' "$NV_APT_LIST"; then
    NV_POSTINST="$ROOTFS/var/lib/dpkg/info/nvidia-l4t-apt-source.postinst"
    NV_SOC=""
    if [ -f "$NV_POSTINST" ]; then
        NV_SOC=$(sed -n 's|.*s/<SOC>/\([a-z0-9][a-z0-9]*\)/g.*|\1|p' "$NV_POSTINST" | head -1)
    fi
    if [ -n "$NV_SOC" ]; then
        echo "источник apt NVIDIA: SOC взят из postinst пакета — $NV_SOC"
    else
        NV_SOC="t234"
        echo "ПРЕДУПРЕЖДЕНИЕ: подстановку <SOC> в postinst не нашёл — беру $NV_SOC (Tegra234, AGX Orin)"
    fi
    sed -i "s/<SOC>/$NV_SOC/g" "$NV_APT_LIST"
    sed -n '/^deb /p' "$NV_APT_LIST" | sed 's|^|  |'
elif [ -f "$NV_APT_LIST" ]; then
    echo "источник apt NVIDIA: <SOC> уже подставлен"
fi

# --------------------------------------------------------------------------
step "ИТОГ"
echo "rootfs:            $ROOTFS"
if [ "$SKIP_USER" -eq 1 ]; then
    echo "пользователь:      нет — только root (-U)"
else
    echo "пользователь:      $USER_NAME (автологин включён)"
fi
[ -n "$HOSTNAME_ARG" ] && echo "имя хоста:         $HOSTNAME_ARG"
if [ -n "$OEM_LEFT" ]; then
    echo "oem-config:        ОСТАЛСЯ (см. предупреждение выше)"
else
    echo "oem-config:        отключён — первая загрузка идёт сразу в систему"
fi
echo
echo "Дальше — 05-generate-images.sh (плата должна быть в recovery)."
