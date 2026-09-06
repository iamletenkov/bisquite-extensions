#!/usr/bin/env bash
# Первая загрузка: включить автологин для пользователя cloud-init.
#
# Вендорская учётка к этому моменту уже удалена — на сборке. Здесь
# остаётся одно: узнать имя нового пользователя, которого на сборке
# знать было неоткуда, и вернуть автологин.
set -euo pipefail
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} cloud-user-desktop: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} cloud-user-desktop: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} cloud-user-desktop: $*"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

user=""
if [[ -x "$HERE/get_cloud_user.sh" ]]; then
    user="$("$HERE/get_cloud_user.sh" 2>/dev/null || true)"
fi
if [[ -z "$user" ]]; then
    log_error "пользователь не определился — автологин остаётся выключенным"
    log_error "вход через приглашение менеджера входа или по ssh"
    exit 1
fi
if [[ ! -d "/home/${user}" ]]; then
    log_error "у '$user' нет домашнего каталога — автологин не включаю"
    exit 1
fi

changed=0
if [[ -f /etc/gdm3/custom.conf ]]; then
    sed -i -e "s/^\s*AutomaticLoginEnable\s*=.*/AutomaticLoginEnable=True/" \
           -e "s/^\s*AutomaticLogin\s*=.*/AutomaticLogin=${user}/" \
           /etc/gdm3/custom.conf
    grep -q "^AutomaticLogin=${user}$" /etc/gdm3/custom.conf || \
        printf 'AutomaticLogin=%s\n' "$user" >> /etc/gdm3/custom.conf
    changed=1
    log_info "gdm3: автологин включён для $user"
fi
for conf in /etc/lightdm/lightdm.conf /etc/lightdm/lightdm.conf.d/*.conf; do
    [[ -f "$conf" ]] || continue
    sed -i "s/^\s*autologin-user\s*=.*/autologin-user=${user}/" "$conf"
    changed=1
    log_info "lightdm: автологин включён для $user ($conf)"
done
(( changed )) || log_warn "менеджера входа не нашлось — автологин не потребовался"
log_info "готово"
