#!/usr/bin/env bash
# Firefox from Mozilla's own APT repository — a real .deb, not the snap.
#
# WHY NOT THE DISTRIBUTION PACKAGE. On Ubuntu 22.04+ `firefox` is a
# transitional package (version 1:1snap1-0ubuntu2) that installs a snap on
# first use, and the image never seeds snapd: the robot ends up with a menu
# entry and no browser. Chromium on arm64 is the same story. Mozilla
# publishes amd64 and arm64 builds at packages.mozilla.org (checked
# 2026-09-14: 155.0.1 for arm64), so the browser is baked in at build time
# and first boot needs no network.
#
# The epoch of the transitional package (1:) outranks Mozilla's version
# string, so a plain `apt-get install` would keep the stub. Pin 1000 on
# origin packages.mozilla.org plus --allow-downgrades replaces it.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} firefox: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} firefox: $*"; }

# Fingerprint published by Mozilla for the repository signing key. The key is
# downloaded over TLS and then compared with this value: a key that does not
# match is refused before it lands in the keyring.
MOZILLA_KEY_URL="https://packages.mozilla.org/apt/repo-signing-key.gpg"
MOZILLA_KEY_FPR="35BAA0B33E9EB396F59CA838C0BA5CE6DC6315A3"
KEYRING=/etc/apt/keyrings/packages.mozilla.org.asc

# Optional language pack, e.g. FIREFOX_LANGPACK=ru -> firefox-l10n-ru.
FIREFOX_LANGPACK="${FIREFOX_LANGPACK:-}"
if [[ -n "$FIREFOX_LANGPACK" && ! "$FIREFOX_LANGPACK" =~ ^[a-z]{2,3}(-[A-Za-z]{2,4})?$ ]]; then
    log_error "FIREFOX_LANGPACK='$FIREFOX_LANGPACK': ожидали код языка вроде ru или pt-BR"
    exit 1
fi

export DEBIAN_FRONTEND=noninteractive
apt-get update
apt-get install -y --no-install-recommends ca-certificates curl gnupg

install -d -m 0755 /etc/apt/keyrings
tmp_key="$(mktemp)"
# gpg needs a home directory; a chroot during the build has no ~/.gnupg and
# gpg exits 2 with "Fatal: /root/.gnupg: directory does not exist".
gpg_home="$(mktemp -d)"
trap 'rm -f "$tmp_key"; rm -r -f -- "$gpg_home"' EXIT
for attempt in 1 2 3 4 5; do
    if curl -fsSL --max-time 60 "$MOZILLA_KEY_URL" -o "$tmp_key"; then
        break
    fi
    (( attempt == 5 )) && { log_error "не скачать ключ $MOZILLA_KEY_URL"; exit 1; }
    sleep $(( attempt * 2 ))
done

actual_fpr="$(gpg --homedir "$gpg_home" --show-keys --with-colons "$tmp_key" \
    | awk -F: '$1 == "fpr" { print $10; exit }')"
if [[ "$actual_fpr" != "$MOZILLA_KEY_FPR" ]]; then
    log_error "отпечаток ключа '$actual_fpr' не совпал с ожидаемым $MOZILLA_KEY_FPR"
    exit 1
fi
install -m 0644 "$tmp_key" "$KEYRING"

echo "deb [signed-by=$KEYRING] https://packages.mozilla.org/apt mozilla main" \
    > /etc/apt/sources.list.d/mozilla.list

# Only Firefox packages follow the pin: the repository carries nothing else
# today, but a broad `Package: *` would silently prefer it for anything added
# there later.
cat > /etc/apt/preferences.d/mozilla <<'PIN'
Package: firefox*
Pin: origin packages.mozilla.org
Pin-Priority: 1000
PIN

packages=(firefox)
[[ -n "$FIREFOX_LANGPACK" ]] && packages+=("firefox-l10n-${FIREFOX_LANGPACK}")

apt-get update
apt-get install -y --allow-downgrades "${packages[@]}"

version="$(dpkg -s firefox | sed -n 's/^Version: //p')"
case "$version" in
    *snap*) log_error "остался транзитный пакет snap ($version) — пин не сработал"; exit 1 ;;
esac
[[ -x /usr/lib/firefox/firefox ]] || { log_error "нет /usr/lib/firefox/firefox после установки"; exit 1; }

log_info "установлен Firefox $version из packages.mozilla.org"
