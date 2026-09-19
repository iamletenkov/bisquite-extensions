#!/usr/bin/env bash
# Драйверы Sensing GMSL2 для Jetson AGX Orin + адаптер SG8A-AGON-G2Y-A1:
# библиотека ISP из оверлея камер NVIDIA, замена ядра, модули, DTB-оверлей,
# загрузочная запись с оверлеем.
#
# ПОЧЕМУ ЭТО СЛОЙ, А НЕ ЧАСТЬ БАЗОВОГО ОБРАЗА. Камеры — не свойство платы
# Jetson вообще, а свойство КОНКРЕТНОГО адаптера на КОНКРЕТНЫХ роботах.
# Образ из BSP (jetson-orin-bsp) остаётся общим для всего флота; этот
# слой ложится только на VMFILE тех машин, где адаптер физически есть.
#
# ЧТО ДЕЛАЕТ. Копирует файлы и правит extlinux.conf — то, что раньше
# делалось руками по ssh на уже прошитой плате (2026-09-11), — и кладёт
# неинтерактивную замену quick_bring_up.sh: режим линка, профиль камеры
# и частоты SoC применяются сами на каждой загрузке (шаг 8). Сам
# quick_bring_up.sh по-прежнему не вызывается: он спрашивает с tty.
#
# С 4.0.0 ЗДЕСЬ ЖЕ libnvisppg.so. Раньше её подменяла станция прошивки при
# подготовке дерева BSP; решение владельца 2026-09-18 убрало из базового
# образа всё, что про камеры. Поэтому расширение закреплено на L4T 36.4.3
# и отказывает на любом другом (шаг 1), до сети.
#
# ПОЧЕМУ НЕ 5.15.148-tegra ИЗ uname -r ХОСТА. Внутри virt-customize
# гость не загружен — это chroot поверх файловой системы образа, а не
# работающая Tegra. Путь /lib/modules/5.15.148-tegra прибит буквально —
# ТАК ЖЕ, КАК он прибит в install.sh самого пакета Sensing (не наша
# догадка, а копия их же литерала), и это правильно: и штатное ядро L4T,
# и ядро Sensing поверх него дают один и тот же `uname -r` (проверено на
# живой плате 2026-09-11) — подмена содержимого, а не номера версии.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} sensing-gmsl2-camera: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} sensing-gmsl2-camera: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} sensing-gmsl2-camera: $*"; }

KERNEL_VERSION="5.15.148-tegra"
BOARD_DTB="tegra234-p3737-0000+p3701-0000-nv.dtb"
REPO_URL="https://github.com/SENSING-Technology/nvidia-jetson-camera-drivers"
# Пакет _GMSL2x8_, а не _YUV_: с _YUV_ эта камера не работает — разбор
# в README («Почему пакет GMSL2x8») и коммит 8f3212a истории расширений.
PKG_REL="${SENSING_CAMERA_PKG_REL:-Jetson AGX Orin Devkit/SG8A-AGON-G2Y-A1/JetPack6.2/SG8A_AGON_G2Y_A1_AGX_Orin_GMSL2x8_JP6.2_L4TR36.4.3}"

# Оверлей камер NVIDIA для L4T 36.4.3: единственная библиотека ISP
# libnvisppg.so (замер 2026-09-19: 280128 байт, внутри libnvisppg.so и
# EULA-public.txt). Суммы не параметры: чужой архив — отказ, а не выбор.
# Штатная — из nvidia-l4t-camera 36.4.3-20250107174145 BSP.
NVISPPG_L4T=36.4.3
NVISPPG_URL=https://developer.nvidia.com/downloads/embedded/L4T/r36_Release_v4.3/overlay_camera_36.4.3.tbz2
NVISPPG_TBZ2_SHA256=acacdf47862b1212fb5ddff2046d49397f9f86757951b15ccde4af5e74f49f3f
NVISPPG_OVERLAY_SHA256=3970c9cc85f86b978fdca1d20f2798c022f6852d26cfe03ae5bceec6ae0666ca
NVISPPG_STOCK_SHA256=7e7c7500fae24da5bbb09dbed8d4235346c5110ab19b78e5daccbd8d078d5a2c

# Режим линка на каждом из 8 портов, через запятую: 0=GMSL1, 1=GMSL2 6 Гбит/с,
# 2=GMSL2 3 Гбит/с. Умолчание 1 — то же, что предлагает вендорский
# quick_bring_up.sh, если на его вопросы ответить Enter.
SENSING_GMSLMODE="${SENSING_GMSLMODE:-1,1,1,1,1,1,1,1}"
# Профиль камеры (SENSING_CAMERA_CONTROLS) и частоты (SENSING_BOOST_CLOCK) —
# ручки домена sensing-camera: имена, типы и умолчания в схеме knobs рядом,
# проверяет и пишет библиотека bisquite-conf (после опознания платы).

if [[ ! "$SENSING_GMSLMODE" =~ ^[012](,[012]){7}$ ]]; then
    log_error "SENSING_GMSLMODE='$SENSING_GMSLMODE': нужно 8 значений 0/1/2 через запятую"
    exit 1
fi
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for f in knobs knobs.apply bisquite-sensing-camera-ctl nvisppg.sh lib/bisquite-conf; do
    [[ -f "$SCRIPT_DIR/$f" ]] || { log_error "рядом нет $f"; exit 1; }
done
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/bisquite-conf"
# shellcheck source=nvisppg.sh
source "$SCRIPT_DIR/nvisppg.sh"

# --- 1. Опознать плату ------------------------------------------------------
#
# /proc/device-tree тут не поможет: внутри chroot это виртуальный appliance,
# а не настоящая Tegra. Единственный build-time сигнал — файлы, которые
# УЖЕ лежат в rootfs: DTB с именем платы, положенный шагом сборки образа
# (jetson-disk-image-creator.sh), и /etc/nv_tegra_release из BSP.
if [[ ! -f /etc/nv_tegra_release ]]; then
    log_error "нет /etc/nv_tegra_release — это не образ NVIDIA Jetson (L4T)"
    exit 1
fi
if [[ ! -f "/boot/dtb/kernel_${BOARD_DTB}" ]]; then
    log_error "нет /boot/dtb/kernel_${BOARD_DTB}"
    log_error "это расширение — только для AGX Orin Devkit (p3701-0000/p3737-0000)"
    log_error "на другой плате DTB-оверлей и модули будут для чужого железа"
    exit 1
fi
log_info "плата: $(head -n1 /etc/nv_tegra_release)"
# Релиз — тоже до сети: ядро, модули, оверлей камер и библиотека ISP
# собраны под один L4T, и на соседнем (36.4.4) это другой набор.
nvisppg_gate "$NVISPPG_L4T" || exit 1

# Ручки камер — до сети: опечатка в SENSING_CAMERA_CONTROLS роняет сборку за
# секунду, а не после клона. Файл создаётся один раз и не переписывается;
# параметры VMFILE — поверх, через проверку схемы. Правка на работающей машине —
# `bisquite-conf set sensing-camera …`, хук перезапускает юниты.
conf_init sensing-camera "$SCRIPT_DIR/knobs" --env || { log_error "/etc/bisquite/sensing-camera/config не записан"; exit 1; }
conf_load sensing-camera

# --- 2. Библиотека ISP из оверлея камер NVIDIA ------------------------------
#
# Штатная libnvisppg.so из nvidia-l4t-camera с этими камерами не работает;
# NVIDIA выпускает замену отдельным «оверлеем камер» на каждый релиз.
# Скачать, сверить с закреплённой суммой, подменить через dpkg-divert —
# разбор в nvisppg.sh. Порядок с ядром и модулями неважен: файлы разные.
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

command -v curl >/dev/null 2>&1 || { log_error "нет curl — поставь его слоем раньше (INSTALL curl)"; exit 1; }
log_info "оверлей камер NVIDIA $NVISPPG_L4T"
mkdir -p "$WORKDIR/nvisppg"
nvisppg_fetch "$NVISPPG_URL" "$NVISPPG_TBZ2_SHA256" "$NVISPPG_OVERLAY_SHA256" "$WORKDIR/nvisppg" || exit 1
nvisppg_install "$WORKDIR/nvisppg/libnvisppg.so" "$NVISPPG_STOCK_SHA256" "$NVISPPG_OVERLAY_SHA256" || exit 1

# --- 3. Скачать пакет драйверов ---------------------------------------------
# НЕ --depth 1 обычный clone: он тянет ВСЕ платы и версии JetPack целиком
# (замер 2026-09-12 — репозиторий больше 380 МБ), а нужна ровно одна папка
# ниже. Внутри virt-customize это клонируется НА ДИСК СОБИРАЕМОГО ОБРАЗА
# (mktemp -d резолвится в /tmp гостя), а не хоста — и там места мало
# по конструкции (базовый образ компактный, см. RESIZE в VMFILE). Первая
# попытка (обычный --depth 1 clone) упала на "No space left on device"
# на 8-гигабайтном APP с ~180 МБ свободного места.
#
# Частичный клон (--filter=blob:none, без чекаута) + sparse-checkout
# в режиме cone: внутрь образа едет только одна папка пакета.
log_info "клонирую $REPO_URL (частично: только $PKG_REL)"
git clone --no-checkout --depth 1 --filter=blob:none "$REPO_URL" "$WORKDIR/repo"
git -C "$WORKDIR/repo" sparse-checkout init --cone
git -C "$WORKDIR/repo" sparse-checkout set "$PKG_REL"
git -C "$WORKDIR/repo" checkout

PKG="$WORKDIR/repo/$PKG_REL"
if [[ ! -d "$PKG" ]]; then
    log_error "в клоне нет каталога: $PKG_REL"
    log_error "структура репозитория Sensing меняется между релизами —"
    log_error "проверь путь через SENSING_CAMERA_PKG_REL"
    exit 1
fi
if [[ ! -f "$PKG/install.sh" ]]; then
    log_error "$PKG не похож на пакет драйверов — в нём нет install.sh"
    exit 1
fi
log_info "пакет: ${PKG_REL##*/}"

# --- 4. Ядро и модули --------------------------------------------------------
#
# Бэкап штатного ядра — cp -n, идемпотентно: повторный прогон расширения
# (или добавление второго Sensing-слоя по ошибке) не затрёт уже сохранённый
# оригинал новой копией самого себя.
cp -n /boot/Image /boot/Image.backup
cp -f "$PKG/boot/Image" /boot/Image

MODDIR_CAMERA="/lib/modules/${KERNEL_VERSION}/updates/drivers/media/platform/tegra/camera"
MODDIR_NVCSI="/lib/modules/${KERNEL_VERSION}/updates/drivers/video/tegra/host/nvcsi"
if [[ ! -d "$MODDIR_CAMERA" || ! -d "$MODDIR_NVCSI" ]]; then
    log_error "нет $MODDIR_CAMERA или $MODDIR_NVCSI"
    log_error "ожидали дерево модулей ядра ${KERNEL_VERSION} — версия базового"
    log_error "образа разошлась с тем, что зашито в этом расширении?"
    exit 1
fi
cp -f "$PKG/ko/tegra-camera.ko" "$MODDIR_CAMERA/"
cp -f "$PKG/ko/nvhost-nvcsi-t194.ko" "$MODDIR_NVCSI/"

# ОСТАЛЬНЫЕ МОДУЛИ ПАКЕТА — ТОЖЕ, И ЭТО НЕ ПОЛНОТА РАДИ ПОЛНОТЫ.
#
# Установщик самой Sensing (install.sh в пакете) кладёт только два модуля
# выше и УДАЛЯЕТ штатный max96712.ko — в расчёте на то, что их замена
# встроена в их же ядро. На нашем образе это не так: замер на живой плате
# 2026-09-13 показал `grep -c max96712 /proc/kallsyms` = 0, драйвер
# не зарегистрирован, и вся цепочка мертва:
#
#     pca954x 2-0070: probe failed        ← мультиплексор без драйвера
#     /dev/video* — нет вовсе
#
# При этом в ko/ пакета лежат готовые модули под ЭТО ЖЕ ядро: max96712.ko
# (дешериализатор), sgx-yuv-gmsl2.ko (сенсор), sgcam-gmsl2.ko, pwm-gpio.ko.
# После их установки и depmod всё поднимается с первой загрузки:
#
#     pca954x 2-0070: registered 2 multiplexed busses for I2C switch pca9543
#     max96712 9-0029: max96712_probe: probe success
#     max96712 10-002d: max96712_probe: probe success
#     /dev/video0 … /dev/video7
#
# Штатный max96712.ko всё равно удаляем: он от другого железа и конфликтует
# с одноимённым модулем Sensing.
rm -f "/lib/modules/${KERNEL_VERSION}/updates/drivers/media/i2c/max96712.ko"

MODDIR_I2C="/lib/modules/${KERNEL_VERSION}/updates/drivers/media/i2c"
MODDIR_PWM="/lib/modules/${KERNEL_VERSION}/updates/drivers/pwm"
install -d "$MODDIR_I2C" "$MODDIR_PWM"
for ko in max96712 sgx-yuv-gmsl2 sgcam-gmsl2; do
    if [[ -f "$PKG/ko/$ko.ko" ]]; then
        install -m 0644 "$PKG/ko/$ko.ko" "$MODDIR_I2C/"
    else
        log_error "в пакете нет ko/$ko.ko — камеры не поднимутся"
        exit 1
    fi
done
if [[ -f "$PKG/ko/pwm-gpio.ko" ]]; then
    install -m 0644 "$PKG/ko/pwm-gpio.ko" "$MODDIR_PWM/"
else
    log_warn "в пакете нет ko/pwm-gpio.ko — внешняя синхронизация камер работать не будет"
fi

# DEPMOD ОБЯЗАТЕЛЕН. Без него modules.dep не знает о новых файлах, и ядро
# не найдёт драйвер по alias'у устройства — модули просто лежат на диске.
if ! depmod "$KERNEL_VERSION"; then
    log_error "depmod ${KERNEL_VERSION} не отработал — модули не будут найдены"
    exit 1
fi
shopt -s nullglob
installed_ko=("$MODDIR_I2C"/*.ko "$MODDIR_PWM"/*.ko)
shopt -u nullglob
log_info "модули: ${#installed_ko[@]} файлов, depmod прошёл"

# --- 5. DTB-оверлей -----------------------------------------------------------
shopt -s nullglob
overlays=("$PKG"/dtb/SGX_YUV_GMSL2/tegra234-camera*.dtbo)
shopt -u nullglob
if [[ ${#overlays[@]} -eq 0 ]]; then
    log_error "в пакете нет dtb/SGX_YUV_GMSL2/tegra234-camera*.dtbo"
    exit 1
fi
cp -f "${overlays[@]}" /boot/
OVERLAY_NAME="$(basename "${overlays[0]}")"
log_info "оверлей камер: $OVERLAY_NAME"

# --- 6. Пакет драйверов целиком в /opt/sensing ------------------------------
# Для ручного quick_bring_up.sh на устройстве — см. README расширения.
rm -rf /opt/sensing
mkdir -p /opt/sensing
cp -a "$PKG/." /opt/sensing/
find /opt/sensing -name '*.sh' -exec chmod +x {} +

# --- 7. extlinux.conf: новая запись с оверлеем, старая остаётся резервной --
#
# Через python3, а не sed/awk построчно: запись root= из уже существующего
# APPEND нужно ПЕРЕИСПОЛЬЗОВАТЬ дословно (PARTUUID сгенерирован при сборке
# базового образа — 08-build-base-image.sh, шаг 4 — трогать его здесь не
# нужно и не следует), а конструировать несколько похожих блоков надёжнее
# из Python, чем из вложенных sed-выражений.
EXTLINUX=/boot/extlinux/extlinux.conf
if [[ ! -f "$EXTLINUX" ]]; then
    log_error "нет $EXTLINUX"
    exit 1
fi

python3 - "$EXTLINUX" "$BOARD_DTB" "$OVERLAY_NAME" <<'PYEOF'
import re
import sys

path, board_dtb, overlay_name = sys.argv[1], sys.argv[2], sys.argv[3]
text = open(path, encoding="utf-8").read()

match = re.search(r"^\s*APPEND\s+(.+)$", text, re.MULTILINE)
if not match:
    sys.exit("не нашёл строку APPEND в extlinux.conf — формат разошёлся с ожидаемым")
append_line = match.group(1).strip()

if "JetsonIO" in text:
    sys.exit(0)  # повторный прогон — запись уже добавлена, идемпотентно

backup_stanza = f"""
LABEL backup
      MENU LABEL backup kernel (stock L4T, без камер)
      LINUX /boot/Image.backup
      INITRD /boot/initrd
      APPEND {append_line}
"""

jetsonio_stanza = f"""
LABEL JetsonIO
      MENU LABEL Custom Header Config: <Sensing GMSL2 camera overlay>
      LINUX /boot/Image
      FDT /boot/dtb/kernel_{board_dtb}
      INITRD /boot/initrd
      APPEND {append_line}
      OVERLAYS /boot/{overlay_name}
"""

text = re.sub(r"^DEFAULT\s+\S+", "DEFAULT JetsonIO", text, count=1, flags=re.MULTILINE)
text = text.rstrip("\n") + "\n" + backup_stanza + jetsonio_stanza

open(path, "w", encoding="utf-8").write(text)
PYEOF

if ! grep -q "DEFAULT JetsonIO" "$EXTLINUX"; then
    log_error "правка extlinux.conf не применилась — DEFAULT не JetsonIO"
    exit 1
fi
if ! grep -q "^LABEL backup" "$EXTLINUX"; then
    log_error "резервная запись backup не появилась в extlinux.conf"
    exit 1
fi

# --- 8. Запуск камер на каждой загрузке ---------------------------------------
#
# БЕЗ ЭТОГО ШАГА КАДРОВ НЕТ НИ НА ОДНОМ ПОРТУ, хотя всё выглядит исправным.
#
# Замер на плате 2026-09-14, образ без этого шага: `/dev/video0..7` есть,
# `max96712_probe: probe success` на обоих дешериализаторах — и на всех
# восьми портах `sensor_probe … detect error` с `link:0x02`, а кадры —
# одна и та же заглушка по 24 КБ. Модули ядро грузит само, по дереву
# устройств, и без параметров: `GMSLMODE_0=0,0,0,0`, то есть GMSL1 на
# всех портах, а камеры — GMSL2.
#
# Вендор делает это интерактивно, в quick_bring_up.sh: `insmod` с
# GMSLMODE, boost_clock.sh, `v4l2-ctl -c sensor_mode=…` на выбранный
# порт. Раньше расширение это сознательно пропускало: считалось, что
# порт и модель известны только на месте. Порт знать не нужно — профиль
# ставится на все узлы драйвера, на пустом порту команда проходит без
# вреда (rc=0). Модель на роботах одного профиля одна, и она параметр.
#
# После этого шага, той же платой после перезагрузки: `link:0xc8` без
# `detect error` на порту камеры, 10 разных кадров по ~217 КБ.
#
# Три части, и у каждой свой механизм — потому что меняются они по-разному:
#   режим линка   /etc/modprobe.d  параметр модуля, живёт до его выгрузки
#   профиль       правило udev     узел может появиться заново (rmmod)
#   частоты SoC   служба загрузки  не связано с узлами вовсе
log_info "режим GMSL по портам: $SENSING_GMSLMODE"
IFS=, read -r -a _m <<<"$SENSING_GMSLMODE"
install -d /etc/modprobe.d
cat > /etc/modprobe.d/bisquite-sensing-gmsl2.conf <<EOF
# Положено расширением sensing-gmsl2-camera (параметр SENSING_GMSLMODE).
# 0=GMSL1, 1=GMSL2 6 Гбит/с, 2=GMSL2 3 Гбит/с; порты 0-3, затем 4-7.
# Применяется при загрузке модуля: после правки — перезагрузка платы.
options sgx_yuv_gmsl2 GMSLMODE_0=${_m[0]},${_m[1]},${_m[2]},${_m[3]} GMSLMODE_1=${_m[4]},${_m[5]},${_m[6]},${_m[7]}
EOF

# The knob file moved to /etc/bisquite/sensing-camera/config in 2.0.0. The old
# path is not read as a fallback; remove it so the image has one source of truth.
if [[ -e /etc/default/bisquite-sensing-camera ]]; then
    log_info "удаляю /etc/default/bisquite-sensing-camera: ручки теперь в /etc/bisquite/sensing-camera/config"
    rm -f /etc/default/bisquite-sensing-camera
fi
# Ручки — /etc/bisquite/sensing-camera/config (записаны до скачивания, см. выше).

# v4l2-ctl — единственная утилита скрипта. В базе L4T она есть не всегда.
if ! command -v v4l2-ctl >/dev/null 2>&1; then
    log_info "ставлю v4l-utils"
    DEBIAN_FRONTEND=noninteractive apt-get install -q -y v4l-utils || {
        log_error "v4l-utils не установился — профиль камер ставить будет нечем"
        exit 1
    }
fi

# Ссылка, а не копия: скрипт находит lib/bisquite-conf рядом с собой через
# `readlink -f`. Прежнюю копию из образа до 3.0.0 `ln -f` заменяет.
chmod +x "$SCRIPT_DIR/bisquite-sensing-camera-ctl"
ln -sfn "$SCRIPT_DIR/bisquite-sensing-camera-ctl" /usr/local/sbin/bisquite-sensing-camera-ctl
install -m 0644 "$SCRIPT_DIR/bisquite-sensing-camera@.service" \
    "$SCRIPT_DIR/bisquite-sensing-clock.service" /etc/systemd/system/
install -m 0644 "$SCRIPT_DIR/99-bisquite-sensing-camera.rules" /etc/udev/rules.d/
# Включение ссылкой, а не `systemctl enable`: внутри virt-customize systemd
# не запущен (тот же приём, что у маскирования в jetson-orin-base.vmfile).
install -d /etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/bisquite-sensing-clock.service \
    /etc/systemd/system/multi-user.target.wants/bisquite-sensing-clock.service
log_info "профиль камер: $SENSING_CAMERA_CONTROLS; частоты на максимум: $SENSING_BOOST_CLOCK"

log_info "готово: libnvisppg.so из оверлея, ядро заменено, модули на месте, extlinux → JetsonIO"
log_info "откат при проблемах — выбрать пункт backup в загрузочном меню"
