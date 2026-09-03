#!/usr/bin/env bash
# Поставить jtop — монитор NVIDIA Jetson (CPU, GPU, память, питание,
# температуры, вентилятор) — и завести его системную службу.
#
# ПОЧЕМУ pip, А НЕ apt. В репозиториях Ubuntu пакета jetson-stats нет вовсе:
# он живёт только на PyPI, и upstream документирует ровно один способ
# установки — `sudo pip3 install -U jetson-stats`
# (README проекта rbonghi/jetson_stats, раздел Install; перед ним стоит
# `apt install python3-pip python3-setuptools`, его мы и повторяем).
#
# ПОЧЕМУ СЛУЖБУ ПРИХОДИТСЯ СТАВИТЬ ОТДЕЛЬНО. jtop — это клиент, который
# ходит в демона через сокет /run/jtop.sock, и без jtop.service он говорит
# «The jtop.service is not active» (jtop/jtop.py:1116). Раньше службу ставил
# сам pip: setup.py объявляет команду build_py, которая копирует
# services/jtop.service в /etc/systemd/system и включает его.
#
# ЗАМЕР 2026-09-03 по артефактам PyPI: начиная с 7.2.0 (14.07.2026) проект
# публикует ГОТОВОЕ КОЛЕСО `jetson_stats-7.2.1-py3-none-any.whl` рядом
# с sdist. pip предпочитает колесо, а из колеса build_py не выполняется
# никогда — значит служба не появляется, и `jtop` на свежепоставленной
# системе отказывает. До 4.3.2 включительно публиковался только sdist,
# и хук срабатывал; поэтому обе ветки живые, и скрипт проверяет ФАКТ
# (есть ли файл юнита), а не версию.
#
# Штатный запасной путь у проекта есть — `jtop --install-service`
# (jtop/__main__.py:174): он ставит /etc/profile.d/jtop_env.sh, заводит
# группу `jtop` и копирует юнит, находя его шаблон в data-файлах колеса
# (/usr/local/share/jetson_stats/jtop.service). Его и зовём, а третьим
# заходом копируем шаблон руками — потому что «поставилось, но не работает»
# обнаружилось бы уже на плате.
#
# ПОЧЕМУ НЕ nvtop — в README, там же замеры.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} jetson-stats: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} jetson-stats: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} jetson-stats: $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Единственный параметр: чем пинить версию. Пусто — последняя с PyPI.
# Ручка не про запас: 7.x и 4.x ставят службу по-разному (см. шапку), и
# закрепиться на проверенной версии — единственный способ повторить сборку.
JETSON_STATS_VERSION="${JETSON_STATS_VERSION:-}"

TEGRA_RELEASE=/etc/nv_tegra_release
UNIT=/etc/systemd/system/jtop.service

# --- 1. Опознать Tegra ------------------------------------------------------
#
# Отказ, а не предупреждение. jtop на не-Jetson бесполезен: он читает
# tegrastats и sysfs-узлы Tegra, а `/etc/nv_tegra_release` — тот самый файл,
# по которому опознаёт плату сам jetson-stats
# (jtop/core/jetson_variables.py:240, jtop/core/hw_detect.py:54).
# Молча поставленный мусор хуже отказа: на плате он выглядит как рабочая
# команда, которая всегда падает.
if [[ ! -f "$TEGRA_RELEASE" ]]; then
    log_error "в образе нет $TEGRA_RELEASE — это не образ NVIDIA Jetson (L4T)"
    log_error "jtop читает tegrastats и sysfs Tegra; на обычном arm64 он бесполезен"
    log_error "для не-Jetson берите обычный монитор (htop, а для GPU — nvtop с NVML)"
    exit 1
fi
log_info "L4T: $(head -n 1 "$TEGRA_RELEASE")"

# --- 2. Зависимости из apt --------------------------------------------------
log_info "ставлю python3-pip и python3-setuptools"
apt-get update || exit 1
apt-get install -y python3-pip python3-setuptools || exit 1

# --- 3. Сам пакет -----------------------------------------------------------
spec="jetson-stats"
if [[ -n "$JETSON_STATS_VERSION" ]]; then
    spec="jetson-stats==${JETSON_STATS_VERSION}"
fi

pip_flags=()
# PEP 668: на Ubuntu 24.04 и новее системный интерпретатор помечен
# «externally managed», и pip отказывается ставить в него без флага.
# Upstream документирует это отдельным пунктом Install (Option 3).
# Смотрим на сам маркер, а не на версию дистрибутива: маркер и есть то,
# на что смотрит pip.
if compgen -G "/usr/lib/python3*/EXTERNALLY-MANAGED" >/dev/null; then
    log_info "найден маркер PEP 668 — добавляю --break-system-packages"
    pip_flags+=(--break-system-packages)
fi

install_package() {
    local attempt=1 max_attempts=5 delay
    while (( attempt <= max_attempts )); do
        log_info "pip3 install -U ${spec} (попытка ${attempt}/${max_attempts})"
        if pip3 install -U "${pip_flags[@]+"${pip_flags[@]}"}" "$spec"; then
            return 0
        fi
        delay=$(( attempt * 2 ))
        log_warn "не вышло, повтор через ${delay}s"
        sleep "$delay"
        attempt=$(( attempt + 1 ))
    done
    return 1
}

if ! install_package; then
    log_error "не удалось поставить ${spec} с PyPI"
    exit 1
fi

# --- 4. Служба jtop.service -------------------------------------------------
if [[ -f "$UNIT" ]]; then
    log_info "$UNIT уже на месте — сработал хук pip (установка из sdist)"
else
    log_info "$UNIT не появился (установка из колеса) — зову jtop --install-service"
    jtop --install-service || log_warn "jtop --install-service отработал с ошибкой"
fi

if [[ ! -f "$UNIT" ]]; then
    # Третий заход: шаблон юнита лежит в data-файлах пакета. Путь зависит
    # от префикса установки (sudo pip3 кладёт в /usr/local), поэтому
    # перебираем оба известных.
    for candidate in /usr/local/share/jetson_stats/jtop.service \
                     /usr/share/jetson_stats/jtop.service; do
        if [[ -f "$candidate" ]]; then
            install -m 0644 "$candidate" "$UNIT"
            log_warn "юнит скопирован руками из $candidate"
            break
        fi
    done
fi

if [[ ! -f "$UNIT" ]]; then
    log_error "jtop.service не установлен ни одним из трёх способов"
    log_error "без него клиент отвечает «The jtop.service is not active»,"
    log_error "то есть образ уехал бы на плату с неработающей командой"
    exit 1
fi

# Группа `jtop` — владелец сокета /run/jtop.sock (0660 root:jtop).
# `jtop --install-service` заводит её сам, но при копировании юнита руками
# её не создаёт никто, а служба без группы падает на старте с
# «Group jtop does not exist!» (jtop/service.py:627).
if ! getent group jtop >/dev/null 2>&1; then
    log_info "завожу группу jtop"
    groupadd jtop || true
fi

systemctl daemon-reload || true
systemctl enable jtop.service || true

# --- 5. Донастройка на первой загрузке --------------------------------------
if [[ -f "$SCRIPT_DIR/configure-jetson-stats.service" ]]; then
    install -m 0644 "$SCRIPT_DIR/configure-jetson-stats.service" \
        /etc/systemd/system/configure-jetson-stats.service
    systemctl enable configure-jetson-stats.service || true
else
    log_error "рядом нет configure-jetson-stats.service"
    log_error "без него пользователь cloud-init не попадёт в группу jtop"
    log_error "и команда jtop от его имени будет отвечать отказом доступа"
    exit 1
fi

log_info "готово: jtop установлен, jtop.service включён"
