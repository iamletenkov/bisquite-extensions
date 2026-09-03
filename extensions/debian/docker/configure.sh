#!/usr/bin/env bash
# First-boot step: give the cloud-init user access to the Docker socket.
#
# Cannot be done at build time: the account is created by cloud-init from the
# deployment manifest, so its name is unknown while the image is being built.
#
# Idempotent — safe to run on every boot.
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} $*"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

user=""
if [[ -x "$HERE/get_cloud_user.sh" ]]; then
    user="$("$HERE/get_cloud_user.sh" 2>/dev/null || true)"
fi

if [[ -z "$user" ]]; then
    # Fallback: the first regular login account with a home directory.
    for candidate in $(getent passwd | awk -F: '$3 >= 1000 && $3 < 65534 {print $1}'); do
        [[ -d "/home/${candidate}" ]] && { user="$candidate"; break; }
    done
fi

if [[ -z "$user" ]]; then
    log_warn "пользователь не определился, группа docker не назначена"
else
    if id -nG "$user" | tr ' ' '\n' | grep -qx docker; then
        log_info "'$user' уже в группе docker"
    else
        usermod -aG docker "$user"
        log_info "'$user' добавлен в группу docker"
        # Membership in `docker` is equivalent to root on this host: the socket
        # can start a privileged container. Stated here so it is a decision,
        # not an accident.
        log_warn "членство в группе docker равносильно root на этой машине"
    fi
fi

# L4T: nvidia-ctk rewrote /etc/docker/daemon.json during the build phase, but
# the daemon was not running then — virt-customize works in a chroot. Pick the
# new runtime up here, once, on the machine where it matters.
if [[ -f /etc/nv_tegra_release ]] && command -v nvidia-ctk >/dev/null 2>&1; then
    if systemctl is-active --quiet docker; then
        systemctl restart docker && log_info "docker перезапущен под среду выполнения NVIDIA"
    else
        log_info "docker не запущен — перезапуск под NVIDIA не нужен"
    fi
fi
