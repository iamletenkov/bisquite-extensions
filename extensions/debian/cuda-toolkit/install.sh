#!/usr/bin/env bash
# Поставить CUDA Toolkit из репозитория NVIDIA jetson/common, уже
# подключённого пакетом nvidia-l4t-apt-source (часть L4T BSP).
#
# ПОЧЕМУ БЕЗ СВОЕГО apt-репозитория. В отличие от amd64-мира (cuda-repo-*
# из developer.download.nvidia.com), у Jetson репозиторий уже есть в
# rootfs: /etc/apt/sources.list.d/nvidia-l4t-apt-source.list ставит
#   deb https://repo.download.nvidia.com/jetson/common r36.4 main
#   deb https://repo.download.nvidia.com/jetson/t234 r36.4 main
# ещё при сборке базового образа (см. nvidia-jetpack). Заводить второй
# источник значило бы либо продублировать то, что уже есть, либо конфликтом
# версий развалить apt на ровном месте.
#
# ПОЧЕМУ `cuda-toolkit`, А НЕ `cuda`. Пакет `cuda` тянет ещё и драйвер
# (`cuda-drivers`) — на Jetson он не нужен и не существует в этом виде:
# GPU-стек тут часть L4T (nvidia-l4t-core и её же ветка), а не отдельный
# NVIDIA-драйвер, который ставит cuda-drivers на дискретных картах.
# `cuda-toolkit` берёт компилятор и библиотеки без этого хвоста — проверено
# на живой плате (JetPack 6.2.1, L4T 36.4.3): версия 12.6.11-1, источник
# jetson/common r36.4/main, 2026-09-12.
#
# PATH/LD_LIBRARY_PATH. Deb-пакет CUDA, в отличие от runfile-инсталлятора,
# профиль сам не прописывает — так документирует сама NVIDIA (post-install
# actions в CUDA Installation Guide). Без этого `nvcc` не найдётся в PATH
# ни у одного пользователя, включая root. Правим через /etc/profile.d —
# системно, один раз при сборке, а не в домашнем каталоге пользователя,
# которого при сборке ещё нет.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} cuda-toolkit: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} cuda-toolkit: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} cuda-toolkit: $*"; }

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

# --- 1. Опознать Jetson ------------------------------------------------------
#
# Отказ, а не предупреждение — тот же довод, что у jetson-stats: молча
# поставленный мусор на чужой архитектуре хуже отказа, а `arch: [arm64]`
# в манифесте не ловит «arm64, но не Jetson».
TEGRA_RELEASE=/etc/nv_tegra_release
if [[ ! -f "$TEGRA_RELEASE" ]]; then
    log_error "в образе нет $TEGRA_RELEASE — это не образ NVIDIA Jetson (L4T)"
    log_error "источник пакетов (jetson/common) кладёт nvidia-l4t-apt-source,"
    log_error "и на другой платформе его в rootfs попросту нет"
    exit 1
fi
log_info "L4T: $(head -n 1 "$TEGRA_RELEASE")"

SOURCE_LIST=/etc/apt/sources.list.d/nvidia-l4t-apt-source.list
if [[ ! -f "$SOURCE_LIST" ]]; then
    log_error "нет $SOURCE_LIST — источник jetson/common не подключён"
    log_error "проверь, что nvidia-jetpack (шаг сборки базового образа L4T)"
    log_error "действительно применён к этому дереву"
    exit 1
fi

# --- 2. Установка ------------------------------------------------------------
log_info "apt-get update"
apt_retry apt-get update -q || exit 1

log_info "ставлю cuda-toolkit (может занять несколько минут — набор большой)"
apt_retry apt-get install "${APT_OPTS[@]}" cuda-toolkit || {
    log_error "cuda-toolkit не установился"
    exit 1
}

# --- 3. Путь окружения --------------------------------------------------------
# cuda-toolkit кладёт себя в /usr/local/cuda-<версия> и симлинк
# /usr/local/cuda -> /usr/local/cuda-<версия>; версию не прибиваем, чтобы
# обновление пакета не оставило профиль указывающим в никуда.
CUDA_HOME=/usr/local/cuda
if [[ ! -e "$CUDA_HOME" ]]; then
    log_error "$CUDA_HOME не появился — пакет поставился, но раскладка другая"
    log_error "$(ls -d /usr/local/cuda-* 2>/dev/null || echo 'cuda-* каталогов нет вовсе')"
    exit 1
fi

cat > /etc/profile.d/cuda-toolkit.sh <<'PROFILEEOF'
# Добавлено расширением cuda-toolkit. Системный профиль, а не .bashrc:
# CUDA нужен любому пользователю, а не только тому, кто ставил образ.
export PATH="/usr/local/cuda/bin${PATH:+:${PATH}}"
export LD_LIBRARY_PATH="/usr/local/cuda/lib64${LD_LIBRARY_PATH:+:${LD_LIBRARY_PATH}}"
PROFILEEOF
chmod 0644 /etc/profile.d/cuda-toolkit.sh

log_info "готово: $(readlink -f "$CUDA_HOME")"
log_info "nvcc появится в PATH после новой сессии входа (profile.d читается при логине)"
