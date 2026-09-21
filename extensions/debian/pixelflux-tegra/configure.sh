#!/usr/bin/env bash
# Первая загрузка: проверить на живом железе то, чего нельзя проверить на сборке.
#
# ЧТО ИМЕННО. В appliance virt-customize нет ни /dev/v4l2-nvenc, ни
# /dev/nvhost-msenc, ни X — «виден ли кодер» там спросить не у кого. Здесь оба
# узла на месте, поэтому спрашивается прямо у pixelflux.
#
# ПОЧЕМУ НЕ ЖУРНАЛ СЕССИИ. Строка «Encoder: TEGRA» появляется, только когда
# подключился клиент, а на первой загрузке его нет. Хуже того, эта строка
# однажды уже соврала: при неприменённой правке гейта реле сервер писал
# «Encoder: TEGRA», занимал NVENC и не отдавал на сокет НИ ОДНОГО кадра. Поэтому
# проверяется то, что действительно доказывает исправность: бэкенд виден железу.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} pixelflux-tegra: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} pixelflux-tegra: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} pixelflux-tegra: $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="$(readlink -f /opt/selkies/current 2>/dev/null || true)"
SELKIES_PY="$PREFIX/usr/conda/bin/python"

if [[ -z "$PREFIX" || ! -x "$SELKIES_PY" ]]; then
    log_error "нет $SELKIES_PY — расширение selkies не установлено"
    exit 1
fi

if [[ ! -f "$PREFIX/.bisquite-pixelflux-tegra" ]]; then
    log_error "нет отпечатка $PREFIX/.bisquite-pixelflux-tegra"
    log_error "AppImage подняли без переустановки расширения — кодирование пойдёт процессором"
    exit 1
fi

# Узел кодера. На JetPack 4 это /dev/nvhost-msenc, на JetPack 5/6 —
# /dev/v4l2-nvenc (заглушка 1:3 поверх /dev/null, которую перехватывает
# libnvv4l2.so). Достаточно любого.
node=""
for candidate in /dev/nvhost-msenc /dev/v4l2-nvenc; do
    [[ -c "$candidate" ]] && { node="$candidate"; break; }
done
[[ -n "$node" ]] || { log_error "нет ни /dev/nvhost-msenc, ни /dev/v4l2-nvenc — кодера в системе не видно"; exit 1; }
log_info "узел кодера: $node"

# ДОСТУП К УЗЛУ. На JetPack 5/6 узел — клон /dev/null с правами 0666, и группа
# не нужна. На JetPack 4 это /dev/nvhost-msenc с root:video 0660, а cloud-init
# создаёт пользователя только с группой sudo
# (infrastructure/device/cloud_init.py) — то есть в образе Nano пользователь
# сессии узел не откроет, и pixelflux молча уйдёт на x264.
user="$("$SCRIPT_DIR/lib/get_cloud_user.sh" 2>/dev/null || true)"
if [[ -z "$user" ]] || ! id "$user" >/dev/null 2>&1; then
    log_error "пользователь сессии не определён — кому давать доступ к $node, неизвестно"
    exit 1
fi
# Права читаются битами, а не пробой от имени пользователя: переключение
# пользователя потребовало бы sudo или runuser, а кодер открывается O_RDWR —
# то есть нужен именно доступ на ЧТЕНИЕ И ЗАПИСЬ, чего `test -r` не покажет.
mode="$(stat -c %a "$node")"
group="$(stat -c %G "$node")"
others="${mode: -1}"
in_group=0
for g in $(id -nG "$user" 2>/dev/null); do [[ "$g" == "$group" ]] && in_group=1; done
# Узел JetPack 5/6 — клон /dev/null с 0666: доступ есть у всех, группа не нужна.
if [[ "$others" == 6 || "$others" == 7 ]]; then
    log_info "$node открыт всем ($mode) — группа не нужна"
elif (( in_group )); then
    log_info "$node доступен через группу $group, $user в ней"
else
    if [[ "$group" == "root" ]]; then
        log_error "$node с правами $mode и группой root — доступа пользователю $user не дать группой"
        exit 1
    fi
    log_warn "$node ($mode, группа $group) недоступен $user — добавляю его в группу $group"
    usermod -aG "$group" "$user" || { log_error "usermod не сработал"; exit 1; }
    # Группы читаются при старте процесса, поэтому уже запущенной сессии новая
    # группа не достанется — её надо перезапустить, иначе проверка ниже пройдёт,
    # а рабочая сессия останется на x264.
    if systemctl is-active "selkies@$user" >/dev/null 2>&1; then
        log_info "перезапускаю selkies@$user, чтобы группа досталась процессу"
        systemctl restart "selkies@$user" || log_warn "перезапуск не удался — потребуется перезагрузка"
    fi
fi
log_info "$node доступен пользователю $user"

# Подкладка берётся из того же drop-in, что получит сессия: на focal без шима
# gbm `import pixelflux` не работает вовсе, и проверка без LD_PRELOAD мерила бы
# не то, что будет работать на самом деле.
DROPIN=/etc/systemd/system/selkies@.service.d/10-pixelflux-tegra.conf
if [[ ! -f "$DROPIN" ]]; then
    log_error "нет drop-in с LD_PRELOAD — сессия упадёт через секунды после старта захвата"
    exit 1
fi
preload="$(sed -n 's/^Environment=LD_PRELOAD=//p' "$DROPIN" | tail -1)"
[[ -n "$preload" ]] || { log_error "в drop-in нет строки Environment=LD_PRELOAD="; exit 1; }
log_info "подкладка: $preload"

# Главная проверка: pixelflux сам говорит, какой бэкенд он выбрал для H.264.
# Загрузка вендорских библиотек здесь идёт до любого GL-стека, то есть в самых
# благоприятных условиях — если бэкенд не виден и тут, он не виден нигде.
# pixelflux печатает в stdout свою диагностику («Render node 0 encodes H264 on
# tegra»), поэтому значение берётся по метке, а не как весь вывод.
raw="$(LD_PRELOAD="$preload" "$SELKIES_PY" -c \
    'import pixelflux; print("BACKEND=" + str(pixelflux.hardware_encoders().get("h264", "нет")))' \
    2>/dev/null || true)"
backend="${raw##*BACKEND=}"
if [[ "$backend" != "tegra" ]]; then
    log_error "pixelflux выбирает для H.264 '$backend', а не 'tegra' — кодирование пойдёт процессором"
    log_error "проверьте вендорские библиотеки: ldconfig -p | grep -E 'libnvv4l2|libnvbufsurface|libnvbuf_utils'"
    exit 1
fi
log_info "бэкенд H.264: tegra"

log_info "проверка пройдена: аппаратное кодирование H.264 доступно"
