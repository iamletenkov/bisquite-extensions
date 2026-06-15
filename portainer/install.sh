#!/usr/bin/env bash
# Extension: portainer — Portainer CE как docker-контейнер под управлением systemd.
# Запускается во время сборки внутри образа (RUN_COMMAND), от root, идемпотентно.
# Зависит от расширения docker (ставьте docker раньше).
#
# Параметры (env):
#   PORTAINER_PORT   HTTPS-порт UI (по умолчанию 9443)
#   PORTAINER_IMAGE  образ (по умолчанию portainer/portainer-ce:latest)
set -euo pipefail

PORTAINER_PORT="${PORTAINER_PORT:-9443}"
PORTAINER_IMAGE="${PORTAINER_IMAGE:-portainer/portainer-ce:latest}"

if ! command -v docker >/dev/null 2>&1; then
  echo "[portainer] нужен docker — подключите extension docker раньше" >&2
  exit 1
fi

cat > /etc/systemd/system/portainer.service <<EOF
[Unit]
Description=Portainer CE
Requires=docker.service
After=docker.service

[Service]
TimeoutStartSec=0
Restart=always
# Образ скачается при первом старте (на загрузке ВМ есть сеть).
ExecStartPre=-/usr/bin/docker rm -f portainer
ExecStart=/usr/bin/docker run --rm --name portainer \\
  -p ${PORTAINER_PORT}:9443 \\
  -v /var/run/docker.sock:/var/run/docker.sock \\
  -v portainer_data:/data \\
  ${PORTAINER_IMAGE}
ExecStop=/usr/bin/docker stop portainer

[Install]
WantedBy=multi-user.target
EOF

systemctl enable portainer.service
echo "[portainer] юнит установлен; UI поднимется на :${PORTAINER_PORT} после загрузки"
