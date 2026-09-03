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

# Функция получения версии из config.yaml
get_version_from_config() {
    local config_file="config.yaml"
    local version=""

    if [[ -f "$config_file" ]]; then
        # Используем grep для поиска VERSION, так как yq может не быть установлен на ранних этапах
        if command -v yq >/dev/null 2>&1; then
            version=$(yq -r '.VERSION // empty' "$config_file" 2>/dev/null || true)
        else
            # Fallback к grep/sed если yq недоступен
            version=$(grep -E '^VERSION:' "$config_file" | sed 's/VERSION: *//' | tr -d ' ' || true)
        fi
    fi

    echo "$version"
}

# Парсинг аргументов
# Переменная окружения имеет приоритет над config.yaml и уступает --version.
# Безусловное затирание пустой строкой означало, что
# `EXTENSION code-server CODE_SERVER_VERSION=4.104.3` ТИХО терял пин: значение
# приходило в окружении и стиралось здесь, до разбора аргументов.
CODE_SERVER_VERSION="${CODE_SERVER_VERSION:-}"

while [[ $# -gt 0 ]]; do
    case $1 in
        --version)
            CODE_SERVER_VERSION="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [--version VERSION]"
            echo "Install mkcert and code-server"
            echo ""
            echo "Options:"
            echo "  --version VERSION    Specify code-server version (default: from config.yaml)"
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

# Если версия не указана, пробуем получить из config.yaml
if [[ -z "$CODE_SERVER_VERSION" ]]; then
    CODE_SERVER_VERSION=$(get_version_from_config)
    if [[ -n "$CODE_SERVER_VERSION" ]]; then
        log_info "Using code-server version from config.yaml: $CODE_SERVER_VERSION"
    else
        log_warn "No version specified and VERSION not found in config.yaml, using latest"
        CODE_SERVER_VERSION="latest"
    fi
fi

# Установка зависимостей
log_info "Installing system dependencies..."
apt-get update
apt-get install -y curl wget gnupg yq

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

# Установка systemd unit-файла из каталога расширения (если присутствует)
if [[ -f "/opt/vmsetup/code-server/configure-code-server.service" ]]; then
  install -m 0644 /opt/vmsetup/code-server/configure-code-server.service /etc/systemd/system/configure-code-server.service || true
else
  log_warn "configure-code-server.service not found in /opt/vmsetup/code-server/"
fi

# Параметры из VMFILE перекрывают config.yaml.
#
# ЗАЧЕМ. config.yaml лежит в каталоге расширения, то есть в кеше источников,
# а кеш перезаписывается на каждом `bs extension sync`. Правка порта в нём
# держалась бы до первой синхронизации и пропадала молча — ровно та болезнь
# «мёртвых ручек», из-за которой у расширения x11vnc настройки переехали
# в переменные окружения (2026-09-03).
#
# Читает config.yaml не install.sh, а configure.sh на первой загрузке
# (`read_config`, оттуда же bind-addr и auth), поэтому перезаписываем файл
# здесь, в фазе сборки, а не подменяем механизм.
_cs_config="/opt/vmsetup/code-server/config.yaml"
if [[ -n "${CODE_SERVER_PORT:-}${CODE_SERVER_PASSWORD:-}${CODE_SERVER_USER:-}" ]]; then
  if [[ -f "$_cs_config" ]]; then
    # Значения, которых не задали, берём из существующего файла, чтобы
    # `EXTENSION code-server CODE_SERVER_PORT=9002` не сбрасывал версию.
    _cs_old_user=$(sed -n 's/^USER:[[:space:]]*//p' "$_cs_config" | head -1)
    _cs_old_pass=$(sed -n 's/^PASSWORD:[[:space:]]*//p' "$_cs_config" | head -1)
    _cs_old_port=$(sed -n 's/^PORT:[[:space:]]*//p' "$_cs_config" | head -1)
    _cs_old_ver=$(sed -n 's/^VERSION:[[:space:]]*//p' "$_cs_config" | head -1)
  fi
  _cs_pass="${CODE_SERVER_PASSWORD:-${_cs_old_pass:-none}}"
  _cs_port="${CODE_SERVER_PORT:-${_cs_old_port:-9001}}"

  # Права ставятся ДО записи: файл может содержать пароль, и промежутка,
  # в котором он лежит с правами по umask, быть не должно.
  install -m 0600 /dev/null "$_cs_config"
  cat > "$_cs_config" <<CSCONF
USER: ${CODE_SERVER_USER:-${_cs_old_user:-}}
PASSWORD: ${_cs_pass}
PORT: ${_cs_port}
VERSION: ${CODE_SERVER_VERSION:-${_cs_old_ver:-latest}}
CSCONF

  # Пароль в журнал НЕ печатается — только факт его наличия. Журнал сборки
  # уезжает в CI и в переписку чаще, чем сам образ.
  if [[ "$_cs_pass" == "none" ]]; then
    log_info "config.yaml перезаписан из VMFILE: порт ${_cs_port}, пароль не задан"
    # configure.sh поднимет сервер как `bind-addr: 0.0.0.0` с `auth: none`.
    # Это ЕДИНСТВЕННОЕ место, где решение видно до того, как образ уедет
    # на устройство, поэтому формулировка прямая.
    log_warn "code-server будет слушать 0.0.0.0 БЕЗ АУТЕНТИФИКАЦИИ:"
    log_warn "  любой, кто достаёт до этой машины по сети, получает шелл"
    log_warn "  от имени пользователя code-server со всеми его правами"
  else
    log_info "config.yaml перезаписан из VMFILE: порт ${_cs_port}, пароль задан"
    # Пароль лежит в образе открытым текстом — и в /opt/vmsetup, и потом
    # в ~/.config/code-server. Кто получит образ, получит и пароль.
    log_warn "пароль хранится в образе открытым текстом: образ = пароль"
  fi
  unset _cs_pass
fi

systemctl daemon-reload || true
systemctl enable configure-code-server.service || true

log_info "Installation completed successfully!"
log_info "code-server is installed and ready to be configured"
log_info "Configuration will be handled by the configure-code-server service"
