#!/usr/bin/env bash
# Одна точка входа для проверок репозитория расширений:
#   * сверка вендоренных копий lib/ с источником;
#   * валидация манифестов extension.yaml.
#
# Обе проверки идут до конца, даже если первая упала: молчать про вторую
# ошибку, потому что нашлась первая, — значит растянуть починку на два прогона.

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

rc=0
echo "== check-lib =="
"$HERE/check-lib.sh" || rc=1
echo
echo "== validate-extensions =="
"$HERE/validate-extensions.py" || rc=1

echo
if (( rc )); then
    echo "проверки не прошли" >&2
else
    echo "проверки прошли"
fi
exit "$rc"
