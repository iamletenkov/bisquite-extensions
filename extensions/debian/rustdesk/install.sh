#!/usr/bin/env bash
# RustDesk: the .deb from GitHub releases by version + sha256, rustdesk.service
# enabled, the renderer of server settings (configure-rustdesk.service) enabled.
#
# The image carries NO server addresses and NO device identity: addresses come
# from /etc/bisquite/rustdesk/config on the device (bisquite-conf set rustdesk …),
# and RustDesk.toml (ID, key pair, password) is removed here, so each device
# makes its own on the first start.
#
# Parameters (environment, from VMFILE):
#   RUSTDESK_VERSION   1.5.0           release tag on github.com/rustdesk/rustdesk
#   RUSTDESK_SHA256    pin of 1.5.0    sha256 of rustdesk-<version>-x86_64.deb;
#                                      required for any other version
#   RUSTDESK_URL       (empty)         full URL of the .deb (a mirror); empty —
#                                      the GitHub release asset
#   RUSTDESK_ID_SERVER, RUSTDESK_RELAY_SERVER, RUSTDESK_API_SERVER, RUSTDESK_KEY
#                                      the `rustdesk` domain (schema in knobs);
#                                      normally left empty in the image and set
#                                      on the device
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} rustdesk: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} rustdesk: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} rustdesk: $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
for f in knobs knobs.apply configure.sh render-toml.sh configure-rustdesk.service lib/bisquite-conf; do
    [[ -f "$SCRIPT_DIR/$f" ]] || { log_error "рядом нет $f — сборка не доставила каталог расширения целиком"; exit 1; }
done
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/bisquite-conf"

# Pins: version -> sha256 of the x86_64 package (GitHub release asset digest,
# checked against the downloaded file 2026-10-14).
DEFAULT_VERSION=1.5.0
pinned_sha256(){
    case "$1" in
        1.5.0) echo 4e2b9701d25a7ef373f3d09bda584a37d6902f97a6ab15f2e86d4a5783e2a0ec ;;
    esac
}

version="${RUSTDESK_VERSION:-$DEFAULT_VERSION}"
sha256="${RUSTDESK_SHA256:-$(pinned_sha256 "$version")}"
[[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { log_error "RUSTDESK_VERSION='$version': ожидали X.Y.Z"; exit 1; }
[[ "$sha256" =~ ^[0-9a-f]{64}$ ]] || { log_error "для RustDesk $version нет sha256 — задайте RUSTDESK_SHA256 (digest файла rustdesk-$version-x86_64.deb на странице релиза)"; exit 1; }

arch="$(dpkg --print-architecture)"
[[ "$arch" == amd64 ]] || { log_error "архитектура $arch: закреплён и проверен только x86_64-пакет"; exit 1; }
file="rustdesk-$version-x86_64.deb"
url="${RUSTDESK_URL:-https://github.com/rustdesk/rustdesk/releases/download/$version/$file}"
[[ "$url" =~ ^https?://[A-Za-z0-9.:/_~%+-]+$ ]] || { log_error "RUSTDESK_URL='$url': ожидали URL"; exit 1; }

apt_retry(){
    local i
    for i in 1 2 3; do
        "$@" && return 0
        log_warn "попытка $i: $* — не удалась, повтор через 10 с"
        sleep 10
    done
    return 1
}

export DEBIAN_FRONTEND=noninteractive
apt_retry apt-get update -q || { log_error "apt-get update не прошёл"; exit 1; }

installed="$(dpkg-query -W -f='${Status} ${Version}\n' rustdesk 2>/dev/null || true)"
if [[ "$installed" == "install ok installed $version" ]]; then
    log_info "RustDesk $version уже установлен"
else
    command -v curl >/dev/null 2>&1 || apt_retry apt-get install -y -q --no-install-recommends curl ca-certificates
    WORK="$(mktemp -d /var/tmp/rustdesk.XXXXXX)"
    trap 'rm -r -f -- "$WORK"' EXIT
    log_info "скачиваю $url"
    curl -fL --retry 5 --retry-delay 5 --connect-timeout 30 --speed-limit 10240 --speed-time 60 \
        -o "$WORK/$file" "$url" || { log_error "$file не скачался"; exit 1; }
    echo "$sha256  $WORK/$file" | sha256sum -c --quiet - || { log_error "sha256 $file не совпал с $sha256"; exit 1; }
    # apt resolves the package's dependencies (GTK, X11 and audio libraries).
    # The file is readable by _apt: mktemp -d is 0700.
    chmod 0755 "$WORK"; chmod 0644 "$WORK/$file"
    apt_retry apt-get install -y -q "$WORK/$file" || { log_error "пакет $file не установился"; exit 1; }
    log_info "установлен $(dpkg-query -W -f='${Package} ${Version}' rustdesk)"
fi

# The unit: the package's postinst copies it only when PID 1 is systemd —
# inside the build appliance it is not, so the unit would be missing.
UNIT=/usr/lib/systemd/system/rustdesk.service
if [[ ! -f "$UNIT" && ! -f /etc/systemd/system/rustdesk.service ]]; then
    install -D -m 0644 /usr/share/rustdesk/files/systemd/rustdesk.service "$UNIT"
    # The same fix as postinst: ExecStop needs an absolute path.
    sed -i 's|^ExecStop=pkill|ExecStop=/usr/bin/pkill|' "$UNIT"
    log_info "юнит $UNIT положен (postinst пакета делает это только под systemd)"
fi
[[ -e /usr/bin/rustdesk ]] || ln -sfn /usr/share/rustdesk/rustdesk /usr/bin/rustdesk

conf_init rustdesk "$SCRIPT_DIR/knobs" --env || { log_error "/etc/bisquite/rustdesk/config не записан"; exit 1; }
install -m 0644 "$SCRIPT_DIR/configure-rustdesk.service" /etc/systemd/system/configure-rustdesk.service

# Under systemd (a test container, not the appliance) postinst has started the
# service, and it has made an ID already: stop it before the cleanup below.
if [[ -d /run/systemd/system ]]; then
    systemctl stop rustdesk.service 2>/dev/null || true
fi

# --- no identity in the image ----------------------------------------------
# RustDesk.toml holds id, key pair, salt and password; RustDesk2.toml the
# options. Both are made on the device: the ID from /etc/machine-id (reset by
# virt-sysprep at the end of the build), the options by configure-rustdesk.
homes=(/root /etc/skel)
while IFS=: read -r _ _ uid _ _ home _; do
    if (( uid >= 1000 && uid < 65534 )) && [[ -d "$home" ]]; then homes+=("$home"); fi
done < <(getent passwd)
for h in "${homes[@]}"; do
    for f in RustDesk.toml RustDesk2.toml RustDesk_local.toml; do
        if [[ -e "$h/.config/rustdesk/$f" ]]; then
            rm -f "$h/.config/rustdesk/$f"
            log_info "удалён $h/.config/rustdesk/$f — у каждого устройства свой ID"
        fi
    done
done
rm -f /var/lib/bisquite/rustdesk/managed
leftover="$(find "${homes[@]}" -path '*/.config/rustdesk/RustDesk*.toml' 2>/dev/null || true)"
[[ -z "$leftover" ]] || { log_error "в образе остались файлы RustDesk: $leftover"; exit 1; }

systemctl daemon-reload 2>/dev/null || true
systemctl enable rustdesk.service configure-rustdesk.service
log_info "rustdesk.service и configure-rustdesk.service включены; сервер задаётся на устройстве: sudo bisquite-conf set rustdesk RUSTDESK_ID_SERVER=… RUSTDESK_KEY=…"
