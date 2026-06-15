#!/usr/bin/env bash
# Extension: chromium-kiosk — полноэкранный Chromium через cage (wayland kiosk).
# Запускается во время сборки внутри образа (RUN_COMMAND), от root, идемпотентно.
# Требует графическую базу/GPU-seat; параметры тюнингуйте под железо.
#
# Параметры (env):
#   KIOSK_URL   стартовый URL (по умолчанию https://example.com)
#   KIOSK_USER  пользователь сессии (по умолчанию kiosk)
set -euo pipefail
export DEBIAN_FRONTEND=noninteractive

KIOSK_URL="${KIOSK_URL:-https://example.com}"
KIOSK_USER="${KIOSK_USER:-kiosk}"

apt-get update
apt-get install -y --no-install-recommends cage chromium seatd

if ! id "${KIOSK_USER}" >/dev/null 2>&1; then
  useradd -m -s /usr/sbin/nologin "${KIOSK_USER}"
fi
# Доступ к видео/вводу/seat для wayland-сессии.
for grp in video render input seat; do
  getent group "${grp}" >/dev/null 2>&1 && usermod -aG "${grp}" "${KIOSK_USER}" || true
done

cat > /etc/systemd/system/chromium-kiosk.service <<EOF
[Unit]
Description=Chromium kiosk (cage)
After=systemd-user-sessions.service seatd.service
Wants=seatd.service

[Service]
User=${KIOSK_USER}
PAMName=login
TTYPath=/dev/tty7
Environment=XDG_RUNTIME_DIR=/run/user/%U
ExecStart=/usr/bin/cage -- /usr/bin/chromium --kiosk --noerrdialogs --disable-infobars --no-first-run ${KIOSK_URL}
Restart=always

[Install]
WantedBy=graphical.target
EOF

systemctl enable seatd.service chromium-kiosk.service
systemctl set-default graphical.target

apt-get clean
rm -rf /var/lib/apt/lists/*
echo "[chromium-kiosk] включён; откроет ${KIOSK_URL} на загрузке (нужен GPU/DRM seat)"
