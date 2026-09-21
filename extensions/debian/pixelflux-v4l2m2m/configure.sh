#!/usr/bin/env bash
# Первая загрузка: проверить на живом железе то, чего нельзя проверить на сборке.
#
# ЧТО ИМЕННО. В appliance virt-customize нет ни /dev/video*, ни X — «виден ли
# кодер» там спросить не у кого. Здесь узлы на месте, поэтому спрашивается
# прямо у pixelflux: его собственная проба обходит /dev/video*, требует от узла
# M2M, H.264 на приёмной очереди и упакованный 32-битный цвет на отдающей.
#
# ПОЧЕМУ НЕ ЖУРНАЛ СЕССИИ. Строка «Encoder: V4L2M2M» появляется, только когда
# подключился клиент, а на первой загрузке его нет. И у соседнего расширения
# такая строка однажды соврала: сервер её печатал, занимал кодер и не отдавал
# клиенту ни одного кадра. Проверяется то, что действительно доказывает
# исправность: бэкенд объявлен железу.
#
# ПОЧЕМУ ОТКАЗ, А НЕ ПРЕДУПРЕЖДЕНИЕ. Расширение указано в VMFILE явно — значит
# от образа ждут аппаратного кодирования. Плата без M2M-узла (например, Pi 5,
# где кодера нет в кремнии) этого расширения в цепочке нести не должна, и тихий
# откат в софт скрыл бы ошибку сборки до первого замера у заказчика.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} pixelflux-v4l2m2m: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} pixelflux-v4l2m2m: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} pixelflux-v4l2m2m: $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PREFIX="$(readlink -f /opt/selkies/current 2>/dev/null || true)"
SELKIES_PY="$PREFIX/usr/conda/bin/python"

if [[ -z "$PREFIX" || ! -x "$SELKIES_PY" ]]; then
    log_error "нет $SELKIES_PY — расширение selkies не установлено"
    exit 1
fi

if [[ ! -f "$PREFIX/.bisquite-pixelflux-v4l2m2m" ]]; then
    log_error "нет отпечатка $PREFIX/.bisquite-pixelflux-v4l2m2m"
    log_error "AppImage подняли без переустановки расширения — кодирование пойдёт процессором"
    exit 1
fi

# Узлы, которые вообще есть на плате: нужны не для решения, а для внятного
# отказа — «узлов нет» и «узлы есть, но ни один не подошёл» чинятся по-разному.
nodes="$(ls /dev/video* 2>/dev/null | tr '\n' ' ' || true)"
log_info "узлы V4L2: ${nodes:-нет}"

# Единственный авторитет — проба самого бэкенда. `encode_node_index` здесь не
# при чём: M2M-кодер не render-узел, и ответ от индекса не зависит.
backend="$("$SELKIES_PY" -c 'import pixelflux; print(pixelflux.hardware_encoders(0).get("h264", "нет"))' 2>/dev/null || echo "ошибка")"

if [[ "$backend" == "v4l2m2m" ]]; then
    log_info "бэкенд объявлен: h264 → v4l2m2m"
else
    log_error "pixelflux не объявляет v4l2m2m для h264 (ответ: $backend)"
    if [[ -z "$nodes" ]]; then
        log_error "узлов /dev/video* на плате нет вовсе: на этой машине кодера нет,"
        log_error "и EXTENSION pixelflux-v4l2m2m в её цепочке быть не должно"
    else
        log_error "узлы есть, но ни один не подошёл: нужен M2M с H264 на приёмной"
        log_error "очереди и упакованным 32-битным цветом на отдающей"
        log_error "посмотреть: v4l2-ctl -d <узел> --all | head -40"
    fi
    exit 1
fi

log_info "проверка пройдена: аппаратное кодирование доступно сессии"
