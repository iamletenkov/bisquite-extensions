#!/usr/bin/env bash
# Install GNOME desktop stack and prepare auto-configuration service

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"


log_info "Installing GNOME and dependencies..."

apt-get update || exit 1
apt-get install -y \
  task-gnome-desktop \
  gdm3 gnome-shell gnome-session \
  xorg xinput dconf-cli \
  usbutils dbus-x11 || exit 1

# Браузер ставится ОТДЕЛЬНО, не обязателен, и ТОЛЬКО нативный.
#
# Имя пакета различается: в Debian это `chromium` — настоящий браузер,
# обычный deb. В Ubuntu пакета `chromium` нет вовсе (замер 2026-09-10
# на jammy: `E: Package 'chromium' has no installation candidate`), а
# `chromium-browser` — переходник на snap, и ставить его НЕЛЬЗЯ.
#
# Почему нельзя (замер 2026-09-12 на собранном образе AGX Orin). Переходник
# тянет за собой `snapd` со всеми его юнитами, а сам браузер не появляется:
# постинст зовёт `snap install chromium`, но внутри virt-customize нет
# работающего systemd, и снап не ставится. Итог — в образе лежит `snapd`,
# `/snap` пуст, браузера нет. Довести дело можно только на первой загрузке
# и только при живой сети, а образы едут на машины, где сети может не быть:
# там это не отказывает громко, а молча не доезжает.
#
# Поэтому откат на `chromium-browser` убран. На Debian поведение прежнее,
# на Ubuntu сессия GNOME поднимается без браузера — ни gdm3, ни gnome-shell
# от него не зависят, и `task-gnome-desktop` тоже (проверено:
# `apt-cache rdepends chromium-browser` не содержит ни одного из них).
# Нужен браузер на Ubuntu — ставь `epiphany-browser` (WebKitGTK, 6 пакетов)
# или `falkon` (QtWebEngine, то есть Chromium внутри) отдельным `INSTALL`.
if apt-get install -y chromium >/dev/null 2>&1; then
    log_info "Browser installed: chromium"
else
    log_warn "нативного пакета chromium в этом дистрибутиве нет"
    log_warn "сессия GNOME работает без него; переходник на snap не ставим"
fi

# Ensure Xorg configuration directory exists
mkdir -p /etc/X11/xorg.conf.d

# --- Донастройка на первой загрузке -----------------------------------------
#
# ОТСУТСТВИЕ ФАЙЛА РЯДОМ — ОТКАЗ СБОРКИ, а не предупреждение. Раньше здесь
# стоял `log_warn` и `|| true`: сборка оставалась зелёной, юнита в образе
# не было, и узнать об этом можно было только на устройстве — из журнала
# платы, которую никто не читает. Из двух отказов дешевле тот, который видит
# собиравший: он у себя на машине чинит это за минуту. То же направление
# у остальной инфраструктуры бисквита (fail-closed у детектора устройств,
# preflight утилит до `dd`) и у соседнего `vino-vnc/install.sh`.
#
# ПУТЬ — ОТ $SCRIPT_DIR, А НЕ ЗАШИТЫЙ `/opt/vmsetup/gnome/`. Зашитая строка
# сцепляла проверку с раскладкой, которую выбирает `EXTENSION`: смена
# раскладки уронила бы разом все сборки. Скрипт лежит в том же каталоге,
# куда расширение скопировано, поэтому `$SCRIPT_DIR` верен при любой
# раскладке, и проверка отвечает на вопрос «файл приехал рядом со мной?»,
# а не «раскладка всё ещё такая?».
#
# В списке — всё, без чего первая загрузка не состоится. `disable_powersave.sh`
# в него не входит намеренно: его отсутствие `configure.sh` переживает
# предупреждением, автологин от него не зависит.
for f in configure-gnome.service configure.sh get_cloud_user.sh daemon.conf; do
  if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
    log_error "рядом нет $f — донастройки на первой загрузке не будет,"
    log_error "а без неё не появится ни автологина, ни выключенного Wayland"
    exit 1
  fi
done

install -m 0644 "$SCRIPT_DIR/configure-gnome.service" \
  /etc/systemd/system/configure-gnome.service

# Enable GDM and set graphical target as default
systemctl daemon-reload || true
systemctl enable gdm3.service || systemctl enable gdm.service || true
systemctl set-default graphical.target || true
systemctl enable configure-gnome.service || true

log_info "GNOME extension installation completed"
