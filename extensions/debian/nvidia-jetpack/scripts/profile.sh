# shellcheck shell=bash
# Профиль пары «плата × релиз». Подключается через source:
#
#     . scripts/profile.sh && load_profile agx-xavier 35.6.5
#
# Порядок: boards/<плата>.env, затем releases/<релиз>.env, затем
# pairs/<плата>@<релиз>.env, если есть. Позднее перекрывает раннее — так пара
# уточняет релиз, а релиз обнуляет то, чего плате в нём не положено.
#
# WORK задаётся ПАРОЙ, а не платой: шаг 03 необратим, шаг 04 правит rootfs на
# месте, и два релиза в одном каталоге затёрли бы друг друга.
_PROFILE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

load_profile() {
    local jetson="${1:-}" l4t="${2:-}" board release pair
    if [ -z "$jetson" ] || [ -z "$l4t" ]; then
        echo "ОТКАЗ: нужны оба значения — jetson=<плата> l4t=<релиз>" >&2
        _profile_list >&2
        return 1
    fi
    board="$_PROFILE_DIR/boards/$jetson.env"
    release="$_PROFILE_DIR/releases/$l4t.env"
    pair="$_PROFILE_DIR/pairs/$jetson@$l4t.env"
    if [ ! -f "$board" ]; then
        echo "ОТКАЗ: плата '$jetson' не объявлена" >&2; _profile_list >&2; return 1
    fi
    if [ ! -f "$release" ]; then
        echo "ОТКАЗ: релиз '$l4t' не объявлен" >&2; _profile_list >&2; return 1
    fi
    set -a
    # shellcheck source=/dev/null
    . "$board"
    # shellcheck source=/dev/null
    . "$release"
    if [ -f "$pair" ]; then
        # shellcheck source=/dev/null
        . "$pair"
    fi
    set +a
    case " ${SOCS:-} " in
        *" ${SOC:-} "*) ;;
        *)
            echo "ОТКАЗ: релиз $l4t не поддерживает ${SOC:-?} ($jetson); поддерживает: ${SOCS:-ничего}" >&2
            return 1 ;;
    esac
    export JETSON="$jetson" L4T="$l4t"
    export WORK="${WORK:-/srv/l4t/$jetson@$l4t}"
    export OUT_DIR="${OUT_DIR:-$WORK/out}"
    export OUT_RAW="${OUT_RAW:-$WORK/system.img}"
    export OUT_QCOW2="${OUT_QCOW2:-$OUT_DIR/system.qcow2}"
}

_profile_list() {
    local d
    for d in boards releases; do
        printf '%-8s' "$d:"
        (cd "$_PROFILE_DIR/$d" 2>/dev/null && ls -- *.env 2>/dev/null) | sed 's/\.env$//' | tr '\n' ' '
        echo
    done
}

_profile_pairs() {
    local b r soc socs
    for b in "$_PROFILE_DIR"/boards/*.env; do
        soc="$(sed -n 's/^SOC=//p' "$b")"
        for r in "$_PROFILE_DIR"/releases/*.env; do
            socs="$(sed -n 's/^SOCS=//p' "$r" | tr -d '"')"
            case " $socs " in
                *" $soc "*) echo "$(basename "$b" .env)@$(basename "$r" .env)" ;;
            esac
        done
    done
}
