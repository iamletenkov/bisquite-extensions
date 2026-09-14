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
# Files vendored out of lib/, each into ITS OWN list of target directories.
#
# Список у каждого файла свой: get_cloud_user.sh нужен всем, кто ищет
# пользователя cloud-init, а bisquite-desktop — только расширениям рабочего
# стола. Общий список разложил бы CLI рабочего стола в docker и code-server.
VENDORED_FILES=(get_cloud_user.sh bisquite-desktop)

targets_file_for() {
    case "$1" in
        get_cloud_user.sh) echo "$REPO_ROOT/tools/lib-targets.txt" ;;
        bisquite-desktop)  echo "$REPO_ROOT/tools/lib-targets-desktop.txt" ;;
        *) echo "ОШИБКА: у lib/$1 нет списка получателей в lib-common.sh" >&2; return 1 ;;
    esac
}

# Header injected right after the shebang of every generated copy.
# Текст для get_cloud_user.sh — прежний байт в байт: существующие копии
# не переписываются из-за того, что заголовок стал параметром.
vendored_header() {
    local name="$1"
    cat <<HDR
#
# ============================================================================
#  СГЕНЕРИРОВАНО ИЗ lib/${name} — РУКАМИ НЕ ПРАВИТЬ.
#
#  Копия лежит рядом со скриптами расширения потому, что до гостя доезжает
#  только каталог одного расширения (\`COPY_IN <ext>:/opt/vmsetup/\`), а
#  потребители ищут файл как \`\$SCRIPT_DIR/${name}\`.
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
    vendored_header "$(basename "$src")"
    tail -n +2 "$src"
}

# Emit target directories of lib/$1 (repo-relative), comments and blanks stripped.
lib_targets() {
    local file
    file="$(targets_file_for "$1")" || return 1
    sed -e 's/#.*$//' -e 's/[[:space:]]*$//' "$file" | grep -v '^$'
}
