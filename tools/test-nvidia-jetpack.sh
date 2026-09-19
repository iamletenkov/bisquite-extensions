#!/usr/bin/env bash
# Тесты сценариев nvidia-jetpack — всё, что проверяется без BSP и без платы:
# профили, манифесты, состав команд, сверка пакета перед прошивкой.
set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
S="$HERE/../extensions/debian/nvidia-jetpack/scripts"
unset WORK OUT_DIR OUT_RAW OUT_QCOW2
fails=0; total=0
ok()  { total=$((total+1)); echo "  ok   $1"; }
bad() { total=$((total+1)); fails=$((fails+1)); echo "  FAIL $1"; }
check()   { local n="$1"; shift; if "$@" >/dev/null 2>&1; then ok "$n"; else bad "$n"; fi; }
refuses() { local n="$1"; shift; if "$@" >/dev/null 2>&1; then bad "$n (не отказал)"; else ok "$n"; fi; }

# --- секции задач ниже этой строки ------------------------------------------

echo "проверок: $total, не прошло: $fails"
[ "$fails" -eq 0 ]
