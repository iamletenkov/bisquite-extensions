#!/usr/bin/env bash
# Install chromium-kiosk and prepare auto-configuration service

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"


log_info "Installing chromium-kiosk and dependencies..."

apt-get update || exit 1
apt-get install -y wget gnupg locales || exit 1

# Configure locale
log_info "Configuring locale..."
sed -i 's/# ru_RU.UTF-8 UTF-8/ru_RU.UTF-8 UTF-8/' /etc/locale.gen
locale-gen ru_RU.UTF-8
update-locale LANG=ru_RU.UTF-8 LC_MESSAGES=POSIX

# Add Salamek repository and install chromium-kiosk
log_info "Adding Salamek repository..."
wget -O- https://repository.salamek.cz/deb/salamek.gpg | tee /usr/share/keyrings/salamek-archive-keyring.gpg > /dev/null
echo "deb [signed-by=/usr/share/keyrings/salamek-archive-keyring.gpg] https://repository.salamek.cz/deb/pub all main" | tee /etc/apt/sources.list.d/salamek.cz.list

log_info "Installing chromium-kiosk..."
apt-get update || exit 1
apt-get install -y chromium-kiosk || exit 1

# --- Файлы, без которых первой загрузки не будет ------------------------------
#
# Отсутствие любого из них — ОТКАЗ СБОРКИ, а не предупреждение, и здесь цена
# выше, чем у соседей: за этим юнитом стоит ЕДИНСТВЕННЫЙ производитель
# рабочего конфига. `/etc/chromium-kiosk/config.yml` создаёт только наш
# configure.sh, а запускает configure.sh только этот юнит. Нет юнита — нет
# фазы первой загрузки — нет конфига, никогда: киоск приезжает с тем, что
# положил пакет из репозитория Salamek, то есть без наших настроек вовсе.
# Предупреждение об этом читает тот, кто смотрит в журнал платы, а не тот,
# кто собирал образ. Образец громкого отказа — vino-vnc/install.sh.
#
# Ищем рядом с собой ($SCRIPT_DIR), а не по зашитому
# /opt/vmsetup/chromium-kiosk/: проверка обязана отвечать на вопрос «файл
# приехал рядом со мной?», а не «раскладка EXTENSION всё ещё такая?». Скрипт
# запускается из того самого каталога, куда его скопировали, поэтому
# $SCRIPT_DIR верен при любой раскладке, и её смена не уронит все сборки разом.
#
# config.yaml в списке потому, что без него configure.sh откажет на первой
# загрузке (его check_prereqs) — то есть его отсутствие стоит столько же,
# сколько отсутствие юнита.
for f in configure-chromium-kiosk.service configure.sh config.yaml; do
  if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
    log_error "рядом нет $f — настройка chromium-kiosk на первой загрузке"
    log_error "не состоится, и киоск останется с конфигом пакета Salamek"
    exit 1
  fi
done

# Без `|| true`: файл нашёлся, а копирование провалилось — исход ровно тот же,
# что и у ненайденного файла, значит и отказ тот же.
install -m 0644 "$SCRIPT_DIR/configure-chromium-kiosk.service" \
  /etc/systemd/system/configure-chromium-kiosk.service

# Enable configuration service
systemctl daemon-reload || true
systemctl enable configure-chromium-kiosk.service || true

log_info "chromium-kiosk extension installation completed"
