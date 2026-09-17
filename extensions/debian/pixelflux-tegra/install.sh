#!/usr/bin/env bash
# Аппаратное кодирование H.264 в Selkies на Jetson: подменяет pixelflux внутри
# AppImage, поставленного расширением selkies, официальным колесом апстрима
# с бэкендом Tegra.
#
# ЗАЧЕМ. Selkies на Jetson кодирует экран ПРОЦЕССОРОМ, и причина не в нём:
# внутри AppImage лежит pixelflux, у которого до 17.09.2026 не было бэкенда для
# Tegra — L4T не поставляет libnvidia-encode, не публикует драйвер render-узла
# для VA-API, а кодер спрятан за вендорской libnvv4l2.so. Замер на AGX Orin,
# 1080p30, живая сессия с браузером: 0.089 ядра против 0.423 на x264.
#
# ПОЧЕМУ ОТДЕЛЬНОЕ РАСШИРЕНИЕ, А НЕ ПРАВКА selkies. Расширение selkies общее
# с amd64, где Selkies работает и без этого; подкладка системной libxcb в чужое
# окружение там ни к чему. Плюс подмена чужого артефакта должна быть видна
# строкой в VMFILE, а не спрятана в общем расширении.
#
# ЧТО ЗДЕСЬ ВРЕМЕННОЕ. rc0-compat.py — отделяемая половина: он нужен только
# потому, что последний релиз Selkies старше pixelflux (ишью апстрима #395).
# Подкладка libxcb (ишью #396) нужна при любой версии, пока AppImage несёт
# свою libxcb: без неё сессия умирает через несколько секунд после старта
# захвата — проверено и на релизе, и на сборке main.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} pixelflux-tegra: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} pixelflux-tegra: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} pixelflux-tegra: $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Колесо апстрима: предрелиз, который CI публикует на каждый коммит main.
# Тег — не «последний», а конкретный: «последний» менялся бы под ногами, а
# sha256 сторожит содержимое.
WHEEL_TAG="b111570"
WHEEL_FILE="pixelflux-2.1.0-cp312-cp312-manylinux_2_28_aarch64.whl"
WHEEL_SHA256="8cfc42acfdb6b3b4ffdf0971671c9a301cf9e568a4cc4c8e8bca9190b732a19e"
PIXELFLUX_VERSION="2.1.0"
# Одно колесо годится обеим платам: manylinux_2_28 старее и focal (glibc 2.31),
# и jammy (2.35).
WHEEL_ABI="cp312"

SYSTEM_LIBXCB="/usr/lib/aarch64-linux-gnu/libxcb.so.1"
SHIM_DIR="/opt/bisquite/pixelflux-tegra-runtime"
DROPIN_DIR="/etc/systemd/system/selkies@.service.d"

# --- преграды -----------------------------------------------------------------

if [[ ! -f /etc/nv_tegra_release ]]; then
    log_error "в образе нет /etc/nv_tegra_release — это не образ NVIDIA Jetson (L4T)"
    exit 1
fi
log_info "L4T: $(head -n 1 /etc/nv_tegra_release)"

case "$(dpkg --print-architecture)" in
    arm64) ;;
    *) log_error "архитектура $(dpkg --print-architecture): бэкенд Tegra существует только на arm64"; exit 1 ;;
esac

for f in rc0-compat.py gbm_shim.c configure.sh verify-pixelflux-tegra.service \
         lib/get_cloud_user.sh; do
    [[ -f "$SCRIPT_DIR/$f" ]] || { log_error "рядом нет $f — расширение доставлено не целиком"; exit 1; }
done

# Порядок строк в VMFILE bisquite не сортирует, поэтому единственная настоящая
# преграда против «поставили раньше selkies» — вот эта.
PREFIX="$(readlink -f /opt/selkies/current 2>/dev/null || true)"
SELKIES_PY="$PREFIX/usr/conda/bin/python"
if [[ -z "$PREFIX" || ! -x "$SELKIES_PY" ]]; then
    log_error "нет /opt/selkies/current/usr/conda/bin/python"
    log_error "EXTENSION pixelflux-tegra обязан идти ПОСЛЕ EXTENSION selkies"
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
# PREFIX у selkies — /opt/selkies/${SELKIES_VERSION}, то есть подъём версии
# AppImage даёт НОВЫЙ каталог. Без отпечатка повторная установка приняла бы его
# за уже пропатченный.
STAMP="$PREFIX/.bisquite-pixelflux-tegra"
STAMP_NOW="wheel=$WHEEL_TAG sha256=$WHEEL_SHA256 abi=$ABI version=$PIXELFLUX_VERSION compat=rc0"
if [[ -f "$STAMP" ]] && [[ "$(cat "$STAMP")" == "$STAMP_NOW" ]]; then
    log_info "уже установлено (отпечаток совпал) — ничего не делаю"
    exit 0
fi

# --- колесо -------------------------------------------------------------------

WORK="$(mktemp -d /var/tmp/pixelflux-tegra.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

command -v curl >/dev/null 2>&1 || { apt-get update -q && apt-get install -y -q curl ca-certificates; } || exit 1

URL="https://github.com/selkies-project/pixelflux/releases/download/$WHEEL_TAG/$WHEEL_FILE"
log_info "скачиваю $URL"
# --speed-limit/--speed-time превращают зависшую передачу в повтор: на Wi-Fi
# платы скачивание AppImage однажды встало на 76 из 535 МБ, и curl ждал час.
curl -fL --retry 5 --retry-delay 5 --connect-timeout 30 \
     --speed-limit 10240 --speed-time 60 --no-progress-meter \
     -o "$WORK/$WHEEL_FILE" "$URL" \
    || { log_error "колесо не скачалось: $URL"; exit 1; }

if ! echo "$WHEEL_SHA256  $WORK/$WHEEL_FILE" | sha256sum -c --quiet -; then
    log_error "sha256 колеса не совпал с закреплённым"
    exit 1
fi

# --no-deps: зависимости уже в AppImage, и тянуть их из сети незачем.
# --no-index: ставится ровно этот файл, а не «что-нибудь похожее с PyPI».
log_info "ставлю колесо питоном AppImage"
"$SELKIES_PY" -m pip install --no-deps --force-reinstall --no-index \
    --root-user-action=ignore "$WORK/$WHEEL_FILE" >/dev/null \
    || { log_error "pip не поставил колесо"; exit 1; }

# --- совместимость Selkies 2.0.0rc0 с новым pixelflux -------------------------

"$SELKIES_PY" "$SCRIPT_DIR/rc0-compat.py" --site "$SITE" \
    || { log_error "правки совместимости не легли — см. отказы выше"; exit 1; }

# --- шим gbm (только focal) ---------------------------------------------------
# В Mesa focal нет gbm_bo_create_with_modifiers2, и `import pixelflux` там
# падает — любой, и наш, и апстримовый. Собирается в госте, потому что готовый
# .so пришлось бы держать в репозитории двоичным файлом.
PRELOAD="$SYSTEM_LIBXCB"
SYSTEM_LIBGBM="/usr/lib/aarch64-linux-gnu/libgbm.so.1"
# Сравнение через case, а не через конвейер с grep -q: тот под `pipefail`
# отвечает ошибкой на совпадение и собрал бы шим там, где он не нужен.
GBM_SYMS=""
[[ -e "$SYSTEM_LIBGBM" ]] && GBM_SYMS="$(nm -D --defined-only "$SYSTEM_LIBGBM" 2>/dev/null || true)"
if [[ -e "$SYSTEM_LIBGBM" ]] && [[ "$GBM_SYMS" != *gbm_bo_create_with_modifiers2* ]]; then
    log_info "в системной libgbm нет gbm_bo_create_with_modifiers2 — собираю шим"
    command -v gcc >/dev/null 2>&1 || { apt-get update -q && apt-get install -y -q gcc; } || exit 1
    install -d "$SHIM_DIR"
    gcc -shared -fPIC -O2 -o "$SHIM_DIR/gbm_shim.so" "$SCRIPT_DIR/gbm_shim.c" \
        || { log_error "шим не собрался"; exit 1; }
    chmod 0644 "$SHIM_DIR/gbm_shim.so"
    PRELOAD="$SHIM_DIR/gbm_shim.so:$PRELOAD"
else
    log_info "системная libgbm полная — шим не нужен"
fi

# --- подкладка через drop-in ---------------------------------------------------
# Правка run-selkies.sh дала бы общему расширению скрытую обратную зависимость
# от нашего и подложила бы системную libxcb в чужое окружение на amd64.
[[ -e "$SYSTEM_LIBXCB" ]] || { log_error "в образе нет $SYSTEM_LIBXCB — без неё сессия падает"; exit 1; }
install -d "$DROPIN_DIR"
cat > "$DROPIN_DIR/10-pixelflux-tegra.conf" <<EOF
[Service]
# AppImage несёт свою libxcb (conda, 1.17), а X/EGL NVIDIA в L4T собран против
# системной: смешение роняет поток захвата через несколько секунд после старта.
# Подробности — ишью апстрима selkies-project/selkies#396.
Environment=LD_PRELOAD=$PRELOAD
EOF
chmod 0644 "$DROPIN_DIR/10-pixelflux-tegra.conf"
log_info "подкладка: LD_PRELOAD=$PRELOAD"

# --- проверки фазы build ------------------------------------------------------
# Живой проверки «Encoder: TEGRA» здесь быть не может: virt-customize не
# пробрасывает устройства, в appliance нет ни /dev/v4l2-nvenc, ни X. Поэтому
# проверяется всё, что проверяемо без железа, а железную часть берёт на себя
# configure.sh на первой загрузке.
GOT="$("$SELKIES_PY" -c 'import importlib.metadata as m; print(m.version("pixelflux"))' 2>/dev/null || true)"
if [[ "$GOT" != "$PIXELFLUX_VERSION" ]]; then
    log_error "после установки pixelflux сообщает версию '$GOT', ожидалась $PIXELFLUX_VERSION"
    exit 1
fi
# С той же подкладкой, что получит сессия: на focal без шима gbm модуль не
# импортируется вовсе, и проверка без LD_PRELOAD проверяла бы не то окружение.
LD_PRELOAD="$PRELOAD" "$SELKIES_PY" -c 'import pixelflux; pixelflux.CaptureSettings().codec' \
    || { log_error "модуль не импортируется или у CaptureSettings нет поля codec"; exit 1; }
MODULE_SO="$SITE/pixelflux.cpython-312-aarch64-linux-gnu.so"
# grep читает двоичный файл сам (-a): конвейер `strings | grep -q` под
# `set -o pipefail` возвращает ошибку именно при УСПЕХЕ — grep закрывает канал
# первым совпадением, и strings получает SIGPIPE.
if ! grep -qa "vendor V4L2 encoder" "$MODULE_SO"; then
    log_error "в модуле нет бэкенда Tegra — колесо собрано без него"
    exit 1
fi
"$SELKIES_PY" "$SCRIPT_DIR/rc0-compat.py" --site "$SITE" --check >/dev/null \
    || { log_error "перепроверка правок не прошла"; exit 1; }

# --- первая загрузка ----------------------------------------------------------
install -m 0644 "$SCRIPT_DIR/verify-pixelflux-tegra.service" \
    /etc/systemd/system/verify-pixelflux-tegra.service
chmod +x "$SCRIPT_DIR/configure.sh"
# Включение ссылкой: внутри virt-customize systemd не работает.
install -d /etc/systemd/system/graphical.target.wants
ln -sf /etc/systemd/system/verify-pixelflux-tegra.service \
    /etc/systemd/system/graphical.target.wants/verify-pixelflux-tegra.service

printf '%s' "$STAMP_NOW" > "$STAMP"
chmod 0644 "$STAMP"
log_info "pixelflux $PIXELFLUX_VERSION с бэкендом Tegra установлен в $PREFIX"
