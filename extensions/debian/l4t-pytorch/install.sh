#!/usr/bin/env bash
# PyTorch и torchvision с CUDA для Jetson (JetPack 6, L4T 36.4).
#
# ЧТО СТАВИТСЯ И ОТКУДА — всё с CDN NVIDIA, GitHub и PyPI:
#
#   torch 2.5.0 nv24.08   колесо NVIDIA для JetPack 6.1, работает и на 6.2
#                         (тот же CUDA 12.6); проверено на плате с GPU
#   cuDNN 9.3             apt, jetson/common (libcudnn9-cuda-12)
#   cuSPARSELt 0.6.2.3    архив NVIDIA redist, сборка linux-aarch64
#   numpy 1.26.4          PyPI
#   torchvision 0.20.0    ИСХОДНИКИ с GitHub, сборка с CUDA здесь же
#
# ПОЧЕМУ НЕ НОВЕЕ. torch 2.8–2.10 и готовый torchvision под Jetson есть
# только в индексе jetson-ai-lab (pypi.jetson-ai-lab.io), а из сети сборки
# он файлы не отдаёт: замер 2026-09-14 — каждая загрузка обрывается на
# 15 865 байтах при 25 Б/с, сама страница индекса при этом отвечает.
# Расширение, которое через раз висит на сборке, хуже старой версии.
# 2.5.0 nv24.08 — последнее, что NVIDIA публикует на своём CDN
# (developer.download.nvidia.com/compute/redist/jp/v61/pytorch/;
# каталога v62 нет вовсе).
#
# ПОЧЕМУ torchvision ИЗ ИСХОДНИКОВ. NVIDIA его под JetPack 6 не публикует,
# а колесо с PyPI собрано под PyPI-torch: его C++-операции (nms,
# roi_align, декодеры) с torch от NVIDIA по ABI несовместимы. Сборка на
# самой плате (12 ядер) — 128 с, колесо 1.4 МБ, и nms идёт на cuda:0.
# Внутри virt-customize ресурсы задаёт `bs image build --smp/--memsize`,
# см. README.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} l4t-pytorch: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} l4t-pytorch: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} l4t-pytorch: $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TORCH_WHEEL="torch-2.5.0a0+872d972e41.nv24.08.17622132-cp310-cp310-linux_aarch64.whl"
TORCH_URL="https://developer.download.nvidia.com/compute/redist/jp/v61/pytorch/${TORCH_WHEEL}"
TORCH_SHA256="6f75fd2d2ef840ede1a90dbcf40a5458214bee26cc803fa510cda2e8978d972a"

CUSPARSELT_URL="https://developer.download.nvidia.com/compute/cusparselt/redist/libcusparse_lt/linux-aarch64/libcusparse_lt-linux-aarch64-0.6.2.3-archive.tar.xz"
CUSPARSELT_SHA256="b081a82a884754fd7ab1f53aa9cd1a943d782b87268c3657991c287af3179811"
CUSPARSELT_DIR=/usr/local/cusparselt

TORCHVISION_REPO="https://github.com/pytorch/vision.git"
TORCHVISION_TAG="v0.20.0"
# Тег сверяется с коммитом: тег в чужом репозитории можно передвинуть,
# а сборка с CUDA длинная, и собрать не то — дорогая ошибка.
TORCHVISION_COMMIT="afc54f754c734d903a06194e416495e20d920ff6"
# 8.7 — Ampere в Orin (Orin Nano, NX, AGX). Другой вычислительной
# архитектуры JetPack 6 не поддерживает: Xavier (7.2) остался на JetPack 5.
TORCH_CUDA_ARCH_LIST="${TORCH_CUDA_ARCH_LIST:-8.7}"

apt_retry(){
    local max=5 n=1 d
    while true; do
        if "$@"; then return 0; fi
        if (( n >= max )); then return 1; fi
        d=$(( n * 2 )); log_warn "команда не отработала, повтор через ${d}s ($n/$max)"
        sleep "$d"; n=$(( n + 1 ))
    done
}

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-q -y -o Dpkg::Options::=--force-confnew)

if [[ ! -f /etc/nv_tegra_release ]]; then
    log_error "в образе нет /etc/nv_tegra_release — это не образ NVIDIA Jetson (L4T)"
    exit 1
fi
if [[ ! -x /usr/local/cuda/bin/nvcc ]]; then
    log_error "нет /usr/local/cuda/bin/nvcc — поставь EXTENSION cuda-toolkit раньше этого"
    exit 1
fi
PYVER="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
if [[ "$PYVER" != "3.10" ]]; then
    log_error "Python $PYVER, а колесо torch собрано под 3.10 (cp310) — это не jammy/L4T 36?"
    exit 1
fi

WORK="$(mktemp -d /var/tmp/l4t-pytorch.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# --- 1. Системные библиотеки ------------------------------------------------
#
# Список — по ldd libtorch_cpu.so и libtorch_cuda.so на плате: всё, что
# не из CUDA и не из самого колеса. libcusparseLt в apt нет — ниже.
# Остальное — для сборки torchvision: jpeg/png для torchvision.io,
# ninja ускоряет сборку расширений, git — для исходников.
log_info "apt: cuDNN 9 и системные библиотеки torch"
apt_retry apt-get update -q || exit 1
apt_retry apt-get install "${APT_OPTS[@]}" \
    libcudnn9-cuda-12 \
    libopenblas0-pthread libgomp1 libgfortran5 \
    python3-pip python3-dev git ninja-build \
    libjpeg-dev libpng-dev zlib1g-dev || {
    log_error "apt не поставил зависимости"
    exit 1
}

# --- 2. cuSPARSELt ------------------------------------------------------------
log_info "cuSPARSELt 0.6.2.3"
apt_retry curl -fsSL --max-time 600 -o "$WORK/cusparselt.tar.xz" "$CUSPARSELT_URL" || exit 1
echo "$CUSPARSELT_SHA256  $WORK/cusparselt.tar.xz" | sha256sum -c --quiet - || {
    log_error "контрольная сумма cuSPARSELt не совпала"
    exit 1
}
rm -rf "$CUSPARSELT_DIR"
install -d "$CUSPARSELT_DIR"
tar -xJf "$WORK/cusparselt.tar.xz" -C "$CUSPARSELT_DIR" --strip-components=1
echo "$CUSPARSELT_DIR/lib" > /etc/ld.so.conf.d/cusparselt.conf
ldconfig

# --- 3. numpy 1.26.4 и torch --------------------------------------------------
#
# NUMPY НЕ СИСТЕМНЫЙ, И ЭТО НЕ ВКУС. torch nv24.08 собран под C-API numpy
# 0x10 (ветка 1.23+), а в jammy numpy 1.21.5 (0xe). С системным numpy
# torch импортируется и считает на GPU, но любой мост torch↔numpy падает:
# `RuntimeError: Numpy is not available` (замер на плате).
#
# 1.26.4 — последняя 1.x: модули apt, собранные под 1.21, с ней работают
# (проверено: Gst, jtop, tensorrt, cv2 4.8.0), а 2.x их бы сломала.
# Ставится в /usr/local и перекрывает системный для всех, кто импортирует
# numpy из Python 3.10, — это и есть цель.
log_info "колесо torch (NVIDIA, 769 МБ)"
apt_retry curl -fsSL --max-time 1800 -o "$WORK/$TORCH_WHEEL" "$TORCH_URL" || exit 1
echo "$TORCH_SHA256  $WORK/$TORCH_WHEEL" | sha256sum -c --quiet - || {
    log_error "контрольная сумма колеса torch не совпала"
    exit 1
}

PIP=(python3 -m pip install --no-cache-dir --constraint "$SCRIPT_DIR/constraints.txt")
# scipy — вместе с numpy, см. constraints.txt.
log_info "pip: numpy, scipy, torch"
apt_retry "${PIP[@]}" numpy scipy "$WORK/$TORCH_WHEEL" || {
    log_error "pip не поставил torch"
    exit 1
}

# --- 4. torchvision из исходников -------------------------------------------
log_info "torchvision $TORCHVISION_TAG: исходники"
apt_retry git clone -q --depth 1 --branch "$TORCHVISION_TAG" "$TORCHVISION_REPO" "$WORK/vision" || exit 1
got="$(git -C "$WORK/vision" rev-parse HEAD)"
if [[ "$got" != "$TORCHVISION_COMMIT" ]]; then
    log_error "тег $TORCHVISION_TAG указывает на $got, ожидали $TORCHVISION_COMMIT"
    exit 1
fi

# Число параллельных компиляций — по памяти, а не по ядрам. Файл CUDA
# у nvcc съедает до ~1.5 ГБ, а в appliance virt-customize памяти столько,
# сколько дали `--memsize` (по умолчанию 2 ГБ): MAX_JOBS=nproc там убивал
# бы компилятор по OOM молча, посреди сборки.
mem_mb=$(( $(awk '/MemAvailable/{print $2}' /proc/meminfo) / 1024 ))
jobs=$(( mem_mb / 1536 )); (( jobs < 1 )) && jobs=1
(( jobs > $(nproc) )) && jobs=$(nproc)
log_info "сборка torchvision с CUDA $TORCH_CUDA_ARCH_LIST: $jobs потоков (память ${mem_mb} МБ, ядер $(nproc))"

(
    cd "$WORK/vision"
    export CUDA_HOME=/usr/local/cuda PATH="/usr/local/cuda/bin:$PATH"
    export FORCE_CUDA=1 TORCH_CUDA_ARCH_LIST BUILD_VERSION="${TORCHVISION_TAG#v}" MAX_JOBS="$jobs"
    python3 -m pip wheel --no-cache-dir --no-deps --no-build-isolation \
        --constraint "$SCRIPT_DIR/constraints.txt" -w "$WORK/wheels" . \
        > "$WORK/torchvision-build.log" 2>&1
) || {
    log_error "сборка torchvision упала, хвост журнала:"
    >&2 tail -40 "$WORK/torchvision-build.log"
    exit 1
}
apt_retry "${PIP[@]}" pillow "$WORK"/wheels/torchvision-*.whl || {
    log_error "pip не поставил собранный torchvision"
    exit 1
}

# --- 5. Проверка --------------------------------------------------------------
#
# Без GPU: внутри virt-customize его нет, и torch.cuda.is_available()
# честно ответит False. Проверяем то, что от сборки зависит: версии CUDA
# и cuDNN в самом torch, загрузку всех .so (включая cuSPARSELt),
# CUDA-операции torchvision и мост с numpy.
python3 - <<'PYEOF' || { log_error "проверка импорта не прошла"; exit 1; }
import warnings; warnings.simplefilter("error", UserWarning)  # numpy/scipy не в паре — отказ
import numpy, scipy, torch, torchvision
assert torch.version.cuda == "12.6", torch.version.cuda
assert torch.backends.cudnn.version() >= 90000, torch.backends.cudnn.version()
cuda_ops = torch.ops.torchvision._cuda_version()
assert cuda_ops > 0, "torchvision собран без CUDA"
assert torch.from_numpy(numpy.ones(3)).sum().item() == 3.0
print(f"torch {torch.__version__} (CUDA {torch.version.cuda}, cuDNN {torch.backends.cudnn.version()}), "
      f"torchvision {torchvision.__version__} (CUDA ops {cuda_ops}), numpy {numpy.__version__}, scipy {scipy.__version__}")
PYEOF
python3 "$SCRIPT_DIR/check-system-python.py" || {
    log_error "установка повредила системный Python — см. выше"
    exit 1
}
log_info "готово"
