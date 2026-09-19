# shellcheck shell=bash
# libnvisppg.so from NVIDIA's camera overlay. Sourced by install.sh, never
# executed:
#
#   source "$SCRIPT_DIR/nvisppg.sh"
#
# WHY THE EXTENSION DOES IT. Until 2026-09-19 the flash station swapped the
# library while preparing the BSP tree (step 03 of nvidia-jetpack, after
# apply_binaries). The owner's decision of 2026-09-18 moved everything
# camera-specific out of the base image: a row of the release matrix then
# means exactly "board x release" (spec 2026-09-18-jetson-release-matrix.md).
#
# WHY A DIVERSION AND NOT A PLAIN COPY. The file belongs to the
# nvidia-l4t-camera package, and a later layer that installs or upgrades it
# would put the stock library back without a word. `dpkg-divert --rename`
# keeps the stock file as libnvisppg.so.distrib (the rollback copy) and makes
# dpkg write any packaged version there instead of over ours.
#
# WHY nvidia/ AND NOT tegra/. Step 03 wrote to .../tegra/libnvisppg.so; in
# L4T 36.x tegra is a symlink to nvidia (measured on the station 2026-09-19),
# so it is the same file. dpkg knows it only by the nvidia/ path, and a
# diversion must name the path dpkg knows. The link is checked, not assumed.
#
# The functions take the pinned values as arguments so that the tests can
# feed a fixture; the pins live in install.sh. NVISPPG_ROOT is a test root,
# empty in the guest. The caller's log_info/log_error are used when defined.

NVISPPG_ROOT="${NVISPPG_ROOT:-}"
NVISPPG_LIB=/usr/lib/aarch64-linux-gnu/nvidia/libnvisppg.so
NVISPPG_LINK=/usr/lib/aarch64-linux-gnu/tegra/libnvisppg.so

_nv_info(){ if declare -F log_info >/dev/null; then log_info "$@"; else >&2 echo "[INFO] $*"; fi; }
_nv_error(){ if declare -F log_error >/dev/null; then log_error "$@"; else >&2 echo "[ERROR] $*"; fi; }

# Print the L4T release: `# R36 (release), REVISION: 4.3, ...` -> 36.4.3.
# rc=1 and no output when the file is missing or the line does not parse.
nvisppg_l4t_release(){
    local file="$NVISPPG_ROOT/etc/nv_tegra_release" line
    [[ -f "$file" ]] || return 1
    line="$(head -n 1 "$file")"
    [[ "$line" =~ ^#\ R([0-9]+)\ .*REVISION:\ ([0-9]+\.[0-9]+) ]] || return 1
    printf '%s.%s\n' "${BASH_REMATCH[1]}" "${BASH_REMATCH[2]}"
}

# Refuse unless the image is exactly L4T WANT. The overlay is cut per release,
# and the Sensing kernel and modules are built for one; a near miss (36.4.4)
# is still a miss.
nvisppg_gate(){
    local want="$1" got
    if ! got="$(nvisppg_l4t_release)"; then
        _nv_error "не разобрал /etc/nv_tegra_release — версия L4T неизвестна"
        return 1
    fi
    if [[ "$got" != "$want" ]]; then
        _nv_error "в образе L4T $got, а расширение закреплено на $want:"
        _nv_error "оверлей камер NVIDIA, ядро и модули Sensing — под один релиз"
        return 1
    fi
    _nv_info "L4T $got"
}

# Download the overlay into DIR, check the archive against TBZ2_SHA, extract
# the library and check it against LIB_SHA. Leaves DIR/libnvisppg.so; any
# failure is a refusal, and nothing is left under that name.
nvisppg_fetch(){
    local url="$1" tbz2_sha="$2" lib_sha="$3" dir="$4" got
    if ! curl -fsSL --retry 3 --max-time 300 -o "$dir/overlay.tbz2" "$url"; then
        _nv_error "оверлей камер не скачался: $url"
        return 1
    fi
    got="$(sha256sum "$dir/overlay.tbz2" | cut -d' ' -f1)"
    if [[ "$got" != "$tbz2_sha" ]]; then
        _nv_error "sha256 оверлея камер $got, закреплена $tbz2_sha — NVIDIA подменила файл?"
        return 1
    fi
    if ! tar -xjf "$dir/overlay.tbz2" -C "$dir" Linux_for_Tegra/libnvisppg.so; then
        _nv_error "в оверлее нет Linux_for_Tegra/libnvisppg.so"
        return 1
    fi
    got="$(sha256sum "$dir/Linux_for_Tegra/libnvisppg.so" | cut -d' ' -f1)"
    if [[ "$got" != "$lib_sha" ]]; then
        _nv_error "sha256 libnvisppg.so из оверлея $got, ждали $lib_sha"
        return 1
    fi
    mv "$dir/Linux_for_Tegra/libnvisppg.so" "$dir/libnvisppg.so"
}

# Put SRC in place of the stock library. What is found there decides:
#   STOCK_SHA    divert with --rename (stock -> .distrib), install SRC 0644;
#   OVERLAY_SHA  already swapped — a base built before 2026-09-19 or a
#                repeated run; only make sure the diversion is recorded;
#   other        refuse: a revision nobody checked.
nvisppg_install(){
    local src="$1" stock_sha="$2" overlay_sha="$3"
    local lib="$NVISPPG_ROOT$NVISPPG_LIB" link="$NVISPPG_ROOT$NVISPPG_LINK" cur
    local divert=(dpkg-divert --local --divert "$NVISPPG_LIB.distrib")
    [[ -n "$NVISPPG_ROOT" ]] && divert+=(--root "$NVISPPG_ROOT")

    if [[ ! -f "$lib" ]]; then
        _nv_error "нет $NVISPPG_LIB — nvidia-l4t-camera не установлен?"
        return 1
    fi
    if [[ "$(readlink -f "$link")" != "$(readlink -f "$lib")" ]]; then
        _nv_error "$NVISPPG_LINK — не тот же файл, что $NVISPPG_LIB:"
        _nv_error "раскладка библиотек L4T не та, что проверялась"
        return 1
    fi
    cur="$(sha256sum "$lib" | cut -d' ' -f1)"
    case "$cur" in
        "$overlay_sha")
            "${divert[@]}" --add "$NVISPPG_LIB" >/dev/null || return 1
            _nv_info "libnvisppg.so уже из оверлея — записано только отведение dpkg"
            return 0 ;;
        "$stock_sha") ;;
        *)
            _nv_error "libnvisppg.so в образе неизвестной ревизии ($cur):"
            _nv_error "не штатная nvidia-l4t-camera и не оверлей — подменять вслепую нельзя"
            return 1 ;;
    esac
    if ! "${divert[@]}" --rename --add "$NVISPPG_LIB" >/dev/null; then
        _nv_error "dpkg-divert не отвёл $NVISPPG_LIB"
        return 1
    fi
    install -m 0644 "$src" "$lib" || return 1
    cur="$(sha256sum "$lib" | cut -d' ' -f1)"
    if [[ "$cur" != "$overlay_sha" ]]; then
        _nv_error "после подмены sha256 $cur, ждали $overlay_sha"
        return 1
    fi
    _nv_info "libnvisppg.so из оверлея NVIDIA; штатная — $NVISPPG_LIB.distrib"
}
