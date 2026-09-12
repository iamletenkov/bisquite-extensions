#!/usr/bin/env bash
# Первая загрузка: прописать обои пользователю, которого создал cloud-init.
#
# ПОЧЕМУ ЭТОГО НЕЛЬЗЯ БЫЛО СДЕЛАТЬ НА СБОРКЕ. `gsettings` пишет в dconf
# КОНКРЕТНОГО пользователя (~/.config/dconf/user). На сборке учётки не
# существует: её создаёт cloud-init из манифеста записи. Записать «в общий
# dconf» нельзя — ключ background персонален по устройству.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} wallpaper: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} wallpaper: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} wallpaper: $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMAGE="/usr/share/backgrounds/bisquite-wallpaper.jpg"

if [[ ! -f "$IMAGE" ]]; then
    log_error "нет $IMAGE — install.sh не отработал?"
    exit 1
fi

for tool in gsettings runuser dbus-run-session; do
    command -v "$tool" >/dev/null 2>&1 || {
        log_error "нет $tool — применить обои нечем"
        exit 1
    }
done

# Схема GNOME. Расширение намеренно поддерживает только её: XFCE хранит
# то же самое в xfconf, LXDE — в pcmanfm, и одинаковой команды для всех
# трёх не существует. Отказ здесь громкий, чтобы «обои не появились»
# не пришлось выяснять по журналу.
if ! gsettings list-schemas 2>/dev/null | grep -qx "org.gnome.desktop.background"; then
    log_error "нет схемы org.gnome.desktop.background — это не GNOME"
    log_error "расширение рассчитано на GNOME; для XFCE/LXDE нужен свой способ"
    exit 1
fi

if [[ ! -x "$SCRIPT_DIR/get_cloud_user.sh" ]]; then
    log_error "нет $SCRIPT_DIR/get_cloud_user.sh"
    exit 1
fi
CLOUD_USER="$("$SCRIPT_DIR/get_cloud_user.sh")" || {
    log_error "не удалось определить пользователя cloud-init"
    exit 1
}
USER_HOME="$(getent passwd "$CLOUD_USER" | cut -d: -f6)"
if [[ -z "$USER_HOME" || ! -d "$USER_HOME" ]]; then
    log_error "у пользователя $CLOUD_USER нет домашнего каталога"
    exit 1
fi
log_info "пользователь: $CLOUD_USER ($USER_HOME)"

# gsettings от имени пользователя и БЕЗ его сессии.
#
# dconf пишет через службу на шине сеанса, а сеанса на этом этапе ещё нет
# (юнит стоит до дисплей-менеджера). `dbus-run-session` поднимает временную
# шину на одну команду — записи всё равно уходят в ~/.config/dconf/user,
# откуда их прочтёт будущая сессия.
#
# HOME задаётся ЯВНО: `runuser` без `-l` окружение не переопределяет, и
# с HOME=/root настройки уехали бы в dconf рута — молча и мимо цели.
gset(){
    local key="$1" value="$2"
    if runuser -u "$CLOUD_USER" -- \
        env HOME="$USER_HOME" dbus-run-session -- \
        gsettings set org.gnome.desktop.background "$key" "$value"; then
        log_info "org.gnome.desktop.background $key = $value"
    else
        log_error "не удалось выставить $key"
        exit 1
    fi
}

# picture-uri-dark — отдельный ключ, появившийся в GNOME 42 (jammy).
# Без него в тёмной теме, которая на Ubuntu включена у части профилей,
# остаётся стандартный фон: выглядит как «обои не применились».
gset picture-uri "file://${IMAGE}"
if gsettings list-keys org.gnome.desktop.background 2>/dev/null | grep -qx "picture-uri-dark"; then
    gset picture-uri-dark "file://${IMAGE}"
else
    log_info "ключа picture-uri-dark нет (GNOME старше 42) — пропускаю"
fi

# zoom, а не centered: картинка 1920x1080, а монитор у робота какой угодно.
gset picture-options zoom

log_info "готово"
