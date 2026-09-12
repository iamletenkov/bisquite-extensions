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
# ВЫВОД СНАЧАЛА В ПЕРЕМЕННУЮ, И ЭТО НЕ СТИЛЬ, А ПОЧИНКА.
#
# Было `gsettings list-schemas | grep -qx …`. Под `set -o pipefail` это
# ловушка: grep выходит по первому совпадению и закрывает канал, gsettings
# получает SIGPIPE и умирает с кодом 141, pipefail делает весь конвейер
# неуспешным — и проверка «схемы нет» срабатывает при том, что схема есть.
# Отказ ГОНОЧНЫЙ: успел gsettings дописать вывод — прошло, не успел — нет.
# Замер 2026-09-12: на первой загрузке прошло, при ручном прогоне на той же
# машине — отказ. Такое ловится живым запуском, а не чтением.
SCHEMAS="$(gsettings list-schemas 2>/dev/null || true)"
if ! grep -qx "org.gnome.desktop.background" <<<"$SCHEMAS"; then
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

# ОТКАЗ ОТ ВЕНДОРСКИХ ОБОЕВ NVIDIA — ДО того, как поднимется сессия.
#
# На L4T пакет nvidia-l4t-configs кладёт /etc/xdg/autostart/nvbackground.sh,
# который при КАЖДОМ старте сессии делает ровно то же, что мы:
#
#     gsettings set org.gnome.desktop.background picture-uri file://…NVIDIA_Wallpaper.jpg
#     gsettings set org.gnome.desktop.background picture-options scaled
#     touch ~/.local/share/applications/nvbackground_${DESKTOP_SESSION}
#
# Замер на живой плате 2026-09-12: наша служба записала значения в 12:58:09,
# dconf пользователя оказался переписан в 12:59:35 — когда стартовала
# сессия. Гонку мы проигрываем по построению: firstboot всегда раньше GDM.
#
# Бороться с этим удалением вендорского файла не надо — NVIDIA сама
# предусмотрела отказ: первая же проверка в её скрипте выходит, если
# маркер УЖЕ существует. Создаём его заранее, и скрипт не делает ничего.
#
# Маркер именуется по DESKTOP_SESSION, а его на сборке знать неоткуда,
# поэтому кладём по файлу на каждую установленную сессию (их единицы,
# файлы пустые).
skip_nvidia_background() {
    local marker_dir="$USER_HOME/.local/share/applications"
    local sessions=() s name
    for s in /usr/share/xsessions/*.desktop /usr/share/wayland-sessions/*.desktop; do
        [[ -e "$s" ]] || continue
        name="$(basename "$s" .desktop)"
        sessions+=("$name")
    done
    if [[ ${#sessions[@]} -eq 0 ]]; then
        log_warn "сессий в xsessions/wayland-sessions не нашлось — маркер не ставлю"
        return 0
    fi
    runuser -u "$CLOUD_USER" -- mkdir -p "$marker_dir" || {
        log_error "не удалось создать $marker_dir"
        exit 1
    }
    for name in "${sessions[@]}"; do
        runuser -u "$CLOUD_USER" -- touch "$marker_dir/nvbackground_$name" || {
            log_error "не удалось создать маркер для сессии $name"
            exit 1
        }
    done
    log_info "автозамена обоев NVIDIA отключена для сессий: ${sessions[*]}"
}

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
skip_nvidia_background

gset picture-uri "file://${IMAGE}"
BG_KEYS="$(gsettings list-keys org.gnome.desktop.background 2>/dev/null || true)"
if grep -qx "picture-uri-dark" <<<"$BG_KEYS"; then
    gset picture-uri-dark "file://${IMAGE}"
else
    log_info "ключа picture-uri-dark нет (GNOME старше 42) — пропускаю"
fi

# zoom, а не centered: картинка 1920x1080, а монитор у робота какой угодно.
gset picture-options zoom

log_info "готово"
