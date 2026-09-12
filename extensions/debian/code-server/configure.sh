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

# Функция логирования (всегда пишем в stderr, чтобы не засорять stdout).
#
# Так же, как в соседнем install.sh и во всех прочих расширениях. Здесь
# диагностика уходила в stdout, то есть в тот же канал, в котором скрипты
# этого репозитория возвращают ЗНАЧЕНИЯ (`get_cloud_user.sh` — имя учётки).
# Цена расхождения не в этом файле — юнит шлёт оба канала в журнал, — а
# в следующем: конвенция, у которой есть исключение, перестаёт быть
# конвенцией.
log_info() {
    >&2 echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    >&2 echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    >&2 echo -e "${RED}[ERROR]${NC} $*"
}

log_debug() {
    >&2 echo -e "${BLUE}[DEBUG]${NC} $*"
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

    if [[ ${#missing_deps[@]} -gt 0 ]]; then
        log_error "Missing required dependencies: ${missing_deps[*]}"
        log_error "Please run install.sh first"
        exit 1
    fi
}

# Чтение одного скалярного поля из config.yaml.
#
# ПОЧЕМУ ЗДЕСЬ ЗАПАСНОЙ ПУТЬ, А НЕ ТРЕБОВАНИЕ yq. Асимметрия между фазами
# была багом: install.sh (сборка) с самого начала читает ЭТОТ ЖЕ файл через
# grep/sed, когда yq недоступен, — с комментарием «yq может не быть
# установлен на ранних этапах». А configure.sh на тех же четырёх полях
# падал с "Missing required dependencies: yq".
#
# Воспроизведено 2026-09-12 на живой плате AGX Orin: code-server и mkcert
# установились, служба configure-code-server упала на первой загрузке,
# и code-server остался ненастроенным и незапущенным. Узнать об этом можно
# было только на устройстве — то есть худший из возможных моментов.
#
# Требовать `requires: [yq]` было бы вторым решением, и оно хуже: yq тянет
# бинарь с GitHub, и каждый профиль с code-server обязан был бы нести это
# расширение ради чтения четырёх скаляров.
#
# Разбор grep/sed достаточен, потому что файл НАШ и плоский: его пишет
# install.sh рядом, поля скалярные, без вложенности и многострочных
# значений. yq, если он есть, по-прежнему используется первым.
read_config_value() {
    local key="$1" file="$2" value=""
    if command -v yq >/dev/null 2>&1; then
        value=$(env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" TERM=dumb \
            yq -r ".${key} // \"\"" "$file" 2>/dev/null || true)
    else
        value=$(sed -n "s/^${key}:[[:space:]]*//p" "$file" | head -n1 | tr -d "\"'" || true)
    fi
    printf '%s' "$value"
}

# Чтение конфигурации из config.yaml
read_config() {
    local script_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    local config_file="$script_dir/config.yaml"

    if [[ ! -f "$config_file" ]]; then
        log_error "Configuration file not found: $config_file"
        exit 1
    fi

    CODE_USER=$(read_config_value USER "$config_file")
    CODE_PASSWORD=$(read_config_value PASSWORD "$config_file")
    CODE_PASSWORD="${CODE_PASSWORD:-none}"
    CODE_PORT=$(read_config_value PORT "$config_file")
    CODE_PORT="${CODE_PORT:-9001}"
    CODE_BIND=$(read_config_value BIND "$config_file")
    # Умолчание историческое: до появления параметра адрес был прибит
    # к 0.0.0.0, и образы, собранные раньше, обязаны вести себя как прежде.
    CODE_BIND="${CODE_BIND:-0.0.0.0}"
    # VERSION отсюда НЕ читается, и это не упущение: поле относится к фазе
    # сборки — его берёт install.sh (`get_version_from_config`) своим
    # способом. Прежняя CODE_VERSION вычиталась здесь и не использовалась
    # больше нигде, то есть была мёртвой ручкой: читатель думал, что версия
    # на что-то влияет на первой загрузке, а менять её тут уже поздно.
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

    # ДОМАШНИЙ КАТАЛОГ СПРАШИВАЕМ У getent, А НЕ СОБИРАЕМ ИЗ "/home/<имя>".
    #
    # Прибитый /home стоял в пяти местах — каталог сертификатов, каталог
    # конфига, два пути внутри самого конфига и `ExecStart --config`. Учётка
    # с домашним каталогом в другом месте (/srv, /export/home, /var/lib/…)
    # ломалась МОЛЧА: каталоги создавались мимо, конфиг писался мимо,
    # а служба рапортовала успех. Тот же способ уже применён в репозитории —
    # kiosk/run-kiosk.sh и wrt_cloudinit/wrt.cloudinit спрашивают getent.
    CODE_HOME="$(getent passwd "$CODE_USER" | cut -d: -f6 || true)"
    if [[ -z "$CODE_HOME" ]]; then
        # Запасного «/home/$CODE_USER» здесь нет намеренно: подстановка
        # догадки — это и есть чинимый дефект. Всё, что настраивает
        # расширение, живёт в домашнем каталоге, и учётка без него
        # настройке не поддаётся.
        log_error "У пользователя '$CODE_USER' в /etc/passwd нет домашнего каталога"
        exit 1
    fi
    log_info "Домашний каталог пользователя: $CODE_HOME"
}

# Создание SSL сертификатов
setup_certificates() {
    local cert_dir="$CODE_HOME/.local/share/code-server/certs"

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
    local config_dir="$CODE_HOME/.config/code-server"

    log_info "Creating code-server configuration..."

    # Создаем директорию конфигурации
    mkdir -p "$config_dir"

    # Создаем конфигурационный файл
    # Аутентификация следует за паролем, а не игнорирует его.
    #
    # Раньше `auth: none` писалось БЕЗУСЛОВНО, каким бы ни был CODE_PASSWORD.
    # Оператор задавал пароль, установка рапортовала «пароль задан», а сервер
    # поднимался открытым — то есть громкость стояла на неверной стороне:
    # предупреждение снималось ровно в том случае, когда защиты не было.
    if [[ -n "$CODE_PASSWORD" && "$CODE_PASSWORD" != "none" ]]; then
        cat > "$config_dir/config.yaml" << EOF
bind-addr: ${CODE_BIND}:${CODE_PORT}
auth: password
password: ${CODE_PASSWORD}
cert: ${CODE_HOME}/.local/share/code-server/certs/localhost.crt
cert-key: ${CODE_HOME}/.local/share/code-server/certs/localhost.key
EOF
        log_info "аутентификация по паролю включена"
    else
        cat > "$config_dir/config.yaml" << EOF
bind-addr: ${CODE_BIND}:${CODE_PORT}
auth: none
cert: ${CODE_HOME}/.local/share/code-server/certs/localhost.crt
cert-key: ${CODE_HOME}/.local/share/code-server/certs/localhost.key
EOF
        # Громкость по адресу, а не по одному лишь отсутствию пароля:
        # code-server без пароля на 127.0.0.1 — обычная связка для доступа
        # по ssh-туннелю, и кричать на неё значит приучать не читать
        # предупреждения. Открытым всей сети он становится от АДРЕСА.
        case "$CODE_BIND" in
            127.*|::1|localhost)
                log_info "аутентификации нет, но сервер слушает только $CODE_BIND — снаружи недоступен"
                ;;
            *)
                log_warn "аутентификации НЕТ, сервер слушает $CODE_BIND — шелл открыт всей сети"
                ;;
        esac
    fi

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
ExecStart=/usr/bin/code-server --config ${CODE_HOME}/.config/code-server/config.yaml
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

    # ОТСУТСТВИЕ ДАННЫХ И ГОНКА — РАЗНЫЕ СЛУЧАИ, И РАЗЛИЧАТЬ ИХ ОБЯЗАТЕЛЬНО.
    #
    # Раньше здесь стоял безусловный `return 1`: нет user-data.txt — значит
    # «менять нечего». На образе БЕЗ cloud-init файл не появится никогда,
    # поэтому служба печатала «No configuration changes needed» и не
    # настраивала ничего — хотя get_cloud_user.sh держит fallback_user()
    # ровно для такого образа. Вторым следствием тот ранний выход перекрывал
    # проверку своего config.yaml, которая стоит ниже (замер 2026-09-06).
    #
    # Различие взято у lib/get_cloud_user.sh, где оно уже сделано по тому же
    # признаку. `yq` здесь в признак не входит: без него check_dependencies
    # уже завершил бы скрипт, то есть до этой строки дело не дошло бы.
    if [[ ! -f "$user_data_file" ]]; then
        if command -v cloud-init >/dev/null 2>&1; then
            # cloud-init есть, а данных пока нет — это ГОНКА, и она законна.
            # Отказ означает «попробуй ещё раз»: взять сейчас запасную
            # учётку значит настроить не того пользователя, раньше, чем
            # cloud-init создаст своего.
            return 1
        fi
        # cloud-init в системе нет — файл не появится никогда, и решают
        # остальные признаки: отметка last-config-time и mtime своего
        # config.yaml. Дальше по тексту.
    fi

    # Получаем время последней конфигурации
    local last_config_time_value
    last_config_time_value=$(cat "$last_config_time" 2>/dev/null || echo "0")

    # НИ РАЗУ НЕ НАСТРАИВАЛИ — НАСТРОИТЬ ХОТЯ БЫ РАЗ.
    #
    # Без этого случая первая настройка на образе без cloud-init висела бы
    # на mtime config.yaml — то есть на файле, который расширение вправе
    # удалить (у x11vnc он удалён целиком). Зависимость от того, чего может
    # не быть, здесь означала бы «не настроено никогда».
    if [[ ! -f "$last_config_time" ]]; then
        return 0
    fi

    # Если user-data новее последней конфигурации, нужно переконфигурировать
    if [[ -f "$user_data_file" ]]; then
        local user_data_mtime
        user_data_mtime=$(stat -c %Y "$user_data_file" 2>/dev/null || echo "0")
        if [[ "$user_data_mtime" -gt "$last_config_time_value" ]]; then
            return 0
        fi
    fi

    # И ЕСЛИ НОВЕЕ НАШ СОБСТВЕННЫЙ config.yaml.
    #
    # Он источник настроек расширения — порт, адрес, пароль, — а
    # проверялся только `user-data` от cloud-init. Правка config.yaml
    # не считалась изменением вовсе, и служба выходила с «No
    # configuration changes needed», оставив прежний конфиг.
    #
    # Замер 2026-09-06 на Jetson Nano: манифест записи менял адрес
    # на 0.0.0.0 через firstboot, служба запускалась следом и молча
    # ничего не делала — сервер остался на 127.0.0.1.
    local script_dir_cfg="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/config.yaml"
    if [[ -f "$script_dir_cfg" ]]; then
        local cfg_mtime
        cfg_mtime=$(stat -c %Y "$script_dir_cfg" 2>/dev/null || echo "0")
        if [[ "$cfg_mtime" -gt "$last_config_time_value" ]]; then
            return 0
        fi
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

    # Итоговая строка следует за фактом, а не за прежним допущением.
    # Прежде здесь безусловно печаталось «Authentication: disabled», а ниже
    # стояла приписка «пароль задан, но аутентификация отключена» —
    # признание дефекта вместо его починки, и читалась она уже на устройстве.
    if [[ -n "$CODE_PASSWORD" && "$CODE_PASSWORD" != "none" ]]; then
        log_info "Authentication: password"
    else
        # Адрес подставляется, а не пишется жёстко. Здесь стояло «на
        # 0.0.0.0» константой, хотя двадцатью строками выше `write_config`
        # уже различает адрес правильным `case`. При
        # `CODE_SERVER_BIND=127.0.0.1` журнал первой загрузки говорил
        # и «снаружи недоступен», и «шелл открыт всей сети» — второе
        # неправда, и именно оно кричало громче.
        case "$CODE_BIND" in
            127.*|::1|localhost)
                log_info "Authentication: НЕТ (auth: none), но адрес $CODE_BIND — снаружи недоступен"
                ;;
            *)
                log_warn "Authentication: НЕТ (auth: none) на $CODE_BIND — шелл открыт всей сети"
                ;;
        esac
    fi
}

main "$@"
