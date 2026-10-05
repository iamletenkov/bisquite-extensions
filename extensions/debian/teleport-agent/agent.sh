# shellcheck shell=bash
# The bisquite-teleport-agent package: where it comes from and how it goes
# on. Sourced by install.sh (image build) and update.sh (running robot);
# tools/test-conf.sh and tools/test-teleport-agent.sh call the pure
# functions. The agent lives in its own repository and ships as a .deb:
# https://github.com/iamletenkov/bisquite-teleport-agent
#
# Parameters (environment):
#   AGENT_VERSION        3.0.0     package version
#   AGENT_SHA256         (pinned)  sha256 of the .deb; the pin below covers
#                                  the default version, any other needs it
#   AGENT_SHA256_<ARCH>  (empty)   per dpkg architecture (AMD64, ARM64),
#                                  wins over AGENT_SHA256
#   AGENT_MIRROR         (empty)   base URL: <base>/<file>, e.g. a portal's
#                                  /dist/teleport/
#   AGENT_URL            (empty)   the full URL of the .deb, wins over both
#   AGENT_DEB            (empty)   a local .deb instead of a download (the
#                                  sum is checked all the same)
# Default source — the GitHub release of the version.

agent_log_info(){ >&2 echo "teleport-agent: $*"; }
agent_log_error(){ >&2 echo "teleport-agent: ОШИБКА: $*"; }

agent_default_version(){ echo 3.0.0; }
# sha256 of bisquite-teleport-agent_3.0.0_all.deb (reproducible build).
agent_default_sha256(){ echo 16f8579d87bb0e6482f7230e8001721cbec0da53913bdaf13ea9e74f0142af6e; }
agent_deb_name(){ echo "bisquite-teleport-agent_$1_all.deb"; }
# agent_url <version> <url> <mirror>
agent_url(){
    if [[ -n "$2" ]]; then
        echo "$2"
    elif [[ -n "$3" ]]; then
        echo "${3%/}/$(agent_deb_name "$1")"
    else
        echo "https://github.com/iamletenkov/bisquite-teleport-agent/releases/download/v$1/$(agent_deb_name "$1")"
    fi
}
# agent_sha256 <version> <dpkg arch>: the pin in effect, empty — none.
agent_sha256(){
    local var="AGENT_SHA256_${2^^}"
    if [[ -n "${!var:-}" ]]; then
        echo "${!var}"
    elif [[ -n "${AGENT_SHA256:-}" ]]; then
        echo "$AGENT_SHA256"
    elif [[ "$1" == "$(agent_default_version)" ]]; then
        agent_default_sha256
    fi
}

RE_AGENT_URL='^https?://[A-Za-z0-9._~:/%+-]+$'

# agent_fetch <work dir> <dpkg arch>: the checked .deb, its path on stdout.
# Never an unpinned package: no sum — no download.
agent_fetch(){
    local work="$1" arch="$2" version sha file url
    version="${AGENT_VERSION:-$(agent_default_version)}"
    [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]] || { agent_log_error "AGENT_VERSION='$version': ожидали X.Y.Z"; return 1; }
    sha="$(agent_sha256 "$version" "$arch")"
    [[ -n "$sha" ]] || { agent_log_error "нет sha256 для пакета агента $version — задайте AGENT_SHA256"; return 1; }
    [[ "$sha" =~ ^[0-9a-f]{64}$ ]] || { agent_log_error "sha256 пакета агента: ожидали 64 hex"; return 1; }
    file="$work/$(agent_deb_name "$version")"
    if [[ -n "${AGENT_DEB:-}" ]]; then
        [[ -f "$AGENT_DEB" ]] || { agent_log_error "AGENT_DEB=$AGENT_DEB: файла нет"; return 1; }
        cp -- "$AGENT_DEB" "$file" || return 1
    else
        [[ -z "${AGENT_URL:-}" || "$AGENT_URL" =~ $RE_AGENT_URL ]] || { agent_log_error "AGENT_URL='$AGENT_URL': ожидали URL"; return 1; }
        [[ -z "${AGENT_MIRROR:-}" || "$AGENT_MIRROR" =~ $RE_AGENT_URL ]] || { agent_log_error "AGENT_MIRROR='$AGENT_MIRROR': ожидали URL"; return 1; }
        url="$(agent_url "$version" "${AGENT_URL:-}" "${AGENT_MIRROR:-}")"
        agent_log_info "скачиваю $url"
        curl -fL --retry 5 --retry-delay 5 \
            --connect-timeout 30 --speed-limit 10240 --speed-time 60 \
            -o "$file" "$url" || { agent_log_error "пакет агента не скачался"; return 1; }
    fi
    if ! echo "$sha  $file" | sha256sum -c --quiet - >/dev/null 2>&1; then
        agent_log_error "sha256 пакета агента не совпал (ждали $sha)"
        return 1
    fi
    echo "$file"
}

# Dependencies of the package that a minimal image may lack: bash,
# coreutils and util-linux are essential, curl and ca-certificates are not.
agent_deps(){
    local p missing=()
    for p in curl ca-certificates; do
        dpkg -s "$p" >/dev/null 2>&1 || missing+=("$p")
    done
    (( ${#missing[@]} )) || return 0
    apt-get update -q && apt-get install -y -q --no-install-recommends "${missing[@]}"
}

agent_install(){
    agent_deps || { agent_log_error "зависимости пакета агента не поставились"; return 1; }
    dpkg -i "$1" || { agent_log_error "dpkg -i $(basename "$1") не прошёл"; return 1; }
}
