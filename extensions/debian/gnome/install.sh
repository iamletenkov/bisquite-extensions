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

# --- gdm: X11, а не Wayland ---------------------------------------------------
#
# На сборке, а не на первой загрузке: имя пользователя тут не нужно, а файл
# конфигурации gdm3 уже лежит — его только что поставил пакет. x11vnc,
# xset и захват экрана работают только в X11.
#
# Какой файл читает gdm, решено при сборке ПАКЕТА, и дистрибутивы
# расходятся (замер 2026-09-03 распаковкой): Debian 13 — daemon.conf,
# Ubuntu — custom.conf. Запись в другой файл не ошибка и предупреждения
# не даёт: gdm его просто не читает. Поэтому пишем тот, что поставил пакет,
# а если нет ни одного — оба.
if [[ ! -f "$SCRIPT_DIR/daemon.conf" ]]; then
  log_error "рядом нет daemon.conf — Wayland останется включённым, x11vnc не заработает"
  exit 1
fi
gdm_targets=()
for c in /etc/gdm3/daemon.conf /etc/gdm3/custom.conf; do [[ -f "$c" ]] && gdm_targets+=("$c"); done
(( ${#gdm_targets[@]} )) || gdm_targets=(/etc/gdm3/daemon.conf /etc/gdm3/custom.conf)
for c in "${gdm_targets[@]}"; do
  install -D -m 0644 "$SCRIPT_DIR/daemon.conf" "$c"
  log_info "gdm: $c — Wayland выключен, автологин выключен до ручки"
done

# --- Ручки рабочего стола ----------------------------------------------------
#
# Автологин, автоблокировка и затемнение — не поведение расширения, а ручки
# (bisquite-desktop, общий код lib/): по умолчанию все выключены, включаются
# параметрами расширения или `bisquite-desktop set` на устройстве. Служба
# bisquite-desktop.service применяет их на каждой загрузке ДО gdm и вносит
# пользователя в группы видеоядра — без этого первая загрузка Jetson
# показывала экран входа (разбор — в самом скрипте).
if [[ ! -x "$SCRIPT_DIR/bisquite-desktop" ]]; then
  log_error "рядом нет bisquite-desktop — ручек автологина и экрана не будет"
  exit 1
fi
apt-get install -y x11-xserver-utils || exit 1
"$SCRIPT_DIR/bisquite-desktop" install "$SCRIPT_DIR" || exit 1

systemctl enable gdm3.service || systemctl enable gdm.service || true
systemctl set-default graphical.target || true

log_info "GNOME extension installation completed"
