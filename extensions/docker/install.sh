#!/usr/bin/env bash
# Install Docker CE using the official convenience script with robust retries and chroot-safe checks

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} $*"; }

apt_retry(){
  local max=5; local n=1
  while true; do
    if "$@"; then return 0; fi
    if (( n >= max )); then return 1; fi
    local d=$(( n * 2 )); log_warn "apt command failed, retry in ${d}s... ($n/$max)"
    sleep "$d"; n=$(( n + 1 ))
  done
}

ensure_curl() {
  if command -v curl >/dev/null 2>&1; then
    return 0
  fi
  if ! command -v apt-get >/dev/null 2>&1; then
    log_error "curl not found and apt-get is unavailable to install it"
    exit 1
  fi
  log_info "curl not found, installing via apt-get..."
  apt_retry apt-get update
  apt_retry apt-get install -y --no-install-recommends ca-certificates curl
}

run_docker_convenience_script() {
  local tmp_script
  tmp_script=$(mktemp /tmp/get-docker.sh.XXXXXX)
  log_info "Fetching Docker convenience script..."
  if ! curl -fsSL https://get.docker.com -o "${tmp_script}"; then
    log_error "Failed to download Docker convenience script"
    exit 1
  fi

  log_info "Running Docker convenience script..."
  if command -v sudo >/dev/null 2>&1 && [[ "${EUID}" -ne 0 ]]; then
    sudo sh "${tmp_script}"
  else
    sh "${tmp_script}"
  fi
  rm -f "${tmp_script}"
}

ensure_curl
run_docker_convenience_script

systemctl enable docker >/dev/null 2>&1 || true
systemctl start docker >/dev/null 2>&1 || true

if ! command -v docker >/dev/null 2>&1; then
  log_error "Docker binary not found after installation"
  exit 1
fi
log_info "Docker installed: $(docker --version 2>/dev/null || echo unknown)"

log_info "Installing docker user provisioning service..."
cat > /usr/local/sbin/docker-user-setup.sh <<'EOS'
#!/usr/bin/env bash
set -euo pipefail

resolve_user() {
  if command -v cloud-init >/dev/null 2>&1 && command -v yq >/dev/null 2>&1; then
    local ud
    if ! ud=$(cloud-init query userdata 2>/dev/null); then
      if [[ -f "/var/lib/cloud/instance/user-data.txt" ]]; then
        ud=$(cat /var/lib/cloud/instance/user-data.txt 2>/dev/null || echo "")
      else
        echo ""; return 0
      fi
    fi
    local u
    u=$(echo "$ud" | env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" TERM=dumb yq -r '.user // empty' 2>/dev/null || true)
    if [[ -z "$u" ]]; then
      u=$(echo "$ud" | env -i PATH="/usr/local/sbin:/usr/local/bin:/usr/sbin:/usr/bin:/sbin:/bin" TERM=dumb yq -r '.users[0].name // empty' 2>/dev/null || true)
    fi
    echo "$u"; return 0
  fi
  echo ""; return 0
}

main(){
  local user
  user=$(resolve_user)
  if [[ -z "$user" ]]; then
    echo "[docker-user-setup] cloud-init user not found, skipping"
    exit 0
  fi
  if ! id "$user" >/dev/null 2>&1; then
    echo "[docker-user-setup] user '$user' does not exist yet, skipping"
    exit 0
  fi
  if groups "$user" | grep -q '\bdocker\b'; then
    echo "[docker-user-setup] user '$user' already in docker group"
    exit 0
  fi
  usermod -aG docker "$user"
  echo "[docker-user-setup] added '$user' to docker group"
}
main "$@"
EOS
chmod +x /usr/local/sbin/docker-user-setup.sh

# Установим unit-файл в системный каталог (если расширение будет скопировано как в code-server)
if [[ -f "/opt/vmsetup/docker/configure-docker.service" ]]; then
  install -m 0644 /opt/vmsetup/docker/configure-docker.service /etc/systemd/system/configure-docker.service || true
fi

cat > /etc/systemd/system/docker-user-setup.service <<'EOS'
[Unit]
Description=Add cloud-init user to docker group
After=network-online.target docker.service
Wants=network-online.target

[Service]
Type=oneshot
ExecStart=/usr/local/sbin/docker-user-setup.sh
RemainAfterExit=yes
StandardOutput=journal
StandardError=journal

[Install]
WantedBy=multi-user.target
EOS

systemctl daemon-reload || true
systemctl enable docker-user-setup.service || true
systemctl enable configure-docker.service || true

log_info "Docker extension installation completed"
