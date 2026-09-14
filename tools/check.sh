#!/usr/bin/env bash
# Одна точка входа для проверок репозитория расширений.
#
# Сегодня проверка одна — валидация манифестов extension.yaml. Сверки копий
# lib/ больше нет: копий нет, общий код доставляет в гостя сама сборка
# (`/opt/bisquite/<имя>/lib`, см. docs/extensions.md). Точка входа остаётся,
# чтобы следующая проверка встала рядом, а не заводила свой скрипт.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

rc=0
echo "== validate-extensions =="
"$HERE/validate-extensions.py" || rc=1

echo
if (( rc )); then
    echo "проверки не прошли" >&2
else
    echo "проверки прошли"
fi
exit "$rc"
