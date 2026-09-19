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

echo "== профили: Nano и источник системы =="
check "nano@32.7.4 грузится, BOARDID=3448"           lp nano 32.7.4 '[ "$BOARDID" = 3448 ]'
check "nano: FAB/SKU/BOARDREV из EEPROM"              lp nano 32.7.4 '[ "$FAB $BOARD_SKU $BOARDREV" = "400 0000 F.0" ]'
check "nano: цель jetson-nano-qspi, nvmassflashgen"   lp nano 32.7.4 '[ "$BOARD_TARGET" = jetson-nano-qspi ] && [ "$BOOTLOADER_TOOL" = nvmassflashgen ]'
check "USB-ID в recovery: nano 7f21"                  lp nano 32.7.4 '[ "$RCM_USB_ID" = 7f21 ]'
check "USB-ID в recovery: xavier 7019"                lp agx-xavier 35.6.5 '[ "$RCM_USB_ID" = 7019 ]'
check "USB-ID в recovery: orin 7023"                  lp agx-orin 36.4.3 '[ "$RCM_USB_ID" = 7023 ]'
check "nano: разметка QSPI, FLASH_XML пуст"           lp nano 32.7.4 '[ "$QSPI_CFG" = bootloader/t210ref/cfg/flash_l4t_t210_max-spi_p3448.xml ] && [ -z "$FLASH_XML" ]'
check "32.7.4: сверенный SHA1, хост 18.04, без -d"    lp nano 32.7.4 '[ "$BSP_SHA1" = 66ba218a9a60373dbbf00e5724fb66e40d1f527c ] && [ "$FLASH_HOSTS" = 18.04 ] && [ "$CREATOR_HAS_DEV_FLAG" = no ]'
check "nano@32.7.4: система — образ вендора R32.6.1"  lp nano 32.7.4 '[ "$ROOTFS_SOURCE" = vendor-image ] && [ "$ROOTFS_L4T" = 32.6.1 ] && [ "$L4T" = 32.7.4 ]'
check "nano@32.7.4: размер .img.xz — число из HEAD"   lp nano 32.7.4 '[ "$VENDOR_IMG_SIZE" = 9383066480 ]'
check "nano@32.7.4: sha256 образа закреплена"         lp nano 32.7.4 '[ "$VENDOR_IMG_SHA256" = 2e74215dd7d36bcbe91175c2e69399492c5b493bcfecdd0a7300c6dfa3d45fd8 ]'
check "xavier: initrd-flash"                          lp agx-xavier 35.6.5 '[ "$BOOTLOADER_TOOL" = initrd-flash ]'
check "orin: initrd-flash"                            lp agx-orin 36.4.3 '[ "$BOOTLOADER_TOOL" = initrd-flash ]'
check "AGX: умолчание — nvidia-bsp, система = релиз"  lp agx-xavier 35.6.5 '[ "$ROOTFS_SOURCE" = nvidia-bsp ] && [ "$ROOTFS_L4T" = 35.6.5 ] && [ -z "${VENDOR_IMG_URL:-}" ]'
check "поля Nano не протекают в следующий профиль"    bash -c ". '$S/profile.sh'; load_profile nano 32.7.4 && load_profile agx-orin 36.4.3 && [ \"\$ROOTFS_SOURCE\" = nvidia-bsp ] && [ \"\$ROOTFS_L4T\" = 36.4.3 ] && [ -z \"\${VENDOR_IMG_URL:-}\" ]"
refuses "nano на 35.6.5 (t210 не в SOCS)"             lp nano 35.6.5 true
refuses "orin на 32.7.4 (t234 не в SOCS)"             lp agx-orin 32.7.4 true
refuses "xavier на 32.7.4 (t194 не в SOCS)"           lp agx-xavier 32.7.4 true
check "_profile_pairs: у nano одна пара — 32.7.4"     bash -c ". '$S/profile.sh'; [ \"\$(_profile_pairs | grep '^nano@')\" = nano@32.7.4 ]"

echo "== шаг 08: аргументы creator'а =="
c08() { ( . "$S/profile.sh" && load_profile agx-xavier 35.6.5 && CREATOR_HAS_DEV_FLAG="$1" DRY_RUN=1 bash "$S/08-build-base-image.sh" ); }
check   "с -d, когда creator его знает"   bash -c "$(declare -f c08); S='$S'; c08 yes | grep -q -- '-d USB'"
refuses "без -d, когда не знает (R32)"    bash -c "$(declare -f c08); S='$S'; c08 no | grep -q -- '-d '"

echo "== manifest.py =="
mt="$(mktemp -d)"
# shellcheck disable=SC2034  # переменные экспортируются для manifest.py через set -a
( set -a; JETSON=agx-xavier L4T=35.6.5 SOC=t194 BOARD_TARGET=jetson-agx-xavier-devkit BOARDID=2888 FAB=400 \
  BOARD_SKU=0001 BOARDREV=J.0 BOOTLOADER_PACKAGE=full BSP_FILE=b.tbz2 BSP_SHA1=abc \
  ROOTFS_SOURCE=nvidia-bsp ROOTFS_L4T=35.6.5; set +a
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

echo "== manifest.py: происхождение системы =="
mr() { ( . "$S/profile.sh" && load_profile "$1" "$2" && python3 "$S/manifest.py" internal --bootloader-files "$mt/files.sha256" --out "$mt/$1.json" ); }
check   "agx: манифест из профиля"                     mr agx-xavier 35.6.5
check   "agx: rootfs — nvidia-bsp той же версии, без суммы образа" python3 -c "import json;r=json.load(open('$mt/agx-xavier.json'))['rootfs'];assert r=={'source':'nvidia-bsp','l4t':'35.6.5'},r"
check   "nano: манифест из профиля"                    mr nano 32.7.4
check   "nano: rootfs — образ вендора 32.6.1 с суммой входа" python3 -c "import json;r=json.load(open('$mt/nano.json'))['rootfs'];assert r=={'source':'vendor-image','l4t':'32.6.1','vendor_img_sha256':'2e74215dd7d36bcbe91175c2e69399492c5b493bcfecdd0a7300c6dfa3d45fd8'},r"
check   "nano: пара названа по загрузчику — 32.7.4"    python3 -c "import json;p=json.load(open('$mt/nano.json'))['pair'];assert p['l4t']=='32.7.4' and 'rootfs_source' not in p"
check   "PROFILE_KEYS не тронуты"                      env PYTHONDONTWRITEBYTECODE=1 python3 -c "import sys;sys.path.insert(0,'$S');from manifest import PROFILE_KEYS as K;assert K==['JETSON','L4T','SOC','BOARD_TARGET','BOARDID','FAB','BOARD_SKU','BOARDREV','BOOTLOADER_PACKAGE','BSP_FILE','BSP_SHA1']"
refuses "неизвестный источник системы — отказ"         bash -c ". '$S/profile.sh' && load_profile agx-xavier 35.6.5 && ROOTFS_SOURCE=nope python3 '$S/manifest.py' internal --bootloader-files '$mt/files.sha256' --out '$mt/z.json'"
refuses "vendor-image без суммы образа — отказ"        bash -c ". '$S/profile.sh' && load_profile nano 32.7.4 && VENDOR_IMG_SHA256= python3 '$S/manifest.py' internal --bootloader-files '$mt/files.sha256' --out '$mt/z.json'"

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
p09n() { ( . "$S/profile.sh" && load_profile nano 32.7.4 && DRY_RUN=1 bash "$S/09-build-jetson-base.sh" "$@" ); }
check   "nano: BSP → пакет → образ вендора → манифесты" bash -c "$(declare -f p09n); S='$S'; [ \"\$(p09n | tr '\n' ' ')\" = '01-fetch-l4t.sh 03-prepare-bsp.sh 11-package-bootloader.sh vendor:fetch vendor:qcow2 manifest:internal manifest:outer ' ]"
refuses "nano: ни камер, ни 04, ни creator'а"      bash -c "$(declare -f p09n); S='$S'; p09n | grep -qE '^(02|04|08)-'"
check   "--fresh сносит raw образа вендора"          bash -c "$(declare -f p09n); S='$S'; p09n --fresh | grep -qx 'сносится: /srv/l4t/nano@32.7.4/vendor-image.raw'"
check   "--fresh сносит недописанный qcow2.tmp"      bash -c "$(declare -f p09n); S='$S'; p09n --fresh | grep -q '^сносится: .*/system.qcow2.tmp$'"
refuses "--fresh не трогает кеш загрузок"            bash -c "$(declare -f p09n); S='$S'; p09n --fresh | grep -q downloads"
refuses "неизвестный ROOTFS_SOURCE — отказ"          bash -c ". '$S/profile.sh' && load_profile nano 32.7.4 && ROOTFS_SOURCE=nope DRY_RUN=1 bash '$S/09-build-jetson-base.sh'"

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
     BOOTLOADER_PACKAGE=full BSP_FILE=b BSP_SHA1=c ROOTFS_SOURCE=nvidia-bsp ROOTFS_L4T=35.6.5
     BOOTLOADER_TOOL=initrd-flash)
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
# A package built before rootfs existed: its manifest has no "rootfs" key.
# Step 14 must not care — PROFILE_KEYS did not change.
mk14 AAA; python3 -c "import json,sys;p=sys.argv[1];m=json.load(open(p));m.pop('rootfs');json.dump(m,open(p,'w'))" "$ft/out/manifest.json"
          check   "манифест старого образца действительно без rootfs" python3 -c "import json;assert 'rootfs' not in json.load(open('$ft/out/manifest.json'))"
          check   "пакет AGX, собранный до rootfs, проходит сверку" r14

echo "== шаг 14: пакет Nano =="
P14N=(JETSON=nano L4T=32.7.4 SOC=t210 BOARD_TARGET=jetson-nano-qspi BOARDID=3448 FAB=400 BOARD_SKU=0000 BOARDREV=F.0
      BOOTLOADER_PACKAGE=qspi-only BOOTLOADER_TOOL=nvmassflashgen BSP_FILE=b BSP_SHA1=c
      ROOTFS_SOURCE=vendor-image ROOTFS_L4T=32.6.1
      VENDOR_IMG_SHA256=2e74215dd7d36bcbe91175c2e69399492c5b493bcfecdd0a7300c6dfa3d45fd8)
mk14n() {  # $1 — cboot.bin in the archive (the manifest is always from "AAA"); $2=extra — an unlisted file
  local d="$ft/nsrc/mfi_jetson-nano-qspi"
  rm -rf "$ft/nsrc" "$ft/nout"; mkdir -p "$d" "$ft/nout"
  printf '#!/bin/sh\n' > "$d/nvmflash.sh"; chmod 755 "$d/nvmflash.sh"
  echo AAA > "$d/cboot.bin"; echo log1 > "$d/mfi.log"
  ( cd "$d" && find . -type f ! -path ./mfi.log ! -path './mfilogs/*' -print0 | sort -z | xargs -0 sha256sum ) > "$ft/nout/bootloader-files.sha256"
  echo "$1" > "$d/cboot.bin"; echo log2 > "$d/mfi.log"
  [ "${2:-}" = extra ] && echo evil > "$d/evil.sh"
  tar -czf "$ft/nout/bootloader.tar.gz" -C "$ft/nsrc" mfi_jetson-nano-qspi
  echo q > "$ft/nout/system.qcow2"
  ( export "${P14N[@]}"
    python3 "$S/manifest.py" outer --bootloader-files "$ft/nout/bootloader-files.sha256" --out "$ft/nout/manifest.json" \
      --artifact "$ft/nout/system.qcow2" --artifact "$ft/nout/bootloader.tar.gz" )
}
r14n() { env "${P14N[@]}" FLASH_HOSTS=18.04 OUT_DIR="$ft/nout" DRY_RUN=1 "$@" bash "$S/14-flash-bootloader.sh"; }
mk14n AAA; check   "nano: целый пакет проходит сверку (журнал сборки не сверяется)" r14n
           check   "…сверены оба файла пакета"        bash -c "$(declare -f r14n); $(declare -p P14N); S='$S' ft='$ft'; out=\"\$(r14n 2>&1)\"; grep -q 'файлы загрузчика: 2 сошлись' <<<\"\$out\""
           refuses "…после DRY_RUN распакованное убрано" test -e "$ft/nout/.flash"
           refuses "nano-пакет под профилем initrd-flash — отказ" r14n BOOTLOADER_TOOL=initrd-flash
           refuses "пустой BOOTLOADER_TOOL — отказ"   r14n BOOTLOADER_TOOL=
mk14n BBB; refuses "nano: подменённый cboot.bin — отказ" r14n
           refuses "…после отказа распакованное убрано" test -e "$ft/nout/.flash"
mk14n AAA extra
           refuses "nano: файл, которого нет в манифесте, — отказ" r14n
# The real (non-DRY_RUN) path up to nvmflash.sh: root via the id stub,
# lsusb scripted per call (LSUSB_1, LSUSB_2), the answer on stdin.
lb="$(mktemp -d)"
printf '#!/bin/bash\ncase "${1:-}" in -u) echo 0 ;; -un) echo root ;; *) exec /usr/bin/id "$@" ;; esac\n' > "$lb/id"
printf '#!/bin/bash\nn=$(( $(cat "$LSUSB_CNT" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$LSUSB_CNT"\nv="LSUSB_$n"; printf "%%b" "${!v:-${LSUSB_1:-}}"\n' > "$lb/lsusb"
chmod +x "$lb/id" "$lb/lsusb"
NANO='Bus 001 Device 009: ID 0955:7f21 NVIDIA Corp. APX\n'
XAV='Bus 001 Device 010: ID 0955:7019 NVIDIA Corp. APX\n'
f14n() { rm -f "$lb/cnt"; printf '%s\n' "$1" | env PATH="$lb:$PATH" LSUSB_CNT="$lb/cnt" "${P14N[@]}" RCM_USB_ID=7f21 FLASH_HOSTS=18.04 \
           OUT_DIR="$ft/nout" LSUSB_1="$2" LSUSB_2="${3:-$2}" bash "$S/14-flash-bootloader.sh"; }
mk14n AAA
check   "nano в recovery одна, «да» — дошло до nvmflash.sh" f14n да "$NANO"
refuses "в recovery Xavier вместо Nano — отказ"      f14n да "$XAV"
refuses "Nano и Xavier в recovery разом — отказ"     f14n да "$NANO$XAV"
refuses "вторая плата подключена во время вопроса — отказ после «да»" f14n да "$NANO" "$NANO$XAV"
refuses "ответ не «да» — отмена"                     f14n нет "$NANO"

echo "== образ вендора: vendor-image.sh =="
vi="$(mktemp -d)"; mkdir -p "$vi/bin" "$vi/out"
head -c 65536 /dev/urandom > "$vi/src.img"; truncate -s 8M "$vi/src.img"
xz -k -T1 "$vi/src.img"
printf 'aaa  ./cboot.bin\n' > "$vi/out/bootloader-files.sha256"
cat > "$vi/bin/df" <<'EOF'
#!/bin/bash
# Stub: FAKE_AVAIL pretends the disk has that many free bytes.
if [ -n "${FAKE_AVAIL:-}" ]; then printf 'Avail\n%s\n' "$FAKE_AVAIL"; else exec /usr/bin/df "$@"; fi
EOF
cat > "$vi/bin/qemu-img" <<'EOF'
#!/bin/bash
# Stub: records how sparse the raw is, then "converts" by copying.
src="${*: -2:1}"; dst="${*: -1}"
stat -c '%s %b %B' "$src" > "$VI_LOG/raw.stat"
if [ "${QEMU_FAIL:-0}" = 1 ]; then : > "$dst"; exit 1; fi
cp -- "$src" "$dst"
EOF
cat > "$vi/bin/guestfish" <<'EOF'
#!/bin/bash
# Stub: records the arguments and keeps a copy of the uploaded file.
echo "$*" > "$VI_LOG/guestfish.args"
prev=""
for a in "$@"; do [ "$prev" = upload ] && cp -- "$a" "$VI_LOG/uploaded.json"; prev="$a"; done
exit "${GF_RC:-0}"
EOF
chmod +x "$vi/bin/"*
# rvi <function> [VAR=value …] — the nano profile pointed at the test image.
rvi() { local fn="$1"; shift
  ( . "$S/profile.sh" && load_profile nano 32.7.4 || exit 1
    export PATH="$vi/bin:$PATH" VI_LOG="$vi" WORK="$vi/w" OUT_DIR="$vi/out" \
           VENDOR_IMG_URL="file://$vi/src.img.xz" VENDOR_IMG_SIZE="$(stat -c %s "$vi/src.img.xz")" \
           VENDOR_IMG_SHA256="$(sha256sum "$vi/src.img.xz" | cut -d' ' -f1)"
    [ $# -eq 0 ] || export "$@"
    . "$S/vendor-image.sh" && "$fn" ); }
check   "fetch: скачал в кеш и сверил sha256"          rvi vendor_fetch
check   "…файл в \$WORK/downloads"                     test -f "$vi/w/downloads/src.img.xz"
check   "fetch: из кеша, без сети"                      rvi vendor_fetch VENDOR_IMG_URL="file://$vi/nope/src.img.xz"
refuses "fetch: sha256 не сошлась — отказ"             rvi vendor_fetch VENDOR_IMG_SHA256=0000000000000000000000000000000000000000000000000000000000000000
refuses "…и файл удалён"                               test -e "$vi/w/downloads/src.img.xz"
refuses "fetch: места под скачивание нет — отказ"      rvi vendor_fetch FAKE_AVAIL=1
refuses "…и ничего не скачано"                         test -e "$vi/w/downloads/src.img.xz"
check   "fetch: скачал после отказа"                    rvi vendor_fetch
refuses "qcow2: места под несжатый образ нет — отказ"  rvi vendor_to_qcow2 FAKE_AVAIL=1048576
refuses "…raw не остался"                              test -e "$vi/w/vendor-image.raw"
refuses "qcow2: qemu-img упал — отказ"                 rvi vendor_to_qcow2 QEMU_FAIL=1
refuses "…raw убран ловушкой"                          test -e "$vi/w/vendor-image.raw"
refuses "…недописанный qcow2.tmp убран"                test -e "$vi/out/system.qcow2.tmp"
refuses "…system.qcow2 не появился"                    test -e "$vi/out/system.qcow2"
check   "qcow2: raw разреженный"                        awk '{ exit !($2 * $3 < $1) }' "$vi/raw.stat"
check   "qcow2: собран qcow2.tmp"                       rvi vendor_to_qcow2
check   "…содержимое — распакованный образ"             cmp -s "$vi/src.img" "$vi/out/system.qcow2.tmp"
refuses "…raw после успеха убран"                      test -e "$vi/w/vendor-image.raw"
refuses "…до манифеста system.qcow2 не появился"       test -e "$vi/out/system.qcow2"
refuses "манифест: guestfish упал — отказ"             rvi vendor_put_manifest GF_RC=1
refuses "…qcow2.tmp убран"                             test -e "$vi/out/system.qcow2.tmp"
refuses "…system.qcow2 не появился"                    test -e "$vi/out/system.qcow2"
check   "qcow2 заново"                                   rvi vendor_to_qcow2
check   "манифест: положен"                             rvi vendor_put_manifest
check   "…system.qcow2 на месте, qcow2.tmp нет"         bash -c "test -f '$vi/out/system.qcow2' && ! test -e '$vi/out/system.qcow2.tmp'"
check   "…guestfish: инспекция, каталог, файл"          grep -qE -- '^--rw --format=qcow2 -a .*/system\.qcow2\.tmp -i mkdir-p /opt/l4t-boot-firmware : upload .* /opt/l4t-boot-firmware/manifest\.json : chmod 0644 /opt/l4t-boot-firmware/manifest\.json$' "$vi/guestfish.args"
check   "…внутри — rootfs образа вендора и пара 32.7.4, без артефактов" python3 -c "import json;m=json.load(open('$vi/uploaded.json'));assert m['rootfs']['source']=='vendor-image' and m['rootfs']['l4t']=='32.6.1' and m['pair']['l4t']=='32.7.4' and 'artifacts' not in m"

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

echo "== шаг 01: образ вендора — без sample rootfs =="
ot="$(mktemp -d)"; mkdir -p "$ot/bin" "$ot/src"
cat > "$ot/bin/wget" <<'EOF'
#!/bin/bash
# Stub for `wget -c -q --show-progress -O <name> <url>` with file:// URLs.
out=""; url=""
while [ $# -gt 0 ]; do
    case "$1" in -O) out="$2"; shift 2 ;; -*) shift ;; *) url="$1"; shift ;; esac
done
echo "$url" >> "$WGET_LOG"
cp -- "${url#file://}" "$out"
EOF
chmod +x "$ot/bin/wget"
echo bsp > "$ot/src/Jetson-210_Linux_R32.7.4_aarch64.tbz2"
echo sums > "$ot/src/release_sha_hashes.txt"
r01() { ( . "$S/profile.sh" && load_profile nano 32.7.4 && \
          env PATH="$ot/bin:$PATH" WGET_LOG="$ot/wget.log" WORK="$ot/w" \
              BSP_URL="file://$ot/src/Jetson-210_Linux_R32.7.4_aarch64.tbz2" \
              BSP_SHA1="$(sha1sum "$ot/src/Jetson-210_Linux_R32.7.4_aarch64.tbz2" | cut -d' ' -f1)" \
              RFS_URL="file://$ot/src/rfs.tbz2" SHA_URL="file://$ot/src/release_sha_hashes.txt" "$@" \
              bash "$S/01-fetch-l4t.sh" ); }
check   "vendor-image: 01 проходит без sample rootfs"  r01
check   "…BSP скачан"                                  test -f "$ot/w/downloads/Jetson-210_Linux_R32.7.4_aarch64.tbz2"
refuses "…а sample rootfs не запрашивался"             grep -q rfs.tbz2 "$ot/wget.log"
refuses "nvidia-bsp: без sample rootfs — отказ"        r01 ROOTFS_SOURCE=nvidia-bsp

echo "== шаг 03: образ вендора — только дерево BSP =="
# Root stub shared by the steps that check `id -u` (03, 11).
rb="$(mktemp -d)"
cat > "$rb/id" <<'EOF'
#!/bin/bash
# Stub: root for the scripts' `id -u` barriers; anything else goes to the real id.
case "${1:-}" in -u) echo 0 ;; -un) echo root ;; *) exec /usr/bin/id "$@" ;; esac
EOF
chmod +x "$rb/id"
pt="$(mktemp -d)"; mkdir -p "$pt/L/Linux_for_Tegra/bootloader" "$pt/L/Linux_for_Tegra/rootfs" "$pt/w/downloads"
printf '#!/bin/sh\n' > "$pt/L/Linux_for_Tegra/flash.sh"
printf '#!/bin/sh\ntouch "%s/applied"\n' "$pt" > "$pt/L/Linux_for_Tegra/apply_binaries.sh"
chmod +x "$pt/L/Linux_for_Tegra/flash.sh" "$pt/L/Linux_for_Tegra/apply_binaries.sh"
echo readme > "$pt/L/Linux_for_Tegra/rootfs/README.txt"
tar -cjf "$pt/w/downloads/Jetson-210_Linux_R32.7.4_aarch64.tbz2" -C "$pt/L" Linux_for_Tegra
r03() { ( . "$S/profile.sh" && load_profile nano 32.7.4 && \
          env PATH="$rb:$PATH" WORK="$pt/w" \
              BSP_SHA1="$(sha1sum "$pt/w/downloads/Jetson-210_Linux_R32.7.4_aarch64.tbz2" | cut -d' ' -f1)" "$@" \
              bash "$S/03-prepare-bsp.sh" ); }
check   "vendor-image: 03 разворачивает BSP"           r03
check   "…дерево на месте"                             test -x "$pt/w/Linux_for_Tegra/flash.sh"
check   "…rootfs/etc — каталог"                        test -d "$pt/w/Linux_for_Tegra/rootfs/etc"
refuses "…apply_binaries не запускался"               test -e "$pt/applied"
refuses "…метки .applied-binaries нет"                test -e "$pt/w/Linux_for_Tegra/rootfs/.applied-binaries"
rm -rf "$pt/w/Linux_for_Tegra/rootfs/etc"; : > "$pt/w/Linux_for_Tegra/rootfs/etc"
check   "повторный прогон по готовому дереву"          r03
check   "…файл rootfs/etc от flash.sh стал каталогом"  test -d "$pt/w/Linux_for_Tegra/rootfs/etc"
refuses "SHA1 тарболла не сошлась — отказ"            r03 BSP_SHA1=0000000000000000000000000000000000000000
# A tree unpacked by hand (no marker) must not be trusted: 03 unpacks again.
rm -f "$pt/w/Linux_for_Tegra/.bsp-sha1"; echo tampered > "$pt/w/Linux_for_Tegra/flash.sh"
check   "дерево без метки распаковки — распаковано заново" r03
check   "…подменённый файл вернулся из тарболла"      grep -qx '#!/bin/sh' "$pt/w/Linux_for_Tegra/flash.sh"
check   "…метка несёт SHA1 тарболла"                  grep -qx "$(sha1sum "$pt/w/downloads/Jetson-210_Linux_R32.7.4_aarch64.tbz2" | cut -d' ' -f1)" "$pt/w/Linux_for_Tegra/.bsp-sha1"
echo keep > "$pt/w/Linux_for_Tegra/sentinel"
check   "метка совпала — распаковка пропущена"       r03
check   "…дерево не тронуто"                          test -e "$pt/w/Linux_for_Tegra/sentinel"

echo "== шаг 11: пакет Nano (nvmassflashgen) =="
check   "nano: offline nvmassflashgen, цель QSPI"   bash -c "$(declare -f c11); S='$S'; c11 nano 32.7.4 | grep -q 'FUSELEVEL=fuselevel_production ./nvmassflashgen.sh jetson-nano-qspi mmcblk0p1'"
check   "nano: измеренные значения"                 bash -c "$(declare -f c11); S='$S'; c11 nano 32.7.4 | grep -q 'BOARDID=3448 BOARDSKU=0000 FAB=400 BOARDREV=F.0'"
refuses "nano: не l4t_initrd_flash"                 bash -c "$(declare -f c11); S='$S'; c11 nano 32.7.4 | grep -q l4t_initrd_flash"
refuses "t210 с целью -qspi-sd — отказ"             bash -c ". '$S/profile.sh' && load_profile nano 32.7.4 && BOARD_TARGET=jetson-nano-qspi-sd DRY_RUN=1 bash '$S/11-package-bootloader.sh'"
refuses "t210 с целью -devkit — отказ"              bash -c ". '$S/profile.sh' && load_profile nano 32.7.4 && BOARD_TARGET=jetson-nano-devkit DRY_RUN=1 bash '$S/11-package-bootloader.sh'"
refuses "неизвестный BOOTLOADER_TOOL — отказ"       bash -c ". '$S/profile.sh' && load_profile nano 32.7.4 && BOOTLOADER_TOOL=flash-sh DRY_RUN=1 bash '$S/11-package-bootloader.sh'"
nt="$(mktemp -d)"; mkdir -p "$nt/w/Linux_for_Tegra/bootloader" "$nt/w/Linux_for_Tegra/rootfs"
# What flash.sh leaves behind in an empty rootfs/: a FILE named etc.
: > "$nt/w/Linux_for_Tegra/rootfs/etc"
cat > "$nt/w/Linux_for_Tegra/nvmassflashgen.sh" <<'EOF'
#!/bin/bash
# Stub with the real layout: the package directory in bootloader/, the
# tarball one level up (nvmassflashgen.sh:1198-1200). Records what it got.
set -e
echo "BOARDID=$BOARDID BOARDSKU=$BOARDSKU FAB=$FAB BOARDREV=$BOARDREV FUSELEVEL=$FUSELEVEL ARGS=$*" > ../gen.env
[ "${STUB_FAIL:-0}" = 1 ] && exit 1
d="mfi_$1"
cd bootloader && rm -rf "$d" && mkdir "$d"
printf '#!/bin/sh\necho flash\n' > "$d/nvmflash.sh"; chmod 755 "$d/nvmflash.sh"
echo cboot > "$d/cboot.bin"; echo "build log $RANDOM" > "$d/mfi.log"
[ "${STUB_LINK:-0}" = 1 ] && ln -s cboot.bin "$d/cboot-alias.bin"
tar cjf "../$d.tbz2" "$d"
EOF
chmod +x "$nt/w/Linux_for_Tegra/nvmassflashgen.sh"
r11n() { ( . "$S/profile.sh" && load_profile nano 32.7.4 && \
           env PATH="$rb:$PATH" WORK="$nt/w" OUT_DIR="$nt/out" "$@" bash "$S/11-package-bootloader.sh" ); }
check   "nano: пакет собран"                        r11n
check   "…rootfs/etc — каталог, а не файл"          test -d "$nt/w/Linux_for_Tegra/rootfs/etc"
check   "…offline-значения доехали до генератора"   grep -qx 'BOARDID=3448 BOARDSKU=0000 FAB=400 BOARDREV=F.0 FUSELEVEL=fuselevel_production ARGS=jetson-nano-qspi mmcblk0p1' "$nt/w/gen.env"
check   "…tar-поток после перекодирования тот же байт в байт" bash -c "cmp -s <(bzip2 -dc '$nt/w/Linux_for_Tegra/mfi_jetson-nano-qspi.tbz2') <(gzip -dc '$nt/out/bootloader.tar.gz')"
check   "…режимы сохранены: nvmflash.sh исполняемый" bash -c "tar -tvzf '$nt/out/bootloader.tar.gz' | grep -qE '^-rwxr-xr-x .* mfi_jetson-nano-qspi/nvmflash.sh$'"
check   "…хеши: весь каталог, скрипт заливки тоже"  bash -c "grep -q ' ./nvmflash.sh$' '$nt/out/bootloader-files.sha256' && grep -q ' ./cboot.bin$' '$nt/out/bootloader-files.sha256'"
refuses "…хеши: журнал сборки не входит"            grep -q 'mfi.log' "$nt/out/bootloader-files.sha256"
# Step 11 → manifest.py → step 14 end to end: both steps must walk the package
# the same way, a symlink included (14 follows links; 11 must hash them too).
rm -rf "$nt/out"
check   "nano: пакет со ссылкой внутри собран"      r11n STUB_LINK=1
check   "…ссылка в списке хешей"                    grep -q ' ./cboot-alias.bin$' "$nt/out/bootloader-files.sha256"
echo q > "$nt/out/system.qcow2"
( export "${P14N[@]}"; python3 "$S/manifest.py" outer --bootloader-files "$nt/out/bootloader-files.sha256" \
    --out "$nt/out/manifest.json" --artifact "$nt/out/system.qcow2" --artifact "$nt/out/bootloader.tar.gz" )
check   "…шаг 14 принимает пакет шага 11 как есть"  env "${P14N[@]}" FLASH_HOSTS=18.04 OUT_DIR="$nt/out" DRY_RUN=1 bash "$S/14-flash-bootloader.sh"
rm -rf "$nt/out"
refuses "сбой nvmassflashgen — отказ"               r11n STUB_FAIL=1
refuses "…и пакета нет"                             test -e "$nt/out/bootloader.tar.gz"

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
# Nano: nvmassflashgen.sh, the board .conf (a symlink to a neighbour, like at
# NVIDIA) and the QSPI layout. $1=qspi — QSPI-only target; sd — the layout
# of jetson-nano-qspi-sd: no NO_ROOTFS=1 and an sdcard device.
mkbspn() {
  local L="$vt/N/Linux_for_Tegra"
  rm -rf "$vt/N"; mkdir -p "$L/bootloader/t210ref/cfg"
  printf '#!/bin/bash\n' > "$L/nvmassflashgen.sh"
  printf 'source "${LDK_DIR}/p3448-0000.conf.common";\nEMMC_CFG=flash_l4t_t210_max-spi_p3448.xml;\n' > "$L/p3449-0000+p3448-0000-qspi.conf"
  printf '<device type="spi" instance="0">\n</device>\n' > "$L/bootloader/t210ref/cfg/flash_l4t_t210_max-spi_p3448.xml"
  if [ "$1" = qspi ]; then
    echo 'NO_ROOTFS=1;' >> "$L/p3449-0000+p3448-0000-qspi.conf"
  else
    printf '<device type="sdcard" instance="0">\n</device>\n' >> "$L/bootloader/t210ref/cfg/flash_l4t_t210_max-spi_p3448.xml"
  fi
  ln -s p3449-0000+p3448-0000-qspi.conf "$L/jetson-nano-qspi.conf"
  tar -cjf "$vt/nbsp.tbz2" -C "$vt/N" Linux_for_Tegra
}
head -c 4096 /dev/urandom > "$vt/vimg.xz"
r15n() { ( . "$S/profile.sh" && load_profile nano 32.7.4 && unset WORK && \
           env BSP_URL="file://$vt/nbsp.tbz2" BSP_SHA1="$(sha1of "$vt/nbsp.tbz2")" \
               VENDOR_IMG_URL="file://$vt/vimg.xz" VENDOR_IMG_SHA256="$(sha256sum "$vt/vimg.xz" | cut -d' ' -f1)" \
               VERIFY_DIR="$vt/v" "$@" bash "$S/15-verify-pair.sh" ); }
code15n() { local want="$1"; shift; r15n "$@" >/dev/null 2>&1; [ "$?" -eq "$want" ]; }
mkbspn qspi; check   "nano: генератор, конфиг, разметка QSPI — проверено" r15n
             check   "…отпечаток называет инструмент и QSPI-only" bash -c "grep -qx 'bootloader_tool=nvmassflashgen' '$vt/v/nano@32.7.4.txt' && grep -qx 'qspi_only=ok' '$vt/v/nano@32.7.4.txt'"
             check   "…в отпечатке — sha256 образа вендора" grep -qx "vendor_img_sha256=$(sha256sum "$vt/vimg.xz" | cut -d' ' -f1)" "$vt/v/nano@32.7.4.txt"
             check   "nvidia-bsp: образ вендора не нужен"   code15n 0 ROOTFS_SOURCE=nvidia-bsp VENDOR_IMG_URL=file:///nonexistent.xz
             refuses "…и в отпечатке его нет"               grep -q vendor_img_sha256 "$vt/v/nano@32.7.4.txt"
mkbspn sd;   refuses "nano: разметка с SD-картой — не собирается" r15n
             check   "…видно в отпечатке"                   grep -qx 'qspi_only=нет' "$vt/v/nano@32.7.4.txt"
mkbspn qspi; r15n >/dev/null 2>&1; cp "$vt/v/nano@32.7.4.txt" "$vt/nbefore.txt"
             check   "sha256 образа вендора не сошлась — код 2" code15n 2 VENDOR_IMG_SHA256=0000000000000000000000000000000000000000000000000000000000000000
             check   "образ вендора недоступен — код 2"      code15n 2 VENDOR_IMG_URL="file://$vt/none.xz"
             check   "…отпечаток после обоих отказов не тронут" cmp -s "$vt/nbefore.txt" "$vt/v/nano@32.7.4.txt"
             check   "неизвестный BOOTLOADER_TOOL — код 2"    code15n 2 BOOTLOADER_TOOL=flash-sh

echo "== шаг 16: матрица =="
mx="$(mktemp -d)"; mkdir -p "$mx/v"
echo "verdict=проверено" > "$mx/v/agx-orin@39.2.txt"
printf 'agx-orin@36.4.3\tпрогнано\tробот\n' > "$mx/status.tsv"
m16() { VERIFY_DIR="$mx/v" STATUS_FILE="$mx/status.tsv" bash "$S/16-matrix.sh"; }
check   "orin@36.4.3 — прогнано (из status.tsv)" bash -c "$(declare -f m16); mx='$mx'; S='$S'; m16 | grep -E '^agx-orin +36\.4\.3 +прогнано'"
check   "orin@39.2 — проверено (из отпечатка)"   bash -c "$(declare -f m16); mx='$mx'; S='$S'; m16 | grep -E '^agx-orin +39\.2 +проверено'"
check   "xavier@35.6.5 — объявлено"              bash -c "$(declare -f m16); mx='$mx'; S='$S'; m16 | grep -E '^agx-xavier +35\.6\.5 +объявлено'"
refuses "xavier@36.4.3 в матрице отсутствует"    bash -c "$(declare -f m16); mx='$mx'; S='$S'; m16 | grep -E '^agx-xavier +36\.4\.3'"
check   "nano@32.7.4 — объявлено"                  bash -c "$(declare -f m16); mx='$mx'; S='$S'; m16 | grep -E '^nano +32\.7\.4 +объявлено +18\.04'"
refuses "nano@35.6.5 в матрице отсутствует"         bash -c "$(declare -f m16); mx='$mx'; S='$S'; m16 | grep -E '^nano +35\.6\.5'"

echo "проверок: $total, не прошло: $fails"
[ "$fails" -eq 0 ]
