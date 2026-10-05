#!/usr/bin/env bash
# shellcheck disable=SC2016  # literal $… in fakes is the test data
# Тесты обёртки teleport-agent 3.x: install.sh (Teleport + пакет агента) и
# update.sh (пакет агента на работающем роботе) — на подменённом корне
# (BISQUITE_TELEPORT_ROOT), с поддельными curl, dpkg, dpkg-query, apt-get и
# teleport в PATH. Пакет — подставной файл: проверяется, что скачивается,
# сверяется по sha256 и отдаётся dpkg -i, а не сам пакет (его тесты — в
# репозитории bisquite-teleport-agent). root, systemd и сеть не нужны.
#
#   tools/test-teleport-agent.sh        код 0 — все проверки прошли

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
EXT="$REPO/extensions/debian/teleport-agent"

TMP="$(mktemp -d)"
trap 'rm -r -f -- "$TMP"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
exec 3>&2
bad(){ fail=$((fail + 1)); echo "FAIL: $*" >&3; }
check(){ local what="$1"; shift; if "$@"; then ok; else bad "$what"; fi; }
check_not(){ local what="$1"; shift; if "$@"; then bad "$what"; else ok; fi; }
eq(){ local what="$1" want="$2" got="$3"; if [[ "$want" == "$got" ]]; then ok; else bad "$what: ждали [$want], получили [$got]"; fi; }

GH=https://github.com/iamletenkov/bisquite-teleport-agent/releases/download
DEB=bisquite-teleport-agent_3.0.0_all.deb

# ---------------------------------------------------------------------------
# FAKE: logs and switches of the fakes.
#   curl.urls       every URL curl was asked for
#   curl-fails      exists — every download fails
#   deb             what a download of *.deb returns
#   tarball         what a download of *.tar.gz returns
#   tarball.sha256  what a download of *.sha256 returns
#   arch            dpkg --print-architecture (amd64 by default)
#   dpkg.log        dpkg -i calls: the file name and its sha256
#   missing         packages `dpkg -s` does not know
#   apt.log         apt-get calls
new_root(){
    ROOT="$(mktemp -d "$TMP/root.XXXXXX")"
    FAKE="$ROOT/fake"
    mkdir -p "$ROOT/bin" "$FAKE"
    export BISQUITE_TELEPORT_ROOT="$ROOT" FAKE
    export PATH="$ROOT/bin:$BASE_PATH"
    unset AGENT_VERSION AGENT_SHA256 AGENT_SHA256_AMD64 AGENT_SHA256_ARM64 AGENT_MIRROR AGENT_URL AGENT_DEB
    unset TELEPORT_VERSION TELEPORT_MIRROR TELEPORT_SHA256
    cat > "$ROOT/bin/curl" <<'EOF'
#!/usr/bin/env bash
out=""; url=""
while (( $# )); do
    case "$1" in
        -o) out="$2"; shift 2 ;;
        --retry|--retry-delay|--connect-timeout|--speed-limit|--speed-time) shift 2 ;;
        -*) shift ;;
        *) url="$1"; shift ;;
    esac
done
echo "$url" >> "$FAKE/curl.urls"
[[ -f "$FAKE/curl-fails" ]] && exit 22
case "$url" in
    *.deb) src="$FAKE/deb" ;;
    *.tar.gz) src="$FAKE/tarball" ;;
    *.sha256) src="$FAKE/tarball.sha256" ;;
    *) exit 22 ;;
esac
[[ -f "$src" ]] || exit 22
if [[ -n "$out" ]]; then cat "$src" > "$out"; else cat "$src"; fi
EOF
    cat > "$ROOT/bin/dpkg" <<'EOF'
#!/usr/bin/env bash
case "$1" in
    --print-architecture) cat "$FAKE/arch" 2>/dev/null || echo amd64 ;;
    -s) ! grep -qx "$2" "$FAKE/missing" 2>/dev/null ;;
    -i) echo "$(basename "$2") $(sha256sum < "$2" | cut -d' ' -f1)" >> "$FAKE/dpkg.log" ;;
    *) exit 2 ;;
esac
EOF
    printf '#!/bin/sh\nexit 1\n' > "$ROOT/bin/dpkg-query"
    printf '#!/bin/sh\necho "$*" >> "$FAKE/apt.log"\n' > "$ROOT/bin/apt-get"
    chmod +x "$ROOT/bin/"*
    echo "fake package $RANDOM" > "$FAKE/deb"
    DEB_SHA="$(sha256sum < "$FAKE/deb" | cut -d' ' -f1)"
}
BASE_PATH="$PATH"
fake_teleport(){
    mkdir -p "$ROOT/usr/local/bin"
    printf '#!/bin/sh\necho "Teleport v%s git: go1.25"\n' "$1" > "$ROOT/usr/local/bin/teleport"
    chmod +x "$ROOT/usr/local/bin/teleport"
}
# A Teleport tarball with only teleport/teleport in it.
fake_tarball(){
    local d="$TMP/tb.$RANDOM"
    mkdir -p "$d/teleport"
    printf '#!/bin/sh\necho "Teleport v%s git: go1.25"\n' "$1" > "$d/teleport/teleport"
    chmod +x "$d/teleport/teleport"
    tar -czf "$FAKE/tarball" -C "$d" teleport
    TB_SHA="$(sha256sum < "$FAKE/tarball" | cut -d' ' -f1)"
    echo "$TB_SHA  teleport-v$1-linux-amd64-bin.tar.gz" > "$FAKE/tarball.sha256"
}
install_sh(){ bash "$EXT/install.sh"; }
update_sh(){ bash "$EXT/update.sh"; }
urls(){ cat "$FAKE/curl.urls" 2>/dev/null; }
installed(){ cat "$FAKE/dpkg.log" 2>/dev/null; }
pure(){ bash -c 'source "$1"; shift; "$@"' _ "$EXT/agent.sh" "$@"; }

# ===========================================================================
echo "== agent.sh: источник и пин =="
eq "версия по умолчанию" 3.0.0 "$(pure agent_default_version)"
check "пин по умолчанию — 64 hex" grep -qE '^[0-9a-f]{64}$' <<< "$(pure agent_default_sha256)"
eq "имя файла" "$DEB" "$(pure agent_deb_name 3.0.0)"
eq "по умолчанию — релиз GitHub" "$GH/v3.0.0/$DEB" "$(pure agent_url 3.0.0 '' '')"
eq "зеркало" "https://portal.example.org/dist/teleport/$DEB" "$(pure agent_url 3.0.0 '' https://portal.example.org/dist/teleport/)"
eq "AGENT_URL сильнее зеркала" https://x.example.org/a.deb "$(pure agent_url 3.0.0 https://x.example.org/a.deb https://portal.example.org/)"
eq "сумма версии по умолчанию — пин" "$(pure agent_default_sha256)" "$(pure agent_sha256 3.0.0 amd64)"
eq "другая версия без суммы — пусто" "" "$(pure agent_sha256 3.0.1 amd64)"
eq "AGENT_SHA256" "$(printf 'a%.0s' {1..64})" "$(AGENT_SHA256="$(printf 'a%.0s' {1..64})" pure agent_sha256 3.0.1 amd64)"
eq "AGENT_SHA256_ARM64 сильнее AGENT_SHA256 на arm64" "$(printf 'b%.0s' {1..64})" \
    "$(AGENT_SHA256="$(printf 'a%.0s' {1..64})" AGENT_SHA256_ARM64="$(printf 'b%.0s' {1..64})" pure agent_sha256 3.0.0 arm64)"
eq "AGENT_SHA256_ARM64 не действует на amd64" "$(printf 'a%.0s' {1..64})" \
    "$(AGENT_SHA256="$(printf 'a%.0s' {1..64})" AGENT_SHA256_ARM64="$(printf 'b%.0s' {1..64})" pure agent_sha256 3.0.0 amd64)"

# ===========================================================================
echo "== install.sh: сборка образа =="
new_root; fake_teleport 18.10.0
out="$(AGENT_SHA256="$DEB_SHA" install_sh 2>&1)"; rc=$?
eq "Teleport уже стоит, пакет по пину — код 0" 0 "$rc"
eq "скачан только пакет, с GitHub" "$GH/v3.0.0/$DEB" "$(urls)"
eq "dpkg -i — тот самый файл" "$DEB $DEB_SHA" "$(installed)"
check_not "apt-get не звался" test -e "$FAKE/apt.log"
check "подсказка про join" grep -q 'bisquite-teleport join' <<< "$out"

new_root; fake_teleport 18.10.0
out="$(install_sh 2>&1)"; rc=$?
check "пин по умолчанию, файл другой — отказ" test "$rc" -ne 0
check "пин по умолчанию — текст про sha256" grep -q 'sha256 пакета агента не совпал' <<< "$out"
eq "пин не совпал — dpkg не звался" "" "$(installed)"

new_root; fake_teleport 18.10.0
out="$(AGENT_VERSION=3.0.1 install_sh 2>&1)"; rc=$?
check "другая версия без суммы — отказ" test "$rc" -ne 0
check "другая версия без суммы — текст" grep -q 'задайте AGENT_SHA256' <<< "$out"
eq "другая версия без суммы — сеть не трогалась" "" "$(urls)"

new_root; fake_teleport 18.10.0
AGENT_SHA256="$DEB_SHA" AGENT_MIRROR=https://portal.example.org/dist/teleport/ install_sh >/dev/null 2>&1
eq "AGENT_MIRROR" "https://portal.example.org/dist/teleport/$DEB" "$(urls)"
new_root; fake_teleport 18.10.0
AGENT_SHA256="$DEB_SHA" AGENT_URL=https://x.example.org/pkgs/agent.deb AGENT_MIRROR=https://portal.example.org/ install_sh >/dev/null 2>&1
eq "AGENT_URL сильнее зеркала" https://x.example.org/pkgs/agent.deb "$(urls)"
new_root; fake_teleport 18.10.0
check_not "AGENT_URL с кавычкой — отказ" env AGENT_SHA256="$DEB_SHA" AGENT_URL='https://x"y/a.deb' bash "$EXT/install.sh" 2>/dev/null
eq "AGENT_URL с кавычкой — dpkg не звался" "" "$(installed)"
new_root; fake_teleport 18.10.0
check_not "AGENT_VERSION не semver — отказ" env AGENT_SHA256="$DEB_SHA" AGENT_VERSION=3.0 bash "$EXT/install.sh" 2>/dev/null

new_root; fake_teleport 18.10.0; echo arm64 > "$FAKE/arch"
AGENT_SHA256="$(printf 'a%.0s' {1..64})" AGENT_SHA256_ARM64="$DEB_SHA" install_sh >/dev/null 2>&1; rc=$?
eq "arm64: сумма AGENT_SHA256_ARM64 — код 0" 0 "$rc"
eq "arm64: тот же пакет _all" "$DEB $DEB_SHA" "$(installed)"

new_root; fake_teleport 18.10.0; touch "$FAKE/curl-fails"
out="$(AGENT_SHA256="$DEB_SHA" install_sh 2>&1)"; rc=$?
check "пакет не скачался — отказ" test "$rc" -ne 0
check "пакет не скачался — текст" grep -q 'не скачался' <<< "$out"
eq "пакет не скачался — dpkg не звался" "" "$(installed)"

new_root; fake_teleport 18.10.0; printf 'ca-certificates\n' > "$FAKE/missing"
AGENT_SHA256="$DEB_SHA" install_sh >/dev/null 2>&1
check "нет ca-certificates — apt-get его ставит" grep -q 'install .*ca-certificates' "$FAKE/apt.log"
check_not "нет ca-certificates — curl не ставится заново" grep -q 'install .*curl' "$FAKE/apt.log"

new_root; echo armhf > "$FAKE/arch"
check_not "armhf — отказ" env AGENT_SHA256="$DEB_SHA" bash "$EXT/install.sh" 2>/dev/null
eq "armhf — сеть не трогалась" "" "$(urls)"

# Teleport itself: as before 3.0.0 — tarball by version, checked by sha256.
new_root; fake_tarball 18.10.0
out="$(AGENT_SHA256="$DEB_SHA" install_sh 2>&1)"; rc=$?
eq "Teleport с CDN и пакет — код 0" 0 "$rc"
eq "Teleport с CDN: сумма, tarball, пакет" \
    "https://cdn.teleport.dev/teleport-v18.10.0-linux-amd64-bin.tar.gz.sha256
https://cdn.teleport.dev/teleport-v18.10.0-linux-amd64-bin.tar.gz
$GH/v3.0.0/$DEB" "$(urls)"
check "бинарь teleport установлен" grep -q 'v18.10.0' <<< "$("$ROOT/usr/local/bin/teleport" version)"
eq "пакет установлен после Teleport" "$DEB $DEB_SHA" "$(installed)"

new_root; fake_tarball 18.10.0
TELEPORT_SHA256="$TB_SHA" TELEPORT_MIRROR=https://binaries.example.org AGENT_SHA256="$DEB_SHA" install_sh >/dev/null 2>&1
eq "Teleport с зеркала по пину — без .sha256 с CDN" \
    "https://binaries.example.org/binaries/teleport/18.10.0/teleport-v18.10.0-linux-amd64-bin.tar.gz
$GH/v3.0.0/$DEB" "$(urls)"

new_root; fake_tarball 18.10.0
out="$(TELEPORT_SHA256="$(printf '0%.0s' {1..64})" AGENT_SHA256="$DEB_SHA" install_sh 2>&1)"; rc=$?
check "tarball не совпал с TELEPORT_SHA256 — отказ" test "$rc" -ne 0
eq "tarball не совпал — пакет не ставился" "" "$(installed)"

new_root; fake_teleport 18.10.0
mkdir -p "$ROOT/var/lib/teleport"; echo 11111111-2222 > "$ROOT/var/lib/teleport/host_uuid"
out="$(AGENT_SHA256="$DEB_SHA" install_sh 2>&1)"; rc=$?
check "регистрация в образе — отказ" test "$rc" -ne 0
check "регистрация в образе — текст" grep -q 'одной нодой' <<< "$out"

# ===========================================================================
echo "== update.sh: работающий робот =="
# A robot of 2.x: agent 18.6.8 (older than the default), joined.
old_robot(){
    new_root; fake_teleport 18.6.8
    mkdir -p "$ROOT/usr/local/sbin" "$ROOT/var/lib/teleport"
    ln -s /opt/bisquite/teleport-agent/bisquite-teleport "$ROOT/usr/local/sbin/bisquite-teleport"
    echo 11111111-2222 > "$ROOT/var/lib/teleport/host_uuid"
}
old_robot
out="$(AGENT_SHA256="$DEB_SHA" update_sh 2>&1)"; rc=$?
eq "update.sh — код 0" 0 "$rc"
eq "update.sh: только пакет, Teleport не скачивался" "$GH/v3.0.0/$DEB" "$(urls)"
eq "update.sh: dpkg -i пакета" "$DEB $DEB_SHA" "$(installed)"
check "update.sh: агент 18.6.8 не тронут" grep -q 'v18.6.8' <<< "$("$ROOT/usr/local/bin/teleport" version)"
check "update.sh: сказано, что было расширение 2.x" grep -q 'было: расширение 2.x' <<< "$out"
check "update.sh: подсказка про labels-enable" grep -q 'labels-enable' <<< "$out"

old_robot
out="$(update_sh 2>&1)"; rc=$?
check "update.sh: пин не совпал — отказ" test "$rc" -ne 0
check "update.sh: пин не совпал — ничего не изменено" grep -q 'ничего не изменено' <<< "$out"
eq "update.sh: пин не совпал — dpkg не звался" "" "$(installed)"

old_robot
cp "$FAKE/deb" "$TMP/local.deb"
AGENT_DEB="$TMP/local.deb" AGENT_SHA256="$DEB_SHA" update_sh >/dev/null 2>&1; rc=$?
eq "update.sh AGENT_DEB — код 0" 0 "$rc"
eq "update.sh AGENT_DEB — сеть не трогалась" "" "$(urls)"
eq "update.sh AGENT_DEB — dpkg -i под именем пакета" "$DEB $DEB_SHA" "$(installed)"
old_robot
echo other > "$TMP/other.deb"
check_not "update.sh AGENT_DEB чужой — отказ" env AGENT_DEB="$TMP/other.deb" AGENT_SHA256="$DEB_SHA" bash "$EXT/update.sh" 2>/dev/null
eq "update.sh AGENT_DEB чужой — dpkg не звался" "" "$(installed)"

old_robot
AGENT_SHA256="$DEB_SHA" AGENT_MIRROR=https://portal.example.org/dist/teleport bash "$EXT/update.sh" >/dev/null 2>&1
eq "update.sh AGENT_MIRROR" "https://portal.example.org/dist/teleport/$DEB" "$(urls)"

# From an archive, as a portal hands it out: git archive of the extension.
if command -v git >/dev/null 2>&1 && git -C "$REPO" rev-parse --git-dir >/dev/null 2>&1; then
    old_robot
    idx="$TMP/index"
    GIT_INDEX_FILE="$idx" git -C "$REPO" read-tree HEAD \
        && GIT_INDEX_FILE="$idx" git -C "$REPO" add -- extensions/debian/teleport-agent \
        && tree="$(GIT_INDEX_FILE="$idx" git -C "$REPO" write-tree)" \
        && git -C "$REPO" archive "$tree" extensions/debian/teleport-agent lib | gzip -n > "$TMP/ta.tar.gz"
    mkdir -p "$TMP/ta" && tar -xzf "$TMP/ta.tar.gz" -C "$TMP/ta"
    AGENT_SHA256="$DEB_SHA" bash "$TMP/ta/extensions/debian/teleport-agent/update.sh" >/dev/null 2>&1; rc=$?
    eq "update.sh из архива git archive — код 0" 0 "$rc"
    eq "update.sh из архива — dpkg -i пакета" "$DEB $DEB_SHA" "$(installed)"
else
    echo "ПРОПУЩЕНО: update.sh из архива — нет git" >&3
fi

echo
echo "проверок: $((pass + fail)), не прошло: $fail"
(( fail == 0 ))
