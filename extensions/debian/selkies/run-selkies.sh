#!/usr/bin/env bash
# Запуск Selkies на X-сессии пользователя (та же, что на мониторе).
#
# МИМО `AppRun`. Штатный вход AppImage делает две вещи, которые роботу вредят:
#   * нет сокета дисплея — поднимает Xvfb 8192×4096 и стримит ПУСТОЙ
#     виртуальный экран. Робот без сессии показал бы чёрный стол вместо
#     ошибки в журнале;
#   * нет PulseAudio пользователя — поднимает свой звуковой сервер в чужой
#     сессии.
# Поэтому переменные из `AppRun` ставятся здесь, а запускается сам бинарь.
#
# ЖДЁМ СЕССИЮ, А НЕ ПАДАЕМ. Сессию открывает менеджер входа, и появляется она
# после graphical.target; при выходе пользователя и повторном входе X
# authority меняется. Юнит перезапускает службу всегда, а обёртка до появления
# сессии ждёт молча (одна строка в журнал), вместо цикла падений каждые 5 с.
# Пропажу сессии во время работы ловит сторож в конце файла.
set -uo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} selkies: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} selkies: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} selkies: $*"; }

USERNAME="${1:?usage: run-selkies.sh <user>}"
UID_OF_USER="$(id -u "$USERNAME")" || { log_error "нет пользователя $USERNAME"; exit 1; }
HOME_OF_USER="$(getent passwd "$USERNAME" | cut -d: -f6)"
PREFIX=/opt/selkies/current
DISPLAY_NUM="${SELKIES_DISPLAY:-:0}"

[[ -x "$PREFIX/usr/conda/bin/selkies" ]] || { log_error "нет $PREFIX/usr/conda/bin/selkies — расширение не установлено"; exit 1; }

# --- Наружу — только с паролем ---------------------------------------------------
#
# Selkies без basic auth на адресе не петли — это рабочий стол, буфер обмена
# и передача файлов любому в сети. На петле защиту даёт тот, кто проксирует
# (Teleport, ssh). Отказ, а не предупреждение: предупреждение в журнале
# робота не прочитает никто. Снимает отказ только явная ручка
# BISQUITE_SELKIES_ALLOW_NO_AUTH=true — решение, записанное в VMFILE или
# манифесте, а не молчаливое умолчание.
addr="${SELKIES_ADDR:-127.0.0.1}"
loopback=1
IFS=',' read -r -a addrs <<< "$addr"
for a in "${addrs[@]}"; do
    case "${a// /}" in 127.*|::1|localhost) ;; *) loopback=0 ;; esac
done
if (( ! loopback )) && [[ "${SELKIES_ENABLE_BASIC_AUTH:-false}" != true ]]; then
  if [[ "${BISQUITE_SELKIES_ALLOW_NO_AUTH:-false}" == true ]]; then
    log_warn "SELKIES_ADDR=$addr без аутентификации (BISQUITE_SELKIES_ALLOW_NO_AUTH=true) — стол открыт всей сети"
  else
    log_error "SELKIES_ADDR=$addr не петля, а SELKIES_ENABLE_BASIC_AUTH не true — не запускаюсь"
    log_error "задайте SELKIES_ENABLE_BASIC_AUTH=true и SELKIES_BASIC_AUTH_PASSWORD в /etc/bisquite/selkies/config"
    log_error "или откройте без пароля осознанно: BISQUITE_SELKIES_ALLOW_NO_AUTH=true"
    exit 1
  fi
fi

session_type(){
    local sid
    sid="$(loginctl list-sessions --no-legend 2>/dev/null | awk -v u="$USERNAME" '$3 == u && $4 == "seat0" {print $1; exit}')"
    [[ -n "$sid" ]] || return 1
    loginctl show-session "$sid" -p Type --value 2>/dev/null
}

# Кандидаты в X authority — те же и в том же порядке, что у x11vnc
# (разбор с замерами — x11vnc/run-x11vnc.sh).
find_authority(){
    local c xorg_pid xorg_auth
    local -a candidates=(
        "$HOME_OF_USER/.Xauthority"
        "/run/user/${UID_OF_USER}/gdm/Xauthority"
        "/run/lightdm/${USERNAME}/xauthority"
    )
    xorg_pid="$(pgrep -x Xorg | head -1 || true)"
    if [[ -n "$xorg_pid" && -r "/proc/$xorg_pid/cmdline" ]]; then
        xorg_auth="$(tr '\0' '\n' < "/proc/$xorg_pid/cmdline" | awk '/^-auth$/{getline; print; exit}')"
        [[ -n "$xorg_auth" ]] && candidates+=("$xorg_auth")
    fi
    for c in "${candidates[@]}"; do
        [[ -r "$c" ]] || continue
        if env XAUTHORITY="$c" xdpyinfo -display "$DISPLAY_NUM" >/dev/null 2>&1; then
            echo "$c"; return 0
        fi
    done
    return 1
}

AUTH=""; waited=0
until AUTH="$(find_authority)"; do
    if (( waited == 0 )); then
        log_info "жду X-сессию '$USERNAME' на $DISPLAY_NUM (без DESKTOP_AUTOLOGIN=1 она появится после входа человека)"
    fi
    if [[ "$(session_type)" == wayland ]]; then
        log_error "сессия '$USERNAME' на Wayland — Selkies подключается только к X.Org"
        exit 1
    fi
    sleep 5; waited=$((waited + 5))
done
log_info "дисплей $DISPLAY_NUM, authority $AUTH"

export DISPLAY="$DISPLAY_NUM" XAUTHORITY="$AUTH"
export HOME="$HOME_OF_USER" USER="$USERNAME"
export XDG_RUNTIME_DIR="/run/user/${UID_OF_USER}"
export PULSE_RUNTIME_PATH="$XDG_RUNTIME_DIR/pulse"
export PULSE_SERVER="unix:$PULSE_RUNTIME_PATH/native"
export PATH="$PREFIX/usr/conda/bin:$PATH"
export SELKIES_INTERPOSER="$PREFIX/usr/lib/selkies_joystick_interposer.so"
export SELKIES_WEBCAM_INTERPOSER="$PREFIX/usr/lib/selkies_v4l2_interposer.so"

# Звук — только PulseAudio пользователя; свой не поднимаем. Сокет появляется
# вместе с user@<uid>.service, а X-сессия автологина бывает готова раньше —
# ждём до 30 с, а не выключаем звук на первой проверке. Захват — monitor
# источника по умолчанию: имя Selkies «output.monitor» есть только в его
# AppRun, и pcmflux откатывается на monitor sink'а по умолчанию
# (замер на AGX Orin: alsa_output.platform-sound.analog-stereo.monitor).
if [[ "${SELKIES_AUDIO_ENABLED:-true}" == true ]]; then
    for _ in $(seq 1 30); do
        [[ -S "$PULSE_RUNTIME_PATH/native" ]] && break
        sleep 1
    done
    if [[ ! -S "$PULSE_RUNTIME_PATH/native" ]]; then
        log_warn "нет $PULSE_RUNTIME_PATH/native за 30 с — звук выключен"
        export SELKIES_AUDIO_ENABLED=false
    fi
fi

# HTTPS: браузер даёт буфер обмена, микрофон, камеру и геймпады только
# защищённому контексту, а http://<адрес робота> им не является. Selkies умеет
# выпустить самоподписанную пару сам, но сначала берёт путь по умолчанию —
# /etc/ssl/certs/ssl-cert-snakeoil.pem. На Ubuntu сертификат там есть, а ключ
# пользователю не читается, и Selkies падает с «PEM lib» вместо генерации
# (замер на AGX Orin 2026-09-14). Поэтому путь по умолчанию переносится
# в состояние пользователя: файла там нет — Selkies создаёт пару на
# устройстве и переиспользует её между перезапусками. Ключ в образ не попадает.
if [[ "${SELKIES_ENABLE_HTTPS:-false}" == true && -z "${SELKIES_HTTPS_CERT:-}" ]]; then
    tls_dir="${XDG_STATE_HOME:-$HOME_OF_USER/.local/state}/selkies"
    mkdir -p "$tls_dir" && chmod 0700 "$tls_dir"
    export SELKIES_HTTPS_CERT="$tls_dir/selkies.pem" SELKIES_HTTPS_KEY="$tls_dir/selkies.key"
fi
scheme=http
[[ "${SELKIES_ENABLE_HTTPS:-false}" == true ]] && scheme=https

# Каталог передачи файлов — в домашнем каталоге того, кто на экране.
if [[ -z "${SELKIES_FILE_MANAGER_PATH:-}" ]]; then
    export SELKIES_FILE_MANAGER_PATH="$HOME_OF_USER/Downloads"
fi
mkdir -p "$SELKIES_FILE_MANAGER_PATH" 2>/dev/null || true

log_info "${scheme}://${addr}:${SELKIES_PORT:-8080}/ файлы=${SELKIES_FILE_TRANSFERS:-} в $SELKIES_FILE_MANAGER_PATH, буфер=${SELKIES_ENABLE_CLIPBOARD:-}"

# СТОРОЖ СЕССИИ. Selkies не умирает вместе с X: замер на AGX Orin 2026-09-14 —
# после `loginctl terminate-session` процесс остался жив (тот же pid), в журнале
# только «X11 clipboard monitor thread exited; respawning», а при новом входе
# к новому X он не подключился бы. Поэтому Selkies — дочерний процесс, а
# обёртка раз в 10 с проверяет дисплей и при двух неудачах подряд гасит его
# и выходит с ошибкой: юнит перезапустит, обёртка дождётся новой сессии.
"$PREFIX/usr/conda/bin/selkies" &
child=$!
trap 'kill -TERM "$child" 2>/dev/null; wait "$child"; exit 0' TERM INT
misses=0
while kill -0 "$child" 2>/dev/null; do
    sleep 10 & wait $!
    if [[ -r "$AUTH" ]] && xdpyinfo -display "$DISPLAY_NUM" >/dev/null 2>&1; then
        misses=0
    else
        misses=$((misses + 1))
        if (( misses >= 2 )); then
            log_warn "X-сессия '$USERNAME' на $DISPLAY_NUM пропала — останавливаю Selkies, дождусь новой"
            kill -TERM "$child" 2>/dev/null
            for _ in 1 2 3 4 5 6 7 8 9 10; do kill -0 "$child" 2>/dev/null || break; sleep 1; done
            kill -KILL "$child" 2>/dev/null
            exit 1
        fi
    fi
done
wait "$child"
rc=$?
log_warn "Selkies завершился с кодом $rc"
exit $(( rc == 0 ? 1 : rc ))
