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
CAMERA_SRC="${CAMERA_SRC:-$WORK/camera-drivers}"   # сюда кладёт скрипт 02
CAMERA_DST="$ROOTFS/opt/sensing"
# Скрипт 02 клонирует ВЕСЬ репозиторий Sensing: там пакеты под несколько
# версий JetPack, собранные Image и DTB и история git. Внутрь образа едет
# только одна папка — иначе system.img распухает на гигабайты, а на плате
# невозможно понять, какая из версий драйверов настоящая.
CAMERA_PKG_REL="${CAMERA_PKG_REL:-Jetson AGX Orin Devkit/SG8A-AGON-G2Y-A1/JetPack6.2/SG8A_AGON_G2Y_A1_AGX_Orin_YUV_JP6.2_L4TR36.4.3}"

# Пакеты для работы с камерами: v4l-utils даёт v4l2-ctl (перечислить сенсоры,
# выставить формат), gstreamer — конвейер для проверки картинки, v4l2loopback
# нужен, когда поток надо отдать второму потребителю.
CAMERA_PACKAGES="v4l-utils gstreamer1.0-tools gstreamer1.0-plugins-good gstreamer1.0-plugins-bad v4l2loopback-utils"

step() { echo; echo "=== $* ==="; }

usage() {
    cat <<'USAGE'
Использование:
  04-customize-rootfs.sh -u ПОЛЬЗОВАТЕЛЬ -p ПАРОЛЬ [-n ИМЯ_ХОСТА]

  -u   имя пользователя, создаваемого в системе платы (обязательно)
  -p   его пароль (обязательно)
  -n   имя хоста платы (необязательно; по умолчанию — как решит L4T)

Умолчаний у -u и -p НЕТ намеренно: пароль, зашитый в скрипт, попал бы
в репозиторий и оттуда в каждый собранный образ. Учётные данные задаёт
оператор в момент прошивки.

Переменные окружения:
  WORK        рабочий каталог станции (умолчание /srv/jetson)
  CAMERA_SRC  распакованные драйверы камер (умолчание $WORK/camera-drivers)
USAGE
}

USER_NAME=""
PASSWORD=""
HOSTNAME_ARG=""

while getopts ":u:p:n:h" opt; do
    case "$opt" in
        u) USER_NAME="$OPTARG" ;;
        p) PASSWORD="$OPTARG" ;;
        n) HOSTNAME_ARG="$OPTARG" ;;
        h) usage; exit 0 ;;
        :) echo "ОШИБКА: у -$OPTARG нет значения"; echo; usage; exit 1 ;;
        \?) echo "ОШИБКА: неизвестный ключ -$OPTARG"; echo; usage; exit 1 ;;
    esac
done

if [ -z "$USER_NAME" ] || [ -z "$PASSWORD" ]; then
    echo "ОШИБКА: -u и -p обязательны."
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
# не должно: ниже стоит rm узлов /dev/random и /dev/urandom, и поверх
# смонтированного /dev он снёс бы их у СТАНЦИИ.
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

if grep -q "^${USER_NAME}:" "$ROOTFS/etc/passwd" 2>/dev/null; then
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
# oem-config между выпусками L4T менялись, а вопрос всегда один — остались ли
# в автозапуске юниты первичной настройки.
OEM_LEFT=$(find "$ROOTFS/etc/systemd/system" -name '*oem-config*' 2>/dev/null | head -5)
if [ -n "$OEM_LEFT" ]; then
    echo "ПРЕДУПРЕЖДЕНИЕ: в автозапуске остались юниты первичной настройки:"
    echo "$OEM_LEFT" | sed "s|$ROOTFS||;s|^|  |"
    echo "Первая загрузка может снова потребовать монитор и клавиатуру."
else
    echo "oem-config отключён: юнитов *oem-config* в /etc/systemd/system нет"
fi

# --------------------------------------------------------------------------
step "2. Пакеты для камер внутрь rootfs (эмуляция aarch64)"
# Шаг НЕОБЯЗАТЕЛЬНЫЙ по последствиям: те же пакеты ставятся и на плате,
# apt там работает. Поэтому отсутствие binfmt — предупреждение и пропуск,
# а не останов: ронять подготовку прошивки из-за необязательного удобства
# значило бы менять цену отказа местами.
SKIP_PKGS=0
if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
    echo "ПРЕДУПРЕЖДЕНИЕ: binfmt для aarch64 не зарегистрирован"
    echo "  (/proc/sys/fs/binfmt_misc/qemu-aarch64 отсутствует)"
    echo "  Поправить: apt-get install -y qemu-user-static binfmt-support"
    echo "  и systemctl restart systemd-binfmt"
    SKIP_PKGS=1
elif [ ! -x "$ROOTFS/usr/bin/qemu-aarch64-static" ]; then
    # apply_binaries кладёт интерпретатор внутрь дерева сам; если его там нет,
    # переносим свой — регистрация binfmt указывает на путь ВНУТРИ chroot.
    if [ -x /usr/bin/qemu-aarch64-static ]; then
        cp -f /usr/bin/qemu-aarch64-static "$ROOTFS/usr/bin/qemu-aarch64-static"
        echo "qemu-aarch64-static скопирован в rootfs"
    else
        echo "ПРЕДУПРЕЖДЕНИЕ: qemu-aarch64-static нет ни в rootfs, ни на станции"
        SKIP_PKGS=1
    fi
fi

if [ "$SKIP_PKGS" -eq 0 ]; then
    # Грабля: TMPDIR, унаследованный от станции, указывает на путь, которого
    # внутри chroot не существует, и первый же mktemp в постустановочном
    # скрипте падает. Не «поправить», а не задавать вовсе.
    unset TMPDIR || true
    echo "TMPDIR = [${TMPDIR:-}]  (обязано быть пусто)"

    # Грабля: узлы /dev/random и /dev/urandom, оставшиеся от прерванных
    # прогонов под qemu, ломают последующую упаковку дерева. Снимаем их
    # и до, и после работы — дерево должно уходить в 05 чистым.
    rm -f "$ROOTFS/dev/random" "$ROOTFS/dev/urandom"

    # /proc нужен apt и постустановочным скриптам; /sys и /dev НЕ монтируем —
    # см. проверку в шаге 0.
    mkdir -p "$ROOTFS/proc"
    PROC_MOUNTED=0
    if ! mountpoint -q "$ROOTFS/proc"; then
        mount -t proc proc "$ROOTFS/proc" && PROC_MOUNTED=1
    fi

    ARCH_IN_ROOTFS=$(chroot "$ROOTFS" /bin/bash -c "uname -m" 2>/dev/null)
    echo "uname -m внутри rootfs: [${ARCH_IN_ROOTFS:-пусто}]  (ждём aarch64)"
    if [ "$ARCH_IN_ROOTFS" != "aarch64" ]; then
        echo "ПРЕДУПРЕЖДЕНИЕ: эмуляция не работает — пакеты пропущены."
        echo "  Их можно поставить на плате после прошивки:"
        echo "  sudo apt-get install -y $CAMERA_PACKAGES"
        SKIP_PKGS=1
    fi
fi

if [ "$SKIP_PKGS" -eq 0 ]; then
    # Идемпотентность: спрашиваем dpkg, что уже стоит, и ставим только
    # недостающее. Повторный запуск скрипта не должен ни дублировать записи,
    # ни платить получасом эмулированного apt за ничего.
    missing=""
    for p in $CAMERA_PACKAGES; do
        if chroot "$ROOTFS" dpkg-query -W -f='${Status}' "$p" 2>/dev/null | grep -q 'install ok installed'; then
            printf '  %-32s уже стоит\n' "$p"
        else
            printf '  %-32s нужен\n' "$p"
            missing="$missing $p"
        fi
    done

    if [ -z "$missing" ]; then
        echo "все пакеты уже в rootfs — apt не запускаю"
    else
        # policy-rc.d возвращает 101 — «запускать сервисы запрещено».
        # Без него postinst попытается стартовать демонов под qemu, где нет
        # ни systemd, ни настоящего ядра, и часть пакетов останется
        # в состоянии «настройка не завершена».
        POLICY="$ROOTFS/usr/sbin/policy-rc.d"
        POLICY_MADE=0
        if [ ! -e "$POLICY" ]; then
            printf '#!/bin/sh\nexit 101\n' > "$POLICY"
            chmod +x "$POLICY"
            POLICY_MADE=1
        fi

        # resolv.conf в rootfs — симлинк на stub-resolv.conf systemd-resolved,
        # внутри chroot он никуда не ведёт, и apt не резолвит зеркала.
        # Подменяем на время работы и ОБЯЗАТЕЛЬНО возвращаем: оставленный
        # обычный файл сломал бы resolved уже на плате.
        RESOLV="$ROOTFS/etc/resolv.conf"
        RESOLV_BAK="$ROOTFS/etc/resolv.conf.04-backup"
        RESOLV_SAVED=0
        if [ -e "$RESOLV" ] || [ -L "$RESOLV" ]; then
            mv -f "$RESOLV" "$RESOLV_BAK" && RESOLV_SAVED=1
        fi
        cp -f /etc/resolv.conf "$RESOLV" 2>/dev/null || echo "nameserver 8.8.8.8" > "$RESOLV"

        echo
        echo "ставлю:$missing  (под эмуляцией это медленно, 5-20 минут)"
        chroot "$ROOTFS" /usr/bin/env -u TMPDIR \
            DEBIAN_FRONTEND=noninteractive LC_ALL=C \
            PATH=/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin \
            /bin/bash -c "apt-get -qq update && apt-get -y install --no-install-recommends$missing"
        apt_rc=$?

        [ "$RESOLV_SAVED" -eq 1 ] && mv -f "$RESOLV_BAK" "$RESOLV"
        [ "$POLICY_MADE" -eq 1 ] && rm -f "$POLICY"

        if [ "$apt_rc" -ne 0 ]; then
            echo "ПРЕДУПРЕЖДЕНИЕ: apt внутри rootfs вернул $apt_rc."
            echo "  Прошивке это не мешает — доставь недостающее уже на плате."
        else
            echo "пакеты установлены"
        fi
    fi

    # Дерево уходит дальше без узлов, которые мог создать эмулированный apt.
    rm -f "$ROOTFS/dev/random" "$ROOTFS/dev/urandom"
    if [ "${PROC_MOUNTED:-0}" -eq 1 ]; then
        umount "$ROOTFS/proc" 2>/dev/null || umount -l "$ROOTFS/proc" 2>/dev/null
    fi
fi

# --------------------------------------------------------------------------
step "3. Драйверы камер в /opt/sensing"
# Кладём заранее, чтобы после прошивки плата не зависела от сети: пакет
# Sensing тянется с их зеркала, а на столе у прошитой платы сети может
# не быть вовсе.
CAMERA_PKG=""
if [ ! -d "$CAMERA_SRC" ]; then
    echo "ПРЕДУПРЕЖДЕНИЕ: $CAMERA_SRC не найден — драйверы камер НЕ попадут в образ."
    echo "  Прогони 02-fetch-camera-drivers.sh, если камеры нужны."
elif [ -f "$CAMERA_SRC/quick_bring_up.sh" ]; then
    # Оператор указал CAMERA_SRC прямо на пакет — берём как есть.
    CAMERA_PKG="$CAMERA_SRC"
elif [ -d "$CAMERA_SRC/$CAMERA_PKG_REL" ]; then
    CAMERA_PKG="$CAMERA_SRC/$CAMERA_PKG_REL"
else
    # Структура репозитория у Sensing между релизами менялась, поэтому
    # ищем по признаку, а не по пути: каталог, в котором лежит
    # quick_bring_up.sh. .git исключаем явно — там встречаются те же имена
    # в объектах рабочего дерева соседних веток.
    mapfile -t FOUND < <(find "$CAMERA_SRC" -name 'quick_bring_up.sh' -not -path '*/.git/*' -printf '%h\n' | sort -u)
    if [ "${#FOUND[@]}" -eq 0 ]; then
        echo "ПРЕДУПРЕЖДЕНИЕ: в $CAMERA_SRC нет quick_bring_up.sh — пакет драйверов не опознан."
        echo "  Ждали: $CAMERA_PKG_REL"
    elif [ "${#FOUND[@]}" -eq 1 ]; then
        CAMERA_PKG="${FOUND[0]}"
        echo "пакет опознан поиском: ${CAMERA_PKG#"$CAMERA_SRC"/}"
    else
        # Молча выбрать один из нескольких — значит увезти на плату
        # драйверы не под ту версию JetPack и узнать об этом уже на столе.
        for d in "${FOUND[@]}"; do
            case "$d" in *L4TR36.4.3*) CAMERA_PKG="$d" ;; esac
        done
        if [ -n "$CAMERA_PKG" ]; then
            echo "кандидатов несколько, выбран по L4TR36.4.3: ${CAMERA_PKG#"$CAMERA_SRC"/}"
        else
            echo "ПРЕДУПРЕЖДЕНИЕ: кандидатов несколько, ни один не про L4T 36.4.3:"
            printf '    %s\n' "${FOUND[@]#"$CAMERA_SRC"/}"
            echo "  Укажи нужный явно: CAMERA_PKG_REL='...' $0 -u ... -p ..."
        fi
    fi
fi

if [ -n "$CAMERA_PKG" ]; then
    mkdir -p "$CAMERA_DST"
    # Идемпотентность через замену, а не через докладывание: cp поверх
    # существующего каталога оставил бы файлы прошлой версии драйверов,
    # и понять, какая из них поедет на плату, было бы нельзя.
    rm -rf "$CAMERA_DST"
    mkdir -p "$CAMERA_DST"
    # Копируем СОДЕРЖИМОЕ пакета, а не сам каталог: на плате ждут
    # /opt/sensing/quick_bring_up.sh, а не /opt/sensing/<длинное имя>/...
    cp -a "$CAMERA_PKG/." "$CAMERA_DST/"
    # Права на скрипты теряются при выкладке через zip и веб-архивы,
    # а quick_bring_up.sh зовёт соседние скрипты по имени.
    find "$CAMERA_DST" -name '*.sh' -exec chmod +x {} + 2>/dev/null
    if [ -f "$CAMERA_DST/quick_bring_up.sh" ]; then
        echo "quick_bring_up.sh: /opt/sensing/quick_bring_up.sh (+x)"
    else
        echo "ПРЕДУПРЕЖДЕНИЕ: quick_bring_up.sh не оказался в корне /opt/sensing"
    fi
    echo "источник   : ${CAMERA_PKG#"$CAMERA_SRC"/}"
    echo "скопировано: $(du -sh "$CAMERA_DST" | cut -f1) в /opt/sensing"
fi

# --------------------------------------------------------------------------
step "ИТОГ"
echo "rootfs:            $ROOTFS"
echo "пользователь:      $USER_NAME (автологин включён)"
[ -n "$HOSTNAME_ARG" ] && echo "имя хоста:         $HOSTNAME_ARG"
if [ -n "$OEM_LEFT" ]; then
    echo "oem-config:        ОСТАЛСЯ (см. предупреждение выше)"
else
    echo "oem-config:        отключён — первая загрузка идёт сразу в систему"
fi
if [ "$SKIP_PKGS" -eq 0 ]; then
    echo "пакеты камер:      в rootfs ($CAMERA_PACKAGES)"
else
    echo "пакеты камер:      ПРОПУЩЕНЫ — доставить на плате"
fi
if [ -d "$CAMERA_DST" ]; then
    echo "/opt/sensing:      $(find "$CAMERA_DST" -type f | wc -l) файлов, $(du -sh "$CAMERA_DST" | cut -f1)"
else
    echo "/opt/sensing:      пусто"
fi
echo
echo "Дальше — 05-generate-images.sh (плата должна быть в recovery)."
