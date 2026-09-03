#!/usr/bin/env bash
# Падает, если вендоренная копия разошлась с lib/.
#
# Три отдельные проверки, и третья — не формальность:
#   1. каждая копия из tools/lib-targets.txt существует и совпадает с lib/;
#   2. права на копию — исполняемые (её зовут как `$SCRIPT_DIR/get_cloud_user.sh`);
#   3. в дереве НЕТ копий, которых нет в tools/lib-targets.txt, — иначе
#      руками добавленный девятый файл разошёлся бы молча.

set -euo pipefail
# shellcheck source=tools/lib-common.sh
source "$(dirname "${BASH_SOURCE[0]}")/lib-common.sh"

fail=0
err() { echo "FAIL: $*" >&2; fail=1; }

declare -A expected=()

while read -r target; do
    dir="$REPO_ROOT/$target"
    [[ -d "$dir" ]] || { err "в tools/lib-targets.txt указан несуществующий каталог: $target"; continue; }
    for name in "${VENDORED_FILES[@]}"; do
        src="$LIB_DIR/$name"
        [[ -f "$src" ]] || { err "нет источника lib/$name"; continue; }
        dst="$dir/$name"
        expected["$target/$name"]=1
        if [[ ! -f "$dst" ]]; then
            err "копия отсутствует: $target/$name (запусти tools/sync-lib.sh)"
            continue
        fi
        tmp="$(mktemp)"
        render_vendored "$src" > "$tmp"
        if ! cmp -s "$tmp" "$dst"; then
            err "копия разошлась с lib/$name: $target/$name"
            diff -u "$tmp" "$dst" | sed 's/^/    /' >&2 || true
        fi
        rm -f "$tmp"
        [[ -x "$dst" ]] || err "копия не исполняемая: $target/$name"
    done
done < <(lib_targets)

# Незарегистрированные копии.
for name in "${VENDORED_FILES[@]}"; do
    while read -r found; do
        rel="${found#"$REPO_ROOT/"}"
        if [[ -z "${expected[$rel]:-}" ]]; then
            err "копия lib/$name лежит вне tools/lib-targets.txt: $rel"
        fi
    done < <(find "$REPO_ROOT/extensions" -type f -name "$name" | sort)
done

if (( fail )); then
    echo "check-lib: расхождения найдены" >&2
    exit 1
fi
echo "check-lib: копии lib/ совпадают с источником"
