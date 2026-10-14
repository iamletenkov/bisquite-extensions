#!/usr/bin/env bash
# Edit the [options] table of one RustDesk2.toml.
#
#   render-toml.sh <file> [name=value ...] [-name ...]
#
# name=value sets the option, -name removes it; other options and every
# other table of the file stay as RustDesk wrote them. Values are written as
# TOML literal strings ('...'), as RustDesk itself writes them; the schema of
# the `rustdesk` domain admits no quote in a value.
#
# configure.sh runs this as the OWNER of the file (runuser), never as root
# in a user's home: a symlink planted there must not make root read or write
# a file the user may not touch.
#
# Prints "changed" when the file was written.
set -euo pipefail

file="${1:?file}"; shift
sets=() dels=()
for a in "$@"; do
    case "$a" in
        -*) dels+=("${a#-}") ;;
        *=*) sets+=("$a") ;;
        *) >&2 echo "render-toml: '$a': ожидали name=value или -name"; exit 2 ;;
    esac
done
for a in "${sets[@]}"; do
    [[ "${a#*=}" != *"'"* && "${a#*=}" != *$'\n'* ]] || { >&2 echo "render-toml: кавычка в значении ${a%%=*}"; exit 2; }
done

# Nothing to set and no file: leave the user's home alone.
if (( ${#sets[@]} == 0 )) && [[ ! -e "$file" ]]; then
    exit 0
fi

umask 077
dir="${file%/*}"
mkdir -p "$dir"
tmp="$(mktemp "$dir/.RustDesk2.toml.XXXXXX")"
trap 'rm -f "$tmp"' EXIT

names=""
for a in "${sets[@]}"; do names+="${a%%=*} "; done
for a in "${dels[@]}"; do names+="$a "; done

# awk: drop our names inside [options], insert the set ones right after the
# header; no [options] table — append one at the end (a table may follow any
# top-level key in TOML).
src=/dev/null
if [[ -e "$file" || -L "$file" ]]; then
    [[ -f "$file" && -r "$file" ]] || { >&2 echo "render-toml: $file — не обычный читаемый файл"; exit 1; }
    src="$file"
fi
awk -v q="'" -v names="$names" -v sets="$(printf '%s\n' "${sets[@]}")" '
    BEGIN {
        n = split(names, ns, " "); for (i = 1; i <= n; i++) drop[ns[i]] = 1
        m = split(sets, ss, "\n")
        for (i = 1; i <= m; i++) {
            if (ss[i] == "") continue
            k = substr(ss[i], 1, index(ss[i], "=") - 1)
            v = substr(ss[i], index(ss[i], "=") + 1)
            ins = ins k " = '\''" v "'\''\n"
        }
    }
    function header(line) { return line ~ /^[ \t]*\[/ }
    {
        if (header($0)) {
            in_opts = ($0 ~ /^[ \t]*\[options\][ \t]*$/)
            print
            if (in_opts) { printf "%s", ins; seen = 1 }
            next
        }
        if (in_opts) {
            key = $0; sub(/^[ \t]*/, "", key); sub(/[ \t]*=.*/, "", key)
            gsub("^[\"" q "]|[\"" q "]$", "", key)
            if ((key in drop) && $0 ~ /=/) next
        }
        print
    }
    END {
        if (!seen && ins != "") { printf "%s[options]\n%s", (NR ? "\n" : ""), ins }
    }
' "$src" > "$tmp"

if [[ -f "$file" ]] && cmp -s "$tmp" "$file"; then
    exit 0
fi
# Keep the mode RustDesk gave the file; a new one is 0600 (umask above).
if [[ -f "$file" ]]; then chmod --reference="$file" "$tmp" 2>/dev/null || true; fi
mv -f "$tmp" "$file"
trap - EXIT
echo changed
