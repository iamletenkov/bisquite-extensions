#!/usr/bin/env bash
# Configure x11vnc from cloud-init user at boot (idempotent)

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info(){ echo -e "${GREEN}[INFO]${NC} $*" >&2; }
log_warn(){ echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error(){ echo -e "${RED}[ERROR]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Проверки `command -v yq` здесь НЕТ, и это решение, а не пропуск.
#
# Этот скрипт `yq` не вызывает ни разу. Нужен он только внутри
# get_cloud_user.sh, и там его отсутствие — не отказ, а переход к
# fallback_user(): «первая учётка с uid 1000..65533 и домашним каталогом».
# То есть расширение отказывалось работать из-за инструмента, который его
# единственный потребитель объявил необязательным, и отказ этот приезжал
# не на сборку, а на первую загрузку устройства.
#
# Подсказка при этом не потерялась, а переехала туда, где есть факты:
# fallback_user() печатает в stderr, что пошла запасным путём и какую
# учётку выбрала. Предупреждение «yq не найден» в скрипте, который yq не
# зовёт, было бы ложным диагнозом — оно указывает на инструмент, к отказу
# отношения не имеющий.
check_prereqs(){
  if [[ ! -x "$SCRIPT_DIR/get_cloud_user.sh" ]]; then
    log_error "get_cloud_user.sh not found or not executable at $SCRIPT_DIR/get_cloud_user.sh"
    exit 1
  fi
}

resolve_user(){
  local user
  local attempts=0
  local max_attempts=40

  # Wait up to 120s for cloud user to appear to avoid racing cloud-init
  while true; do
    if user="$("$SCRIPT_DIR/get_cloud_user.sh" 2>/dev/null || true)" && [[ -n "$user" ]]; then
      if id "$user" >/dev/null 2>&1; then
        log_info "Found user from cloud-init: $user"
        echo "$user"
        return 0
      fi
    fi

    attempts=$((attempts+1))
    if (( attempts >= max_attempts )); then
      log_error "Timeout waiting for cloud-init user to be created"
      exit 1
    fi

    log_info "Waiting for cloud-init user (attempt $attempts/$max_attempts)..."
    sleep 3
  done
}

# Пароль VNC отдаём в собственность тому, кто его читает.
#
# Сервер работает юнитом `x11vnc@<пользователь>` с `User=%i`, то есть
# `-rfbauth` открывает НЕ root. На сборке этой учётки ещё нет (её создаёт
# cloud-init), поэтому install.sh может поставить только права (0600), а
# владельца знает первая загрузка — то есть это место.
#
# Пара обязательна: 0600 root:root означало бы, что обёртка не прочтёт файл
# и поднимет сервер с `-nopw`. Права, закрывающие пароль, открыли бы тогда
# рабочий стол — ровно противоположное задуманному.
hand_over_passfile(){
  local cloud_user="$1"
  local env_file=/etc/default/bisquite-x11vnc
  local passfile

  [[ -f "$env_file" ]] || return 0
  passfile="$(sed -n 's/^X11VNC_PASSFILE=//p' "$env_file" | tail -n 1)"
  [[ -n "$passfile" && -f "$passfile" ]] || return 0

  if chown "$cloud_user" "$passfile" && chmod 0600 "$passfile"; then
    log_info "файл пароля $passfile передан '$cloud_user' (0600)"
  else
    # Громко: иначе сервер молча поднимется с `-nopw`, а образ будет
    # выглядеть защищённым паролем.
    log_error "не удалось передать $passfile пользователю '$cloud_user'"
    exit 1
  fi
}

# Гасим прежние экземпляры шаблона при смене пользователя.
#
# `systemctl enable x11vnc@<user>` кладёт симлинк в graphical.target.wants/
# (шаблон объявлен WantedBy=graphical.target), и `disable` прежнего не делал
# никто. После смены пользователя там оставались ОБА экземпляра, и на
# следующей загрузке поднимались два сервера на один дисплей: второй не
# займёт порт 5900 и уйдёт в цикл рестарта — шум в журнале и работа впустую.
#
# Ищем именно в graphical.target.wants/, потому что это единственный
# надёжный список ВКЛЮЧЁННЫХ экземпляров: сам шаблон ничего не помнит,
# а `systemctl list-units 'x11vnc@*'` показывает запущенные.
#
# Уже прошитое устройство эта правка не лечит: симлинк лежит в его образе,
# и снять его можно только перезаписью носителя или `systemctl disable`
# руками.
disable_stale_instances(){
  local keep="$1"
  local wants_dir=/etc/systemd/system/graphical.target.wants
  local unit name

  [[ -d "$wants_dir" ]] || return 0

  shopt -s nullglob
  for unit in "$wants_dir"/'x11vnc@'*.service; do
    name="$(basename "$unit")"
    [[ "$name" == "x11vnc@${keep}.service" ]] && continue
    log_info "гашу прежний экземпляр $name"
    systemctl disable --now "$name" || log_warn "не удалось погасить $name"
  done
  shopt -u nullglob
}

configure_x11vnc_service(){
  local cloud_user="$1"

  hand_over_passfile "$cloud_user"
  disable_stale_instances "$cloud_user"

  # Порт, дисплей, пароль и адрес прослушивания сюда больше не читаются:
  # раньше их доставали из config.yaml и НИГДЕ не использовали — юнит
  # хардкодил свои значения. Теперь они приходят из VMFILE переменными
  # окружения, install.sh кладёт их в /etc/default/bisquite-x11vnc,
  # а юнит читает оттуда.
  systemctl enable "x11vnc@${cloud_user}.service" || true
  # Без `|| true`: отказ обязан быть виден. Раньше обе команды глушились,
  # и немой цикл рестарта из-за ненайденного authority выглядел как успех.
  if systemctl restart "x11vnc@${cloud_user}.service"; then
    log_info "x11vnc запущен для '$cloud_user'"
  else
    log_error "x11vnc не запустился для '$cloud_user' — смотрите journalctl -u x11vnc@${cloud_user}"
    exit 1
  fi
}

main(){
  check_prereqs
  local user
  user=$(resolve_user)

  log_info "Configuring x11vnc for user '$user'"
  configure_x11vnc_service "$user"
  log_info "x11vnc configuration completed for '$user'"
}

main "$@"
