#!/usr/bin/env bash
# Первая загрузка: внести пользователя cloud-init в группу `jtop` и
# убедиться, что демон поднялся.
#
# ЗАЧЕМ ЭТО ОТДЕЛЬНОЙ ФАЗОЙ. Демон создаёт сокет /run/jtop.sock и выставляет
# ему 0660 root:jtop (jtop/service.py, JtopServer.start: chown на gid группы
# `jtop`, затем chmod S_IREAD|S_IWRITE|S_IRGRP|S_IWGRP). Пользователь вне
# группы получает от клиента не подсказку, а невнятное
# «I can't access jtop.service. Please logout or reboot this board»
# (jtop/jtop.py:1117) — то есть отказ выглядит как «надо перезагрузиться»,
# хотя перезагрузка не поможет.
#
# На сборке внести в группу некого: пользователя создаёт cloud-init уже на
# устройстве, и его имя приходит из seed. Тот же довод, по которому автологин
# настраивается на первой загрузке (см. gnome/configure.sh).
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} jetson-stats: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} jetson-stats: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} jetson-stats: $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

check_prereqs(){
    if [[ ! -x "$SCRIPT_DIR/get_cloud_user.sh" ]]; then
        log_error "нет $SCRIPT_DIR/get_cloud_user.sh или он не исполняемый"
        exit 1
    fi
}

# Ждём пользователя cloud-init теми же 40 попытками по 3 секунды, что
# и остальные расширения: гонка с cloud-init реальна, а «пользователя нет»
# на второй секунде первой загрузки — это не отказ, а «ещё не создан».
resolve_user(){
    local user attempts=0 max_attempts=40
    while true; do
        if user="$("$SCRIPT_DIR/get_cloud_user.sh" 2>/dev/null || true)" && [[ -n "$user" ]]; then
            if id "$user" >/dev/null 2>&1; then
                echo "$user"
                return 0
            fi
        fi
        attempts=$(( attempts + 1 ))
        if (( attempts >= max_attempts )); then
            log_error "не дождался пользователя cloud-init за ${max_attempts} попыток"
            exit 1
        fi
        log_info "жду пользователя cloud-init (попытка ${attempts}/${max_attempts})"
        sleep 3
    done
}

add_to_group(){
    local user="$1"
    if ! getent group jtop >/dev/null 2>&1; then
        # Группу заводит сборка; если её нет — значит установка прошла не так,
        # как задумано, и демон всё равно не стартует («Group jtop does not
        # exist!»). Заводим и говорим об этом вслух.
        log_warn "группы jtop нет — завожу её здесь, хотя это работа install.sh"
        groupadd jtop
    fi
    if id -nG "$user" | tr ' ' '\n' | grep -qx jtop; then
        log_info "'$user' уже в группе jtop"
        return 0
    fi
    usermod -aG jtop "$user"
    log_info "'$user' внесён в группу jtop"
    # Членство в группе применяется при входе в сессию. Если автологин уже
    # случился (расширение gnome его настраивает), текущая сессия группу не
    # увидит — и `jtop` в ней откажет. Сказать об этом надо здесь, иначе
    # оператор прочтёт «Please logout or reboot» и решит, что расширение
    # не отработало.
    log_warn "членство применится при следующем входе; в уже открытой сессии jtop"
    log_warn "ещё будет отвечать отказом доступа — помогает logout или reboot"
}

ensure_service(){
    if systemctl is-active --quiet jtop.service; then
        log_info "jtop.service уже работает"
        return 0
    fi
    # Без `|| true`: отказ обязан быть виден. Неработающий демон означает,
    # что команда jtop на плате не работает вовсе, а расширение при этом
    # отрапортовало бы успехом.
    if systemctl start jtop.service; then
        log_info "jtop.service запущен"
    else
        log_error "jtop.service не запустился — смотрите journalctl -u jtop.service"
        exit 1
    fi
}

main(){
    check_prereqs
    local user
    user="$(resolve_user)"
    log_info "пользователь cloud-init: $user"
    add_to_group "$user"
    ensure_service
    log_info "готово"
}

main "$@"
