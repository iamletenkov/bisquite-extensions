#!/usr/bin/env bash
# Одна точка входа для проверок репозитория расширений.
#
# Две проверки: валидация манифестов extension.yaml (и схем настроек, и того,
# как скрипты обращаются с файлами настроек) и тесты библиотеки настроек
# lib/bisquite-conf на подменённом корне. Сверки копий lib/ нет: копий нет,
# общий код доставляет в гостя сама сборка (`/opt/bisquite/<имя>/lib`, см.
# docs/extensions.md). Все проверки доводятся до конца, даже если первая упала.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

rc=0
echo "== validate-extensions =="
"$HERE/validate-extensions.py" || rc=1

echo
echo "== test-conf =="
"$HERE/test-conf.sh" || rc=1

echo "== test-nvidia-jetpack =="
"$HERE/test-nvidia-jetpack.sh" || rc=1

echo
if (( rc )); then
    echo "проверки не прошли" >&2
else
    echo "проверки прошли"
fi
exit "$rc"
