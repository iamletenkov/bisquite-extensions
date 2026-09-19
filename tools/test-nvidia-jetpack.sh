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

echo "== профили =="
lp() { ( . "$S/profile.sh" && load_profile "$1" "$2" && eval "$3" ); }
check "xavier@35.6.5 грузится, BOARDID=2888"      lp agx-xavier 35.6.5 '[ "$BOARDID" = 2888 ]'
check "xavier: BOARDREV измеренный J.0"            lp agx-xavier 35.6.5 '[ "$BOARDREV" = J.0 ]'
check "xavier: пакет full"                         lp agx-xavier 35.6.5 '[ "$BOOTLOADER_PACKAGE" = full ]'
check "orin: пакет qspi-only"                      lp agx-orin 36.4.3 '[ "$BOOTLOADER_PACKAGE" = qspi-only ]'
check "WORK по паре"                               lp agx-xavier 35.6.5 '[ "$WORK" = /srv/l4t/agx-xavier@35.6.5 ]'
check "OUT_QCOW2 внутри OUT_DIR"                   lp agx-orin 36.4.3 '[ "$OUT_QCOW2" = "$OUT_DIR/system.qcow2" ]'
check "пустой оверлей у 35.6.5 остаётся пустым"    lp agx-xavier 35.6.5 '[ -z "$OV_QSPI_URL" ] && [ "${OV_QSPI_URL+x}" = x ]'
check "пара orin@36.4.3 даёт оверлей QSPI"         lp agx-orin 36.4.3 '[ -n "$OV_QSPI_URL" ]'
check "orin@39.2 без пары: оверлея нет"            lp agx-orin 39.2 '[ -z "$OV_QSPI_URL" ]'
refuses "неизвестная плата"                        lp nope 35.6.5 true
refuses "неизвестный релиз"                        lp agx-xavier 1.0 true
refuses "пустой релиз"                             lp agx-xavier "" true
refuses "xavier на 36.4.3 (t194 не в SOCS)"        lp agx-xavier 36.4.3 true
check "_profile_pairs: xavier@35.6.5 есть"  bash -c ". '$S/profile.sh'; _profile_pairs | grep -qx 'agx-xavier@35.6.5'"
check "_profile_pairs: xavier@36.4.3 нет"   bash -c ". '$S/profile.sh'; ! _profile_pairs | grep -qx 'agx-xavier@36.4.3'"

echo "== шаг 08: аргументы creator'а =="
c08() { ( . "$S/profile.sh" && load_profile agx-xavier 35.6.5 && CREATOR_HAS_DEV_FLAG="$1" DRY_RUN=1 bash "$S/08-build-base-image.sh" ); }
check   "с -d, когда creator его знает"   bash -c "$(declare -f c08); S='$S'; c08 yes | grep -q -- '-d USB'"
refuses "без -d, когда не знает (R32)"    bash -c "$(declare -f c08); S='$S'; c08 no | grep -q -- '-d '"

echo "== manifest.py =="
mt="$(mktemp -d)"
( set -a; JETSON=agx-xavier L4T=35.6.5 SOC=t194 BOARD_TARGET=jetson-agx-xavier-devkit BOARDID=2888 FAB=400 \
  BOARD_SKU=0001 BOARDREV=J.0 BOOTLOADER_PACKAGE=full BSP_FILE=b.tbz2 BSP_SHA1=abc; set +a
  printf 'aaa  ./a.bin\nbbb  ./sub/b.bin\n' > "$mt/files.sha256"
  echo qcow > "$mt/system.qcow2"; echo tgz > "$mt/bootloader.tar.gz"
  python3 "$S/manifest.py" internal --bootloader-files "$mt/files.sha256" --out "$mt/in.json"
  python3 "$S/manifest.py" outer --bootloader-files "$mt/files.sha256" --out "$mt/out.json" \
      --artifact "$mt/system.qcow2" --artifact "$mt/bootloader.tar.gz"
  ! python3 "$S/manifest.py" internal --bootloader-files "$mt/files.sha256" --out "$mt/x.json" --artifact "$mt/system.qcow2" 2>/dev/null
) >/dev/null 2>&1 && ok "manifest.py отработал" || bad "manifest.py отработал"
check "внутренний: пара и файлы" python3 -c "import json;m=json.load(open('$mt/in.json'));assert m['pair']['jetson']=='agx-xavier' and len(m['bootloader_files'])==2 and 'artifacts' not in m"
check "внешний: суммы артефактов" python3 -c "import json,hashlib;m=json.load(open('$mt/out.json'));assert m['artifacts']['system.qcow2']==hashlib.sha256(open('$mt/system.qcow2','rb').read()).hexdigest()"
refuses "без профиля — отказ" env -i PATH="$PATH" python3 "$S/manifest.py" internal --bootloader-files "$mt/files.sha256" --out "$mt/y.json"

echo "проверок: $total, не прошло: $fails"
[ "$fails" -eq 0 ]
