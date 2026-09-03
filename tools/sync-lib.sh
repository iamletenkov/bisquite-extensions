#!/usr/bin/env bash
# Раскладывает файлы из lib/ по каталогам расширений, перечисленным в
# tools/lib-targets.txt.
#
# Копия — не «ещё один источник», а артефакт: она несёт шапку «не править
# руками», а расхождение ловит tools/check-lib.sh.
#
# Использование:
#   tools/sync-lib.sh            # записать копии
#   tools/sync-lib.sh --dry-run  # только показать, что изменится

set -euo pipefail
# shellcheck source=tools/lib-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-common.sh"

DRY_RUN=0
case "${1:-}" in
    --dry-run|-n) DRY_RUN=1 ;;
    "") ;;
    *) echo "usage: $0 [--dry-run]" >&2; exit 2 ;;
esac

changed=0
total=0

while read -r target; do
    dir="$REPO_ROOT/$target"
    if [[ ! -d "$dir" ]]; then
        echo "ОШИБКА: в tools/lib-targets.txt указан несуществующий каталог: $target" >&2
        exit 1
    fi
    for name in "${VENDORED_FILES[@]}"; do
        src="$LIB_DIR/$name"
        [[ -f "$src" ]] || { echo "ОШИБКА: нет источника $src" >&2; exit 1; }
        dst="$dir/$name"
        total=$((total + 1))
        tmp="$(mktemp)"
        render_vendored "$src" > "$tmp"
        if [[ -f "$dst" ]] && cmp -s "$tmp" "$dst"; then
            rm -f "$tmp"
            continue
        fi
        changed=$((changed + 1))
        if (( DRY_RUN )); then
            echo "изменится: $target/$name"
            rm -f "$tmp"
        else
            # Права как у источника: файл запускается как `$SCRIPT_DIR/get_cloud_user.sh`.
            install -m 0755 "$tmp" "$dst"
            rm -f "$tmp"
            echo "записан: $target/$name"
        fi
    done
done < <(lib_targets)

if (( DRY_RUN )); then
    echo "итого: $changed из $total копий разошлись с lib/"
else
    echo "итого: обновлено $changed из $total копий"
fi
