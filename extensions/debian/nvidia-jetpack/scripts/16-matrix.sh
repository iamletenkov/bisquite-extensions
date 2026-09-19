#!/bin/bash
# Шаг 16: таблица «плата × релиз × статус».
#
# Строки порождаются профилями (совместимые по SoC пары), статус — записями,
# а не памятью: status.tsv (собрано / прогнано — ведёт человек после прогона),
# иначе отпечаток make verify, иначе «объявлено».
set -uo pipefail

S="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
VERIFY_DIR="${VERIFY_DIR:-./verified}"
STATUS_FILE="${STATUS_FILE:-./status.tsv}"
# shellcheck source=/dev/null
. "$S/profile.sh"

fmt='%-12s %-8s %-14s %-14s %s\n'
# shellcheck disable=SC2059
printf "$fmt" ПЛАТА L4T СТАТУС ХОСТ-ПРОШИВКИ ПРИМЕЧАНИЕ
for p in $(_profile_pairs); do
    j="${p%@*}"; r="${p#*@}"
    hosts="$( (unset WORK OUT_DIR; load_profile "$j" "$r" >/dev/null 2>&1 && echo "$FLASH_HOSTS") )"
    st=объявлено; note=""
    if [ -f "$VERIFY_DIR/$p.txt" ]; then
        st="$(sed -n 's/^verdict=//p' "$VERIFY_DIR/$p.txt")"
    fi
    rec="$(awk -F'\t' -v p="$p" '$1 == p { s = $2; n = $3 } END { if (s != "") print s "\t" n }' "$STATUS_FILE" 2>/dev/null)"
    if [ -n "$rec" ]; then
        st="${rec%%$'\t'*}"; note="${rec#*$'\t'}"
    fi
    # shellcheck disable=SC2059
    printf "$fmt" "$j" "$r" "$st" "${hosts:-?}" "$note"
done
