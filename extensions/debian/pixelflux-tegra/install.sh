#!/usr/bin/env bash
# Аппаратное кодирование H.264/H.265 в Selkies на Jetson.
#
# С Selkies 2.0.0rc1 подменять колесо больше не нужно: релиз несёт pixelflux
# 2.1.0rc1 с бэкендом Tegra. Но одно расширение всё равно требуется — и вот
# почему.
#
# ПОДКЛАДКА libxcb (ишью апстрима selkies#396). AppImage несёт свою libxcb
# (conda 1.17), а X/EGL NVIDIA в L4T собран против системной; смешение роняет
# поток захвата через несколько секунд после старта. Апстрим починил это в
# AppRun, но наша служба selkies@ запускает бинарь МИМО AppRun (run-selkies.sh
# цепляется к живой X-сессии, а не поднимает Xvfb), поэтому подкладку системной
# libxcb ставим сами — drop-in к юниту.
#
# ШИМ gbm (focal). В Mesa focal нет gbm_bo_create_with_modifiers2; собираем
# крошечный шим, если системная libgbm без этого символа. На jammy не нужен.
#
# ПОЧЕМУ ОТДЕЛЬНОЕ РАСШИРЕНИЕ, А НЕ ПРАВКА selkies. Расширение selkies общее
# с amd64, где подкладка системной libxcb ни к чему; требование этой подкладки
# должно быть видно строкой в VMFILE, а не спрятано в общем расширении.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} pixelflux-tegra: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} pixelflux-tegra: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} pixelflux-tegra: $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

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

for f in gbm_shim.c configure.sh verify-pixelflux-tegra.service lib/get_cloud_user.sh; do
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

# --- шим gbm (только focal) ---------------------------------------------------
# В Mesa focal нет gbm_bo_create_with_modifiers2, и на такой системе `import
# pixelflux` может падать. Собирается в госте, потому что готовый .so пришлось
# бы держать в репозитории двоичным файлом.
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

# --- проверка фазы build ------------------------------------------------------
# Живой проверки «Encoder: TEGRA» здесь быть не может: virt-customize не
# пробрасывает устройства, в appliance нет ни /dev/v4l2-nvenc, ни X. Поэтому
# проверяется всё, что проверяемо без железа, а железную часть берёт на себя
# configure.sh на первой загрузке.
#
# С той же подкладкой, что получит сессия: на focal без шима gbm модуль может не
# импортироваться вовсе, и проверка без LD_PRELOAD проверяла бы не то окружение.
LD_PRELOAD="$PRELOAD" "$SELKIES_PY" -c 'import pixelflux; pixelflux.CaptureSettings().codec' \
    || { log_error "модуль не импортируется или у CaptureSettings нет поля codec"; exit 1; }
MODULE_SO="$("$SELKIES_PY" -c 'import pixelflux; print(pixelflux.__file__)' 2>/dev/null || true)"
[[ -f "$MODULE_SO" ]] || { log_error "не удалось найти модуль pixelflux в AppImage"; exit 1; }
# grep читает двоичный файл сам (-a): конвейер `strings | grep -q` под
# `set -o pipefail` возвращает ошибку именно при УСПЕХЕ — grep закрывает канал
# первым совпадением, и strings получает SIGPIPE.
if ! grep -qa "vendor V4L2 encoder" "$MODULE_SO"; then
    log_error "в базовом pixelflux нет бэкенда Tegra — Selkies собран без него"
    log_error "модуль: $MODULE_SO"
    exit 1
fi
log_info "базовый pixelflux несёт бэкенд Tegra"

# --- отпечаток и первая загрузка ----------------------------------------------
# PREFIX у selkies — /opt/selkies/${SELKIES_VERSION}, то есть подъём версии
# AppImage даёт НОВЫЙ каталог. Без отпечатка повторная установка приняла бы его
# за уже настроенный.
STAMP="$PREFIX/.bisquite-pixelflux-tegra"
printf '%s' "preload=$PRELOAD prefix=$PREFIX" > "$STAMP"
chmod 0644 "$STAMP"

install -m 0644 "$SCRIPT_DIR/verify-pixelflux-tegra.service" \
    /etc/systemd/system/verify-pixelflux-tegra.service
chmod +x "$SCRIPT_DIR/configure.sh"
# Включение ссылкой: внутри virt-customize systemd не работает.
install -d /etc/systemd/system/graphical.target.wants
ln -sf /etc/systemd/system/verify-pixelflux-tegra.service \
    /etc/systemd/system/graphical.target.wants/verify-pixelflux-tegra.service

log_info "подкладка Tegra настроена; служба verify подтвердит железо на первой загрузке"
