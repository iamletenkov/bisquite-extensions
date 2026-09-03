#!/usr/bin/env bash
# Install Docker CE from Docker's own apt repository.
#
# WHY NOT get.docker.com. Docker's documentation is explicit:
#   "The convenience script isn't recommended for production environments,
#    but it's useful for creating a provisioning script tailored to your needs."
# It also cannot be customised, is not designed to upgrade an existing install,
# and pins nothing. The apt repository is the documented production path.
#
# WHY NOT Debian's docker.io. That package trails upstream by a lot and does
# not ship `docker buildx` or `docker compose` as plugins. This extension
# installs the five upstream packages instead.
#
# WHICH REPOSITORY. Docker publishes separate repos for "debian" and
# "raspbian", selected by ID in /etc/os-release:
#
#   Raspberry Pi OS 64-bit  ID=debian    -> linux/debian    (this is the one)
#   Raspberry Pi OS 32-bit  ID=raspbian  -> linux/raspbian  (armhf only, no trixie)
#
# The raspbian repo has no trixie suite at all (404) and stopped at Docker
# 28.x, while debian/trixie/arm64 is current. Docker's own convenience script
# hardcodes the same conclusion:
#
#   # Docker does not publish a Raspbian Trixie repo; use Debian Trixie instead.
#
# So 64-bit Raspberry Pi OS is served by the plain Debian instructions, and
# this script follows them for Debian, Ubuntu and Raspberry Pi OS alike.
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

# --- какой мы дистрибутив ---------------------------------------------------
. /etc/os-release
DISTRO_ID="${ID:-}"
CODENAME="${VERSION_CODENAME:-}"

case "$DISTRO_ID" in
    debian|ubuntu) REPO_OS="$DISTRO_ID" ;;
    raspbian)
        # See the header: no raspbian trixie exists upstream.
        if [[ "$CODENAME" == "trixie" ]]; then
            REPO_OS="debian"
            log_warn "raspbian trixie в репозитории Docker отсутствует, беру debian"
        else
            REPO_OS="raspbian"
        fi
        ;;
    *)
        log_error "неподдерживаемый дистрибутив: ID=$DISTRO_ID"
        exit 1
        ;;
esac

[[ -n "$CODENAME" ]] || { log_error "в /etc/os-release нет VERSION_CODENAME"; exit 1; }
ARCH="$(dpkg --print-architecture)"
log_info "дистрибутив $DISTRO_ID $CODENAME ($ARCH) -> репозиторий linux/$REPO_OS"

# --- убрать конфликтующие пакеты --------------------------------------------
# Debian's own docker.io and the podman shim own the same binaries and will
# fight the upstream packages. Removed only if actually present.
for pkg in docker.io docker-compose docker-doc docker-buildx podman-docker containerd runc; do
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
log_info "ключ установлен"

# deb822, а не однострочный docker.list: это текущий формат в документации
# Docker. Строка Architectures обязательна — Raspberry Pi OS собирается с
# добавленной второй архитектурой (dpkg --add-architecture в pi-gen), и без
# неё apt пойдёт ещё и за индексом, которого может не быть.
cat > /etc/apt/sources.list.d/docker.sources <<SOURCES
Types: deb
URIs: https://download.docker.com/linux/${REPO_OS}
Suites: ${CODENAME}
Components: stable
Architectures: ${ARCH}
Signed-By: /etc/apt/keyrings/docker.asc
SOURCES
log_info "репозиторий прописан"

apt_retry apt-get "${APT_OPTS[@]}" update

# --- пакеты ------------------------------------------------------------------
apt_retry apt-get "${APT_OPTS[@]}" install \
    docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin
log_info "Docker CE установлен"

systemctl enable docker.service containerd.service || \
    log_warn "не удалось включить юниты (нормально при сборке в chroot)"

# --- memory cgroup на Raspberry Pi -------------------------------------------
# Ядро Raspberry Pi выключает memory cgroup через DTB, поэтому
# `docker run --memory` МОЛЧА игнорируется:
#   WARNING: Your kernel does not support memory limit capabilities
#            or the cgroup is not mounted. Limitation discarded.
# Лечится строкой в cmdline.txt; параметры из файла применяются ПОСЛЕ
# аргументов из DTB и потому перебивают cgroup_disable=memory.
# В документации Docker об этом нет ни слова.
#
# cgroup_memory=1 намеренно НЕ добавляется: на ядрах 6.12+ он избыточен и
# логируется как нераспознанный (позиция мейнтейнера ядра Raspberry Pi).
CMDLINE=/boot/firmware/cmdline.txt
if [[ -f "$CMDLINE" ]]; then
    if grep -q "cgroup_enable=memory" "$CMDLINE"; then
        log_info "cgroup_enable=memory уже в cmdline.txt"
    else
        cp -a "$CMDLINE" "$CMDLINE.before-docker-ce"
        # Всё должно остаться ОДНОЙ строкой — требование загрузчика.
        sed -i '1s/[[:space:]]*$//; 1s/$/ cgroup_enable=memory/' "$CMDLINE"
        log_info "в cmdline.txt добавлен cgroup_enable=memory (нужна перезагрузка)"
    fi
else
    log_info "cmdline.txt не найден — не Raspberry Pi, правка не нужна"
fi

# --- сервис донастройки при первом запуске -----------------------------------
if [[ -f /opt/vmsetup/docker-ce/configure-docker-ce.service ]]; then
    install -m 0644 /opt/vmsetup/docker-ce/configure-docker-ce.service \
        /etc/systemd/system/configure-docker-ce.service
    systemctl daemon-reload || true
    systemctl enable configure-docker-ce.service || true
    log_info "configure-docker-ce.service включён"
else
    log_warn "configure-docker-ce.service не найден рядом — пропускаю"
fi

log_info "установка docker-ce завершена"
