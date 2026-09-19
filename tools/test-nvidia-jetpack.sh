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
# shellcheck disable=SC2034  # переменные экспортируются для manifest.py через set -a
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

echo "== шаг 11: команда пакета =="
c11() { ( . "$S/profile.sh" && load_profile "$1" "$2" && DRY_RUN=1 bash "$S/11-package-bootloader.sh" ); }
check   "orin: --qspi-only"               bash -c "$(declare -f c11); S='$S'; c11 agx-orin 36.4.3 | grep -q -- '--qspi-only'"
refuses "xavier: без --qspi-only"         bash -c "$(declare -f c11); S='$S'; c11 agx-xavier 35.6.5 | grep -q -- '--qspi-only'"
check   "xavier: измеренные значения"     bash -c "$(declare -f c11); S='$S'; c11 agx-xavier 35.6.5 | grep -q 'BOARDID=2888 FAB=400 BOARDSKU=0001 BOARDREV=J.0'"
check   "offline massflash, internal"     bash -c "$(declare -f c11); S='$S'; c11 agx-orin 36.4.3 | grep -q -- '--no-flash --massflash 1 --network usb0.*jetson-agx-orin-devkit internal'"
refuses "пустой BOARDREV — отказ"         bash -c ". '$S/profile.sh' && load_profile agx-orin 36.4.3 && BOARDREV= DRY_RUN=1 bash '$S/11-package-bootloader.sh'"

echo "== шаг 09: порядок =="
p09() { ( . "$S/profile.sh" && load_profile agx-xavier 35.6.5 && DRY_RUN=1 bash "$S/09-build-jetson-base.sh" ); }
check   "пакет загрузчика до образа"   bash -c "$(declare -f p09); S='$S'; p09 | tr '\n' ' ' | grep -q '11-package-bootloader.sh manifest:internal 08-build-base-image.sh manifest:outer'"
refuses "импорта в bisquite нет"        bash -c "$(declare -f p09); S='$S'; p09 | grep -q 'import'"
refuses "без профиля — отказ"           bash -c "unset WORK; DRY_RUN=1 bash '$S/09-build-jetson-base.sh'"
check   "OUT_QCOW2 вне OUT_DIR — отказ"  bash -c "export OUT_QCOW2=/elsewhere/x.qcow2; . '$S/profile.sh' && load_profile agx-xavier 35.6.5 && out=\"\$(DRY_RUN=1 bash '$S/09-build-jetson-base.sh')\"; [ \$? -ne 0 ] && grep -q 'ОТКАЗ: OUT_QCOW2=/elsewhere' <<<\"\$out\""

echo "== шаг 14: сверка пакета перед прошивкой =="
ft="$(mktemp -d)"
mk14() {  # $1 — содержимое a.bin в архиве; манифест всегда от "AAA"
  rm -rf "$ft/src" "$ft/out"; mkdir -p "$ft/src/mfi_x/tools/kernel_flash/images/internal" "$ft/out"
  echo AAA > "$ft/src/mfi_x/tools/kernel_flash/images/internal/a.bin"
  ( cd "$ft/src/mfi_x/tools/kernel_flash/images/internal" && find . -type f -print0 | sort -z | xargs -0 sha256sum ) > "$ft/out/bootloader-files.sha256"
  echo "$1" > "$ft/src/mfi_x/tools/kernel_flash/images/internal/a.bin"
  tar -czf "$ft/out/bootloader.tar.gz" -C "$ft/src" mfi_x
  echo q > "$ft/out/system.qcow2"
  ( export "${P14[@]}"
    python3 "$S/manifest.py" outer --bootloader-files "$ft/out/bootloader-files.sha256" --out "$ft/out/manifest.json" \
      --artifact "$ft/out/system.qcow2" --artifact "$ft/out/bootloader.tar.gz" )
}
# Профиль, под который собран тестовый пакет; r14 принимает поправки поверх.
P14=(JETSON=agx-xavier L4T=35.6.5 SOC=t194 BOARD_TARGET=x BOARDID=1 FAB=1 BOARD_SKU=1 BOARDREV=1
     BOOTLOADER_PACKAGE=full BSP_FILE=b BSP_SHA1=c)
r14() { env "${P14[@]}" FLASH_HOSTS=22.04 OUT_DIR="$ft/out" DRY_RUN=1 "$@" bash "$S/14-flash-bootloader.sh"; }
mk14 AAA; check   "целый пакет проходит сверку"       r14
          refuses "после DRY_RUN распакованное убрано" test -e "$ft/out/.flash"
          refuses "чужая пара — отказ"                r14 JETSON=agx-orin
          refuses "чужой BOARD_SKU — отказ"           r14 BOARD_SKU=2
          refuses "чужой BOARD_TARGET — отказ"        r14 BOARD_TARGET=y
          check   "отказ по SKU называет поле"        bash -c "$(declare -f r14); $(declare -p P14); S='$S' ft='$ft'; out=\"\$(r14 BOARD_SKU=2 2>&1)\"; grep -q 'board_sku' <<<\"\$out\""
          check   "баннер/вывод показывает плату из манифеста" bash -c "$(declare -f r14); $(declare -p P14); S='$S' ft='$ft'; out=\"\$(r14 2>&1)\"; grep -q 'board_sku=1 boardrev=1' <<<\"\$out\""
          check   "отказ по BOARD_TARGET — до распаковки, с именем поля" bash -c "$(declare -f r14); $(declare -p P14); S='$S' ft='$ft'; out=\"\$(r14 BOARD_TARGET=y 2>&1)\"; grep -q 'board_target' <<<\"\$out\" && ! grep -q 'архив:' <<<\"\$out\""
mk14 BBB; refuses "подменённый файл загрузчика — отказ" r14
          refuses "после отказа распакованное убрано" test -e "$ft/out/.flash"
mk14 AAA; echo tamper >> "$ft/out/bootloader.tar.gz"
          refuses "испорченный архив — отказ"         r14

echo "== шаг 07: rootfs по ssh =="
st="$(mktemp -d)"; mkdir -p "$st/bin" "$st/w/Linux_for_Tegra/tools/kernel_flash/images/external"
echo img > "$st/w/Linux_for_Tegra/tools/kernel_flash/images/external/system.img"
# Всё, чем 07 трогает плату и сеть, подменено: вызов оставляет след в журнале.
for c in sshpass ssh lsusb ip; do
  printf '#!/bin/sh\necho "%s $*" >> "%s/calls"\n' "$c" "$st" > "$st/bin/$c"; chmod +x "$st/bin/$c"
done
r07() { env PATH="$st/bin:$PATH" WORK="$st/w" JETSON=agx-orin L4T=36.4.3 "$@" bash "$S/07-flash-rootfs-ssh.sh" </dev/null; }
check   "DRY_RUN: выход 0"                         r07 DRY_RUN=1
check   "DRY_RUN: план называет пару и образ"      bash -c "$(declare -f r07); S='$S' st='$st'; out=\"\$(r07 DRY_RUN=1)\"; grep -q 'agx-orin@36.4.3' <<<\"\$out\" && grep -q 'images/external/system.img' <<<\"\$out\""
check   "DRY_RUN: ни ssh, ни lsusb, ни ip — до mke2fs не дошёл" test ! -e "$st/calls"
check   "DRY_RUN: не спрашивает «да»"              bash -c "$(declare -f r07); S='$S' st='$st'; out=\"\$(r07 DRY_RUN=1)\"; ! grep -q 'Введи' <<<\"\$out\""
refuses "без образа — отказ и под DRY_RUN"         r07 DRY_RUN=1 WORK="$st/nope"

echo "== шаг 15: проверка по BSP =="
vt="$(mktemp -d)"
# Раскладка как у NVIDIA: .conf платы и XML разметки — симлинки на соседние
# файлы с другими именами (R35.6.5: jetson-agx-xavier-devkit.conf ->
# p2822-0000+p2888-0004.conf, flash_l4t_t194_nvme.xml -> flash_l4t_nvme.xml).
mkbsp() {  # $1=yes — положить .conf платы; dangling — ссылка без цели
  rm -rf "$vt/L"; mkdir -p "$vt/L/Linux_for_Tegra/tools/kernel_flash"
  printf '\t\tjetson-agx-xavier-devkit)\n\t\t\tboardid="2888"\n\t\t-d | --device)\n' \
      > "$vt/L/Linux_for_Tegra/tools/jetson-disk-image-creator.sh"
  touch "$vt/L/Linux_for_Tegra/tools/kernel_flash/flash_l4t_nvme.xml"
  ln -s flash_l4t_nvme.xml "$vt/L/Linux_for_Tegra/tools/kernel_flash/flash_l4t_t194_nvme.xml"
  [ "$1" = yes ] && touch "$vt/L/Linux_for_Tegra/p2822-0000+p2888-0004.conf"
  [ "$1" = no ] || ln -s p2822-0000+p2888-0004.conf "$vt/L/Linux_for_Tegra/jetson-agx-xavier-devkit.conf"
  tar -cjf "$vt/bsp.tbz2" -C "$vt/L" Linux_for_Tegra
}
# Профили несут настоящие SHA1 BSP NVIDIA; тестовому архиву нужна его сумма.
sha1of() { sha1sum "$1" | cut -d' ' -f1; }
# r15 [VAR=значение …] — поправки окружения после load_profile.
r15() { ( . "$S/profile.sh" && load_profile agx-xavier 35.6.5 && unset WORK && \
          env BSP_URL="file://$vt/bsp.tbz2" BSP_SHA1="$(sha1of "$vt/bsp.tbz2")" VERIFY_DIR="$vt/v" "$@" \
              bash "$S/15-verify-pair.sh" ); }
code15() { local want="$1"; shift; r15 "$@" >/dev/null 2>&1; [ "$?" -eq "$want" ]; }
mkbsp yes; check   "ветка, конфиг и XML на месте — проверено" r15
           check   "отпечаток записан"  grep -q '^verdict=проверено' "$vt/v/agx-xavier@35.6.5.txt"
           check   "в отпечатке — посчитанная SHA1 потока" grep -qx "bsp_sha1=$(sha1of "$vt/bsp.tbz2")" "$vt/v/agx-xavier@35.6.5.txt"
mkbsp no;  refuses "ветка в creator есть, конфига нет — не собирается" r15
           check   "это видно в отпечатке" grep -q '^conf=нет' "$vt/v/agx-xavier@35.6.5.txt"
mkbsp dangling; refuses "симлинк конфига без цели — не собирается" r15
           check   "это тоже видно в отпечатке" grep -q '^conf=нет' "$vt/v/agx-xavier@35.6.5.txt"
mkbsp yes; r15 >/dev/null 2>&1
check   "недоступный BSP — код 2, а не вердикт"        code15 2 BSP_URL="file://$vt/nope.tbz2"
check   "отпечаток после сбоя загрузки не тронут"      grep -q '^verdict=проверено' "$vt/v/agx-xavier@35.6.5.txt"
check   "SHA1 потока не сошлась с профилем — код 2"    code15 2 BSP_SHA1=0000000000000000000000000000000000000000
check   "пустой BSP_SHA1 в профиле — код 2"            code15 2 BSP_SHA1=
# Локальный тарболл шага 01, оборванный wget -c: creator в начале архива
# извлекается, .conf дальше обрыва — нет. Без сверки суммы вышло бы
# записанное «не-собирается».
# Архив, где creator лежит в первом блоке bzip2, а .conf и XML — после 2 МБ
# несжимаемого наполнителя, то есть за обрывом.
mkbsp yes
head -c 2097152 /dev/urandom > "$vt/L/Linux_for_Tegra/filler.bin"
( cd "$vt/L" && tar -cjf "$vt/bsp.tbz2" Linux_for_Tegra/tools/jetson-disk-image-creator.sh \
    Linux_for_Tegra/filler.bin Linux_for_Tegra/p2822-0000+p2888-0004.conf \
    Linux_for_Tegra/jetson-agx-xavier-devkit.conf Linux_for_Tegra/tools/kernel_flash )
lb="$vt/w/downloads/$( . "$S/profile.sh" && load_profile agx-xavier 35.6.5 && echo "$BSP_FILE")"
mkdir -p "$(dirname "$lb")"
cp "$vt/bsp.tbz2" "$lb"
check   "целый локальный тарболл — проверено"          code15 0 WORK="$vt/w" BSP_URL=file:///nonexistent.tbz2
head -c "$(( $(stat -c %s "$vt/bsp.tbz2") * 3 / 4 ))" "$vt/bsp.tbz2" > "$lb"
cp "$vt/v/agx-xavier@35.6.5.txt" "$vt/before.txt"
check   "обрезанный локальный тарболл — код 2"         code15 2 WORK="$vt/w" BSP_URL=file:///nonexistent.tbz2
check   "отпечаток после обрезанного тарболла не тронут" cmp -s "$vt/before.txt" "$vt/v/agx-xavier@35.6.5.txt"
check   "тот же большой архив потоком — SHA1 сошлась"  code15 0

echo "== шаг 16: матрица =="
mx="$(mktemp -d)"; mkdir -p "$mx/v"
echo "verdict=проверено" > "$mx/v/agx-orin@39.2.txt"
printf 'agx-orin@36.4.3\tпрогнано\tробот\n' > "$mx/status.tsv"
m16() { VERIFY_DIR="$mx/v" STATUS_FILE="$mx/status.tsv" bash "$S/16-matrix.sh"; }
check   "orin@36.4.3 — прогнано (из status.tsv)" bash -c "$(declare -f m16); mx='$mx'; S='$S'; m16 | grep -E '^agx-orin +36\.4\.3 +прогнано'"
check   "orin@39.2 — проверено (из отпечатка)"   bash -c "$(declare -f m16); mx='$mx'; S='$S'; m16 | grep -E '^agx-orin +39\.2 +проверено'"
check   "xavier@35.6.5 — объявлено"              bash -c "$(declare -f m16); mx='$mx'; S='$S'; m16 | grep -E '^agx-xavier +35\.6\.5 +объявлено'"
refuses "xavier@36.4.3 в матрице отсутствует"    bash -c "$(declare -f m16); mx='$mx'; S='$S'; m16 | grep -E '^agx-xavier +36\.4\.3'"

echo "проверок: $total, не прошло: $fails"
[ "$fails" -eq 0 ]
