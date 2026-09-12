#!/usr/bin/env bash
# Поставить TensorRT из репозитория NVIDIA jetson/common — того же
# источника, что уже подключён базовым образом L4T (nvidia-l4t-apt-source).
# Разбор источника — в cuda-toolkit/install.sh, тот же довод дословно.
#
# ПОЧЕМУ `tensorrt`, А НЕ `libnvinfer*` ПО ОТДЕЛЬНОСТИ. Пакеты движка
# (`libnvinfer10`, `libnvinfer-plugin10`, …) можно ставить и поштучно, но
# `tensorrt` — мета-пакет, который тянет ровно совместимый набор рантайма
# и dev-заголовков одной версией; собирать его вручную из полутора десятков
# имён — источник рассинхрона версий, которого сам apt и избегает.
#
# ПОЧЕМУ ЕЩЁ И `python3-libnvinfer`. Инференс на Jetson в подавляющем
# большинстве случаев идёт из Python (ultralytics, deepstream-обвязка,
# собственные скрипты), и без биндингов TensorRT доступен только из C++.
# Ставим отдельным пакетом, а не полагаемся на Recommends: `tensorrt`
# биндинги не тянет вовсе — они в отдельном пакете, который apt сам
# не подхватит.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} tensorrt: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} tensorrt: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} tensorrt: $*"; }

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

TEGRA_RELEASE=/etc/nv_tegra_release
if [[ ! -f "$TEGRA_RELEASE" ]]; then
    log_error "в образе нет $TEGRA_RELEASE — это не образ NVIDIA Jetson (L4T)"
    exit 1
fi
log_info "L4T: $(head -n 1 "$TEGRA_RELEASE")"

SOURCE_LIST=/etc/apt/sources.list.d/nvidia-l4t-apt-source.list
if [[ ! -f "$SOURCE_LIST" ]]; then
    log_error "нет $SOURCE_LIST — источник jetson/common не подключён"
    exit 1
fi

log_info "apt-get update"
apt_retry apt-get update -q || exit 1

# ПОЧЕМУ ЗДЕСЬ НЕТ `nvidia-l4t-dla-compiler`, ХОТЯ БЕЗ НЕГО НЕ РАБОТАЕТ
# `import tensorrt`.
#
# Без него Python-биндинг падает: `ImportError: libnvdla_compiler.so`.
# C++-часть при этом полностью работоспособна. Соблазн доставить пакет
# велик, и он был реализован 2026-09-12 — а собранный образ после этого
# не поднял графическую сессию вовсе: gnome-shell падал с
# `NvRmMemInitNvmap failed with Permission denied` и `Unable to initialize
# the Clutter backend: no available drivers found`.
#
# Причина: в репозитории jetson/common пакет опубликован ТОЛЬКО версии
# 36.4.0 (`apt-cache madison`), тогда как BSP образа — 36.4.3. Установка
# тянет за собой обновление стека L4T до 36.4.7, и userspace разъезжается
# с ядром. Версионные смеси L4T не поддерживаются, и ломается именно
# NvRm — то есть весь GPU-стек, а не одна библиотека.
#
# Вывод, который стоит запомнить: `apt-get install` любого пакета
# nvidia-l4t-* без привязки к версии способен утащить вперёд весь стек.
# Прежде чем добавлять сюда такой пакет, сверь `apt-cache madison`
# с версией из /etc/nv_tegra_release.
log_info "ставлю tensorrt и python3-libnvinfer (может занять несколько минут)"
apt_retry apt-get install "${APT_OPTS[@]}" tensorrt python3-libnvinfer || {
    log_error "tensorrt не установился"
    exit 1
}

log_info "готово: $(dpkg-query -W -f='${Version}' tensorrt 2>/dev/null || echo '?')"
