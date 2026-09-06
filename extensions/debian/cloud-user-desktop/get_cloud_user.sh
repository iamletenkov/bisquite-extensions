#!/usr/bin/env bash
#
# ============================================================================
#  СГЕНЕРИРОВАНО ИЗ lib/get_cloud_user.sh — РУКАМИ НЕ ПРАВИТЬ.
#
#  Копия лежит рядом со скриптами расширения потому, что до гостя доезжает
#  только каталог одного расширения (`COPY_IN <ext>:/opt/vmsetup/`), а
#  потребители ищут файл как `$SCRIPT_DIR/get_cloud_user.sh`.
#
#  Правь источник и запусти tools/sync-lib.sh.
#  Расхождение источника и копий ловит tools/check-lib.sh.
# ============================================================================
# Скрипт получения имени пользователя из cloud-init userdata
# Выводит только имя пользователя или завершается с ошибкой если не найден

set -euo pipefail

# Функция для получения пользователя из cloud-init
fallback_user() {
    # Первая обычная учётная запись с домашним каталогом.
    #
    # Диапазон uid тот же, что у `adduser` в Debian: 1000..65533. Верхняя
    # граница отсекает `nobody` (65534), нижняя — системные учётки.
    # Домашний каталог обязателен: всё, что настраивают расширения
    # (gsettings, ключи, автозапуск), живёт в нём, и учётка без него
    # настройке не поддаётся.
    local candidate
    for candidate in $(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1}'); do
        if [[ -d "/home/${candidate}" ]]; then
            echo "$candidate"
            return 0
        fi
    done
    echo "Error: no cloud-init user and no regular account with a home dir" >&2
    return 1
}

get_cloud_user() {
    local ci_user=""

    # Проверяем доступность необходимых команд
    # Отсутствие cloud-init или yq — НЕ отказ, а переход к запасному пути.
    #
    # Раньше здесь стоял `return 1`, и на образе без cloud-init поиск
    # проваливался всегда. Замер 2026-09-04 на живом Jetson: вендорский
    # образ Q-engineering собран без cloud-init, и `vino-vnc` с
    # `jetson-stats` не настроились вовсе, а `docker` настроился —
    # потому что у него, единственного из трёх, запасной путь был
    # дописан в своём `configure.sh`. Одна задача решалась в двух
    # местах по-разному, и работало то, где решили полнее.
    #
    # Запасной путь теперь здесь, в общем скрипте: он одинаков у всех
    # девяти расширений (файлы байт в байт совпадают), и класть его
    # в каждое `configure.sh` значило бы завести девять расходящихся
    # копий вместо одной.
    if ! command -v cloud-init >/dev/null 2>&1 || ! command -v yq >/dev/null 2>&1; then
        fallback_user
        return $?
    fi

    # Получаем пользовательские данные из cloud-init
    local userdata
    if ! userdata=$(cloud-init query userdata 2>/dev/null); then
        # Альтернативный способ - читаем напрямую из файла
        local user_data_file="/var/lib/cloud/instance/user-data.txt"
        if [[ -f "$user_data_file" ]]; then
            userdata=$(cat "$user_data_file" 2>/dev/null || echo "")
        else
            # cloud-init установлен, но данных пока нет — это ГОНКА,
            # а не отсутствие. Отказ здесь означает «попробуй ещё раз»,
            # и вызывающий цикл ждёт. Запасной путь тут вернул бы
            # вендорского пользователя раньше, чем cloud-init создаст
            # своего, — то есть настроил бы не того.
            echo "Error: cloud-init userdata not ready yet" >&2
            return 1
        fi
    fi

    # Если userdata пустые, выходим с ошибкой
    if [[ -z "$userdata" ]] || [[ "$userdata" == "null" ]]; then
        # Тоже гонка: см. выше.
        echo "Error: No cloud-init userdata found" >&2
        return 1
    fi

    # Извлекаем пользователя с помощью yq в чистом окружении
    ci_user=$(echo "$userdata" | env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" TERM=dumb yq -r '.user // ""' 2>/dev/null || true)

    # Если пользователь не найден, пробуем альтернативные поля
    if [[ -z "$ci_user" ]]; then
        ci_user=$(echo "$userdata" | env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" TERM=dumb yq -r '.users[0].name // ""' 2>/dev/null || true)
    fi

    # Если пользователь найден, возвращаем его
    if [[ -n "$ci_user" ]]; then
        echo "$ci_user"
        return 0
    fi

    # Данные cloud-init есть, пользователя в них нет. Запасной путь здесь
    # неуместен: это ошибка манифеста (seed без пользователя), а не
    # отсутствие cloud-init, и подставлять вендорскую учётку значило бы
    # заминать ошибку вместо того, чтобы её показать.
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
