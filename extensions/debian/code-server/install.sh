#!/usr/bin/env bash
# Скрипт установки mkcert и code-server
# Аргументы: --version VERSION (опционально)

set -euo pipefail

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Функция логирования (всегда пишем в stderr, чтобы не засорять stdout при пайпинге)
log_info() {
    >&2 echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    >&2 echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    >&2 echo -e "${RED}[ERROR]${NC} $*"
}

# Каталог расширения — от каталога СКРИПТА, а не от зашитой строки.
#
# `EXTENSION` копирует каталог в /opt/bisquite/<имя>/ и запускает install.sh
# оттуда, поэтому $SCRIPT_DIR и есть тот каталог при любой раскладке.
# Проверки ниже спрашивают «файл приехал рядом со мной?», а не «раскладка
# всё ещё такая?»: прибитый путь превращал смену раскладки в отказ всех
# сборок разом.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"


# Функция для выполнения curl с retry логикой
# Пишет тело ответа ТОЛЬКО в stdout, логи — в stderr (без смешивания)
curl_with_retry() {
    local url="$1"
    local max_attempts=5
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        log_info "Attempt $attempt/$max_attempts: Downloading $url"

        # stdout: тело, stderr: ошибки
        if curl -fsSL "$url" 2>/tmp/curl_error; then
            # Вывести тело прямо в stdout без логов
            return 0
        else
            local error_msg=$(cat /tmp/curl_error 2>/dev/null || echo "Unknown error")
            log_warn "Attempt $attempt failed: $error_msg"

            # Проверяем сетевые ошибки — делаем повтор
            if echo "$error_msg" | grep -qi "connection reset\|recv failure\|network is unreachable\|timeout\|timed out\|temporarily unavailable"; then
                if [ $attempt -lt $max_attempts ]; then
                    local delay=$((attempt * 2))
                    log_info "Waiting ${delay}s before retry..."
                    sleep $delay
                fi
            else
                log_error "Non-network error, aborting: $error_msg"
                return 1
            fi
        fi

        attempt=$((attempt + 1))
    done

    log_error "Failed to download $url after $max_attempts attempts"
    return 1
}

# Функция wget с retry логикой (загрузка в файл)
wget_with_retry() {
    local url="$1"
    local out_file="$2"
    local max_attempts=5
    local attempt=1

    while [ $attempt -le $max_attempts ]; do
        log_info "Attempt $attempt/$max_attempts: Downloading $url -> $out_file"
        if wget -q -O "$out_file" "$url" 2>/tmp/wget_error; then
            return 0
        fi
        local error_msg=$(cat /tmp/wget_error 2>/dev/null || echo "Unknown error")
        log_warn "Attempt $attempt failed: $error_msg"
        if [ $attempt -lt $max_attempts ]; then
            local delay=$((attempt * 2))
            log_info "Waiting ${delay}s before retry..."
            sleep $delay
        fi
        attempt=$((attempt + 1))
    done
    log_error "Failed to download $url after $max_attempts attempts"
    return 1
}

# Парсинг аргументов
# Версия — решение сборки, а не настройка устройства, поэтому в
# /etc/bisquite/code-server/config её нет: --version сильнее параметра VMFILE,
# параметр — сильнее закреплённой здесь. Прежнее безусловное затирание пустой
# строкой означало, что `EXTENSION code-server CODE_SERVER_VERSION=4.104.3`
# ТИХО терял пин.
DEFAULT_CODE_SERVER_VERSION="4.135.0"
ARG_VERSION=""

while [[ $# -gt 0 ]]; do
    case $1 in
        --version)
            ARG_VERSION="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--version VERSION]"
            echo "Install mkcert and code-server"
            echo ""
            echo "Options:"
            echo "  --version VERSION    Specify code-server version (default: CODE_SERVER_VERSION)"
            echo "  -h, --help          Show this help message"
            exit 0
            ;;
        *)
            log_error "Unknown option: $1"
            exit 1
            ;;
    esac
done

log_info "Starting code-server installation..."

for f in knobs knobs.apply teleport-app.sh lib/bisquite-conf; do
    if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
        log_error "рядом нет $f — настройки code-server записать нечем"
        exit 1
    fi
done
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/bisquite-conf"

# Настройки устройства — /etc/bisquite/code-server/config, до скачивания:
# опечатка в CODE_SERVER_PORT роняет сборку за секунду.
#
# ПОЧЕМУ В /etc. В /opt по FHS живёт код, а настройки держат etckeeper и
# бэкапы. Файл создаётся один раз и не переписывается: повторная установка
# оставляет правки `bisquite-conf set code-server …`; параметры VMFILE
# ложатся поверх через проверку схемы (knobs). 0600: в файле бывает пароль.
#
# Прежний /etc/bisquite/code-server/config.yaml (2.x) переносится сюда один раз
# и удаляется.
CODE_SERVER_VERSION="${ARG_VERSION:-${CODE_SERVER_VERSION:-$DEFAULT_CODE_SERVER_VERSION}}"
if [[ ! "$CODE_SERVER_VERSION" =~ ^(latest|[0-9]+\.[0-9]+\.[0-9]+)$ ]]; then
    log_error "CODE_SERVER_VERSION='$CODE_SERVER_VERSION': ожидали X.Y.Z или latest"
    exit 1
fi
# VERSION прежнего config.yaml не переносится: версия — не настройка устройства.
conf_init code-server "$SCRIPT_DIR/knobs" --env \
    --migrate-yaml USER=CODE_SERVER_USER,PASSWORD=CODE_SERVER_PASSWORD,PORT=CODE_SERVER_PORT,BIND=CODE_SERVER_BIND \
    || { log_error "/etc/bisquite/code-server/config не записан"; exit 1; }
conf_load code-server
log_info "code-server version: $CODE_SERVER_VERSION"

# Установка зависимостей
log_info "Installing system dependencies..."
apt-get update
apt-get install -y curl wget gnupg

# Установка mkcert
log_info "Installing mkcert..."
if [[ "$EUID" -eq 0 ]]; then
    # Установка mkcert для root пользователя
    if ! command -v mkcert >/dev/null 2>&1; then
        # Архитектура выбирается по гостю, а не прибита к amd64.
        #
        # Прибитая ссылка была ЕДИНСТВЕННОЙ причиной, по которой расширение
        # объявлялось только для amd64 (см. комментарий в extension.yaml):
        # сам code-server arm64 поддерживает, и его штатный установщик
        # определяет архитектуру сам. Замер 2026-09-03: релиз mkcert v1.4.4
        # публикует mkcert-v1.4.4-linux-amd64, -linux-arm64 и -linux-arm,
        # то есть выбирать было из чего с самого начала.
        #
        # Имя берётся у dpkg, а не у uname: у dpkg тот же словарь, что
        # у релизов mkcert (amd64/arm64/armhf), а uname говорит x86_64
        # и aarch64 — пришлось бы заводить таблицу перевода.
        _mkcert_arch="$(dpkg --print-architecture)"
        case "$_mkcert_arch" in
            amd64|arm64) : ;;
            armhf)       _mkcert_arch="arm" ;;
            *)
                log_error "для архитектуры ${_mkcert_arch} релиз mkcert v1.4.4 не публикуется"
                log_error "поддерживаются amd64, arm64 и armhf"
                exit 1
                ;;
        esac
        tmp_file="/tmp/mkcert-linux-${_mkcert_arch}.$$"
        MKCERT_GH_URL="https://github.com/FiloSottile/mkcert/releases/download/v1.4.4/mkcert-v1.4.4-linux-${_mkcert_arch}"
        log_info "mkcert для ${_mkcert_arch}"
        # Качаем только из GitHub релиза через wget
        if wget_with_retry "$MKCERT_GH_URL" "$tmp_file"; then
            chmod 0755 "$tmp_file"
            # Проверка магических байт ELF
            if ! head -c 4 "$tmp_file" | grep -q $'\x7fELF'; then
                log_error "Downloaded mkcert is not an ELF binary"
                rm -f "$tmp_file"
                exit 1
            fi
            # Валидация: бинарь должен исполняться и печатать версию
            if ! "$tmp_file" -version >/dev/null 2>&1; then
                log_error "Downloaded mkcert is corrupted or not executable"
                rm -f "$tmp_file"
                exit 1
            fi
            cp "$tmp_file" /usr/local/bin/mkcert
            chmod 0755 /usr/local/bin/mkcert
            rm -f "$tmp_file"
            sync || true
            # Дополнительная проверка установленного бинаря (абсолютный путь для chroot)
            if ! /usr/local/bin/mkcert -version >/dev/null 2>&1; then
                log_error "Installed mkcert failed to run (ensure /usr/local/bin is accessible)"
                rm -f /usr/local/bin/mkcert
                exit 1
            fi
            log_info "mkcert installed successfully"
        else
            rm -f "$tmp_file" 2>/dev/null || true
            log_error "Failed to download mkcert from GitHub"
            exit 1
        fi
    else
        log_info "mkcert already installed"
    fi
else
    log_error "This script must be run as root for mkcert installation"
    exit 1
fi

# Установка code-server
log_info "Installing code-server version: $CODE_SERVER_VERSION"

if [[ "$CODE_SERVER_VERSION" == "latest" ]]; then
    # Установка последней версии
    if ! curl_with_retry "https://code-server.dev/install.sh" | sh; then
        log_error "Failed to install code-server"
        exit 1
    fi
else
    # Установка конкретной версии
    if ! curl_with_retry "https://code-server.dev/install.sh" | sh -s -- --version "$CODE_SERVER_VERSION"; then
        log_error "Failed to install code-server version $CODE_SERVER_VERSION"
        exit 1
    fi
fi

# --- Донастройка на первой загрузке -----------------------------------------
# Отсутствие любого из этих файлов — ОТКАЗ СБОРКИ, а не предупреждение.
#
# Раньше здесь стоял log_warn и `|| true`: сборка оставалась зелёной, юнита
# в образе не было, и новость приходила из журнала платы без монитора —
# самый дорогой вид отказа в этом проекте. Из двух отказов дешевле тот,
# который читает собиравший: он у своей машины и чинит за минуту.
# Образец — vino-vnc/install.sh.
#
for f in configure-code-server.service configure.sh lib/get_cloud_user.sh; do
    if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
        log_error "рядом нет $f — донастройка на первой загрузке не состоится,"
        log_error "а без неё code-server не получит ни сертификата, ни юнита"
        exit 1
    fi
done

# Без `|| true`: файл нашёлся, а копирование провалилось — это ровно тот же
# исход, что и ненайденный файл.
install -m 0644 "$SCRIPT_DIR/configure-code-server.service" \
    /etc/systemd/system/configure-code-server.service

# Пароль в журнал НЕ печатается — только факт его наличия. Журнал сборки
# уезжает в CI и в переписку чаще, чем сам образ.
if [[ -z "$CODE_SERVER_PASSWORD" || "$CODE_SERVER_PASSWORD" == none ]]; then
  log_info "порт ${CODE_SERVER_PORT}, адрес ${CODE_SERVER_BIND}, пароль не задан"
  # Это ЕДИНСТВЕННОЕ место, где решение видно до того, как образ уедет
  # на устройство, поэтому формулировка прямая. Но громкость идёт по
  # АДРЕСУ, а не по одному лишь отсутствию пароля: без пароля на
  # 127.0.0.1 — обычная связка для доступа по ssh-туннелю, и крик на
  # неё приучает не читать предупреждения.
  case "$CODE_SERVER_BIND" in
    127.*|::1|localhost)
      log_info "аутентификации нет, но адрес ${CODE_SERVER_BIND} — снаружи сервер недоступен"
      ;;
    *)
      log_warn "code-server будет слушать ${CODE_SERVER_BIND} БЕЗ АУТЕНТИФИКАЦИИ:"
      log_warn "  любой, кто достаёт до этой машины по сети, получает шелл"
      log_warn "  от имени пользователя code-server со всеми его правами"
      ;;
  esac
else
  log_info "порт ${CODE_SERVER_PORT}, адрес ${CODE_SERVER_BIND}, пароль задан"
  # Пароль лежит в образе открытым текстом — и в /etc/bisquite/code-server,
  # и потом в ~/.config/code-server. Кто получит образ, получит и пароль.
  log_warn "пароль хранится в образе открытым текстом: образ = пароль"
fi

# Declaration for teleport-agent: publish code-server as a Teleport app.
# The same script runs on every reconfiguration (configure.sh), so a port
# changed with `bisquite-conf set` reaches the declaration too.
bash "$SCRIPT_DIR/teleport-app.sh" || { log_error "объявление для Teleport не положено"; exit 1; }

systemctl daemon-reload || true
systemctl enable configure-code-server.service || true

log_info "Installation completed successfully!"
log_info "code-server is installed and ready to be configured"
log_info "Configuration will be handled by the configure-code-server service"
