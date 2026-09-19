# shellcheck shell=bash
# System half of a pair with ROOTFS_SOURCE=vendor-image: a ready vendor image
# (Nano: Q-engineering) becomes system.qcow2 with its content untouched plus
# one added file, the internal manifest. Sourced by step 09; the functions
# read the profile when called, not when sourced.
#
#     vendor_fetch          $WORK/downloads/<name>: cache, sha256 — a mismatch refuses
#     vendor_to_qcow2       sparse raw in $WORK -> $OUT_DIR/system.qcow2.tmp
#     vendor_put_manifest   internal manifest into system.qcow2.tmp -> system.qcow2
#
# The vendor sha256 is the sum of the INPUT .img.xz, not of system.qcow2.
# The station is never cleaned up here: short of space means refusal, and
# what to delete is the owner's call. Spec 2026-09-19-jetson-nano-mixed-pair.md.
_VI_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

_vi_xz()    { echo "$WORK/downloads/$(basename "$VENDOR_IMG_URL")"; }
_vi_raw()   { echo "$WORK/vendor-image.raw"; }
_vi_tmp()   { echo "$OUT_DIR/system.qcow2.tmp"; }
_vi_avail() { df -B1 --output=avail "$1" | tail -1 | tr -dc '0-9'; }

vendor_fetch() {
    : "${WORK:?профиль не загружен}" "${VENDOR_IMG_URL:?}" "${VENDOR_IMG_SIZE:?}" "${VENDOR_IMG_SHA256:?}"
    local f dir have left avail got
    f="$(_vi_xz)"; dir="$(dirname "$f")"
    mkdir -p "$dir" || return 1
    have=0
    [ -f "$f" ] && have="$(stat -c %s "$f")"
    if [ "$have" -gt "$VENDOR_IMG_SIZE" ]; then
        echo "$f длиннее заявленного ($have > $VENDOR_IMG_SIZE) — удаляю, качаю заново"
        rm -f -- "$f"
        have=0
    fi
    if [ "$have" -lt "$VENDOR_IMG_SIZE" ]; then
        # Checked BEFORE downloading: the xz index is not known yet, so the
        # bar here is what is left to download.
        left=$((VENDOR_IMG_SIZE - have))
        avail="$(_vi_avail "$dir")"
        if [ "${avail:-0}" -lt "$left" ]; then
            echo "ОТКАЗ: под образ нужно ещё $left байт в $dir, свободно ${avail:-?}"
            echo "       что удалить, решает владелец станции — сценарий ничего не чистит"
            return 1
        fi
        echo "качаю $(basename "$f"): есть $have из $VENDOR_IMG_SIZE байт"
        curl -fL --retry 3 -C - -o "$f" "$VENDOR_IMG_URL" \
            || { echo "ОТКАЗ: загрузка оборвалась (curl $?) — повторный запуск докачает"; return 1; }
    else
        echo "$(basename "$f"): в кеше целиком ($have байт) — не качаю"
    fi
    got="$(sha256sum "$f" | cut -d' ' -f1)"
    if [ "$got" != "$VENDOR_IMG_SHA256" ]; then
        rm -f -- "$f"
        echo "ОТКАЗ: sha256 $(basename "$f") = $got, в профиле $VENDOR_IMG_SHA256 — файл удалён"
        return 1
    fi
    echo "sha256 сошлась: $got"
}

vendor_to_qcow2() {
    : "${WORK:?профиль не загружен}" "${OUT_DIR:?}" "${VENDOR_IMG_URL:?}"
    local xzf raw tmp need avail
    xzf="$(_vi_xz)"; raw="$(_vi_raw)"; tmp="$(_vi_tmp)"
    [ -s "$xzf" ] || { echo "ОТКАЗ: нет $xzf — сначала vendor_fetch"; return 1; }
    need="$(xz --robot -l "$xzf" | awk -F'\t' '$1 == "totals" { print $5 }')"
    [ -n "$need" ] || { echo "ОТКАЗ: xz не прочитал индекс $xzf"; return 1; }
    avail="$(_vi_avail "$WORK")"
    if [ "${avail:-0}" -lt "$need" ]; then
        echo "ОТКАЗ: несжатый образ — $need байт (индекс xz), свободно в $WORK ${avail:-?}"
        echo "       что удалить, решает владелец станции — сценарий ничего не чистит"
        return 1
    fi
    mkdir -p "$OUT_DIR" || return 1
    (
        # Neither the raw nor an unfinished qcow2 survives a failure.
        trap 'rm -f -- "$raw" "$tmp"' EXIT
        trap 'exit 130' INT TERM HUP
        rm -f -- "$raw" "$tmp"
        # qemu-img cannot read a pipe (it needs the input size), hence the raw.
        # conv=sparse skips all-zero blocks; GNU dd extends a zero tail itself.
        xz -dc "$xzf" | dd of="$raw" bs=1M iflag=fullblock conv=sparse status=none
        st=("${PIPESTATUS[@]}")
        [ "${st[0]}" = 0 ] && [ "${st[1]}" = 0 ] \
            || { echo "ОТКАЗ: распаковка $xzf не удалась (xz ${st[0]}, dd ${st[1]})"; exit 1; }
        [ "$(stat -c %s "$raw")" = "$need" ] \
            || { echo "ОТКАЗ: raw — $(stat -c %s "$raw") байт, индекс xz обещал $need"; exit 1; }
        # qcow2 holds the allocated blocks of the raw and nothing more.
        alloc=$(( $(stat -c '%b * %B' "$raw") ))
        avail="$(_vi_avail "$OUT_DIR")"
        if [ "${avail:-0}" -lt "$alloc" ]; then
            echo "ОТКАЗ: qcow2 займёт до $alloc байт, свободно в $OUT_DIR ${avail:-?}"
            exit 1
        fi
        qemu-img convert -f raw -O qcow2 "$raw" "$tmp" \
            || { echo "ОТКАЗ: qemu-img convert вернул $?"; exit 1; }
        trap 'rm -f -- "$raw"' EXIT
        echo "qcow2: $tmp ($(du -h "$tmp" | cut -f1)), raw занимал $alloc байт из $need"
    )
}

vendor_put_manifest() {
    : "${OUT_DIR:?профиль не загружен}"
    local tmp man
    tmp="$(_vi_tmp)"
    [ -s "$tmp" ] || { echo "ОТКАЗ: нет $tmp — сначала vendor_to_qcow2"; return 1; }
    man="$(mktemp)" || return 1
    (
        trap 'rm -f -- "$man"' EXIT
        python3 "$_VI_DIR/manifest.py" internal \
            --bootloader-files "$OUT_DIR/bootloader-files.sha256" --out "$man" \
            || { echo "ОТКАЗ: внутренний манифест не записан"; exit 1; }
        # guestfish, not virt-customize: virt-customize rewrites the guest's
        # random seed on every run, and the rule for a vendor image is to ADD
        # one file and change nothing that was there. -i finds the OS root by
        # inspection; none or several roots is a loud refusal.
        guestfish --rw --format=qcow2 -a "$tmp" -i \
            mkdir-p /opt/l4t-boot-firmware : \
            upload "$man" /opt/l4t-boot-firmware/manifest.json : \
            chmod 0644 /opt/l4t-boot-firmware/manifest.json \
            || { echo "ОТКАЗ: guestfish не положил манифест в $tmp"; exit 1; }
    ) || { rm -f -- "$tmp"; return 1; }
    # Only a complete image, manifest included, gets the working name.
    mv -f -- "$tmp" "$OUT_DIR/system.qcow2"
    echo "внутренний манифест -> $OUT_DIR/system.qcow2:/opt/l4t-boot-firmware/manifest.json"
}
