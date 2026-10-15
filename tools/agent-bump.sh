#!/usr/bin/env bash
# Raise the bisquite-teleport-agent pin of the teleport-agent extension to a
# release of the agent, in the working tree only.
#
# Usage: tools/agent-bump.sh <tag> <SHA256SUMS>
#
#   <tag>         agent release tag, vX.Y.Z
#   <SHA256SUMS>  that release's SHA256SUMS file, e.g. fetched with
#                 gh release download <tag> -R iamletenkov/bisquite-teleport-agent \
#                     -p SHA256SUMS -D <dir>
#
# Edits: the default version and sha256 in agent.sh (and its comments), the
# extension version with a history line in extension.yaml, the
# AGENT_VERSION row of the README, the example in update.sh and the fixtures
# of tools/test-teleport-agent.sh. Does not commit, does not run the checks —
# the caller does (tools/check.sh).
#
# Prints `version=`, `sha256=`, `ext_version=` and `changed=true|false`
# (GITHUB_OUTPUT format) on stdout. An agent older than the pin or already
# pinned is `changed=false`, not an error: a rebuild of an old release
# dispatches here too. The same version with another sum is an error — the
# pinned package changed under its version, a human has to look.
set -euo pipefail

TAG="${1:-}"
SUMS="${2:-}"
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
EXT="$ROOT/extensions/debian/teleport-agent"
AGENT_SH="$EXT/agent.sh"
MANIFEST="$EXT/extension.yaml"
README="$EXT/README.md"
UPDATE_SH="$EXT/update.sh"
TESTS="$ROOT/tools/test-teleport-agent.sh"
SEMVER='[0-9]+\.[0-9]+\.[0-9]+'

die(){ echo "error: $*" >&2; exit 1; }

[[ "$TAG" =~ ^v[0-9]+\.[0-9]+\.[0-9]+$ ]] || { echo "error: tag must match vX.Y.Z, got '$TAG'" >&2; exit 2; }
[[ -f "$SUMS" ]] || { echo "error: SHA256SUMS file required, got '$SUMS'" >&2; exit 2; }

new="${TAG#v}"
deb="bisquite-teleport-agent_${new}_all.deb"
# sha256sum writes "<sum>  <file>" (text) or "<sum> *<file>" (binary).
sha="$(awk -v f="$deb" '$2 == f || $2 == "*" f {print $1}' "$SUMS")"
[[ "$sha" =~ ^[0-9a-f]{64}$ ]] || die "no single sha256 for $deb in $SUMS"

old="$(sed -nE "s/^agent_default_version\(\)\{ echo ($SEMVER); \}$/\1/p" "$AGENT_SH")"
old_sha="$(sed -nE 's/^agent_default_sha256\(\)\{ echo ([0-9a-f]{64}); \}$/\1/p' "$AGENT_SH")"
[[ "$old" =~ ^$SEMVER$ && -n "$old_sha" ]] || die "pin not found in $AGENT_SH"

echo "version=$new"
echo "sha256=$sha"

if [[ "$old" == "$new" ]]; then
    [[ "$old_sha" == "$sha" ]] \
        || die "agent $new is pinned with sha256 $old_sha, the release lists $sha"
    echo "changed=false"
    echo "teleport-agent already pins agent $new" >&2
    exit 0
fi
if [[ "$(printf '%s\n%s\n' "$old" "$new" | sort -V | tail -n 1)" == "$old" ]]; then
    echo "changed=false"
    echo "agent $new is older than the pinned $old — nothing to do" >&2
    exit 0
fi

ext_old="$(sed -nE "s/^version: ($SEMVER)$/\1/p" "$MANIFEST")"
[[ "$ext_old" =~ ^$SEMVER$ ]] || die "no version in $MANIFEST"
# The extension follows the agent version (3.0.1 pinned 3.0.1, 3.1.0 — 3.1.0);
# an extension already ahead by its own changes gets a minor bump instead.
if [[ "$(printf '%s\n%s\n' "$ext_old" "$new" | sort -V | tail -n 1)" == "$new" && "$new" != "$ext_old" ]]; then
    ext_new="$new"
else
    IFS=. read -r major minor _ <<< "$ext_old"
    ext_new="$major.$((minor + 1)).0"
fi
echo "ext_version=$ext_new"

old_re="${old//./\\.}"

# agent.sh: the pin, the comment above the sum and the parameter table.
sed -i -E \
    -e "s/^(agent_default_version\(\)\{ echo )$old_re(; \})$/\1$new\2/" \
    -e "s/^(agent_default_sha256\(\)\{ echo )[0-9a-f]{64}(; \})$/\1$sha\2/" \
    -e "s/^# sha256 of bisquite-teleport-agent_${SEMVER}_all\.deb \(GitHub release v$SEMVER\)\.$/# sha256 of $deb (GitHub release $TAG)./" \
    -e "s/^(#   AGENT_VERSION +)$SEMVER +/\1$(printf '%-10s' "$new")/" \
    "$AGENT_SH"

# extension.yaml: the new version, the history line on top of the others.
sed -i -E \
    -e "s/^version: $ext_old$/version: $ext_new/" \
    -e "/^layout: /a # $ext_new: пин пакета bisquite-teleport-agent $new." \
    "$MANIFEST"

sed -i -E "s/^(\| \`AGENT_VERSION\` \| \`)$SEMVER(\` \|)/\1$new\2/" "$README"
sed -i -E "s/(AGENT_DEB=\.\/bisquite-teleport-agent_)${SEMVER}(_all\.deb)/\1$new\2/" "$UPDATE_SH"

# The fixtures name the default version only: every standalone old version
# becomes the new one; other versions there (3.0.0, 3.0.2) stay below the
# pin, as a bump only ever goes up. The loop catches adjacent occurrences.
sed -i -E ":a; s/(^|[^0-9.])$old_re([^0-9.]|$)/\1$new\2/; ta" "$TESTS"

# A silent no-op here would ship a PR that half-moves the pin.
check(){ grep -qE -- "$2" "$1" || die "not updated in ${1#"$ROOT"/}: $2"; }
check "$AGENT_SH" "^agent_default_version\(\)\{ echo ${new//./\\.}; \}$"
check "$AGENT_SH" "^agent_default_sha256\(\)\{ echo $sha; \}$"
check "$AGENT_SH" "^# sha256 of ${deb//./\\.} \(GitHub release ${TAG//./\\.}\)\.$"
check "$AGENT_SH" "^#   AGENT_VERSION +${new//./\\.} "
check "$MANIFEST" "^version: ${ext_new//./\\.}$"
check "$MANIFEST" "^# ${ext_new//./\\.}: "
check "$README" "^\| \`AGENT_VERSION\` \| \`${new//./\\.}\` \|"
check "$UPDATE_SH" "AGENT_DEB=\./${deb//./\\.} "
check "$TESTS" "^DEB=${deb//./\\.}$"
if grep -qE "(^|[^0-9.])$old_re([^0-9.]|$)" "$AGENT_SH" "$TESTS" "$UPDATE_SH"; then
    die "old version $old still present"
fi

echo "changed=true"
