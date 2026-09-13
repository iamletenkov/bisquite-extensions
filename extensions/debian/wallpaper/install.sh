#!/usr/bin/env bash
# Обои рабочего стола: картинка в систему на сборке, привязка к пользователю
# на первой загрузке.
#
# ПОЧЕМУ ДВЕ ФАЗЫ. Сам файл одинаков на всём тираже — ему место в build.
# А `gsettings` пишет в dconf КОНКРЕТНОГО пользователя
# (~/.config/dconf/user), и имя его на сборке неизвестно: учётку создаёт
# cloud-init. Тот же приём и по той же причине, что в vino-vnc.
#
# ПОЧЕМУ /usr/share/backgrounds. Штатный каталог Ubuntu для обоев: он уже
# существует в образе с GNOME, читается всеми пользователями и переживает
# смену учётки. Класть картинку в домашний каталог нельзя — на сборке его
# ещё нет.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} wallpaper: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} wallpaper: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} wallpaper: $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# КАКУЮ КАРТИНКУ КЛАСТЬ — ПАРАМЕТР СЛОЯ.
#
# Путь ОТНОСИТЕЛЬНЫЙ, от каталога расширения: держать картинки внутри
# расширения — единственный способ довезти их до гостя, потому что
# bisquite копирует в образ именно этот каталог целиком, а до путей
# хост-машины изнутри virt-customize не дотянуться.
#
# Задаётся из VMFILE:
#     EXTENSION wallpaper WALLPAPER_IMAGE=images/dst_1080.jpg
#
# Абсолютный путь отвергается намеренно: он указывал бы на файловую
# систему ГОСТЯ, а не хоста, и «работал» бы ровно до первого чужого
# образа, где такого файла нет.
WALLPAPER_IMAGE="${WALLPAPER_IMAGE:-images/dst_1080.jpg}"
if [[ "$WALLPAPER_IMAGE" = /* ]]; then
    log_error "WALLPAPER_IMAGE обязан быть относительным путём от каталога расширения"
    log_error "получено: $WALLPAPER_IMAGE"
    exit 1
fi
IMAGE_SRC="$SCRIPT_DIR/$WALLPAPER_IMAGE"
IMAGE_DST="/usr/share/backgrounds/bisquite-wallpaper.jpg"

# --- 1. Картинка -------------------------------------------------------------
#
# Отсутствие файла — ОТКАЗ СБОРКИ, а не предупреждение. Слой ставят ровно
# затем, чтобы на рабочем столе была заданная картинка; молча собрать образ
# без неё значит отдать роботу не то, что просили, и узнать об этом на
# экране устройства.
if [[ ! -f "$IMAGE_SRC" ]]; then
    log_error "нет файла: $IMAGE_SRC"
    log_error "WALLPAPER_IMAGE=$WALLPAPER_IMAGE ищется от каталога расширения"
    log_error "положи картинку туда или поправь параметр слоя в VMFILE"
    exit 1
fi

install -d /usr/share/backgrounds
# 0644: читать должен любой пользователь, включая того, кого создаст
# cloud-init, и greeter дисплей-менеджера.
install -m 0644 "$IMAGE_SRC" "$IMAGE_DST"
log_info "картинка: $WALLPAPER_IMAGE -> $IMAGE_DST ($(du -h "$IMAGE_DST" | cut -f1))"

# --- 2. Инструменты для первой загрузки -------------------------------------
#
# gsettings приезжает с libglib2.0-bin, а он не обязан стоять в образе:
# GNOME тянет его как зависимость, но расширение не вправе на это
# рассчитывать молча — отказ на первой загрузке читался бы как «обои
# не применились», а не как «нет утилиты».
if ! command -v gsettings >/dev/null 2>&1; then
    log_info "ставлю libglib2.0-bin (нет gsettings)"
    apt-get update || { log_error "apt-get update не прошёл"; exit 1; }
    apt-get install -y --no-install-recommends libglib2.0-bin \
        || { log_error "не удалось поставить libglib2.0-bin"; exit 1; }
fi

# --- 3. Юнит первой загрузки --------------------------------------------------
#
# ОТСУТСТВИЕ ФАЙЛА РЯДОМ — ОТКАЗ СБОРКИ, а не предупреждение: иначе юнита
# в образе не будет, а узнать об этом можно только на устройстве.
# КОПИРОВАТЬ configure.sh И get_cloud_user.sh НЕ НАДО, И ЭТО НЕ ЭКОНОМИЯ.
#
# Каталог расширения целиком кладёт в гостя сам bisquite — в
# /opt/vmsetup/<имя>/, оттуда же он и запускает этот install.sh. То есть
# SCRIPT_DIR УЖЕ равен /opt/vmsetup/wallpaper, и `install` из него туда же
# отказывает: «are the same file». Проверено отказом сборки 2026-09-12.
# Юнит поэтому ставится один, а ExecStart указывает прямо в этот каталог.
for f in configure-wallpaper.service configure.sh get_cloud_user.sh; do
    if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
        log_error "рядом нет $f — обои не применятся на первой загрузке"
        exit 1
    fi
done

install -m 0644 "$SCRIPT_DIR/configure-wallpaper.service" \
    /etc/systemd/system/configure-wallpaper.service
systemctl enable configure-wallpaper.service \
    || { log_error "не удалось включить configure-wallpaper.service"; exit 1; }

log_info "готово: привязка к пользователю — на первой загрузке"
