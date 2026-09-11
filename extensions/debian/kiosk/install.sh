#!/usr/bin/env bash
# Install Chromium for kiosk mode

set -euo pipefail

# Colors for output
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m' # No Color

# Logging functions (always write to stderr to avoid polluting stdout)
log_info() {
    >&2 echo -e "${GREEN}[INFO]${NC} $*"
}

log_warn() {
    >&2 echo -e "${YELLOW}[WARN]${NC} $*"
}

log_error() {
    >&2 echo -e "${RED}[ERROR]${NC} $*"
}

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log_info "Starting kiosk extension installation..."

# Update package lists
log_info "Updating package lists..."

apt-get update || exit 1

# Install common dependencies
#
# x11-utils и xauth объявлены ЯВНО: обёртке нужен `xdpyinfo`, чтобы проверить
# кандидата в X authority, а лежит он в x11-utils — не в x11-xserver-utils,
# который даёт xset/xrandr/xhost. Прежний юнит звал xdpyinfo, не поставив его:
# работало лишь тогда, когда пакет приезжал прицепом за `xorg` от расширения
# десктопа, то есть зависело от порядка слоёв в VMFILE. Та же правка и по той
# же причине уже сделана у расширения x11vnc.
log_info "Installing common dependencies..."
apt-get install -y curl wget x11-xserver-utils x11-utils xauth dbus-x11 || exit 1

# Install Chromium
log_info "Installing Chromium browser..."
apt-get install -y chromium chromium-driver || exit 1
log_info "Chromium installed successfully"

# --- Файлы, без которых первой загрузки не будет ------------------------------
#
# Отсутствие любого из них — ОТКАЗ СБОРКИ, а не предупреждение. Раньше юниты
# «не нашлись» тихо (log_warn плюс `|| true`), сборка оставалась зелёной,
# а юнита в образе не было — и узнавал об этом тот, кто включил плату без
# монитора. Из двух отказов дешевле тот, который читает собиравший: он чинит
# за минуту на своей машине. То же направление у всей остальной инфраструктуры
# bisquite — fail-closed у детектора устройств, preflight утилит до `dd`.
# Образец — vino-vnc/install.sh. Отказ на `run-kiosk.sh` здесь был и раньше,
# то есть внутри одного файла стояли оба подхода: обёртка важнее юнита,
# который её запускает, — такого порядка быть не может.
#
# Ищем рядом с собой ($SCRIPT_DIR), а не по зашитому /opt/vmsetup/kiosk/:
# проверка обязана отвечать на вопрос «файл приехал рядом со мной?», а не
# «раскладка EXTENSION всё ещё такая?». Скрипт запускается из того самого
# каталога, куда его скопировали, поэтому $SCRIPT_DIR верен при любой
# раскладке, и её смена не уронит все сборки разом.
#
# config.yaml и get_cloud_user.sh в списке потому, что без них `configure.sh`
# откажет на первой загрузке (его check_prereqs), — то есть их отсутствие
# стоит ровно столько же, сколько отсутствие юнита.
for f in configure-kiosk.service kiosk-chromium@.service run-kiosk.sh \
         configure.sh config.yaml get_cloud_user.sh; do
    if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
        log_error "рядом нет $f — настройка киоска на первой загрузке не состоится,"
        log_error "а без неё браузер не развернётся ни при какой конфигурации"
        exit 1
    fi
done

# Без `|| true`: файл нашёлся, а копирование провалилось — исход ровно тот же,
# что и у ненайденного файла, значит и отказ тот же.
install -m 0644 "$SCRIPT_DIR/configure-kiosk.service" \
    /etc/systemd/system/configure-kiosk.service
install -m 0644 "$SCRIPT_DIR/kiosk-chromium@.service" \
    /etc/systemd/system/kiosk-chromium@.service

# Обёртка, которая ищет X authority в рантайме и запускает chromium. Юнит
# зовёт её через `/bin/bash`, то есть бит исполнения ему не нужен; он нужен
# человеку, который запустит обёртку руками при диагностике.
chmod +x "$SCRIPT_DIR/run-kiosk.sh"

# Reload systemd and enable configuration service
systemctl daemon-reload || true
systemctl enable configure-kiosk.service || true

log_info "Installation completed successfully!"
log_info "Kiosk extension is installed and ready to be configured"
log_info "Configuration will be handled by the configure-kiosk service"
