#!/bin/bash
# Шаг 15: доказать, что пара собирается, — по самому BSP, а не по документации.
#
# Справка jetson-disk-image-creator.sh копируется из релиза в релиз и за
# поддержкой не следит: R36.4.3 и R39.2 перечисляют jetson-agx-xavier-devkit
# при нуле конфигов t194 (проба 2026-09-18). Поэтому ветка в creator'е —
# необходимое, но НЕ достаточное условие; доказательство — .conf платы и XML
# разметки под SoC.
#
# Тарболл не кладётся на диск: нужные файлы вынимаются из потока. Если он уже
# скачан шагом 01 ($WORK/downloads) — берётся оттуда, без второй закачки.
set -uo pipefail

: "${JETSON:?профиль не загружен}" "${L4T:?}" "${BOARD_TARGET:?}" "${FLASH_XML:?}" "${BSP_URL:?}"
VERIFY_DIR="${VERIFY_DIR:-./verified}"
tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

members=(
    "Linux_for_Tegra/tools/jetson-disk-image-creator.sh"
    "Linux_for_Tegra/$BOARD_TARGET.conf"
    "Linux_for_Tegra/$FLASH_XML"
)
local_bsp="${WORK:-/nonexistent}/downloads/${BSP_FILE:-none}"
# Отсутствующий в архиве член — это и есть ответ «нет», поэтому код tar
# здесь не проверяется; проверяются сами файлы ниже.
if [ -s "$local_bsp" ]; then
    tar -xjf "$local_bsp" -C "$tmp" "${members[@]}" 2>/dev/null
else
    curl -sL --max-time 2400 "$BSP_URL" | tar -xjf - -C "$tmp" "${members[@]}" 2>/dev/null
fi

L="$tmp/Linux_for_Tegra"
creator="$L/tools/jetson-disk-image-creator.sh"
v_branch=нет; grep -qE "^[[:space:]]*${BOARD_TARGET}\)" "$creator" 2>/dev/null && v_branch=ok
v_conf=нет;   [ -f "$L/$BOARD_TARGET.conf" ] && v_conf=ok
v_xml=нет;    [ -f "$L/$FLASH_XML" ] && v_xml=ok
v_dev=нет;    grep -qE -- '-d \| --device' "$creator" 2>/dev/null && v_dev=да

verdict=не-собирается
if [ "$v_branch" = ok ] && [ "$v_conf" = ok ] && [ "$v_xml" = ok ]; then
    verdict=проверено
fi

mkdir -p "$VERIFY_DIR"
out="$VERIFY_DIR/$JETSON@$L4T.txt"
{
    echo "pair=$JETSON@$L4T"
    echo "date=$(date -I)"
    echo "bsp=$(basename "$BSP_URL")"
    echo "bsp_sha1=${BSP_SHA1:-}"
    echo "creator_branch=$v_branch"
    echo "conf=$v_conf"
    echo "flash_xml=$v_xml"
    echo "creator_dev_flag=$v_dev"
    echo "verdict=$verdict"
} > "$out"
cat "$out"

declared="${CREATOR_HAS_DEV_FLAG:-yes}"
if { [ "$v_dev" = да ] && [ "$declared" != yes ]; } || { [ "$v_dev" = нет ] && [ "$declared" = yes ]; }; then
    echo "ВНИМАНИЕ: CREATOR_HAS_DEV_FLAG=$declared в профиле релиза, а у creator'а флаг -d: $v_dev"
fi
[ "$verdict" = проверено ]
