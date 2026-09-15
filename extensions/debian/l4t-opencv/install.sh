#!/usr/bin/env bash
# OpenCV для Jetson из репозитория NVIDIA: cv2 4.8.0 с бэкендом GStreamer.
#
# ПОЧЕМУ NVIDIA 4.8.0, А НЕ python3-opencv ИЗ UBUNTU. Убунтовский — 4.5.4,
# и Python-модуль к нему в образе не стоит (замер на плате 2026-09-14:
# libopencv-*4.5d приехали зависимостями GStreamer-dev, а `import cv2`
# падал). NVIDIA собирает 4.8.0 под L4T с GStreamer, FFmpeg и V4L2 — ровно
# то, что нужно, чтобы взять кадр с камеры через аппаратный nvvidconv:
#
#   v4l2src ! video/x-raw,format=UYVY ! nvvidconv ! video/x-raw,format=BGRx
#     ! videoconvert ! video/x-raw,format=BGR ! appsink
#
# Проверено на плате: 30 кадров 1920×1080 с камеры Sensing в cv2.
#
# ЧЕГО В ЭТОЙ СБОРКЕ НЕТ — CUDA. Модуль cv2.cuda отсутствует. CUDA-сборка
# OpenCV готовой не существует нигде, кроме индекса jetson-ai-lab, а он
# из сети сборки файлы не отдаёт (замер 2026-09-14: каждая загрузка
# обрывается на 15 865 байтах при 25 Б/с). Своя сборка из исходников —
# час-два компиляции на каждый образ. На Jetson вычисления на GPU обычно
# и не идут через cv2.cuda: преобразование кадра делает nvvidconv, а сеть —
# TensorRT или PyTorch.
#
# ПОЧЕМУ ТОЛЬКО РАНТАЙМ И PYTHON, БЕЗ libopencv-dev ОТ NVIDIA. Он объявлен
# Conflicts с убунтовским libopencv-dev, и apt снёс бы его вместе
# с libgstreamer-plugins-bad1.0-dev, который от него зависит (замер:
# симуляция удаляла 19 пакетов -dev). Заголовки C++ в образе остаются
# убунтовские, 4.5.4 — `pkg-config opencv4` покажет именно их. Для C++
# с OpenCV 4.8 это ловушка, и она описана в README.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} l4t-opencv: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} l4t-opencv: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} l4t-opencv: $*"; }

apt_retry(){
    local max=5 n=1 d
    while true; do
        if "$@"; then return 0; fi
        if (( n >= max )); then return 1; fi
        d=$(( n * 2 )); log_warn "apt не отработал, повтор через ${d}s ($n/$max)"
        sleep "$d"; n=$(( n + 1 ))
    done
}

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-q -y -o Dpkg::Options::=--force-confnew)

if [[ ! -f /etc/nv_tegra_release ]]; then
    log_error "в образе нет /etc/nv_tegra_release — это не образ NVIDIA Jetson (L4T)"
    exit 1
fi

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/lib/l4t" ]] || { log_error "рядом нет lib/l4t — сборка не доставила lib/ источника"; exit 1; }
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/l4t"

# ВЕТКА R32 (Jetson Nano, JetPack 4.6): ПРОВЕРИТЬ И ЗАКРЕПИТЬ.
#
# В образе Q-engineering OpenCV 4.8.0 уже собран — и в отличие от ветки r36
# С CUDA 10.2 и GStreamer 1.16.3 (замер на живом Nano 2026-09-15). Ставить
# нечего и неоткуда: репозитории NVIDIA отключены. Ветка сверяет, что cv2
# импортируется и собран с CUDA и GStreamer, и отказывает, если нет.
#
# Одно она всё-таки меняет: OPENBLAS_CORETYPE=ARMV8 (см. lib/l4t). Без него
# `import cv2` на Cortex-A57 падает `Illegal instruction`, а вендорский
# образ экспортировал переменную из .bashrc удаляемой учётки jetson.
r32_verify(){
    local info
    l4t_openblas_pin l4t-opencv || { log_error "OPENBLAS_CORETYPE не записан"; return 1; }
    # Импорт — с окружением, собранным из записанных файлов, а не с export.
    l4t_openblas_check 'import cv2; print("cv2", cv2.__version__)' || return 1
    info="$(env -i OPENBLAS_CORETYPE="$L4T_OPENBLAS_CORETYPE" /usr/bin/python3 -c 'import cv2; print(cv2.getBuildInformation())' 2>&1)" || {
        log_error "cv2.getBuildInformation() не прошёл:"
        >&2 echo "$info"
        return 1
    }
    if ! grep -qE "^\s*NVIDIA CUDA:\s*YES" <<<"$info"; then
        log_error "cv2 собран без CUDA — это не образ Q-engineering с OpenCV под CUDA"
        return 1
    fi
    if ! grep -qE "^\s*GStreamer:\s*YES" <<<"$info"; then
        log_error "cv2 собран без GStreamer — кадры с камер через nvvidconv не взять"
        return 1
    fi
    log_info "готово (R32): cv2 с CUDA и GStreamer, ничего не ставилось"
}

if [[ "$(l4t_major || true)" == 32 ]]; then
    r32_verify || exit 1
    exit 0
fi

log_info "apt-get update"
apt_retry apt-get update -q || exit 1

# ОБА ПАКЕТА ЯВНО. libopencv-python от NVIDIA не объявляет зависимость
# от собственных библиотек: apt ставит один cv2, и импорт падает
# с `libopencv_ml.so.408: cannot open shared object file` (замер на плате).
log_info "ставлю libopencv и libopencv-python"
apt_retry apt-get install "${APT_OPTS[@]}" libopencv libopencv-python || {
    log_error "установка не прошла"
    exit 1
}
ldconfig || log_warn "ldconfig отработал с ошибкой"

# Импорт в chroot сборки работает: cv2 не трогает устройства при загрузке.
BUILD_INFO="$(python3 -c 'import cv2; print(cv2.__version__); print(cv2.getBuildInformation())' 2>&1)" || {
    log_error "import cv2 не прошёл:"
    >&2 echo "$BUILD_INFO"
    exit 1
}
log_info "cv2 $(head -n 1 <<<"$BUILD_INFO")"
if ! grep -qE "^\s*GStreamer:\s*YES" <<<"$BUILD_INFO"; then
    log_error "cv2 собран без GStreamer — кадры с камер через nvvidconv не взять"
    exit 1
fi
log_info "готово: GStreamer в cv2 есть, CUDA нет (см. шапку файла)"
