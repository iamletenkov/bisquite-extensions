#!/usr/bin/env bash
# Аппаратное кодирование H.264 в Selkies на плате, чей кодер выставлен
# стандартным V4L2 M2M: подменяет pixelflux внутри AppImage, поставленного
# расширением selkies, официальным колесом апстрима с бэкендом v4l2m2m.
#
# ЗАЧЕМ. На Raspberry Pi 4 кодер в кремнии есть (bcm2835-codec, H.264), но
# выставлен он через ядерный M2M, куда pixelflux не ходил: его лестница знала
# NVENC, VA-API и вендорский V4L2 Tegra, а VA-API-драйвера для bcm2835 не
# существует. Замер на живом рабочем столе 1080p, одна сессия, разница только
# в use_cpu: 0.378 ядра против 1.128 на x264 — втрое меньше.
#
# ПОЧЕМУ ОТДЕЛЬНОЕ РАСШИРЕНИЕ, А НЕ ПРАВКА selkies. Ровно по той же причине,
# что и у pixelflux-tegra: расширение selkies общее с amd64, где всё работает
# и без подмены, а подмена чужого артефакта должна быть видна строкой в VMFILE.
#
# ЧТО ЗДЕСЬ ВРЕМЕННОЕ. Всё. lib/rc0-compat.py нужен, пока последний релиз
# Selkies (2.0.0rc0) старше pixelflux в main: мейнтейнер в selkies#395 сказал
# прямо, что наборы двигаются вместе и API между версиями несовместим. Когда
# выйдет rc1 с парным pixelflux, расширение схлопывается до одной строки
# `pip install pixelflux==<версия>` либо исчезает целиком.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} pixelflux-v4l2m2m: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} pixelflux-v4l2m2m: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} pixelflux-v4l2m2m: $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# ⚠️ ЗАКРЕПЛЕНИЕ ЕЩЁ НЕ СУЩЕСТВУЕТ. Бэкенд отправлен в апстрим
# (selkies-project/pixelflux#35) и не влит, поэтому официального колеса с ним
# нет. Их CI публикует предрелиз на каждый коммит main: после мерджа сюда
# встают тег того коммита, имя файла и sha256 — ровно как в pixelflux-tegra.
# До тех пор расширение ОТКАЗЫВАЕТСЯ ставиться: собрать образ, который молча
# получит софтовое кодирование, хуже, чем не собрать его вовсе.
WHEEL_TAG=""
WHEEL_FILE=""
WHEEL_SHA256=""
PIXELFLUX_VERSION="2.1.0"
WHEEL_ABI="cp312"

# --- преграды -----------------------------------------------------------------

if [[ -z "$WHEEL_TAG" || -z "$WHEEL_FILE" || -z "$WHEEL_SHA256" ]]; then
    log_error "закрепление колеса не заполнено: бэкенд v4l2m2m ещё не в апстриме"
    log_error "следите за selkies-project/pixelflux#35; после мерджа впишите тег коммита, имя файла и sha256"
    exit 1
fi

case "$(dpkg --print-architecture)" in
    arm64) ;;
    *) log_error "закреплённое колесо собрано под arm64, а образ — $(dpkg --print-architecture)"; exit 1 ;;
esac

# Устройства внутри virt-customize не пробрасываются, поэтому проверить наличие
# M2M-узла на фазе сборки НЕЛЬЗЯ, и гейта по железу здесь нет: расширение
# ставится там, где его указали в VMFILE. Решение «железо или софт» принимает
# сам бэкенд в рантайме, а живую проверку берёт на себя configure.sh.
for f in configure.sh verify-pixelflux-v4l2m2m.service lib/rc0-compat.py; do
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

ABI="$("$SELKIES_PY" -c 'import sys; print(f"cp{sys.version_info.major}{sys.version_info.minor}")')"
if [[ "$ABI" != "$WHEEL_ABI" ]]; then
    log_error "питон AppImage — $ABI, а закреплённое колесо собрано под $WHEEL_ABI"
    log_error "поднялась версия Selkies: нужно новое колесо под этот ABI (или релиз, и тогда расширение почти не нужно)"
    exit 1
fi
SITE="$("$SELKIES_PY" -c 'import site; print(site.getsitepackages()[0])')"
[[ -d "$SITE/selkies" ]] || { log_error "в $SITE нет пакета selkies — раскладка AppImage сменилась"; exit 1; }

# --- отпечаток ----------------------------------------------------------------
STAMP="$PREFIX/.bisquite-pixelflux-v4l2m2m"
STAMP_NOW="wheel=$WHEEL_TAG sha256=$WHEEL_SHA256 abi=$ABI version=$PIXELFLUX_VERSION compat=rc0"
if [[ -f "$STAMP" ]] && [[ "$(cat "$STAMP")" == "$STAMP_NOW" ]]; then
    log_info "уже установлено (отпечаток совпал) — ничего не делаю"
    exit 0
fi

# --- колесо -------------------------------------------------------------------

WORK="$(mktemp -d /var/tmp/pixelflux-v4l2m2m.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

command -v curl >/dev/null 2>&1 || { apt-get update -q && apt-get install -y -q curl ca-certificates; } || exit 1

URL="https://github.com/selkies-project/pixelflux/releases/download/$WHEEL_TAG/$WHEEL_FILE"
log_info "скачиваю $URL"
curl -fL --retry 5 --retry-delay 5 --connect-timeout 30 \
     --speed-limit 10240 --speed-time 60 --no-progress-meter \
     -o "$WORK/$WHEEL_FILE" "$URL" \
    || { log_error "колесо не скачалось: $URL"; exit 1; }

if ! echo "$WHEEL_SHA256  $WORK/$WHEEL_FILE" | sha256sum -c --quiet -; then
    log_error "sha256 колеса не совпал с закреплённым"
    exit 1
fi

log_info "ставлю колесо питоном AppImage"
"$SELKIES_PY" -m pip install --no-deps --force-reinstall --no-index \
    --root-user-action=ignore "$WORK/$WHEEL_FILE" >/dev/null \
    || { log_error "pip не поставил колесо"; exit 1; }

# --- совместимость Selkies 2.0.0rc0 с новым pixelflux -------------------------
# Девять правок в двух группах: переименования питоньего API и смена формата
# кадра на проводе. Пропустить вторую половину — получить сессию, которая
# кодирует, и клиента, который бесконечно просит ключевой кадр.
"$SELKIES_PY" "$SCRIPT_DIR/lib/rc0-compat.py" --site "$SITE" \
    || { log_error "правки совместимости не легли — см. отказы выше"; exit 1; }

# --- проверки фазы build ------------------------------------------------------
# Живой проверки «Encoder: V4L2M2M» здесь быть не может: virt-customize не
# пробрасывает устройства, в appliance нет ни /dev/video*, ни X.
GOT="$("$SELKIES_PY" -c 'import importlib.metadata as m; print(m.version("pixelflux"))' 2>/dev/null || true)"
if [[ "$GOT" != "$PIXELFLUX_VERSION" ]]; then
    log_error "после установки pixelflux сообщает версию '$GOT', ожидалась $PIXELFLUX_VERSION"
    exit 1
fi
"$SELKIES_PY" -c 'import pixelflux; pixelflux.CaptureSettings().codec' \
    || { log_error "модуль не импортируется или у CaptureSettings нет поля codec"; exit 1; }
MODULE_SO="$SITE/pixelflux.cpython-312-aarch64-linux-gnu.so"
# grep читает двоичный файл сам (-a): конвейер `strings | grep -q` под
# `set -o pipefail` возвращает ошибку именно при УСПЕХЕ.
if ! grep -qa "V4L2 M2M encoder on" "$MODULE_SO"; then
    log_error "в модуле нет бэкенда v4l2m2m — колесо собрано без него"
    exit 1
fi
"$SELKIES_PY" "$SCRIPT_DIR/lib/rc0-compat.py" --site "$SITE" --check >/dev/null \
    || { log_error "перепроверка правок не прошла"; exit 1; }

# --- первая загрузка ----------------------------------------------------------
install -m 0644 "$SCRIPT_DIR/verify-pixelflux-v4l2m2m.service" \
    /etc/systemd/system/verify-pixelflux-v4l2m2m.service
chmod +x "$SCRIPT_DIR/configure.sh"
install -d /etc/systemd/system/graphical.target.wants
ln -sf /etc/systemd/system/verify-pixelflux-v4l2m2m.service \
    /etc/systemd/system/graphical.target.wants/verify-pixelflux-v4l2m2m.service

printf '%s' "$STAMP_NOW" > "$STAMP"
chmod 0644 "$STAMP"
log_info "pixelflux $PIXELFLUX_VERSION с бэкендом v4l2m2m установлен в $PREFIX"
