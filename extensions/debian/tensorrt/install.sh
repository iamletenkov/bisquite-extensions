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

# ПОЧЕМУ ЕЩЁ И `nvidia-l4t-dla-compiler`. Без него `import tensorrt`
# падает с `ImportError: libnvdla_compiler.so: cannot open shared object
# file`, хотя C++-часть полностью на месте. Зависимостью пакета `tensorrt`
# он НЕ тянется — проверено на собранном образе 2026-09-12: 19 пакетов
# TensorRT, libnvinfer.so.10 есть, а Python-биндинг не импортируется.
#
# Питон тут не «ещё один способ» — это основной способ: Jetson берут под
# инференс, и выглядит такой образ полностью рабочим ровно до первой
# попытки что-нибудь запустить.
log_info "ставлю tensorrt, python3-libnvinfer и компилятор DLA"
apt_retry apt-get install "${APT_OPTS[@]}" \
    tensorrt python3-libnvinfer nvidia-l4t-dla-compiler || {
    log_error "tensorrt не установился"
    exit 1
}

# LDCONFIG ЯВНО, А НЕ НАДЕЯСЬ НА ТРИГГЕР ПАКЕТА.
#
# libnvdla_compiler.so ложится в /usr/lib/aarch64-linux-gnu/nvidia — путь
# объявлен в /etc/ld.so.conf.d/nvidia-tegra.conf, но КЕШ после установки
# не перестраивается. Замер на живой плате: `ldconfig -p | grep -c nvdla`
# давал 1 до и 2 после ручного `ldconfig`, и ровно между этими числами
# лежала разница между падающим и работающим `import tensorrt`.
# Внутри virt-customize триггеры и подавно не отрабатывают штатно.
ldconfig || log_warn "ldconfig отработал с ошибкой"

if ldconfig -p 2>/dev/null | grep -q "libnvdla_compiler.so"; then
    log_info "libnvdla_compiler.so виден загрузчику"
else
    log_error "libnvdla_compiler.so не виден загрузчику — import tensorrt упадёт"
    exit 1
fi

log_info "готово: $(dpkg-query -W -f='${Version}' tensorrt 2>/dev/null || echo '?')"
