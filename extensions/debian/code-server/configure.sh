#!/usr/bin/env bash
# Скрипт автоконфигурации code-server
# Создает сертификаты, конфигурацию и запускает сервис для указанного пользователя

set -euo pipefail

# Очищаем переменные окружения, которые могут содержать цветовые коды
unset "${!LC_@}"
unset "${!LANG_@}"

# Цвета для вывода
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m' # No Color

# Функция логирования
log_info() {
    echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    echo -e "${RED}[ERROR]${NC} $*"
}

log_debug() {
    echo -e "${BLUE}[DEBUG]${NC} $*"
}

# Проверка наличия необходимых команд
check_dependencies() {
    local missing_deps=()

    if ! command -v mkcert >/dev/null 2>&1; then
        missing_deps+=("mkcert")
    fi

    if ! command -v code-server >/dev/null 2>&1; then
        missing_deps+=("code-server")
    fi

    if ! command -v yq >/dev/null 2>&1; then
        missing_deps+=("yq")
    fi

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        log_error "Please run install.sh first"
        exit 1
    fi
}

# Чтение конфигурации из config.yaml
read_config() {
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local config_file="$script_dir/config.yaml"

    if [[ ! -f "$config_file" ]]; then
        log_error "Configuration file not found: $config_file"
        exit 1
    fi

    # Читаем значения с помощью yq в чистом окружении
    CODE_USER=$(env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" TERM=dumb yq -r '.USER // empty' "$config_file" 2>/dev/null || echo "")
    CODE_PASSWORD=$(env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" TERM=dumb yq -r '.PASSWORD // empty' "$config_file" 2>/dev/null || echo "none")
    CODE_PORT=$(env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" TERM=dumb yq -r '.PORT // empty' "$config_file" 2>/dev/null || echo "9001")
    CODE_VERSION=$(env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" TERM=dumb yq -r '.VERSION // empty' "$config_file" 2>/dev/null || echo "latest")
}

# Определение пользователя
resolve_user() {
    if [[ -z "$CODE_USER" ]]; then
        log_info "USER not specified in config, trying to get from cloud-init..."

        local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
        if [[ -x "$script_dir/get_cloud_user.sh" ]]; then
            if CODE_USER=$("$script_dir/get_cloud_user.sh"); then
                log_info "Found user from cloud-init: $CODE_USER"
            else
                log_error "Failed to get user from cloud-init"
                exit 1
            fi
        else
            log_error "get_cloud_user.sh not found at $script_dir/get_cloud_user.sh"
            exit 1
        fi
    else
        log_info "Using user from config: $CODE_USER"
    fi

    # Проверяем существование пользователя
    if ! id "$CODE_USER" >/dev/null 2>&1; then
        log_error "User '$CODE_USER' does not exist"
        exit 1
    fi

    # Валидация имени пользователя для использования в имени сервиса systemd
    # systemd сервисы не могут содержать некоторые символы в именах
    if [[ ! "$CODE_USER" =~ ^[a-zA-Z0-9._-]+$ ]]; then
        log_error "Invalid username '$CODE_USER' for systemd service name"
        log_error "Username can only contain letters, numbers, dots, underscores and hyphens"
        exit 1
    fi
}

# Создание SSL сертификатов
setup_certificates() {
    local cert_dir="/home/$CODE_USER/.local/share/code-server/certs"
    local user_home="/home/$CODE_USER"

    log_info "Setting up SSL certificates for user: $CODE_USER"

    # Создаем директории
    sudo -u "$CODE_USER" mkdir -p "$cert_dir"

    # Проверяем, существуют ли сертификаты
    if [[ -f "$cert_dir/localhost.crt" ]] && [[ -f "$cert_dir/localhost.key" ]]; then
        log_info "SSL certificates already exist, skipping generation"
        return 0
    fi

    log_info "Generating SSL certificates..."

    # Создаем сертификаты от root (mkcert установит их в правильном месте)
    cd "$cert_dir"

    # Выполняем команды в чистом окружении без цветовых кодов
    env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" CAROOT="$cert_dir" TERM=dumb mkcert -install >/dev/null 2>&1

    # Генерируем сертификат для localhost
    env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" CAROOT="$cert_dir" TERM=dumb mkcert localhost 127.0.0.1 ::1 >/dev/null 2>&1

    # Переименовываем сертификаты для code-server
    if [[ -f "$cert_dir/localhost+2.pem" ]]; then
        mv "$cert_dir/localhost+2.pem" "$cert_dir/localhost.crt"
    fi

    if [[ -f "$cert_dir/localhost+2-key.pem" ]]; then
        mv "$cert_dir/localhost+2-key.pem" "$cert_dir/localhost.key"
    fi

    # Устанавливаем правильные права доступа
    chown -R "$CODE_USER:$CODE_USER" "$cert_dir"
    chmod 600 "$cert_dir/localhost.key" 2>/dev/null || true

    log_info "SSL certificates generated successfully"
}

# Создание конфигурации code-server
create_config() {
    local config_dir="/home/$CODE_USER/.config/code-server"

    log_info "Creating code-server configuration..."

    # Создаем директорию конфигурации
    mkdir -p "$config_dir"

    # Создаем конфигурационный файл
    cat > "$config_dir/config.yaml" << EOF
bind-addr: 0.0.0.0:${CODE_PORT}
auth: none
cert: /home/${CODE_USER}/.local/share/code-server/certs/localhost.crt
cert-key: /home/${CODE_USER}/.local/share/code-server/certs/localhost.key
EOF

    # Устанавливаем правильные права доступа
    chown -R "$CODE_USER:$CODE_USER" "$config_dir"
    chmod 600 "$config_dir/config.yaml"

    log_info "Configuration created at $config_dir/config.yaml"
}

# Создание systemd сервиса для пользователя
create_user_service() {
    log_info "Creating systemd service for user: $CODE_USER"

    # Останавливаем существующий сервис если он запущен
    env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" TERM=dumb systemctl disable "code-server@${CODE_USER}.service" 2>/dev/null || true
    env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" TERM=dumb systemctl stop "code-server@${CODE_USER}.service" 2>/dev/null || true

    # Создаем пользовательский сервис
    cat > "/etc/systemd/system/code-server@${CODE_USER}.service" << EOF
[Unit]
Description=code-server for user ${CODE_USER}
After=network.target

[Service]
Type=exec
User=${CODE_USER}
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
ExecStart=/usr/bin/code-server --config /home/${CODE_USER}/.config/code-server/config.yaml
Restart=on-failure
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF

    # Включаем сервис
    env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" TERM=dumb systemctl daemon-reload
    env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" TERM=dumb systemctl enable "code-server@${CODE_USER}.service"
    env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" TERM=dumb systemctl restart "code-server@${CODE_USER}.service"

    log_info "Service code-server@${CODE_USER}.service created and started"
}

# Функция для отслеживания изменений в cloud-init
should_reconfigure() {
    local user_data_file="/var/lib/cloud/instance/user-data.txt"
    local last_config_time="/var/lib/code-server/last-config-time"

    # Создаем директорию для хранения времени последней конфигурации
    mkdir -p /var/lib/code-server

    # Если файл user-data не существует, выходим
    if [[ ! -f "$user_data_file" ]]; then
        return 1
    fi

    # Получаем время модификации user-data
    local user_data_mtime
    user_data_mtime=$(stat -c %Y "$user_data_file" 2>/dev/null || echo "0")

    # Получаем время последней конфигурации
    local last_config_time_value
    last_config_time_value=$(cat "$last_config_time" 2>/dev/null || echo "0")

    # Если user-data новее последней конфигурации, нужно переконфигурировать
    if [[ "$user_data_mtime" -gt "$last_config_time_value" ]]; then
        return 0
    fi

    return 1
}

# Основная функция
main() {
    log_info "Starting code-server configuration check..."

    # Проверяем, нужна ли реконфигурация
    if ! should_reconfigure; then
        log_info "No configuration changes needed, exiting"
        exit 0
    fi

    log_info "Configuration changes detected, reconfiguring code-server..."

    check_dependencies
    read_config
    resolve_user
    setup_certificates
    create_config
    create_user_service

    # Сохраняем время последней конфигурации
    local current_time
    current_time=$(date +%s)
    echo "$current_time" > /var/lib/code-server/last-config-time

    log_info "Configuration completed successfully!"
    log_info "code-server is now running for user '$CODE_USER' on port $CODE_PORT"
    log_info "Access URL: https://localhost:$CODE_PORT"
    log_info "Authentication: disabled (auth: none)"

    if [[ "$CODE_PASSWORD" != "none" ]]; then
        log_warn "Note: PASSWORD is set in config but authentication is disabled"
    fi
}

main "$@"
