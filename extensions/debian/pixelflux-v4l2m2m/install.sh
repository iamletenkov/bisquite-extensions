#!/usr/bin/env bash
# Аппаратное кодирование H.264 в Selkies на плате, чей кодер выставлен
# стандартным V4L2 M2M (Raspberry Pi 3/4/CM4 — bcm2835-codec).
#
# С Selkies 2.0.0rc1 подменять уже нечего: релиз несёт pixelflux 2.1.0rc1,
# а в нём есть бэкенд v4l2m2m, и лестчница сама падает с VA-API на M2M. Роль
# расширения свелась к двум вещам:
#   * на сборке — убедиться, что базовый pixelflux действительно несёт бэкенд
#     v4l2m2m (если апстрим его однажды уронит, сборка должна встать, а не
#     тихо уехать в софт);
#   * на первой загрузке — служба verify проверяет на живом железе, что сессия
#     идёт на V4L2M2M, а не свалилась в софт (configure.sh).
#
# ЗАЧЕМ вообще. Замер на живом рабочем столе 1080p, одна сессия, разница только
# в use_cpu: 0.378 ядра против 1.128 на x264 — втрое меньше.
#
# ПОЧЕМУ ОТДЕЛЬНОЕ РАСШИРЕНИЕ, А НЕ ПРАВКА selkies. Расширение selkies общее
# с amd64 и Jetson; «проверить именно M2M» осмысленно только на плате с таким
# кодером, и требование этой проверки должно быть видно строкой в VMFILE.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} pixelflux-v4l2m2m: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} pixelflux-v4l2m2m: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} pixelflux-v4l2m2m: $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- преграды -----------------------------------------------------------------

case "$(dpkg --print-architecture)" in
    arm64) ;;
    *) log_error "M2M-платы в нашем парке (Pi 3/4/CM4) — arm64, а образ — $(dpkg --print-architecture)"; exit 1 ;;
esac

# Устройства внутри virt-customize не пробрасываются, поэтому проверить наличие
# M2M-узла на фазе сборки НЕЛЬЗЯ, и гейта по железу здесь нет: расширение
# ставится там, где его указали в VMFILE. Решение «железо или софт» принимает
# сам бэкенд в рантайме, а живую проверку берёт на себя configure.sh.
for f in configure.sh verify-pixelflux-v4l2m2m.service; do
    [[ -f "$SCRIPT_DIR/$f" ]] || { log_error "рядом нет $f — расширение доставлено не целиком"; exit 1; }
done

# Порядок строк в VMFILE bisquite не сортирует, поэтому единственная настоящая
# преграда против «поставили раньше selkies» — вот эта.
PREFIX="$(readlink -f /opt/selkies/current 2>/dev/null || true)"
SELKIES_PY="$PREFIX/usr/conda/bin/python"
if [[ -z "$PREFIX" || ! -x "$SELKIES_PY" ]]; then
    log_error "нет /opt/selkies/current/usr/conda/bin/python"
    log_error "EXTENSION pixelflux-v4l2m2m обязан идти ПОСЛЕ EXTENSION selkies"
    exit 1
fi
log_info "AppImage Selkies: $PREFIX"

# --- отпечаток ----------------------------------------------------------------
# PREFIX у selkies — /opt/selkies/${SELKIES_VERSION}, то есть подъём версии
# AppImage даёт НОВЫЙ каталог, и служба verify туда не встанет без переустановки.
STAMP="$PREFIX/.bisquite-pixelflux-v4l2m2m"
STAMP_NOW="verify-only prefix=$PREFIX"
if [[ -f "$STAMP" ]] && [[ "$(cat "$STAMP")" == "$STAMP_NOW" ]]; then
    log_info "уже установлено (отпечаток совпал) — ничего не делаю"
    exit 0
fi

# --- проверка фазы build ------------------------------------------------------
# Живой проверки «Encoder: V4L2M2M» здесь быть не может: virt-customize не
# пробрасывает устройства, в appliance нет ни /dev/video*, ни X. Но что базовый
# pixelflux НЕСЁТ бэкенд v4l2m2m — проверяемо и здесь: если апстрим его уронит
# при следующем подъёме Selkies, сборка обязана встать.
MODULE_SO="$("$SELKIES_PY" -c 'import pixelflux; print(pixelflux.__file__)' 2>/dev/null || true)"
[[ -f "$MODULE_SO" ]] || { log_error "не удалось найти модуль pixelflux в AppImage"; exit 1; }
# grep читает двоичный файл сам (-a): конвейер `strings | grep -q` под
# `set -o pipefail` возвращает ошибку именно при УСПЕХЕ.
if ! grep -qa "V4L2 M2M encoder on" "$MODULE_SO"; then
    log_error "в базовом pixelflux нет бэкенда v4l2m2m — Selkies собран без него"
    log_error "модуль: $MODULE_SO"
    exit 1
fi
log_info "базовый pixelflux несёт бэкенд v4l2m2m"

# --- первая загрузка ----------------------------------------------------------
install -m 0644 "$SCRIPT_DIR/verify-pixelflux-v4l2m2m.service" \
    /etc/systemd/system/verify-pixelflux-v4l2m2m.service
chmod +x "$SCRIPT_DIR/configure.sh"
install -d /etc/systemd/system/graphical.target.wants
ln -sf /etc/systemd/system/verify-pixelflux-v4l2m2m.service \
    /etc/systemd/system/graphical.target.wants/verify-pixelflux-v4l2m2m.service

printf '%s' "$STAMP_NOW" > "$STAMP"
chmod 0644 "$STAMP"
log_info "проверка v4l2m2m включена; служба verify подтвердит железо на первой загрузке"
