#!/usr/bin/env bash
# Render the system locale and keyboard layouts from the `locale` domain
# (/etc/bisquite/locale/config). Idempotent; called by install.sh (build) and
# by the knobs.apply hook (running machine).
#
# Writes:
#   /etc/locale.gen + locale-gen        the locale is compiled
#   /etc/default/locale                 LANG (update-locale --reset)
#   /etc/default/keyboard               console (console-setup) and Xorg via udev
#   /etc/X11/xorg.conf.d/00-keyboard.conf   the same for Xorg/GDM, as localectl writes it
#   /etc/dconf/db/local.d/40-bisquite-locale   GNOME input-sources defaults (no locks:
#                                              a user may change them)
#   /etc/dconf/db/gdm.d/40-bisquite-locale     the login screen, if gdm has a dconf profile
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$(readlink -f "${BASH_SOURCE[0]}")")" && pwd)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/bisquite-conf"

log(){ >&2 echo "locale: $*"; }
die(){ log "$*"; exit 1; }

conf_load locale || exit 1

# --- locale -----------------------------------------------------------------
charset="${LOCALE#*.}"; charset="${charset%%@*}"
line="$LOCALE $charset"
grep -qxF "$line" /usr/share/i18n/SUPPORTED 2>/dev/null \
    || die "локали '$LOCALE' нет в /usr/share/i18n/SUPPORTED (пакет locales)"

touch /etc/locale.gen
if ! grep -qxF "$line" /etc/locale.gen; then
    # Uncomment the shipped line ("# en_US.UTF-8 UTF-8") or append ours.
    if grep -qE "^#[[:space:]]*${line//./\\.}\$" /etc/locale.gen; then
        sed -i -E "s|^#[[:space:]]*(${line//./\\.})\$|\1|" /etc/locale.gen
    else
        echo "$line" >> /etc/locale.gen
    fi
fi
# Debian's locale-gen compiles everything listed in /etc/locale.gen; Ubuntu's
# takes the locale as an argument (and records it in supported.d) — the
# argument form works on both.
if [[ -r /etc/os-release ]] && grep -q '^ID=ubuntu' /etc/os-release; then
    locale-gen "$LOCALE" >/dev/null || die "locale-gen $LOCALE не прошёл"
else
    locale-gen >/dev/null || die "locale-gen не прошёл"
fi
norm="$(echo "${LOCALE%%.*}.${charset}" | tr '[:upper:]' '[:lower:]' | sed 's/utf-8/utf8/')"
locale -a 2>/dev/null | tr '[:upper:]' '[:lower:]' | grep -qxF "${norm}${LOCALE#*.UTF-8}" \
    || die "после locale-gen '$LOCALE' нет в locale -a"
update-locale --reset "LANG=$LOCALE" || die "update-locale не прошёл"
log "LANG=$LOCALE (/etc/default/locale)"

# --- keyboard ---------------------------------------------------------------
layouts=() variants=()
IFS=, read -r -a items <<< "$KEYBOARD_LAYOUTS"
for it in "${items[@]}"; do
    if [[ "$it" =~ ^([a-z]+)\(([a-z0-9_]+)\)$ ]]; then
        layouts+=("${BASH_REMATCH[1]}"); variants+=("${BASH_REMATCH[2]}")
    else
        layouts+=("$it"); variants+=("")
    fi
done
xkb_layout="$(IFS=,; echo "${layouts[*]}")"
xkb_variant="$(IFS=,; echo "${variants[*]}")"
[[ "$xkb_variant" =~ ^,*$ ]] && (( ${#layouts[@]} == 1 )) && xkb_variant=""

for i in "${!layouts[@]}"; do
    [[ -e "/usr/share/X11/xkb/symbols/${layouts[$i]}" ]] \
        || log "раскладки '${layouts[$i]}' нет в /usr/share/X11/xkb/symbols — проверьте имя"
done

model="pc105"
if [[ -f /etc/default/keyboard ]]; then
    m="$(sed -n 's/^XKBMODEL="\{0,1\}\([^"]*\)"\{0,1\}$/\1/p' /etc/default/keyboard | tail -1)"
    [[ -n "$m" ]] && model="$m"
fi

write_if_changed(){
    local target="$1" mode="$2" tmp
    install -d -m 0755 "${target%/*}"
    tmp="$(mktemp "${target%/*}/.bisquite-locale.XXXXXX")"
    cat > "$tmp"
    chmod "$mode" "$tmp"
    if [[ -f "$target" ]] && cmp -s "$tmp" "$target"; then
        rm -f "$tmp"; return 1
    fi
    mv -f "$tmp" "$target"
}

write_if_changed /etc/default/keyboard 0644 <<EOF || true
# KEYBOARD CONFIGURATION FILE
# Written by the bisquite extension locale from /etc/bisquite/locale/config.
# Change: sudo bisquite-conf set locale KEYBOARD_LAYOUTS=us,ru KEYBOARD_TOGGLE=grp:alt_shift_toggle

XKBMODEL="$model"
XKBLAYOUT="$xkb_layout"
XKBVARIANT="$xkb_variant"
XKBOPTIONS="$KEYBOARD_TOGGLE"

BACKSPACE="guess"
EOF

write_if_changed /etc/X11/xorg.conf.d/00-keyboard.conf 0644 <<EOF || true
# Written by the bisquite extension locale from /etc/bisquite/locale/config
# (the same format localectl set-x11-keymap writes).
Section "InputClass"
        Identifier "system-keyboard"
        MatchIsKeyboard "on"
        Option "XkbLayout" "$xkb_layout"
        Option "XkbModel" "$model"
        Option "XkbVariant" "$xkb_variant"
        Option "XkbOptions" "$KEYBOARD_TOGGLE"
EndSection
EOF
shown_variant=""
[[ "$xkb_variant" =~ [a-z] ]] && shown_variant=" (варианты $xkb_variant)"
log "раскладки $xkb_layout$shown_variant${KEYBOARD_TOGGLE:+, переключение $KEYBOARD_TOGGLE}"

# The console keymap is cached by console-setup; refresh the cache so the next
# boot does not compile it from scratch (and does it at all on a read-only /etc).
if command -v setupcon >/dev/null 2>&1; then
    setupcon --save-only >/dev/null 2>&1 || log "setupcon --save-only не прошёл — консоль соберёт раскладку при загрузке"
fi

# --- GNOME input sources ----------------------------------------------------
sources=""
for i in "${!layouts[@]}"; do
    id="${layouts[$i]}${variants[$i]:++${variants[$i]}}"
    sources+="${sources:+, }('xkb', '$id')"
done
# An empty GVariant array needs its type: dconf cannot infer it from `[]`
# and `dconf update` rejects the whole keyfile.
options="@as []"
[[ -n "$KEYBOARD_TOGGLE" ]] && options="['$KEYBOARD_TOGGLE']"
keyfile="$(cat <<EOF
# Written by the bisquite extension locale: defaults (not locks) of GNOME
# input sources. A user's own choice in Settings wins.
[org/gnome/desktop/input-sources]
sources=[$sources]
xkb-options=$options
EOF
)"

dconf_changed=0
install -d -m 0755 /etc/dconf/profile /etc/dconf/db/local.d
# Same profile rule as lib/bisquite-desktop: a user db over the system db `local`.
if [[ ! -f /etc/dconf/profile/user ]]; then
    printf 'user-db:user\nsystem-db:local\n' > /etc/dconf/profile/user
elif ! grep -q '^system-db:local$' /etc/dconf/profile/user; then
    printf 'system-db:local\n' >> /etc/dconf/profile/user
fi
printf '%s\n' "$keyfile" | write_if_changed /etc/dconf/db/local.d/40-bisquite-locale 0644 && dconf_changed=1
# The login screen reads its own profile (profile/gdm -> system-db:gdm).
if [[ -f /etc/dconf/profile/gdm ]]; then
    install -d -m 0755 /etc/dconf/db/gdm.d
    printf '%s\n' "$keyfile" | write_if_changed /etc/dconf/db/gdm.d/40-bisquite-locale 0644 && dconf_changed=1
fi
if command -v dconf >/dev/null 2>&1; then
    if (( dconf_changed )) || [[ ! -f /etc/dconf/db/local ]]; then
        dconf update || die "dconf update не прошёл"
    fi
    log "GNOME input-sources по умолчанию: [$sources]"
else
    log "dconf нет (не GNOME) — умолчания GNOME записаны, база соберётся, когда появится dconf (dconf update)"
fi
