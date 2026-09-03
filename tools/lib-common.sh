#!/usr/bin/env bash
# Shared helpers for sync-lib.sh and check-lib.sh: one definition of where the
# canonical file lives, what header a vendored copy carries, and which
# directories receive a copy.
#
# Sourced, never executed — отсюда disable SC2034: переменные использует
# тот, кто сорсит файл, а не сам файл.
# shellcheck disable=SC2034

set -euo pipefail

REPO_ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
LIB_DIR="$REPO_ROOT/lib"
TARGETS_FILE="$REPO_ROOT/tools/lib-targets.txt"

# Files vendored out of lib/ into every target directory.
VENDORED_FILES=(get_cloud_user.sh)

# Header injected right after the shebang of every generated copy.
vendored_header() {
    cat <<'HDR'
#
# ============================================================================
#  СГЕНЕРИРОВАНО ИЗ lib/get_cloud_user.sh — РУКАМИ НЕ ПРАВИТЬ.
#
#  Копия лежит рядом со скриптами расширения потому, что до гостя доезжает
#  только каталог одного расширения (`COPY_IN <ext>:/opt/vmsetup/`), а
#  потребители ищут файл как `$SCRIPT_DIR/get_cloud_user.sh`.
#
#  Правь источник и запусти tools/sync-lib.sh.
#  Расхождение источника и копий ловит tools/check-lib.sh.
# ============================================================================
HDR
}

# Print the exact expected content of a vendored copy of $1 (a file in lib/).
render_vendored() {
    local src="$1"
    head -n 1 "$src"
    vendored_header
    tail -n +2 "$src"
}

# Emit target directories (repo-relative), comments and blank lines stripped.
lib_targets() {
    sed -e 's/#.*$//' -e 's/[[:space:]]*$//' "$TARGETS_FILE" | grep -v '^$'
}
