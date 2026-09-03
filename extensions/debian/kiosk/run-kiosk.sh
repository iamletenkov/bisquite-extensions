#!/usr/bin/env bash
# Start Chromium in kiosk mode, resolving the X authority at runtime.
#
# ПОЧЕМУ ОБЁРТКА, А НЕ ПУТЬ В ЮНИТЕ. В `kiosk-chromium@.service` было прибито
#
#     Environment="XAUTHORITY=/home/%i/.Xauthority"
#
# — путь, который верен ровно под LightDM и не существует под GDM >= 42, где
# authority лежит в /run/user/<uid>/gdm/Xauthority. Это тот же дефект, что уже
# исправлен у расширения x11vnc; замеры на живой ВМ (debian 12, 2026-09-03,
# GDM и LightDM подряд на одной машине) записаны в шапке
# extensions/debian/x11vnc/run-x11vnc.sh и здесь не дублируются — источник
# один, и расходиться двум копиям незачем.
#
# Отказ был НЕМЫМ вдвойне. `ExecStartPre` десять секунд ждал `xdpyinfo`
# с тем же неверным XAUTHORITY, сдавался, а `Restart=always` заводил цикл
# раз в десять секунд навсегда: в журнале — только «Failed to open display»,
# и ни слова о том, где искали.
#
# ВТОРОЙ ДЕФЕКТ, ВСКРЫТЫЙ ЗАОДНО: `xdpyinfo` расширение не ставило вовсе.
# install.sh просил `x11-xserver-utils` (xset, xrandr, xhost), а `xdpyinfo`
# лежит в пакете `x11-utils`. Проверка из ExecStartPre работала лишь тогда,
# когда x11-utils приехал прицепом за `xorg` от расширения десктопа, то есть
# зависела от порядка слоёв в VMFILE. Пакет теперь объявлен явно — ровно то,
# что было сделано у x11vnc по той же причине.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} kiosk: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} kiosk: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} kiosk: $*"; }

USERNAME="${1:?usage: run-kiosk.sh <user>}"
UID_OF_USER="$(id -u "$USERNAME")"
HOME_OF_USER="$(getent passwd "$USERNAME" | cut -d: -f6)"

# Параметры приходят из /var/lib/kiosk/config через EnvironmentFile юнита;
# его пишет configure.sh из config.yaml. Умолчания здесь — последний рубеж
# на случай отсутствующего файла, и они совпадают с умолчаниями configure.sh.
DISPLAY_NUM="${DISPLAY:-:0}"
URL="${URL:-https://github.com/iamletenkov/bisquite}"
EXTRA_FLAGS_RAW="${CHROMIUM_FLAGS:-}"

# Кандидаты в authority — в порядке убывания надёжности, у каждого источник
# знания. Список пересобирается на каждой попытке: под GDM файл
# /run/user/<uid>/gdm/Xauthority появляется не раньше сессии, то есть его
# может не быть в момент первой проверки.
authority_candidates() {
    local -n out="$1"
    out=()
    [[ -n "${XAUTHORITY:-}" ]] && out+=("$XAUTHORITY")
    out+=(
        "${HOME_OF_USER}/.Xauthority"                  # LightDM, session.c
        "/run/user/${UID_OF_USER}/gdm/Xauthority"      # GDM >= 42, gdm-x-session.c
        "/run/lightdm/${USERNAME}/xauthority"          # LightDM, user-authority-in-system-dir=true
    )
    # Xorg получает -auth от того, кто его запустил; если файл читается нашим
    # пользователем, он подойдёт.
    local xorg_pid xorg_auth
    xorg_pid="$(pgrep -x Xorg | head -1 || true)"
    if [[ -n "$xorg_pid" && -r "/proc/$xorg_pid/cmdline" ]]; then
        xorg_auth="$(tr '\0' '\n' < "/proc/$xorg_pid/cmdline" \
            | awk '/^-auth$/{getline; print; exit}' || true)"
        [[ -n "$xorg_auth" ]] && out+=("$xorg_auth")
    fi
    # Legacy-раскладка GDM — последней: на современных сборках её нет.
    local legacy
    for legacy in /run/gdm3/auth-for-"$USERNAME"-*/database; do
        [[ -e "$legacy" ]] && out+=("$legacy")
    done
    # Явный успех обязателен: последним выполняется `[[ -e ... ]]` по
    # несовпавшей маске, то есть функция вернула бы 1, и `set -e` убил бы
    # скрипт молча, ещё до первой строки в журнале. Поймано смоук-прогоном
    # с заглушками, а не рассуждением.
    return 0
}

# Ждём не «сокет появился», а «дисплей открывается с этим authority»: сокет
# /tmp/.X11-unix/X0 есть и под Wayland (его создаёт mutter для Xwayland),
# и он ничего не говорит о правах.
AUTH=""
candidates=()
for attempt in $(seq 1 30); do
    authority_candidates candidates
    for candidate in "${candidates[@]}"; do
        [[ -r "$candidate" ]] || continue
        if env XAUTHORITY="$candidate" xdpyinfo -display "$DISPLAY_NUM" >/dev/null 2>&1; then
            AUTH="$candidate"
            break 2
        fi
    done
    (( attempt == 1 )) && log_info "жду X-дисплей $DISPLAY_NUM (до 60 с)"
    sleep 2
done

if [[ -z "$AUTH" ]]; then
    # Громкий отказ вместо немого цикла рестарта: перечисляем ВСЁ, что
    # проверили. Без этого следующий читатель журнала видит только
    # «Failed to open display» и не знает, где искать.
    log_error "не нашёл X authority для '$USERNAME' на дисплее $DISPLAY_NUM"
    log_error "проверены пути:"
    for candidate in "${candidates[@]}"; do
        log_error "  $candidate $( [[ -r "$candidate" ]] && echo '(есть, но xdpyinfo не прошёл)' || echo '(нет)' )"
    done
    log_error "расширение kiosk X-сервер и автологин НЕ ставит — их даёт gnome, xfce4 или lxde"
    exit 1
fi
log_info "authority: $AUTH"

export XAUTHORITY="$AUTH"
export DISPLAY="$DISPLAY_NUM"

# Базовый набор — тот же, что был зашит в юните. Флаги из CHROMIUM_FLAGS
# ДОБАВЛЯЮТСЯ к нему, а не заменяют его.
args=(
    --kiosk
    --noerrdialogs
    --disable-infobars
    --no-first-run
    --disable-translate
    --disable-session-crashed-bubble
    --disable-features=TranslateUI
)
# Разбиение по пробелам, кавычки внутри значения не поддерживаются — так же,
# как в прежнем `bash -c` с неэкранированным $CHROMIUM_FLAGS. Флаги Chromium
# пробелов внутри себя не содержат, поэтому цена нулевая; если однажды
# понадобится, значение придётся передавать массивом, а не строкой.
if [[ -n "$EXTRA_FLAGS_RAW" ]]; then
    read -r -a extra_flags <<< "$EXTRA_FLAGS_RAW"
    args+=("${extra_flags[@]}")
fi

log_info "открываю $URL"
exec chromium "${args[@]}" "$URL"
