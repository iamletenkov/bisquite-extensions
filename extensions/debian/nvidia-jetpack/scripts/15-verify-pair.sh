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
#
# The evidence depends on the bootloader tool (BOOTLOADER_TOOL):
#   initrd-flash    creator branch, board .conf, layout XML (FLASH_XML);
#   nvmassflashgen  nvmassflashgen.sh, board .conf, QSPI layout (QSPI_CFG),
#                   and the target must address QSPI only. The creator takes
#                   no part: the system half is a vendor image.
# For ROOTFS_SOURCE=vendor-image the vendor image's sha256 is checked too,
# streamed; a mismatch means no verdict, like a network failure.
set -uo pipefail

: "${JETSON:?профиль не загружен}" "${L4T:?}" "${BOARD_TARGET:?}" "${BSP_URL:?}"
VERIFY_DIR="${VERIFY_DIR:-./verified}"

case "${BOOTLOADER_TOOL:-}" in
    initrd-flash)
        : "${FLASH_XML:?в профиле пуст FLASH_XML}"
        layout_xml="$FLASH_XML"
        sentinel="Linux_for_Tegra/tools/jetson-disk-image-creator.sh" ;;
    nvmassflashgen)
        : "${QSPI_CFG:?в профиле пуст QSPI_CFG}"
        layout_xml="$QSPI_CFG"
        sentinel="Linux_for_Tegra/nvmassflashgen.sh" ;;
    *)
        echo "ОТКАЗ: BOOTLOADER_TOOL=${BOOTLOADER_TOOL:-<пусто>}, ждали initrd-flash или nvmassflashgen —"
        echo "       вердикта нет, отпечаток не записан"
        exit 2 ;;
esac

tmp="$(mktemp -d)"
trap 'rm -rf -- "$tmp"' EXIT

# .conf платы и XML разметки у NVIDIA — симлинки на соседей с другими именами
# (jetson-agx-xavier-devkit.conf -> p2822-0000+p2888-0004.conf,
# flash_l4t_t194_nvme.xml -> flash_l4t_nvme.xml). Вынутая по имени одна ссылка
# осталась бы битой и дала ложное «нет» на каждой паре, поэтому берутся все
# соседи того же каталога — без подкаталогов (--no-wildcards-match-slash).
xml_dir="$(dirname "$layout_xml")"
members=(
    "$sentinel"
    "Linux_for_Tegra/*.conf"
    "Linux_for_Tegra/$xml_dir/*.xml"
)
tar_opts=(--wildcards --no-wildcards-match-slash)
local_bsp="${WORK:-/nonexistent}/downloads/${BSP_FILE:-none}"
# Вердикт относится к архиву с суммой BSP_SHA1 — значит, сумма считается по
# байтам, которые реально прочитаны (файл или поток), и сверяется с ней.
# Без эталона вердикт не к чему привязать.
[ -n "${BSP_SHA1:-}" ] || { echo "ОТКАЗ: в профиле пуст BSP_SHA1 — вердикта нет, отпечаток не записан"; exit 2; }
# Отсутствующий в архиве член (кроме признака, см. ниже) — это и есть ответ
# «нет», поэтому код tar сам по себе не проверяется; проверяются файлы ниже.
curl_status=0
if [ -s "$local_bsp" ]; then
    src="$local_bsp"
    got_sha1="$(sha1sum "$local_bsp" | cut -d' ' -f1)"
    tar -xjf "$local_bsp" -C "$tmp" "${tar_opts[@]}" "${members[@]}" 2>/dev/null
else
    src="$BSP_URL"
    # tar может выйти, не дочитав поток (все члены найдены раньше конца), —
    # тогда sha1sum увидел бы обрезок. cat после tar дочитывает остаток.
    curl -fsSL --max-time 2400 "$BSP_URL" \
        | tee >(sha1sum | cut -d' ' -f1 > "$tmp/sha1") \
        | { tar -xjf - -C "$tmp" "${tar_opts[@]}" "${members[@]}" 2>/dev/null; cat >/dev/null; }
    curl_status="${PIPESTATUS[0]}"
    # Процесс-подстановка асинхронна: ждать, пока sha1sum допишет сумму.
    for _ in $(seq 100); do [ -s "$tmp/sha1" ] && break; sleep 0.1; done
    got_sha1="$(cat "$tmp/sha1" 2>/dev/null)"
fi
if [ "$curl_status" -eq 0 ] && [ "$got_sha1" != "$BSP_SHA1" ]; then
    echo "ОТКАЗ: SHA1 прочитанного BSP ($src) = ${got_sha1:-?}, в профиле $BSP_SHA1 —"
    echo "       архив обрезан или подменён; вердикта нет, отпечаток не записан"
    exit 2
fi

L="$tmp/Linux_for_Tegra"
# Сбой загрузки — это не вердикт «не собирается», а невозможность его
# вынести. The sentinel (jetson-disk-image-creator.sh for initrd-flash,
# nvmassflashgen.sh for R32 t210) is in EVERY BSP of its kind, so its absence
# after extraction means «архив не дошёл» (сеть, HTTP-ошибка, обрыв потока),
# а не «пара не собирается». Отпечаток — доказательство, и записывать его по
# недоказанному нельзя: временный сбой сети иначе навсегда пометил бы
# собираемую пару как несобираемую.
if [ "$curl_status" -ne 0 ] || [ ! -f "$tmp/$sentinel" ]; then
    reason="curl вернул $curl_status"
    [ "$curl_status" -eq 0 ] && reason="$(basename "$sentinel") не извлёкся из архива"
    echo "ОТКАЗ: BSP не получен ($reason) — вердикта нет, отпечаток не записан"
    exit 2
fi

# The vendor image: its sum is checked before anything is written. A cached
# download counts only when complete; otherwise the image is streamed — 8.7 GB
# never touch the disk. pipefail makes a curl failure the status of the
# whole substitution.
vendor_sha=""
if [ "${ROOTFS_SOURCE:-nvidia-bsp}" = vendor-image ]; then
    : "${VENDOR_IMG_URL:?в профиле пуст VENDOR_IMG_URL}" "${VENDOR_IMG_SHA256:?в профиле пуст VENDOR_IMG_SHA256}"
    local_img="${WORK:-/nonexistent}/downloads/$(basename "$VENDOR_IMG_URL")"
    img_status=0
    if [ -f "$local_img" ] && [ "$(stat -c %s "$local_img")" = "${VENDOR_IMG_SIZE:-}" ]; then
        img_src="$local_img"
        vendor_sha="$(sha256sum "$local_img" | cut -d' ' -f1)"
    else
        img_src="$VENDOR_IMG_URL"
        vendor_sha="$(curl -fsSL --max-time 7200 "$VENDOR_IMG_URL" | sha256sum | cut -d' ' -f1)" || img_status=$?
    fi
    if [ "$img_status" -ne 0 ]; then
        echo "ОТКАЗ: образ вендора не получен ($img_src, код $img_status) — вердикта нет, отпечаток не записан"
        exit 2
    fi
    if [ "$vendor_sha" != "$VENDOR_IMG_SHA256" ]; then
        echo "ОТКАЗ: sha256 образа вендора ($img_src) = $vendor_sha, в профиле $VENDOR_IMG_SHA256 —"
        echo "       образ перезалит или подменён; вердикта нет, отпечаток не записан"
        exit 2
    fi
fi

mkdir -p "$VERIFY_DIR"
out="$VERIFY_DIR/$JETSON@$L4T.txt"
case "$BOOTLOADER_TOOL" in
    initrd-flash)
        creator="$L/tools/jetson-disk-image-creator.sh"
        v_branch=нет; grep -qE "^[[:space:]]*${BOARD_TARGET}\)" "$creator" 2>/dev/null && v_branch=ok
        v_conf=нет;   [ -f "$L/$BOARD_TARGET.conf" ] && v_conf=ok
        v_xml=нет;    [ -f "$L/$FLASH_XML" ] && v_xml=ok
        v_dev=нет;    grep -qE -- '-d \| --device' "$creator" 2>/dev/null && v_dev=да
        verdict=не-собирается
        if [ "$v_branch" = ok ] && [ "$v_conf" = ok ] && [ "$v_xml" = ok ]; then
            verdict=проверено
        fi
        {
            echo "pair=$JETSON@$L4T"
            echo "date=$(date -I)"
            echo "bsp=$(basename "$BSP_URL")"
            echo "bsp_sha1=$got_sha1"
            echo "creator_branch=$v_branch"
            echo "conf=$v_conf"
            echo "flash_xml=$v_xml"
            echo "creator_dev_flag=$v_dev"
            if [ -n "$vendor_sha" ]; then
                echo "rootfs_source=vendor-image"
                echo "vendor_img_sha256=$vendor_sha"
            fi
            echo "verdict=$verdict"
        } > "$out" ;;
    nvmassflashgen)
        v_conf=нет; [ -f "$L/$BOARD_TARGET.conf" ] && v_conf=ok
        v_xml=нет;  [ -f "$L/$QSPI_CFG" ] && v_xml=ok
        # The package must address QSPI only: NO_ROOTFS=1 in the board .conf
        # and no sdcard device in the layout. jetson-nano-qspi-sd and
        # jetson-nano-devkit fail here.
        v_qspi_only=нет
        if [ "$v_conf" = ok ] && [ "$v_xml" = ok ] \
           && grep -qE '^[[:space:]]*NO_ROOTFS=1' "$L/$BOARD_TARGET.conf" \
           && ! grep -q 'type="sdcard"' "$L/$QSPI_CFG"; then
            v_qspi_only=ok
        fi
        verdict=не-собирается
        if [ "$v_conf" = ok ] && [ "$v_xml" = ok ] && [ "$v_qspi_only" = ok ]; then
            verdict=проверено
        fi
        {
            echo "pair=$JETSON@$L4T"
            echo "date=$(date -I)"
            echo "bsp=$(basename "$BSP_URL")"
            echo "bsp_sha1=$got_sha1"
            echo "bootloader_tool=nvmassflashgen"
            echo "conf=$v_conf"
            echo "qspi_xml=$v_xml"
            echo "qspi_only=$v_qspi_only"
            if [ -n "$vendor_sha" ]; then
                echo "rootfs_source=vendor-image"
                echo "vendor_img_sha256=$vendor_sha"
            fi
            echo "verdict=$verdict"
        } > "$out" ;;
esac
cat "$out"

if [ "$BOOTLOADER_TOOL" = initrd-flash ]; then
    declared="${CREATOR_HAS_DEV_FLAG:-yes}"
    if { [ "$v_dev" = да ] && [ "$declared" != yes ]; } || { [ "$v_dev" = нет ] && [ "$declared" = yes ]; }; then
        echo "ВНИМАНИЕ: CREATOR_HAS_DEV_FLAG=$declared в профиле релиза, а у creator'а флаг -d: $v_dev"
    fi
fi
[ "$verdict" = проверено ]
