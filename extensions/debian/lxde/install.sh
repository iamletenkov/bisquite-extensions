#!/usr/bin/env bash
# Install LXDE desktop stack and prepare auto-configuration service

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"


log_info "Installing LXDE and dependencies..."

apt-get update || exit 1
apt-get install -y \
  lxde \
  lightdm lightdm-gtk-greeter \
  xorg xinput \
  usbutils dbus-x11 || exit 1

# Браузер ставится ОТДЕЛЬНО и не обязателен.
#
# Пока `firefox-esr` стоял в общем списке с `|| exit 1`, отсутствие одного
# необязательного пакета роняло установку ВСЕГО десктопа — при том что ни
# lightdm, ни сессия LXDE от браузера не зависят. Ровно эта ошибка у соседа
# уже замерена: `gnome/install.sh:25-49`, jammy 2026-09-10,
# `E: Package 'chromium' has no installation candidate`. Имя пакета там
# другое, механизм отказа тот же; замера под сам `firefox-esr` мы не делали
# и выдумывать его не надо — довод держится на уже замеренном случае.
#
# Поэтому: перебираем известные имена, ставим первое доступное, и отсутствие
# всех — предупреждение, а не отказ. Порядок перебора — сначала настоящий
# пакет Debian, потом имя, под которым браузер живёт в Ubuntu (там это
# переходник на snap, и внутри appliance он вполне может не поставиться —
# это тоже промах, то есть предупреждение).
browser_installed=""
for browser in firefox-esr firefox; do
    if apt-get install -y "$browser" >/dev/null 2>&1; then
        browser_installed="$browser"
        break
    fi
done

if [[ -n "$browser_installed" ]]; then
    log_info "Browser installed: $browser_installed"
else
    log_warn "No firefox package available in this distribution"
    log_warn "LXDE session works without it; install a browser manually if needed"
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
# ПУТЬ — ОТ $SCRIPT_DIR, А НЕ ЗАШИТЫЙ `/opt/vmsetup/lxde/`. Зашитая строка
# сцепляла проверку с раскладкой, которую выбирает `EXTENSION`: смена
# раскладки уронила бы разом все сборки. Скрипт лежит в том же каталоге,
# куда расширение скопировано, поэтому `$SCRIPT_DIR` верен при любой
# раскладке, и проверка отвечает на вопрос «файл приехал рядом со мной?»,
# а не «раскладка всё ещё такая?».
#
# В списке — всё, без чего первая загрузка не состоится. `disable_powersave.sh`
# в него не входит намеренно: его отсутствие `configure.sh` переживает
# предупреждением, автологин от него не зависит.
for f in configure-lxde.service configure.sh get_cloud_user.sh lightdm.conf; do
  if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
    log_error "рядом нет $f — донастройки на первой загрузке не будет,"
    log_error "а без неё автологина не появится: менеджер входа покажет приглашение"
    exit 1
  fi
done

install -m 0644 "$SCRIPT_DIR/configure-lxde.service" \
  /etc/systemd/system/configure-lxde.service

# Enable LightDM and set graphical target as default
systemctl daemon-reload || true
systemctl enable lightdm.service || true
systemctl set-default graphical.target || true
systemctl enable configure-lxde.service || true

log_info "LXDE extension installation completed"
