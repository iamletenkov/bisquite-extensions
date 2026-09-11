#!/usr/bin/env bash
# Драйверы Sensing GMSL2 для Jetson AGX Orin + адаптер SG8A-AGON-G2Y-A1:
# замена ядра, модули, DTB-оверлей, загрузочная запись с оверлеем.
#
# ПОЧЕМУ ЭТО СЛОЙ, А НЕ ЧАСТЬ БАЗОВОГО ОБРАЗА. Камеры — не свойство платы
# Jetson вообще, а свойство КОНКРЕТНОГО адаптера на КОНКРЕТНЫХ роботах.
# Базовый образ (jetson-orin-base) остаётся общим для всего флота; этот
# слой ложится только на VMFILE тех машин, где адаптер физически есть.
#
# ЧТО ДЕЛАЕТ И ЧЕГО НЕ ДЕЛАЕТ. Копирует файлы и правит extlinux.conf —
# ровно то, что раньше делалось руками по ssh на уже прошитой плате
# (2026-09-11, воспроизведено и задокументировано). НЕ вызывает
# quick_bring_up.sh: выбор модели камеры и номера порта — это то, что
# станет известно только на конкретной сборке адаптера (см. README,
# «номер отвода кабеля не равен номеру порта»), и автоматизировать это
# на сборке значило бы дать ложное чувство готовности.
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
# Тот же пакет, что и в CAMERA_PKG_REL станции прошивки (nvidia-jetpack/
# scripts/02-fetch-camera-drivers.sh) — _YUV_ на этой камере не работает,
# см. README и коммит 8f3212a истории расширений.
PKG_REL="${SENSING_CAMERA_PKG_REL:-Jetson AGX Orin Devkit/SG8A-AGON-G2Y-A1/JetPack6.2/SG8A_AGON_G2Y_A1_AGX_Orin_GMSL2x8_JP6.2_L4TR36.4.3}"

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

# --- 2. Скачать пакет драйверов ---------------------------------------------
WORKDIR="$(mktemp -d)"
trap 'rm -rf "$WORKDIR"' EXIT

# НЕ --depth 1 обычный clone: он тянет ВСЕ платы и версии JetPack целиком
# (замер 2026-09-12 — репозиторий больше 380 МБ), а нужна ровно одна папка
# ниже. Внутри virt-customize это клонируется НА ДИСК СОБИРАЕМОГО ОБРАЗА
# (mktemp -d резолвится в /tmp гостя), а не хоста — и там места мало
# по конструкции (базовый образ компактный, см. RESIZE в VMFILE). Первая
# попытка (обычный --depth 1 clone) упала на "No space left on device"
# на 8-гигабайтном APP с ~180 МБ свободного места.
#
# Частичный клон (--filter=blob:none, без чекаута) + sparse-checkout
# в режиме cone — тот же приём, каким чинили этот класс проблемы уже
# в проекте (nvidia-jetpack/scripts/02-fetch-camera-drivers.sh: «внутрь
# образа едет только одна папка»), только здесь дерево ещё и физически
# теснее.
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

# --- 3. Ядро и модули --------------------------------------------------------
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
rm -f "/lib/modules/${KERNEL_VERSION}/updates/drivers/media/i2c/max96712.ko"

# --- 4. DTB-оверлей -----------------------------------------------------------
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

# --- 5. Пакет драйверов целиком в /opt/sensing ------------------------------
# Для ручного quick_bring_up.sh на устройстве — см. README расширения.
rm -rf /opt/sensing
mkdir -p /opt/sensing
cp -a "$PKG/." /opt/sensing/
find /opt/sensing -name '*.sh' -exec chmod +x {} +

# --- 6. extlinux.conf: новая запись с оверлеем, старая остаётся резервной --
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

log_info "готово: ядро заменено, модули на месте, extlinux → JetsonIO"
log_info "откат при проблемах — выбрать пункт backup в загрузочном меню"
