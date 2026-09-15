#!/usr/bin/env bash
# GStreamer для Jetson: аппаратные плагины NVIDIA плюс тот набор убунтовского
# GStreamer, который нужен роботу — камеры, RTSP, WebRTC, запись, Python.
#
# ПОЧЕМУ РАСШИРЕНИЕ, КОГДА ПОЛОВИНА УЖЕ БЫЛА В ОБРАЗЕ. В рабочей станции
# (тогда jetson-orin-workstation) убунтовский GStreamer приехал СЛУЧАЙНО — как
# зависимости GNOME и dev-пакетов из списка утилит. Безголовый робот поверх
# тогдашним jetson-orin-camera его бы не получил, а зависеть от того, что тянет
# рабочий стол, свойству «на роботе есть видео» нельзя. Замер на плате
# 2026-09-14: при всём этом не было ни nvidia-l4t-gstreamer (нет
# nvv4l2h264enc — аппаратного кодека), ни gstreamer1.0-nice (webrtcbin
# регистрируется, но на первом соединении падает — ICE ему нечем делать).
#
# Проверено на той же плате после установки ровно этого набора:
#   videotestsrc 1080p        → nvvidconv → nvv4l2h264enc → mp4, 10 с
#   ximagesrc рабочего стола  → nvvidconv → nvv4l2h264enc, 3840×2160
#   v4l2src камеры Sensing    → nvvidconv → nvv4l2h265enc, 1920×1080
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} l4t-gstreamer: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} l4t-gstreamer: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} l4t-gstreamer: $*"; }

# Заголовки и .pc для сборки своих приложений на GStreamer (C/C++, а также
# OpenCV из исходников с -DWITH_GSTREAMER=ON) и Jetson Multimedia API.
# Роботу в поле не нужны — 0 их снимает.
GSTREAMER_DEV="${GSTREAMER_DEV:-1}"
if [[ "$GSTREAMER_DEV" != 0 && "$GSTREAMER_DEV" != 1 ]]; then
    log_error "GSTREAMER_DEV='$GSTREAMER_DEV': только 0 или 1"
    exit 1
fi

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
log_info "L4T: $(head -n 1 /etc/nv_tegra_release)"

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/lib/l4t" ]] || { log_error "рядом нет lib/l4t — сборка не доставила lib/ источника"; exit 1; }
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/l4t"

# ВЕТКА R32 (Jetson Nano, JetPack 4.6): ПРОВЕРИТЬ, А НЕ СТАВИТЬ.
#
# Репозитории NVIDIA в образе Q-engineering отключены («disabled on upgrade
# to focal»), а собраны под bionic — включать их на focal нельзя. Плагины
# при этом в образе уже есть и работают (замер на живом Nano 2026-09-15:
# nvv4l2h264enc/h265enc, nvv4l2decoder, nvarguscamerasrc, пакет
# nvidia-l4t-gstreamer 32.6.1). Поэтому ветка сверяет то, ради чего
# расширение существует, и отказывает громко, если этого нет.
#
# Ревизия сравнивается по версии до дефиса: у пакетов R32 суффикс — дата
# сборки, и у одного стека он разный (на Nano core 32.6.1-20210726122000,
# gstreamer 32.6.1-20210916211029).
r32_verify(){
    local core gst missing=() so
    local gst_dir=/usr/lib/aarch64-linux-gnu/gstreamer-1.0
    core="$(dpkg-query -W -f='${Version}' nvidia-l4t-core 2>/dev/null || true)"
    gst="$(dpkg-query -W -f='${Version}' nvidia-l4t-gstreamer 2>/dev/null || true)"
    if [[ -z "$core" || -z "$gst" ]]; then
        log_error "нет пакета nvidia-l4t-core или nvidia-l4t-gstreamer (core='$core', gstreamer='$gst')"
        log_error "ветка R32 ничего не ставит: плагины NVIDIA обязаны быть в базовом образе"
        return 1
    fi
    if [[ "${core%%-*}" != "${gst%%-*}" ]]; then
        log_error "nvidia-l4t-gstreamer $gst не той ревизии, что nvidia-l4t-core $core"
        return 1
    fi
    # Файлами, а не gst-inspect-1.0 — довод тот же, что в конце ветки r36.
    for so in libgstnvvideo4linux2 libgstnvvidconv libgstnvarguscamerasrc; do
        [[ -f "$gst_dir/$so.so" ]] || missing+=("$so")
    done
    if (( ${#missing[@]} )); then
        log_error "не хватает плагинов NVIDIA: ${missing[*]}"
        return 1
    fi
    # WebRTC без libnice соединения не устанавливает; в образе Q-engineering
    # его нет. Не отказ: ставить на R32 нечем, а камеры и кодек работают.
    [[ -f "$gst_dir/libgstnice.so" ]] || log_warn "нет libgstnice.so: webrtcbin не установит соединение (ICE)"
    log_info "готово (R32): nvidia-l4t-gstreamer $gst, плагины NVIDIA на месте, ничего не ставилось"
}

if [[ "$(l4t_major || true)" == 32 ]]; then
    r32_verify || exit 1
    exit 0
fi

# ВЕРСИЯ ПЛАГИНОВ NVIDIA — ПО ВЕРСИИ СТЕКА, А НЕ ПО КАНДИДАТУ APT.
#
# Репозиторий r36.4 публикует обновления одной веткой: на 2026-09-14
# кандидат nvidia-l4t-gstreamer — 36.4.7, а стек в образе — 36.4.3.
# Зависимости у пакета мягкие (`nvidia-l4t-multimedia (>= 36.3.0)`),
# поэтому apt без возражений поставил бы плагин 36.4.7 поверх
# libnvbufsurface 36.4.3 — и ни одна проверка это не заметит, пока
# не разойдётся ABI. Берём ровно версию nvidia-l4t-core: она в том же
# репозитории есть (замер: 36.4.0, 36.4.3, 36.4.4, 36.4.7).
#
# Нет такой версии — отказ, а не откат на кандидата: смешанный стек
# хуже громкой ошибки на сборке.
L4T_VERSION="$(dpkg-query -W -f='${Version}' nvidia-l4t-core 2>/dev/null || true)"
if [[ -z "$L4T_VERSION" ]]; then
    log_error "nvidia-l4t-core не установлен — не с чем сверять версию плагинов"
    exit 1
fi
log_info "стек L4T: $L4T_VERSION"

log_info "apt-get update"
apt_retry apt-get update -q || exit 1

# Список версий — в переменную, и grep по herestring: `… | grep -q` под
# pipefail роняет конвейер по SIGPIPE, и проверка врёт (на этом уже
# дважды падала сборка — gnome и tensorrt).
AVAILABLE="$(apt-cache madison nvidia-l4t-gstreamer | awk '{print $3}')"
if ! grep -qxF "$L4T_VERSION" <<<"$AVAILABLE"; then
    log_error "в репозитории нет nvidia-l4t-gstreamer=$L4T_VERSION"
    log_error "есть: $(paste -sd' ' <<<"$AVAILABLE")"
    exit 1
fi

PKGS=(
    "nvidia-l4t-gstreamer=$L4T_VERSION"

    # Ядро и базовые плагины. gstreamer1.0-libav — программные декодеры
    # (avdec_h264 и пр.) на случай потока, который аппаратный декодер
    # не берёт.
    gstreamer1.0-tools
    gstreamer1.0-plugins-base
    gstreamer1.0-plugins-good
    gstreamer1.0-plugins-bad
    gstreamer1.0-plugins-ugly
    gstreamer1.0-libav

    # Вывод и захват экрана: ximagesrc (x), glimagesink (gl).
    gstreamer1.0-x
    gstreamer1.0-gl

    # Звук — для записи и WebRTC с микрофона.
    gstreamer1.0-alsa
    gstreamer1.0-pulseaudio

    # RTSP: клиент (rtspsrc) есть в good, а СЕРВЕР — отдельная библиотека.
    # Раздавать камеры по RTSP — самый частый способ отдать видео с робота.
    gstreamer1.0-rtsp
    libgstrtspserver-1.0-0
    gir1.2-gst-rtsp-server-1.0

    # WebRTC (webrtcbin в bad) без libnice не устанавливает соединение:
    # элемент регистрируется, gst-inspect его показывает, а падает он уже
    # на ICE. Нужен и Selkies, и любому своему WebRTC-стримеру.
    gstreamer1.0-nice

    # Python-конвейеры: Gst, GstWebRTC/GstSdp (из plugins-bad), GstRtspServer.
    python3-gi
    python3-gst-1.0
    gir1.2-gstreamer-1.0
    gir1.2-gst-plugins-base-1.0
    gir1.2-gst-plugins-bad-1.0

    # v4l2-ctl: форматы и контролы камер, без него отладка v4l2src вслепую.
    v4l-utils
)
if [[ "$GSTREAMER_DEV" == 1 ]]; then
    PKGS+=(
        libgstreamer1.0-dev
        libgstreamer-plugins-base1.0-dev
        libgstreamer-plugins-bad1.0-dev
        libgstrtspserver-1.0-dev
        # Jetson Multimedia API — заголовки и примеры прямой работы
        # с аппаратным кодеком мимо GStreamer. Версия — та же, что у стека.
        "nvidia-l4t-jetson-multimedia-api=$L4T_VERSION"
    )
fi

log_info "ставлю ${#PKGS[@]} пакетов (dev: $GSTREAMER_DEV)"
apt_retry apt-get install "${APT_OPTS[@]}" "${PKGS[@]}" || {
    log_error "установка не прошла"
    exit 1
}

# ПРОВЕРКА ФАЙЛАМИ, А НЕ gst-inspect-1.0.
#
# Внутри virt-customize гость не загружен: нет /dev/nvhost-*, нет
# /dev/v4l2-nvenc, и плагины NVIDIA при сканировании реестра отваливаются
# по причинам, которых на плате не будет. gst-inspect здесь дал бы ложный
# отказ. Проверяем, что на месте именно те плагины, ради которых
# расширение существует, и что версия стека не уползла.
GST_DIR=/usr/lib/aarch64-linux-gnu/gstreamer-1.0
missing=()
for so in libgstnvvideo4linux2 libgstnvvidconv libgstnvarguscamerasrc \
          libgstnvv4l2camerasrc libgstnvcompositor libgstnvjpeg \
          libgstnice libgstwebrtc libgstx264 libgstximagesrc libgstrtsp; do
    [[ -f "$GST_DIR/$so.so" ]] || missing+=("$so")
done
if (( ${#missing[@]} )); then
    log_error "не хватает плагинов: ${missing[*]}"
    exit 1
fi

AFTER="$(dpkg-query -W -f='${Version}' nvidia-l4t-core)"
if [[ "$AFTER" != "$L4T_VERSION" ]]; then
    log_error "стек L4T сдвинулся при установке: $L4T_VERSION → $AFTER"
    exit 1
fi

log_info "готово: nvidia-l4t-gstreamer $L4T_VERSION, GStreamer $(dpkg-query -W -f='${Version}' libgstreamer1.0-0)"
