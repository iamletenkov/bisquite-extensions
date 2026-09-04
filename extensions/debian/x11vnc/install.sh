#!/usr/bin/env bash
# Install x11vnc and prepare auto-configuration service

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} $*"; }


# Параметры приходят из VMFILE переменными окружения, потому что RUN_COMMAND
# отдаёт строку шеллу гостя целиком:
#
#   RUN_COMMAND X11VNC_PORT=5901 X11VNC_LISTEN=all /opt/vmsetup/x11vnc/install.sh
#
# Раньше на их месте лежал config.yaml, чьи ключи PORT/PASSWORD/DISPLAY
# читались и НИГДЕ не использовались — юнит хардкодил свои значения, а README
# обещал парольный доступ, которого не было. Файл удалён вместе с обещанием.
X11VNC_PORT="${X11VNC_PORT:-5900}"
X11VNC_DISPLAY="${X11VNC_DISPLAY:-:0}"
X11VNC_PASSWORD="${X11VNC_PASSWORD:-}"
X11VNC_LISTEN="${X11VNC_LISTEN:-localhost}"

log_info "Installing x11vnc and dependencies..."
# yq: из репозитория, а при его отсутствии — статическим бинарём.
#
# ЗАЧЕМ. Пакета `yq` НЕТ в Ubuntu 20.04 focal — он появился в дистрибутивах
# позже. Замер 2026-09-04 на Jetson Nano: `apt-cache policy yq` пуст,
# и строка `apt-get install -y … yq` падала ЦЕЛИКОМ, унося с собой и curl,
# и wget, и всё расширение. Сборка воркстейшна Jetson умирала на девятом
# слое за 51 секунду, а сообщение об отказе тонуло в дампе builder.log.
#
# Версия прибита намеренно: `latest` означал бы, что тот же VMFILE завтра
# соберёт другой образ. Архитектура берётся у dpkg, а не угадывается.
ensure_yq() {
    if command -v yq >/dev/null 2>&1; then
        return 0
    fi
    if apt-get install -y yq >/dev/null 2>&1 && command -v yq >/dev/null 2>&1; then
        echo "[INFO] yq установлен из репозитория" >&2
        return 0
    fi
    local arch url
    arch="$(dpkg --print-architecture)"
    case "$arch" in
        arm64|amd64) ;;
        *) echo "[ERROR] yq: неизвестная архитектура $arch" >&2; return 1 ;;
    esac
    url="https://github.com/mikefarah/yq/releases/download/v4.45.1/yq_linux_${arch}"
    echo "[INFO] yq в репозитории отсутствует, качаю статический бинарь ($arch)" >&2
    if ! wget -nv -O /usr/local/bin/yq "$url"; then
        echo "[ERROR] yq не скачался: $url" >&2
        return 1
    fi
    chmod 0755 /usr/local/bin/yq
    # Полным путём: PATH гостевой оболочки virt-customize не содержит
    # /usr/local/bin, и голое `yq --version` дало бы 127.
    if ! /usr/local/bin/yq --version >/dev/null 2>&1; then
        echo "[ERROR] yq не запускается" >&2
        return 1
    fi
    echo "[INFO] yq установлен статическим бинарём" >&2
}

apt-get update || exit 1
# xauth и x11-utils объявлены явно: обёртке нужен `xdpyinfo`, чтобы
# проверить кандидата в authority, а у пакета x11vnc он лишь в Recommends.
# Раньше они приезжали только потому, что десктопное расширение поставило
# `xorg`, — то есть работа зависела от порядка слоёв в VMFILE.
apt-get install -y \
  x11vnc \
  xauth \
  x11-utils || exit 1
ensure_yq || exit 1

# Install systemd unit template from extension directory if present
if [[ -f "/opt/vmsetup/x11vnc/x11vnc@.service" ]]; then
  install -m 0644 /opt/vmsetup/x11vnc/x11vnc@.service /etc/systemd/system/x11vnc@.service || true
else
  log_warn "x11vnc@.service not found in /opt/vmsetup/x11vnc/"
fi

# Install configure script systemd unit if present
if [[ -f "/opt/vmsetup/x11vnc/configure-x11vnc.service" ]]; then
  install -m 0644 /opt/vmsetup/x11vnc/configure-x11vnc.service /etc/systemd/system/configure-x11vnc.service || true
else
  log_warn "configure-x11vnc.service not found in /opt/vmsetup/x11vnc/"
fi

# Обёртка, которая ищет X authority в рантайме
if [[ -f "/opt/vmsetup/x11vnc/run-x11vnc.sh" ]]; then
  chmod +x /opt/vmsetup/x11vnc/run-x11vnc.sh || true
else
  log_error "run-x11vnc.sh не найден рядом — юнит не запустится"
  exit 1
fi

# Параметры в EnvironmentFile, который читает юнит.
install -d -m 0755 /etc/default
{
  echo "X11VNC_PORT=${X11VNC_PORT}"
  echo "X11VNC_DISPLAY=${X11VNC_DISPLAY}"
  echo "X11VNC_LISTEN=${X11VNC_LISTEN}"
} > /etc/default/bisquite-x11vnc

if [[ -n "$X11VNC_PASSWORD" ]]; then
  # Файл пароля VNC, а не открытый пароль в окружении: у -rfbauth формат свой.
  install -d -m 0755 /etc/x11vnc
  if x11vnc -storepasswd "$X11VNC_PASSWORD" /etc/x11vnc/passwd >/dev/null 2>&1; then
    chmod 0644 /etc/x11vnc/passwd
    echo "X11VNC_PASSFILE=/etc/x11vnc/passwd" >> /etc/default/bisquite-x11vnc
    log_info "пароль записан в /etc/x11vnc/passwd"
  else
    log_warn "не удалось записать файл пароля — сервер поднимется без него"
  fi
fi
chmod 0644 /etc/default/bisquite-x11vnc

log_info "порт ${X11VNC_PORT}, дисплей ${X11VNC_DISPLAY}, слушает ${X11VNC_LISTEN}"
if [[ "$X11VNC_LISTEN" != "localhost" && -z "$X11VNC_PASSWORD" ]]; then
  log_warn "X11VNC_LISTEN=${X11VNC_LISTEN} без пароля: рабочий стол будет открыт всей сети"
fi

# Enable configuration service
systemctl daemon-reload || true
systemctl enable configure-x11vnc.service || true

log_info "x11vnc extension installation completed"
