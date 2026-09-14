#!/usr/bin/env bash
# Selkies: X-сессия, которая на мониторе, — в браузере, через один
# WebSocket-порт. Ставится на сборке, включается на первой загрузке.
#
# ПОЧЕМУ AppImage. Пакеты Selkies 2.0 собраны под Ubuntu 26.04 и Debian
# trixie, а AppImage несёт своё окружение (conda, pixelflux, pcmflux) и на
# Ubuntu 22.04 запустился без правок (AGX Orin, 2026-09-14). Версия и sha256
# закреплены на архитектуру: релиз-кандидат, и «последний» менялся бы под
# ногами.
#
# ПОЧЕМУ РАСПАКОВАН. Смонтированный AppImage требует FUSE в госте и
# распаковывает squashfs на каждом старте; распакованный (6 с на сборке,
# 1.7 ГБ) не зависит ни от чего. Запускается бинарь мимо `AppRun` — почему,
# в шапке run-selkies.sh.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} selkies: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} selkies: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} selkies: $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SELKIES_VERSION="2.0.0rc0"
declare -A APPIMAGE_SHA256=(
    [x86_64]="ed875d63fb93c17b79f2044104be1304413d4ee7f6c379e8080822e8f868071a"
    [aarch64]="a1abb4658c3117188afa6881eaab93a24c172a5db5c0cbb18889c43c60e59043"
)
PREFIX="/opt/selkies/${SELKIES_VERSION}"
CONF=/etc/bisquite/selkies/config

case "$(dpkg --print-architecture)" in
    amd64) APPARCH=x86_64 ;;
    arm64) APPARCH=aarch64 ;;
    *) log_error "архитектура $(dpkg --print-architecture) — AppImage Selkies только для amd64 и arm64"; exit 1 ;;
esac

for f in selkies@.service configure-selkies.service run-selkies.sh configure.sh get_cloud_user.sh; do
    if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
        log_error "рядом нет $f — Selkies на устройстве не запустится"
        exit 1
    fi
done

# --- Умолчания для робота -----------------------------------------------------
#
# Имена — родные переменные Selkies (`selkies --help`, «Env:»): юнит читает
# файл как EnvironmentFile, и Selkies берёт их сам. Любую `SELKIES_*`,
# переданную параметром расширения, дописываем поверх умолчаний — отдельного
# словаря bisquite поверх Selkies нет.
#
# Каждое умолчание — ответ на конкретное свойство робота:
#   ADDR 127.0.0.1         снаружи — через Teleport или ssh-туннель
#   ENABLE_BASIC_AUTH      аутентификацию делает Teleport; на петле пароль ничего
#   false                  не добавляет (открыть наружу без него обёртка не даст)
#   ENABLE_RESIZE false    иначе Selkies подгоняет разрешение МОНИТОРА под окно браузера
#   GAMEPAD/WEBCAM/        роботу не нужны; геймпады к тому же заводят сокеты в /tmp
#   MICROPHONE false
#   COMMAND_ENABLED false  API выполнения команд
#   ENABLE_SHARING false   ссылки для просмотра другими
#
# BISQUITE_SELKIES_ALLOW_NO_AUTH — не переменная Selkies, а ручка обёртки:
# true снимает отказ стартовать на адресе не петли без basic auth. Решение
# «рабочий стол любому в сети» принимается явно, в VMFILE или манифесте.
#   FILE_TRANSFERS         передача файлов в обе стороны; каталог — ~/Downloads
#   upload,download        пользователя, его ставит обёртка
declare -A DEFAULTS=(
    [SELKIES_ADDR]="127.0.0.1"
    [SELKIES_PORT]="8080"
    [SELKIES_MODE]="websockets"
    [SELKIES_ENABLE_DUAL_MODE]="false"
    [SELKIES_ENABLE_HTTPS]="false"
    [SELKIES_ENABLE_BASIC_AUTH]="false"
    [SELKIES_ENABLE_RESIZE]="false"
    [SELKIES_ENCODER]="h264enc"
    [SELKIES_FRAMERATE]="30,8-60"
    [SELKIES_AUDIO_ENABLED]="true"
    [SELKIES_MICROPHONE_ENABLED]="false"
    [SELKIES_GAMEPAD_ENABLED]="false"
    [SELKIES_WEBCAM_ENABLED]="false"
    [SELKIES_ENABLE_CLIPBOARD]="true"
    [SELKIES_FILE_TRANSFERS]="upload,download"
    [SELKIES_COMMAND_ENABLED]="false"
    [SELKIES_ENABLE_SHARING]="false"
    [SELKIES_SECOND_SCREEN]="false"
    [SELKIES_UI_SIDEBAR_SHOW_GAMEPADS]="false"
    [SELKIES_UI_SIDEBAR_SHOW_WEBCAM]="false"
    [SELKIES_UI_SIDEBAR_SHOW_SHARING]="false"
    [SELKIES_UI_SIDEBAR_SHOW_APPS]="false"
    [BISQUITE_SELKIES_ALLOW_NO_AUTH]="false"
)

# --- AppImage -----------------------------------------------------------------
URL="https://github.com/selkies-project/selkies/releases/download/v${SELKIES_VERSION}/selkies-${SELKIES_VERSION}-${APPARCH}.AppImage"
WORK="$(mktemp -d /var/tmp/selkies.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

if [[ -x "$PREFIX/usr/conda/bin/selkies" ]]; then
    log_info "Selkies $SELKIES_VERSION уже распакован в $PREFIX"
else
    command -v curl >/dev/null 2>&1 || { apt-get update -q && apt-get install -y -q curl ca-certificates; } || exit 1
    log_info "скачиваю $URL"
    curl -fL --retry 5 --retry-delay 5 -o "$WORK/selkies.AppImage" "$URL" || { log_error "AppImage не скачался"; exit 1; }
    if ! echo "${APPIMAGE_SHA256[$APPARCH]}  $WORK/selkies.AppImage" | sha256sum -c --quiet -; then
        log_error "sha256 AppImage не совпал с закреплённым для $APPARCH"
        exit 1
    fi
    chmod +x "$WORK/selkies.AppImage"
    # --appimage-extract работает без FUSE: рантайм AppImage статический и
    # распаковывает squashfs сам. В текущий каталог — отсюда `cd`.
    ( cd "$WORK" && ./selkies.AppImage --appimage-extract >/dev/null ) || { log_error "AppImage не распаковался"; exit 1; }
    [[ -x "$WORK/squashfs-root/usr/conda/bin/selkies" ]] || { log_error "в AppImage нет usr/conda/bin/selkies — раскладка сменилась"; exit 1; }
    rm -rf "$PREFIX"; install -d "$(dirname "$PREFIX")"
    mv "$WORK/squashfs-root" "$PREFIX"
    chmod -R a+rX "$PREFIX"
    log_info "распакован в $PREFIX ($(du -sh "$PREFIX" | cut -f1))"
fi
ln -sfn "$PREFIX" /opt/selkies/current
"$PREFIX/usr/conda/bin/selkies" --help >/dev/null 2>&1 || { log_error "selkies --help не запускается в госте"; exit 1; }

# Обёртке нужен xdpyinfo — проверить кандидата в X authority, как у x11vnc.
apt-get install -y -q x11-utils xauth >/dev/null || { log_error "x11-utils не поставился"; exit 1; }

# --- /etc/bisquite/selkies/config ---------------------------------------------
declare -A VALUES=()
for k in "${!DEFAULTS[@]}"; do VALUES[$k]="${DEFAULTS[$k]}"; done
while IFS='=' read -r k v; do
    [[ "$k" =~ ^(SELKIES|BISQUITE_SELKIES)_[A-Z0-9_]+$ ]] || continue
    VALUES[$k]="$v"
done < <(env)
# The file moved from /etc/default/bisquite-selkies in 2.0.0. The old path is
# not read as a fallback; remove it so the image has one source of truth.
if [[ -e /etc/default/bisquite-selkies ]]; then
    log_info "удаляю /etc/default/bisquite-selkies: параметры теперь в $CONF"
    rm -f /etc/default/bisquite-selkies
fi
install -d -m 0755 "$(dirname "$CONF")"
# 0600 before the first byte: SELKIES_BASIC_AUTH_PASSWORD may land here.
install -m 0600 /dev/null "$CONF"
{
    echo "# Положено расширением selkies. Имена — переменные Selkies (selkies --help)."
    echo "# После правки: sudo systemctl restart 'selkies@*'"
    for k in $(printf '%s\n' "${!VALUES[@]}" | sort); do
        v="${VALUES[$k]}"
        if [[ "$v" == *$'\n'* ]]; then log_error "$k: перевод строки в значении"; exit 1; fi
        printf '%s=%s\n' "$k" "$v"
    done
} > "$CONF"
# Читает файл systemd (EnvironmentFile), а не пользователь.
chmod 0600 "$CONF"

addr="${VALUES[SELKIES_ADDR]}"
auth="${VALUES[SELKIES_ENABLE_BASIC_AUTH]}"
log_info "адрес ${addr}:${VALUES[SELKIES_PORT]}, basic auth ${auth}, файлы ${VALUES[SELKIES_FILE_TRANSFERS]}, буфер ${VALUES[SELKIES_ENABLE_CLIPBOARD]}"
case "$addr" in
    127.0.0.1|::1|localhost|"127.0.0.1,::1") ;;
    *)
        if [[ "$auth" == true ]]; then
            :
        elif [[ "${VALUES[BISQUITE_SELKIES_ALLOW_NO_AUTH]}" == true ]]; then
            log_warn "SELKIES_ADDR=$addr БЕЗ АУТЕНТИФИКАЦИИ (BISQUITE_SELKIES_ALLOW_NO_AUTH=true):"
            log_warn "  рабочий стол, буфер обмена и файлы — любому, кто достаёт до робота по сети"
        else
            log_warn "SELKIES_ADDR=$addr без SELKIES_ENABLE_BASIC_AUTH=true — обёртка откажется стартовать"
            log_warn "  (открыть без пароля осознанно: BISQUITE_SELKIES_ALLOW_NO_AUTH=true)"
        fi
        ;;
esac

# --- Юниты ----------------------------------------------------------------------
install -m 0644 "$SCRIPT_DIR/selkies@.service" /etc/systemd/system/selkies@.service
install -m 0644 "$SCRIPT_DIR/configure-selkies.service" /etc/systemd/system/configure-selkies.service
chmod +x "$SCRIPT_DIR/run-selkies.sh" "$SCRIPT_DIR/configure.sh"
# Включение ссылкой: внутри virt-customize systemd не работает.
install -d /etc/systemd/system/graphical.target.wants
ln -sf /etc/systemd/system/configure-selkies.service \
    /etc/systemd/system/graphical.target.wants/configure-selkies.service

log_info "Selkies $SELKIES_VERSION установлен ($APPARCH)"
