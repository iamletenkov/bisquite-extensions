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

# The account name comes from the shared get_cloud_user.sh, and this script
# keeps NO fallback of its own.
#
# The local copy removed here ("first account with uid >= 1000 and a home
# directory") is the one that moved into lib/get_cloud_user.sh: measurement
# 2026-09-04 on a live Jetson, vendor image built without cloud-init — vino-vnc
# and jetson-stats configured nothing, docker configured fine, because docker
# was the only one carrying a fallback. The reason is recorded in the library
# itself: it was centralised so that nine diverging copies would not exist.
#
# The copy had DIVERGED, and in the worse direction. The shared script tells
# two cases apart: cloud-init absent (-> fallback) and cloud-init present but
# userdata not ready yet (-> refuse, because the vendor account is not the one
# cloud-init is about to create). The copy made no such distinction and in that
# race handed the docker group to the vendor account.
#
# stderr is NOT silenced: fallback_user() says there that it took the fallback
# path and which account it picked — exactly what has to be in the journal when
# the group went to an unexpected user.
user=""
if [[ -x "$HERE/get_cloud_user.sh" ]]; then
    user="$("$HERE/get_cloud_user.sh" || true)"
fi

if [[ -z "$user" ]]; then
    # Not a failure: Docker itself works without this, the group is a
    # convenience. There is no wait loop here, and none is needed — the unit is
    # Type=oneshot and runs on every boot, while cloud-init's userdata stays in
    # /var/lib/cloud/instance, so a first-boot race resolves on the next boot.
    log_warn "пользователь не определился, группа docker не назначена"
    log_warn "на первой загрузке это может быть гонка с cloud-init — группа назначится на следующей"
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

# Raspberry Pi: memory cgroup.
#
# The kernel supports memcg (CONFIG_MEMCG=y in every branch) but the DTB turns
# it off: bcm2711-rpi-ds.dtsi and bcm2712-rpi.dtsi carry cgroup_disable=memory
# in bootargs. Without the fix `docker run --memory` is SILENTLY ignored:
#   WARNING: Your kernel does not support memory limit capabilities
#            or the cgroup is not mounted. Limitation discarded.
#
# This runs here and not at build time for a measured reason: inside
# virt-customize /boot/firmware is EMPTY — libguestfs does not mount the FAT
# partition even though the guest fstab declares it. The build-time check
# never found the file and silently took the "not a Raspberry Pi" branch.
#
# cgroup_enable= is a Raspberry Pi patch, not upstream: torvalds/linux only
# has cgroup_disable=. On any other kernel the argument is ignored, and the
# file gate below closes that case anyway.
CMDLINE=/boot/firmware/cmdline.txt
if [[ -f "$CMDLINE" ]]; then
    if grep -q "cgroup_enable=memory" "$CMDLINE"; then
        log_info "cgroup_enable=memory уже в cmdline.txt"
    else
        cp -a "$CMDLINE" "$CMDLINE.before-docker"
        # Everything must stay on ONE line — the bootloader requires it.
        sed -i '1s/[[:space:]]*$//; 1s/$/ cgroup_enable=memory/' "$CMDLINE"
        log_info "в cmdline.txt добавлен cgroup_enable=memory"
        log_warn "ограничения памяти у контейнеров заработают после перезагрузки"
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
