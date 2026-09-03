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
# VMFILE, install.sh кладёт их в /etc/default/bisquite-vino, а configure.sh
# читает оттуда — единственный источник правды об их именах — этот файл.
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

# Умолчания объявлены здесь, и README обязан совпадать с этим местом.
VINO_PORT="${VINO_PORT:-5900}"
VINO_LISTEN="${VINO_LISTEN:-localhost}"
VINO_PASSWORD="${VINO_PASSWORD:-}"
VINO_ENCRYPTION="${VINO_ENCRYPTION:-false}"

ENV_FILE=/etc/default/bisquite-vino
PASS_FILE=/etc/vino/vnc-password.b64

# --- Проверка параметров до установки ---------------------------------------
#
# Диапазон 5000–50000 взят не с потолка: он записан в описании ключа
# `alternative-port` схемы org.gnome.Vino («Valid values are in the range of
# 5000 to 50000»). Значение вне него vino молча не применит, и отказ вылез бы
# на плате в виде «порт закрыт».
if [[ ! "$VINO_PORT" =~ ^[0-9]+$ ]] || (( VINO_PORT < 5000 || VINO_PORT > 50000 )); then
    log_error "VINO_PORT=${VINO_PORT} вне диапазона 5000–50000"
    log_error "диапазон задан схемой org.gnome.Vino (ключ alternative-port)"
    exit 1
fi

case "$VINO_ENCRYPTION" in
    true|false) ;;
    *)
        log_error "VINO_ENCRYPTION=${VINO_ENCRYPTION}: допустимо только true или false"
        log_error "значение уезжает в gsettings как булев ключ require-encryption"
        exit 1
        ;;
esac

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

# --- Параметры для первой загрузки ------------------------------------------
install -d -m 0755 /etc/default
{
    echo "VINO_PORT=${VINO_PORT}"
    echo "VINO_LISTEN=${VINO_LISTEN}"
    echo "VINO_ENCRYPTION=${VINO_ENCRYPTION}"
} > "$ENV_FILE"
chmod 0644 "$ENV_FILE"

if [[ -n "$VINO_PASSWORD" ]]; then
    # Ключ `vnc-password` схемы org.gnome.Vino хранит пароль в base64 —
    # так написано в его описании. Кодируем здесь, чтобы configure.sh
    # не занимался форматом, и держим отдельным файлом с правами 0600:
    # base64 разворачивается тривиально, поэтому файл — секрет, а не
    # «закодированное значение».
    install -d -m 0700 /etc/vino
    printf '%s' "$VINO_PASSWORD" | base64 -w0 > "$PASS_FILE"
    chmod 0600 "$PASS_FILE"
    echo "VINO_PASSWORD_FILE=${PASS_FILE}" >> "$ENV_FILE"
    # Сам пароль в журнал не печатаем — ни в открытом виде, ни в base64.
    log_info "пароль записан в ${PASS_FILE}"

    if (( ${#VINO_PASSWORD} > 8 )); then
        # Аутентификация VNC (RFB, тип 2) кладёт в ключ DES ровно 8 байт,
        # остальное отбрасывается. Двадцатисимвольный пароль здесь не
        # сильнее восьмисимвольного, и знать это надо до, а не после.
        log_warn "пароль длиннее 8 символов: VNC-аутентификация использует только первые 8"
    fi
fi

# --- Предупреждения о доступе -----------------------------------------------
log_info "порт ${VINO_PORT}, слушает ${VINO_LISTEN}, шифрование ${VINO_ENCRYPTION}"

if [[ "$VINO_LISTEN" == "localhost" ]]; then
    log_info "наружу порт не выставлен; доступ — SSH-туннелем"
else
    log_warn "VINO_LISTEN=${VINO_LISTEN}: сервер будет слушать ВСЕ интерфейсы"
    if [[ -z "$VINO_PASSWORD" ]]; then
        log_warn "и БЕЗ ПАРОЛЯ — рабочий стол получит кто угодно в этой сети,"
        log_warn "с правами вошедшего пользователя и без следа в журнале"
    fi
    if [[ "$VINO_ENCRYPTION" != "true" ]]; then
        log_warn "и БЕЗ ШИФРОВАНИЯ — нажатия клавиш пойдут по сети открытым текстом"
    fi
fi

# --- Донастройка на первой загрузке -----------------------------------------
for f in configure-vino-vnc.service configure.sh get_cloud_user.sh; do
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
