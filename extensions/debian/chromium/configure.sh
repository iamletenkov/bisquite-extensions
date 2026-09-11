#!/usr/bin/env bash
# Довести установку snap chromium на первой загрузке.
#
# На сборке (virt-customize) постинст deb-пакета chromium-browser мог не
# довести дело: нет работающего systemd, снап-демон под эмуляцией не
# гарантированно стартует. Здесь — реальная система, реальный systemd,
# реальная сеть, и это правильное место доводить установку snap-пакетов.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} configure-chromium: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} configure-chromium: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} configure-chromium: $*"; }

if command -v chromium >/dev/null 2>&1 || command -v chromium-browser >/dev/null 2>&1; then
    log_info "chromium уже доступен в PATH — постинст на сборке справился, нечего делать"
    exit 0
fi

if ! command -v snap >/dev/null 2>&1; then
    log_error "команды snap нет — пакет chromium-browser не поставил snapd?"
    exit 1
fi

log_info "жду, пока snapd закончит первичный seed"
if ! snap wait system seed.loaded; then
    log_warn "snap wait не отработал — пробую установку всё равно"
fi

install_snap() {
    local attempt=1 max_attempts=6 delay
    while (( attempt <= max_attempts )); do
        log_info "snap install chromium (попытка ${attempt}/${max_attempts})"
        if snap install chromium; then
            return 0
        fi
        delay=$(( attempt * 10 ))
        log_warn "не вышло, повтор через ${delay}s (снап тяжёлый, сеть могла ещё не устояться)"
        sleep "$delay"
        attempt=$(( attempt + 1 ))
    done
    return 1
}

if ! install_snap; then
    log_error "не удалось поставить snap chromium после нескольких попыток"
    log_error "проверь сеть и повтори вручную: sudo snap install chromium"
    exit 1
fi

log_info "готово: $(snap list chromium 2>/dev/null | tail -1)"
