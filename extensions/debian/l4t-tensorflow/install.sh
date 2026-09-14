#!/usr/bin/env bash
# TensorFlow с CUDA для Jetson (JetPack 6, L4T 36.4): колесо NVIDIA.
#
#   tensorflow 2.16.1 nv24.08   CDN NVIDIA, сборка под JetPack 6.1 (CUDA 12.6),
#                               работает и на 6.2 — проверено обучением на GPU
#   cuDNN 9.3                   apt, jetson/common
#   keras 3.3.3                 PyPI, та, с которой вышел TF 2.16
#   numpy 1.26.4, scipy 1.13.1  PyPI, те же, что у l4t-pytorch
#
# ЭТО ПОСЛЕДНЯЯ ВЕРСИЯ, И НОВОЙ НЕ БУДЕТ. NVIDIA публикует TF для Jetson
# на developer.download.nvidia.com/compute/redist/jp/, и последний каталог
# с TF — v61 (август 2024); каталога v62 нет. Индекс jetson-ai-lab отдаёт
# под именем tensorflow обычные колёса PyPI (cp313, без CUDA для Jetson).
# То есть расширение закрывает старые модели и код на TF/Keras, а не
# открывает дорогу вперёд — это надо знать, прежде чем тащить 1.9 ГБ
# в образ.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} l4t-tensorflow: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} l4t-tensorflow: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} l4t-tensorflow: $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

TF_WHEEL="tensorflow-2.16.1+nv24.08-cp310-cp310-linux_aarch64.whl"
TF_URL="https://developer.download.nvidia.com/compute/redist/jp/v61/tensorflow/${TF_WHEEL}"
TF_SHA256="ee3cd33c24f75ec9d429580499ae9c7bfdcb4a833b4e92e8b3b1092659fb287c"

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
if [[ ! -d /usr/local/cuda/lib64 ]]; then
    log_error "нет /usr/local/cuda/lib64 — поставь EXTENSION cuda-toolkit раньше этого"
    exit 1
fi
PYVER="$(python3 -c 'import sys; print("%d.%d" % sys.version_info[:2])')"
if [[ "$PYVER" != "3.10" ]]; then
    log_error "Python $PYVER, а колесо TF собрано под 3.10 (cp310)"
    exit 1
fi

WORK="$(mktemp -d /var/tmp/l4t-tensorflow.XXXXXX)"
trap 'rm -rf "$WORK"' EXIT

# Системные библиотеки: по ldd всех .so в колесе на плате не хватало
# только cuDNN — остальное TF носит с собой или берёт из тулкита.
# h5py с PyPI — колесо manylinux со своим libhdf5, apt-овый не нужен.
log_info "apt: cuDNN 9"
apt_retry apt-get update -q || exit 1
apt_retry apt-get install "${APT_OPTS[@]}" libcudnn9-cuda-12 python3-pip || {
    log_error "apt не поставил зависимости"
    exit 1
}

log_info "колесо TensorFlow (NVIDIA, 553 МБ)"
apt_retry curl -fsSL --max-time 1800 -o "$WORK/$TF_WHEEL" "$TF_URL" || exit 1
echo "$TF_SHA256  $WORK/$TF_WHEEL" | sha256sum -c --quiet - || {
    log_error "контрольная сумма колеса TensorFlow не совпала"
    exit 1
}

# numpy/scipy — первыми и явно: без явного указания pip оставил бы
# apt-овый numpy 1.21.5, если бы тот удовлетворил требованию, а TF
# требует >=1.23.5 — ставить всё равно, так пусть это будет видно здесь.
log_info "pip: numpy, scipy, keras, tensorflow"
apt_retry python3 -m pip install --no-cache-dir --constraint "$SCRIPT_DIR/constraints.txt" \
    numpy scipy keras "$WORK/$TF_WHEEL" || {
    log_error "pip не поставил TensorFlow"
    exit 1
}

# Без GPU: внутри virt-customize его нет. Проверяем, что это сборка
# с CUDA нужной версии и что keras именно закреплённый.
python3 - <<'PYEOF' || { log_error "проверка импорта не прошла"; exit 1; }
import os, warnings
os.environ["TF_CPP_MIN_LOG_LEVEL"] = "2"
warnings.simplefilter("error", UserWarning)  # numpy/scipy не в паре — отказ
import numpy, scipy, tensorflow as tf
info = tf.sysconfig.get_build_info()
assert info.get("is_cuda_build"), "TensorFlow собран без CUDA"
assert info.get("cuda_version") == "12.6", info.get("cuda_version")
assert tf.keras.__version__ == "3.3.3", tf.keras.__version__
print(f"tensorflow {tf.__version__} (CUDA {info['cuda_version']}, cuDNN {info['cudnn_version']}), "
      f"keras {tf.keras.__version__}, numpy {numpy.__version__}, scipy {scipy.__version__}")
PYEOF

python3 "$SCRIPT_DIR/check-system-python.py" || {
    log_error "установка повредила системный Python — см. выше"
    exit 1
}
log_info "готово"
