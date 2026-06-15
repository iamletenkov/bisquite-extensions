#!/usr/bin/env bash
# Extension: docker — Docker CE (engine, CLI, buildx, compose plugin).
# Запускается во время сборки внутри образа (RUN_COMMAND), от root, идемпотентно.
#
# Параметры (env):
#   DOCKER_USERS  пользователи в группу docker, через пробел (по умолчанию "debian")
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

DOCKER_USERS="${DOCKER_USERS:-debian}"

# shellcheck disable=SC1091
. /etc/os-release   # ID (debian/ubuntu), VERSION_CODENAME

apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg

install -m 0755 -d /etc/apt/keyrings
curl -fsSL "https://download.docker.com/linux/${ID}/gpg" -o /etc/apt/keyrings/docker.asc
chmod a+r /etc/apt/keyrings/docker.asc

echo "deb [arch=$(dpkg --print-architecture) signed-by=/etc/apt/keyrings/docker.asc] https://download.docker.com/linux/${ID} ${VERSION_CODENAME} stable" \
  > /etc/apt/sources.list.d/docker.list

apt-get update
apt-get install -y --no-install-recommends \
  docker-ce docker-ce-cli containerd.io docker-buildx-plugin docker-compose-plugin

for u in ${DOCKER_USERS}; do
  if id "${u}" >/dev/null 2>&1; then
    usermod -aG docker "${u}"
  fi
done

# Включаем сервис: символическую ссылку systemd создаёт offline, старт — на загрузке.
systemctl enable docker.service containerd.service

apt-get clean
rm -rf /var/lib/apt/lists/*
echo "[docker] установлен; в группе docker: ${DOCKER_USERS}"
