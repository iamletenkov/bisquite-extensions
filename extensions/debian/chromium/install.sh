#!/usr/bin/env bash
# Ставит браузер Chromium через транзитный apt-пакет chromium-browser.
#
# ПОЧЕМУ ТРАНЗИТНЫЙ ПАКЕТ, А НЕ НАСТОЯЩИЙ .deb. У Canonical для jammy
# нативного `.deb` с Chromium нет вовсе — с 19.10 `chromium-browser`
# в архиве Ubuntu это ЗАГЛУШКА (проверено 2026-09-12: apt-cache show
# chromium-browser отвечает "Transitional package - chromium-browser ->
# chromium snap", Installed-Size 161). Настоящий браузер — snap-пакет,
# и ставит его постинст этой заглушки.
#
# ПОЧЕМУ ЭТОГО МОЖЕТ БЫТЬ НЕДОСТАТОЧНО ЗДЕСЬ. Постинст deb-пакета внутри
# virt-customize выполняется в chroot без работающего systemd и без
# гарантии сети именно в момент установки — тот же класс проблемы, что
# уже задокументирован в проекте для докер-демона и прочих постинстов,
# пытающихся стартовать сервис под эмуляцией. Поэтому эта же установка
# ДОВОДИТСЯ явно на первой загрузке — см. configure.sh и
# configure-chromium.service. Если постинст уже справился на сборке,
# firstboot-шаг увидит установленный snap и завершится мгновенно.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} chromium: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} chromium: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} chromium: $*"; }

apt_retry(){
    local max=5 n=1 d
    while true; do
        if "$@"; then return 0; fi
        if (( n >= max )); then return 1; fi
        d=$(( n * 2 )); log_warn "apt не отработал, повтор через ${d}s ($n/$max)"
        sleep "$d"; n=$(( n + 1 ))
    done
}

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-q -y -o Dpkg::Options::=--force-confnew)

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

log_info "apt-get update"
apt_retry apt-get update -q || exit 1

log_info "ставлю chromium-browser (транзитный пакет; тянет snapd)"
apt_retry apt-get install "${APT_OPTS[@]}" chromium-browser || {
    log_error "chromium-browser не установился"
    exit 1
}

if [[ -f "$SCRIPT_DIR/configure-chromium.service" ]]; then
    install -m 0644 "$SCRIPT_DIR/configure-chromium.service" \
        /etc/systemd/system/configure-chromium.service
    systemctl enable configure-chromium.service || true
else
    log_error "рядом нет configure-chromium.service"
    log_error "без него snap chromium может не довестись до конца, если"
    log_error "постинст пакета не успел сделать это во время сборки"
    exit 1
fi

log_info "готово: пакет поставлен, довод snap — на первой загрузке"
