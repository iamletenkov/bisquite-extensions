#!/usr/bin/env bash
# Скрипт получения имени пользователя из cloud-init userdata
# Выводит только имя пользователя или завершается с ошибкой если не найден

set -euo pipefail

# Функция для получения пользователя из cloud-init
get_cloud_user() {
    local ci_user=""

    # Проверяем доступность необходимых команд
    if ! command -v cloud-init >/dev/null 2>&1; then
        echo "Error: cloud-init not found" >&2
        return 1
    fi

    if ! command -v yq >/dev/null 2>&1; then
        echo "Error: yq not found" >&2
        return 1
    fi

    # Получаем пользовательские данные из cloud-init
    local userdata
    if ! userdata=$(cloud-init query userdata 2>/dev/null); then
        # Альтернативный способ - читаем напрямую из файла
        local user_data_file="/var/lib/cloud/instance/user-data.txt"
        if [[ -f "$user_data_file" ]]; then
            userdata=$(cat "$user_data_file" 2>/dev/null || echo "")
        else
            echo "Error: Failed to query cloud-init userdata and file not found: $user_data_file" >&2
            return 1
        fi
    fi

    # Если userdata пустые, выходим с ошибкой
    if [[ -z "$userdata" ]] || [[ "$userdata" == "null" ]]; then
        echo "Error: No cloud-init userdata found" >&2
        return 1
    fi

    # Извлекаем пользователя с помощью yq в чистом окружении
    ci_user=$(echo "$userdata" | env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" TERM=dumb yq -r '.user // empty' 2>/dev/null || true)

    # Если пользователь не найден, пробуем альтернативные поля
    if [[ -z "$ci_user" ]]; then
        ci_user=$(echo "$userdata" | env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" TERM=dumb yq -r '.users[0].name // empty' 2>/dev/null || true)
    fi

    # Если пользователь найден, возвращаем его
    if [[ -n "$ci_user" ]]; then
        echo "$ci_user"
        return 0
    fi

    echo "Error: User not found in cloud-init userdata" >&2
    return 1
}

# Основная логика
main() {
    local user

    if user=$(get_cloud_user); then
        echo "$user"
        exit 0
    else
        exit 1
    fi
}

main "$@"
