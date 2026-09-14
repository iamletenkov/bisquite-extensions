#!/usr/bin/env bash
# Первая загрузка: включить selkies@<пользователь cloud-init>.
#
# Имя пользователя на сборке неизвестно — его создаёт cloud-init. Всё
# остальное (адрес, порт, что включено) уже лежит в /etc/bisquite/selkies/config
# со сборки, сети здесь не нужно.
set -euo pipefail
RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} selkies: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} selkies: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} selkies: $*"; }
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

user=""
for _ in $(seq 1 40); do
    user="$("$SCRIPT_DIR/lib/get_cloud_user.sh" 2>/dev/null || true)"
    [[ -n "$user" ]] && id "$user" >/dev/null 2>&1 && break
    user=""; sleep 3
done
[[ -n "$user" ]] || { log_error "пользователь cloud-init не появился за 120 с"; exit 1; }

# Прежние экземпляры другого пользователя — погасить, иначе два сервера
# спорят за один порт (тот же довод, что у x11vnc/configure.sh).
shopt -s nullglob
for unit in /etc/systemd/system/graphical.target.wants/selkies@*.service; do
    name="$(basename "$unit")"
    [[ "$name" == "selkies@${user}.service" ]] && continue
    log_info "гашу прежний экземпляр $name"
    systemctl disable --now "$name" || log_warn "не удалось погасить $name"
done
shopt -u nullglob

systemctl enable "selkies@${user}.service"
if systemctl restart "selkies@${user}.service"; then
    log_info "selkies@${user} запущен — journalctl -u selkies@${user}"
else
    log_error "selkies@${user} не запустился — journalctl -u selkies@${user}"
    exit 1
fi
