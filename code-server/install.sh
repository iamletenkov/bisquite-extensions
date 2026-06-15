#!/usr/bin/env bash
# Extension: code-server — VS Code в браузере.
# Запускается во время сборки внутри образа (RUN_COMMAND), от root, идемпотентно.
#
# Параметры (env):
#   CODE_SERVER_USER     пользователь systemd-сервиса (по умолчанию debian)
#   CODE_SERVER_VERSION  версия code-server (пусто = последняя)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

CODE_SERVER_USER="${CODE_SERVER_USER:-debian}"
CODE_SERVER_VERSION="${CODE_SERVER_VERSION:-}"

apt-get update
apt-get install -y --no-install-recommends curl ca-certificates

if [ -n "${CODE_SERVER_VERSION}" ]; then
  curl -fsSL https://code-server.dev/install.sh | sh -s -- --version "${CODE_SERVER_VERSION}"
else
  curl -fsSL https://code-server.dev/install.sh | sh
fi

# Официальный установщик кладёт шаблонный юнит code-server@.service.
systemctl enable "code-server@${CODE_SERVER_USER}"

apt-get clean
rm -rf /var/lib/apt/lists/*
echo "[code-server] установлен; включён сервис code-server@${CODE_SERVER_USER}"
echo "[code-server] пароль — в /home/${CODE_SERVER_USER}/.config/code-server/config.yaml после первого старта"
