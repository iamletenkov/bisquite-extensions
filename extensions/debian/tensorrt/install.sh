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

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
[[ -f "$SCRIPT_DIR/lib/l4t" ]] || { log_error "рядом нет lib/l4t — сборка не доставила lib/ источника"; exit 1; }
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/l4t"

# ВЕТКА R32 (Jetson Nano, JetPack 4.6): ПРОВЕРИТЬ, А НЕ СТАВИТЬ.
#
# TensorRT 8.0.1.6 в образе Q-engineering уже есть (libnvinfer8, trtexec в
# libnvinfer-bin), а репозитории NVIDIA отключены — ставить неоткуда. Ветка
# сверяет движок и отказывает, если его нет.
#
# PYTHON-МОДУЛЯ НЕТ, И ЭТО НЕ ОТКАЗ. JetPack 4.6 публикует `tensorrt` только
# под Python 3.6 (bionic), а в образе 3.8 (focal). Сборка биндингов из
# исходников — часы ради модуля, которым сегодня никто не пользуется;
# говорим об этом вслух, чтобы `import tensorrt` не стал сюрпризом.
r32_verify(){
    local ver ldcache
    local trtexec=/usr/src/tensorrt/bin/trtexec
    ver="$(dpkg-query -W -f='${db:Status-Abbrev}${Version}' libnvinfer8 2>/dev/null || true)"
    if [[ "$ver" != ii* ]]; then
        log_error "libnvinfer8 не установлен — ветка R32 ничего не ставит, движок обязан быть в базовом образе"
        return 1
    fi
    ver="${ver#ii }"
    if [[ ! -x "$trtexec" ]]; then
        log_error "нет $trtexec (пакет libnvinfer-bin)"
        return 1
    fi
    # В переменную, а не `ldconfig -p | grep -q`: pipefail и SIGPIPE.
    ldcache="$(ldconfig -p 2>/dev/null || true)"
    if ! grep -q "libnvinfer.so.8 " <<<"$ldcache"; then
        log_error "libnvinfer.so.8 не виден загрузчику"
        return 1
    fi
    # OPENBLAS_CORETYPE — чтобы numpy внутри модуля не выдал отсутствие за падение.
    if OPENBLAS_CORETYPE="$L4T_OPENBLAS_CORETYPE" /usr/bin/python3 -c 'import tensorrt' >/dev/null 2>&1; then
        log_info "Python-модуль tensorrt есть"
    else
        log_warn "Python-модуля tensorrt для $(/usr/bin/python3 -V 2>&1) нет: JetPack 4.6 публикует его только под 3.6; TensorRT доступен из C++ и trtexec"
    fi
    log_info "готово (R32): libnvinfer8 ${ver}, $trtexec, ничего не ставилось"
}

if [[ "$(l4t_major || true)" == 32 ]]; then
    r32_verify || exit 1
    exit 0
fi

SOURCE_LIST=/etc/apt/sources.list.d/nvidia-l4t-apt-source.list
if [[ ! -f "$SOURCE_LIST" ]]; then
    log_error "нет $SOURCE_LIST — источник jetson/common не подключён"
    exit 1
fi

log_info "apt-get update"
apt_retry apt-get update -q || exit 1

# ПОЧЕМУ ЕЩЁ И `nvidia-l4t-dla-compiler`.
#
# Без него не работает Python-биндинг, а на Jetson он и есть основной
# способ: `import tensorrt` падает с `ImportError: libnvdla_compiler.so`,
# и та же ошибка валит `jtop`, который читает версию TensorRT через
# ctypes. C++-часть при этом полностью работоспособна, поэтому образ
# выглядит исправным ровно до первого запуска.
#
# ИСТОРИЯ, КОТОРУЮ СТОИТ ЗНАТЬ. Пакет уже добавлялся 2026-09-12 и был
# откачен: собранный образ не поднимал рабочий стол. Диагноз оказался
# НЕВЕРНЫМ — виновата была гонка в cloud-user-desktop (сессия забирала
# неполный список групп, без `video`), и чинилась она там же. Пакет
# к отказу отношения не имел.
#
# Проверено на живой плате 2026-09-13: `apt-get install -s` ставит ровно
# этот пакет и ничего не обновляет — версии nvidia-l4t-core и
# nvidia-l4t-3d-core остаются 36.4.3. Прежнее уползание стека до 36.4.7
# вызвала отдельная команда `--reinstall nvidia-l4t-3d-core
# nvidia-l4t-core`, а не эта установка.
#
# Оговорка про версию всё же есть: сам пакет опубликован как 36.4.7 при
# стеке 36.4.3, и файл он несёт один — libnvdla_compiler.so. Если однажды
# сломается что-то в GPU-стеке, проверять стоит и это тоже.
log_info "ставлю tensorrt, python3-libnvinfer и компилятор DLA"
apt_retry apt-get install "${APT_OPTS[@]}" \
    tensorrt python3-libnvinfer nvidia-l4t-dla-compiler || {
    log_error "tensorrt не установился"
    exit 1
}

# LDCONFIG ЯВНО, А НЕ НАДЕЯСЬ НА ТРИГГЕР ПАКЕТА.
#
# libnvdla_compiler.so ложится в /usr/lib/aarch64-linux-gnu/nvidia — путь
# объявлен в /etc/ld.so.conf.d/nvidia-tegra.conf, но кеш после установки
# не перестраивается. Замер на живой плате: `ldconfig -p | grep -c nvdla`
# давал 1 до ручного ldconfig и 2 после, и ровно между этими числами
# лежала разница между падающим и работающим `import tensorrt`.
ldconfig || log_warn "ldconfig отработал с ошибкой"

# Вывод сначала в переменную: `ldconfig -p | grep -q` под `set -o pipefail`
# роняет конвейер по SIGPIPE, и проверка врёт (сборка 2026-09-12 упала
# именно так).
LDCACHE="$(ldconfig -p 2>/dev/null || true)"
if grep -q "libnvdla_compiler.so" <<<"$LDCACHE"; then
    log_info "libnvdla_compiler.so виден загрузчику"
else
    log_error "libnvdla_compiler.so не виден загрузчику — import tensorrt упадёт"
    exit 1
fi

log_info "готово: $(dpkg-query -W -f='${Version}' tensorrt 2>/dev/null || echo '?')"
