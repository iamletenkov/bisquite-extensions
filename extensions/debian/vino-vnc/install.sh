#!/usr/bin/env bash
# Сборка: поставить vino — штатный VNC-сервер GNOME — и записать параметры
# туда, откуда их возьмёт первая загрузка.
#
# ПОЧЕМУ ОТДЕЛЬНОЕ РАСШИРЕНИЕ, А НЕ РЕЖИМ x11vnc. Общего кода почти нет:
# у x11vnc свой системный юнит и обёртка, ищущая X authority в рантайме;
# vino — часть GNOME, он живёт ВНУТРИ пользовательской сессии, настраивается
# через gsettings и стартует автозапуском XDG. Ни authority, ни системного
# юнита у него не бывает.
#
# ПОЧЕМУ ПАРАМЕТРЫ — ПЕРЕМЕННЫЕ ОКРУЖЕНИЯ, А НЕ config.yaml. У x11vnc на этом
# месте лежал config.yaml, чьи ключи читались и нигде не использовались:
# юнит хардкодил свои значения, а README обещал парольный доступ, которого
# не было. Файл удалили вместе с обещанием. Здесь параметры приезжают из
# VMFILE, библиотека bisquite-conf кладёт их в /etc/bisquite/vino/config, а
# configure.sh читает оттуда. Имена, типы и умолчания — схема knobs рядом.
#
# ПОЧЕМУ НАСТРОЙКА НЕ ЗДЕСЬ. `gsettings` пишет в dconf конкретного
# пользователя, а автозапуск — в его домашний каталог. Пользователя создаёт
# cloud-init на устройстве, и на сборке его имени нет. Поэтому здесь только
# пакеты и параметры, а применение — в configure.sh.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} vino-vnc: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} vino-vnc: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} vino-vnc: $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

ENV_FILE=/etc/bisquite/vino/config
# Path before 2.0.0. Not read as a fallback: removed below so the image never
# carries two sources of truth.
LEGACY_ENV_FILE=/etc/default/bisquite-vino

for f in knobs knobs.secret knobs.apply lib/bisquite-conf; do
    if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
        log_error "рядом нет $f — параметры vino записать нечем"
        exit 1
    fi
done
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/bisquite-conf"

# --- Параметры: проверка и запись до установки ------------------------------
#
# Проверяет схема (knobs): диапазон порта 5000–50000 взят из описания ключа
# `alternative-port` схемы org.gnome.Vino («Valid values are in the range of
# 5000 to 50000») — значение вне него vino молча не применит, и отказ вылез бы
# на плате в виде «порт закрыт»; VINO_ENCRYPTION уезжает в gsettings булевым
# ключом require-encryption, поэтому только true или false. До apt: опечатка
# видна за секунды, а хуку пароля пакет vino не нужен (только base64).
#
# Файл создаётся один раз и не переписывается — повторная установка оставляет
# правки `bisquite-conf set vino …`. Пароль — ключ secret:hook: хук
# knobs.secret кладёт его base64 в /etc/vino/vnc-password.b64 (0600) и пишет
# VINO_PASSWORD_FILE; сам пароль в журнал не печатается — ни в открытом виде,
# ни в base64.
if [[ -e "$LEGACY_ENV_FILE" ]]; then
    log_info "удаляю $LEGACY_ENV_FILE: параметры теперь в $ENV_FILE"
    rm -f "$LEGACY_ENV_FILE"
fi
conf_init vino "$SCRIPT_DIR/knobs" --env || { log_error "$ENV_FILE не записан"; exit 1; }
conf_load vino

# --- Пакеты -----------------------------------------------------------------
#
# libglib2.0-bin и dbus объявлены ЯВНО, а не взяты «десктоп же их притащит»:
# configure.sh зовёт `gsettings` (из libglib2.0-bin) и `dbus-run-session`
# (из dbus), и зависимость от порядка слоёв в VMFILE здесь уже обжигала —
# см. историю с xauth и x11-utils у x11vnc.
log_info "ставлю vino и утилиты настройки"
apt-get update || exit 1
apt-get install -y \
    vino \
    libglib2.0-bin \
    dbus || exit 1

# --- Предупреждения о доступе -----------------------------------------------
log_info "порт ${VINO_PORT}, слушает ${VINO_LISTEN}, шифрование ${VINO_ENCRYPTION}"

if [[ "$VINO_LISTEN" == "localhost" ]]; then
    log_info "наружу порт не выставлен; доступ — SSH-туннелем"
else
    log_warn "VINO_LISTEN=${VINO_LISTEN}: сервер будет слушать ВСЕ интерфейсы"
    if [[ -z "$VINO_PASSWORD_FILE" ]]; then
        log_warn "и БЕЗ ПАРОЛЯ — рабочий стол получит кто угодно в этой сети,"
        log_warn "с правами вошедшего пользователя и без следа в журнале"
    fi
    if [[ "$VINO_ENCRYPTION" != "true" ]]; then
        log_warn "и БЕЗ ШИФРОВАНИЯ — нажатия клавиш пойдут по сети открытым текстом"
    fi
fi

# --- Донастройка на первой загрузке -----------------------------------------
for f in configure-vino-vnc.service configure.sh lib/get_cloud_user.sh; do
    if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
        log_error "рядом нет $f — донастройка на первой загрузке не состоится,"
        log_error "а без неё vino не запустится ни при каком параметре"
        exit 1
    fi
done

install -m 0644 "$SCRIPT_DIR/configure-vino-vnc.service" \
    /etc/systemd/system/configure-vino-vnc.service
systemctl daemon-reload || true
systemctl enable configure-vino-vnc.service || true

log_info "готово: настройка применится на первой загрузке"
