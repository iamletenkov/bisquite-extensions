#!/usr/bin/env bash
# Install Docker CE from Docker's own apt repository.
#
# ONE PATH, NOT TWO. This extension used to have a twin (`docker-ce`) on the
# grounds that get.docker.com was needed for old releases. Measured 2026-09-03,
# that was wrong twice over:
#
#   * the convenience script installs from THIS repository — it only writes a
#     one-line .list instead of deb822 (getdocker.sh:596,606). There was never
#     a second source of packages;
#   * on bionic the script is broken. version_gte() returns true whenever
#     VERSION is empty (getdocker.sh:230-234), so `docker-model-plugin` is
#     added unconditionally — and that package does not exist in the bionic
#     repository for either amd64 or arm64. With `set -e` the build dies.
#
# NO BRANCHING ON DISTRIBUTION. Also measured, also contrary to what the
# earlier scripts assumed:
#
#   * deb822 with `Signed-By: <path>` works from apt 1.6.17 (bionic). Only an
#     *embedded* key needs apt >= 2.4, and nothing here needs one;
#   * 64-bit Raspberry Pi OS reports ID=debian, so the linux/debian repository
#     serves it. The raspbian repository is armhf-only and has no trixie;
#   * `${UBUNTU_CODENAME:-$VERSION_CODENAME}` covers both families in one
#     expression — that is what Docker's own instructions use;
#   * the five package names are identical on every target, bionic included.
#
# The real branches are HARDWARE traits, and they are orthogonal to the
# distribution: a Pi 4 running Ubuntu reports ID=ubuntu, and so does a Jetson
# running JetPack 6. Branching on ID would miss both.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} $*"; }

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

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# --- какая это система ------------------------------------------------------
# shellcheck disable=SC1091
. /etc/os-release
DISTRO_ID="${ID:-}"
SUITE="${UBUNTU_CODENAME:-${VERSION_CODENAME:-}}"

case "$DISTRO_ID" in
    debian|ubuntu) REPO_OS="$DISTRO_ID" ;;
    *)
        log_error "расширение docker рассчитано на debian и ubuntu, а здесь ID=$DISTRO_ID"
        log_error "OpenWrt обслуживается отдельно: там apk/opkg и нет systemd"
        exit 1
        ;;
esac

[[ -n "$SUITE" ]] || { log_error "в /etc/os-release нет VERSION_CODENAME"; exit 1; }
ARCH="$(dpkg --print-architecture)"
log_info "система $DISTRO_ID $SUITE ($ARCH) -> репозиторий linux/$REPO_OS"

# --- признаки железа, а не системы ------------------------------------------
IS_RPI=0
[[ -f /boot/firmware/cmdline.txt || -f /etc/rpi-issue ]] && IS_RPI=1
IS_L4T=0
[[ -f /etc/nv_tegra_release ]] && IS_L4T=1
(( IS_RPI )) && log_info "опознан Raspberry Pi"
(( IS_L4T )) && log_info "опознан L4T (Jetson)"

# --- убрать конфликтующее ----------------------------------------------------
# docker.io конфликтует с docker-ce напрямую; docker-cli — с docker-ce-cli;
# docker-compose-v2 добавлен по документации Docker для Ubuntu.
for pkg in docker.io docker-cli docker-compose docker-compose-v2 docker-doc \
           docker-buildx podman-docker containerd runc; do
    if dpkg -l "$pkg" 2>/dev/null | grep -q '^ii'; then
        log_info "убираю конфликтующий пакет $pkg"
        apt_retry apt-get "${APT_OPTS[@]}" remove "$pkg" || log_warn "не удалось убрать $pkg"
    fi
done

# --- ключ и репозиторий ------------------------------------------------------
apt_retry apt-get "${APT_OPTS[@]}" update
apt_retry apt-get "${APT_OPTS[@]}" install ca-certificates curl

install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://download.docker.com/linux/${REPO_OS}/gpg" -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

# Строка Architectures обязательна: Raspberry Pi OS собирается с добавленной
# второй архитектурой (dpkg --add-architecture в pi-gen), и без неё apt пойдёт
# ещё и за индексом, которого в репозитории может не быть.
cat > /etc/apt/sources.list.d/docker.sources <<SOURCES
Types: deb
URIs: https://download.docker.com/linux/${REPO_OS}
Suites: ${SUITE}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
SOURCES
log_info "репозиторий прописан"

apt_retry apt-get "${APT_OPTS[@]}" update

# --- гейт: есть ли пакет для этой цели ---------------------------------------
# Спрашиваем у самого репозитория, а не сверяемся с таблицей поддерживаемых
# сюит: таблица устарела бы молча — тот же довод, по которому отвергнута ось
# «дистрибутив» в манифестах расширений. Заодно ловит опечатку в кодовом имени
# и молча не отработавший apt-get update.
CANDIDATE="$(apt-cache policy docker-ce 2>/dev/null | awk '/Candidate:/{print $2}')"
if [[ -z "$CANDIDATE" || "$CANDIDATE" == "(none)" ]]; then
    log_error "в репозитории Docker нет пакетов для ${REPO_OS}/${SUITE} (${ARCH})"
    log_error "отката на дистрибутивный docker.io НЕТ намеренно: он тихо подменил"
    log_error "бы версию движка, и на флот уехали бы разные образы из одного VMFILE"
    log_error "нужен именно docker.io — это отдельное расширение под своим именем"
    exit 1
fi
log_info "кандидат docker-ce: $CANDIDATE"

# Наличие пакета и его свежесть — разные вопросы. Репозиторий для bionic
# существует, но заморожен на июне 2023 (docker-ce 24.0.2 против 29.7.2
# у noble), и об этом надо сказать вслух, а не молча собрать трёхлетний движок.
case "$SUITE" in
    trusty|xenial|bionic|focal|stretch|buster)
        log_warn "сюита ${SUITE} в репозитории Docker заморожена — ставится ${CANDIDATE}"
        log_warn "это потолок цели, а не выбор способа установки"
        ;;
esac

# --- пакеты ------------------------------------------------------------------
# Ровно пять и ничего сверх. docker-model-plugin не просим намеренно: его нет
# в старых сюитах, и именно на нём ломается get.docker.com.
apt_retry apt-get "${APT_OPTS[@]}" install \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
log_info "Docker CE установлен"

# Юниты включает сама упаковка (замерено в debian:13: symlink'и создаются
# postinst'ом даже при снятом policy-rc.d). Строка оставлена как страховка на
# случай упаковки, которая этого не делает, и потому не считается отказом.
systemctl enable docker.service containerd.service 2>/dev/null || \
    log_info "юниты уже включены упаковкой"

# --- Raspberry Pi: memory cgroup ---------------------------------------------
# Ядро Raspberry Pi умеет memcg (CONFIG_MEMCG=y во всех ветках), но DTB его
# выключает: bcm2711-rpi-ds.dtsi и bcm2712-rpi.dtsi несут cgroup_disable=memory
# в bootargs. Из-за этого `docker run --memory` МОЛЧА игнорируется:
#   WARNING: Your kernel does not support memory limit capabilities
#            or the cgroup is not mounted. Limitation discarded.
#
# cgroup_enable= — патч Raspberry Pi, а не upstream: в torvalds/linux есть
# только cgroup_disable=. На чужом ядре аргумент будет проигнорирован, и гейт
# по файлу это закрывает.
#
# ⚠️ НЕ ПРОВЕРЕНО на живой машине: что параметры из cmdline.txt применяются
# ПОСЛЕ аргументов из DTB. Механика ядра на стороне этого утверждения —
# cgroup_disable и cgroup_enable два независимых __setup-обработчика, и
# последний выигрывает, — но замера загрузкой не делалось.
CMDLINE=/boot/firmware/cmdline.txt
if (( IS_RPI )) && [[ -f "$CMDLINE" ]]; then
    if grep -q "cgroup_enable=memory" "$CMDLINE"; then
        log_info "cgroup_enable=memory уже в cmdline.txt"
    else
        cp -a "$CMDLINE" "$CMDLINE.before-docker"
        # Всё обязано остаться ОДНОЙ строкой — требование загрузчика.
        sed -i '1s/[[:space:]]*$//; 1s/$/ cgroup_enable=memory/' "$CMDLINE"
        log_info "в cmdline.txt добавлен cgroup_enable=memory (нужна перезагрузка)"
    fi
elif (( IS_RPI )); then
    log_warn "Raspberry Pi опознан, но $CMDLINE не найден — memory cgroup не включён"
fi

# --- L4T: среда выполнения NVIDIA --------------------------------------------
# Берём из джетсоновского репозитория, а не из общего nvidia.github.io:
# пакеты nvidia-container-csv-* публикуются ТОЛЬКО там, а без них контейнер
# не увидит CUDA/cuDNN/TensorRT хоста.
#
# nvidia-docker2 объявляет `Depends: docker-ce | docker-ee | docker.io`,
# так что установленный выше Docker CE её удовлетворяет.
if (( IS_L4T )); then
    L4T_REL="$(awk 'NR==1{gsub(/[^0-9]/,"",$2); print $2}' /etc/nv_tegra_release 2>/dev/null || true)"
    L4T_REV="$(awk -F'REVISION: ' 'NR==1{split($2,a,","); print a[1]}' /etc/nv_tegra_release 2>/dev/null | tr -d ' ' || true)"
    if [[ -n "$L4T_REL" && -n "$L4T_REV" ]]; then
        L4T_SUITE="r${L4T_REL}.${L4T_REV%%.*}"
        log_info "L4T $L4T_SUITE — подключаю репозиторий NVIDIA"
        curl -fsSL "https://repo.download.nvidia.com/jetson/jetson-ota-public.asc" \
            -o /etc/apt/keyrings/nvidia-jetson.asc || \
            log_warn "ключ NVIDIA не скачался"
        cat > /etc/apt/sources.list.d/nvidia-jetson.sources <<NVSOURCES
Types: deb
URIs: https://repo.download.nvidia.com/jetson/common
Suites: ${L4T_SUITE}
Components: main
Architectures: arm64
Signed-By: /etc/apt/keyrings/nvidia-jetson.asc
NVSOURCES
        apt_retry apt-get "${APT_OPTS[@]}" update || log_warn "индекс NVIDIA не обновился"
        if apt_retry apt-get "${APT_OPTS[@]}" install nvidia-container-toolkit; then
            # Правит только /etc/docker/daemon.json — это фаза сборки.
            # Перезапуск демона уезжает в configure.sh: systemd здесь не работает.
            nvidia-ctk runtime configure --runtime=docker || \
                log_warn "nvidia-ctk не настроил среду выполнения"
            log_info "среда выполнения NVIDIA настроена"
        else
            log_warn "nvidia-container-toolkit не установился — GPU в контейнерах не будет"
        fi
    else
        log_warn "/etc/nv_tegra_release не разобрался — репозиторий NVIDIA пропущен"
    fi
fi

# --- сервис донастройки при первом запуске -----------------------------------
if [[ -f "$HERE/configure-docker.service" ]]; then
    install -m 0644 "$HERE/configure-docker.service" \
        /etc/systemd/system/configure-docker.service
    systemctl daemon-reload || true
    systemctl enable configure-docker.service || true
    log_info "configure-docker.service включён"
else
    log_warn "configure-docker.service не найден рядом — пропускаю"
fi

log_info "установка docker завершена"
