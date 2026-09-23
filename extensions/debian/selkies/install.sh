#!/usr/bin/env bash
# Selkies: X-сессия, которая на мониторе, — в браузере, через один
# WebSocket-порт. Ставится на сборке, включается на первой загрузке.
#
# ПОЧЕМУ AppImage. Пакеты Selkies 2.0 собраны под Ubuntu 26.04 и Debian
# trixie, а AppImage несёт своё окружение (conda, pixelflux, pcmflux) и на
# Ubuntu 22.04 запустился без правок (AGX Orin, 2026-09-14). Версия и sha256
# закреплены на архитектуру: «последний» менялся бы под ногами, а образ обязан
# собираться одинаково и через месяц.
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

SELKIES_VERSION="2.0.0"
declare -A APPIMAGE_SHA256=(
    [x86_64]="8dcdbe239dc8930545819aae510c45283cf25922250b6b7348ff2fd790c41ed8"
    [aarch64]="01ef981ff31279807705107dbe23a35e20ec68b246376c1efc5cce0ddc7a23d8"
)
PREFIX="/opt/selkies/${SELKIES_VERSION}"

case "$(dpkg --print-architecture)" in
    amd64) APPARCH=x86_64 ;;
    arm64) APPARCH=aarch64 ;;
    *) log_error "архитектура $(dpkg --print-architecture) — AppImage Selkies только для amd64 и arm64"; exit 1 ;;
esac

for f in selkies@.service configure-selkies.service run-selkies.sh configure.sh \
         knobs knobs.apply teleport-app.sh lib/get_cloud_user.sh lib/bisquite-conf; do
    if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
        log_error "рядом нет $f — Selkies на устройстве не запустится"
        exit 1
    fi
done

# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/bisquite-conf"

# --- Умолчания для робота -----------------------------------------------------
#
# Объявлены в схеме knobs рядом, вместе с типами. Каждое умолчание — ответ на
# конкретное свойство робота:
#   ADDR 127.0.0.1         снаружи — через Teleport или ssh-туннель
#   ENABLE_BASIC_AUTH      аутентификацию делает Teleport; на петле пароль ничего
#   false                  не добавляет (открыть наружу без него обёртка не даст)
#   ENABLE_RESIZE false    иначе Selkies подгоняет разрешение МОНИТОРА под окно браузера
#   GAMEPAD/WEBCAM/        роботу не нужны; геймпады к тому же заводят сокеты в /tmp
#   MICROPHONE false
#   COMMAND_ENABLED false  API выполнения команд
#   ENABLE_SHARING false   ссылки для просмотра другими
#   FILE_TRANSFERS         передача файлов в обе стороны; каталог — ~/Downloads
#   upload,download        пользователя, его ставит обёртка
#
# BISQUITE_SELKIES_ALLOW_NO_AUTH — не переменная Selkies, а ручка обёртки:
# true снимает отказ стартовать на адресе не петли без basic auth. Решение
# «рабочий стол любому в сети» принимается явно, в VMFILE или манифесте.
#
# Любая `SELKIES_*`, переданная параметром расширения, ложится поверх
# (шаблон SELKIES_* в схеме) — отдельного словаря bisquite поверх Selkies нет.

# --- AppImage -----------------------------------------------------------------
# The release tag lost its `v` prefix upstream (v2.0.0rc0 -> 2.0.0rc0, seen
# 2026-09-15: the old URL answers 404, the asset is byte-identical). Both
# spellings are tried; the pinned sha256 below is what guards the content.
ASSET="selkies-${SELKIES_VERSION}-${APPARCH}.AppImage"
RELEASES="https://github.com/selkies-project/selkies/releases/download"
URLS=("$RELEASES/${SELKIES_VERSION}/$ASSET" "$RELEASES/v${SELKIES_VERSION}/$ASSET")
WORK="$(mktemp -d /var/tmp/selkies.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

if [[ -x "$PREFIX/usr/conda/bin/selkies" ]]; then
    log_info "Selkies $SELKIES_VERSION уже распакован в $PREFIX"
else
    command -v curl >/dev/null 2>&1 || { apt-get update -q && apt-get install -y -q curl ca-certificates; } || exit 1
    fetched=0
    for URL in "${URLS[@]}"; do
        log_info "скачиваю $URL"
        # --speed-limit/--speed-time turn a stalled transfer into a retry: over
        # the board's Wi-Fi the appliance download froze at 76 of 535 MB and
        # curl waited an hour with no timeout (AGX Orin, 2026-09-15).
        if curl -fL --retry 5 --retry-delay 5 \
                --connect-timeout 30 --speed-limit 10240 --speed-time 60 \
                -o "$WORK/selkies.AppImage" "$URL"; then
            fetched=1; break
        fi
    done
    (( fetched )) || { log_error "AppImage не скачался ни по одной ссылке: ${URLS[*]}"; exit 1; }
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
# The file moved from /etc/default/bisquite-selkies in 2.0.0. The old path is
# not read as a fallback; remove it so the image has one source of truth.
if [[ -e /etc/default/bisquite-selkies ]]; then
    log_info "удаляю /etc/default/bisquite-selkies: параметры теперь в /etc/bisquite/selkies/config"
    rm -f /etc/default/bisquite-selkies
fi
# Создаётся один раз и не переписывается: повторная установка оставляет
# правки `bisquite-conf set selkies …`; параметры VMFILE — поверх, через
# проверку схемы. 0600 — в файле бывают пароли basic auth.
conf_init selkies "$SCRIPT_DIR/knobs" --env || { log_error "/etc/bisquite/selkies/config не записан"; exit 1; }
conf_load selkies

addr="$SELKIES_ADDR"
auth="$SELKIES_ENABLE_BASIC_AUTH"
log_info "адрес ${addr}:${SELKIES_PORT}, basic auth ${auth}, файлы ${SELKIES_FILE_TRANSFERS}, буфер ${SELKIES_ENABLE_CLIPBOARD}"
case "$addr" in
    127.0.0.1|::1|localhost|"127.0.0.1,::1") ;;
    *)
        if [[ "$auth" == true ]]; then
            :
        elif [[ "$BISQUITE_SELKIES_ALLOW_NO_AUTH" == true ]]; then
            log_warn "SELKIES_ADDR=$addr БЕЗ АУТЕНТИФИКАЦИИ (BISQUITE_SELKIES_ALLOW_NO_AUTH=true):"
            log_warn "  рабочий стол, буфер обмена и файлы — любому, кто достаёт до робота по сети"
        else
            log_warn "SELKIES_ADDR=$addr без SELKIES_ENABLE_BASIC_AUTH=true — обёртка откажется стартовать"
            log_warn "  (открыть без пароля осознанно: BISQUITE_SELKIES_ALLOW_NO_AUTH=true)"
        fi
        ;;
esac

# --- Объявление для teleport-agent ---------------------------------------------
#
# Как у code-server: только NAME и URI на петле, кому видно — решает env ноды.
# Скрипт общий с хуком применения и первой загрузкой: сменённый порт доезжает
# до объявления любым из трёх путей.
bash "$SCRIPT_DIR/teleport-app.sh" || { log_error "объявление для Teleport не положено"; exit 1; }

# --- Юниты ----------------------------------------------------------------------
install -m 0644 "$SCRIPT_DIR/selkies@.service" /etc/systemd/system/selkies@.service
install -m 0644 "$SCRIPT_DIR/configure-selkies.service" /etc/systemd/system/configure-selkies.service
chmod +x "$SCRIPT_DIR/run-selkies.sh" "$SCRIPT_DIR/configure.sh" "$SCRIPT_DIR/teleport-app.sh"
# Включение ссылкой: внутри virt-customize systemd не работает.
install -d /etc/systemd/system/graphical.target.wants
ln -sf /etc/systemd/system/configure-selkies.service \
    /etc/systemd/system/graphical.target.wants/configure-selkies.service

log_info "Selkies $SELKIES_VERSION установлен ($APPARCH)"
