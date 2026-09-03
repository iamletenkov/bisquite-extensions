#!/usr/bin/env bash
# Собрать ядро L4T с KVM и сделать его загружаемым по умолчанию.
#
# ЗАЧЕМ. Штатное ядро Jetson собрано без KVM, и libguestfs из-за этого
# поднимает appliance под полной эмуляцией TCG. Замер на Jetson Nano
# (2026-09-02): `libguestfs-test-tool` — 2 мин 42 с на штатном ядре против
# 11.8 с на ядре с KVM, то есть ~14 раз. Без этого Jetson как машина
# сборки arm64-образов непрактичен.
#
# ПОЧЕМУ ФАЗА BUILD, А НЕ FIRSTBOOT. Ядро обязано быть запечено в образ:
# собранное на устройстве давало бы каждой плате свой бинарь, и «одинаковый
# флот» переставал бы быть правдой. Тот же довод, которым `resolve_phases`
# запрещает подменять `build` на `firstboot`.
#
# ЭТО ДОЛГО: около трёх часов на Nano и 11 ГБ под исходники. Поэтому
# расширению место в БАЗОВОМ образе, откуда всё остальное наследует ядро
# через `FROM`, а не в каждой сборке.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} l4t-kernel-kvm: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} l4t-kernel-kvm: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} l4t-kernel-kvm: $*"; }

JOBS="${L4T_KERNEL_JOBS:-2}"
LOCALVERSION="${L4T_KERNEL_LOCALVERSION:--tegra-kvm}"
KEEP_SOURCES="${L4T_KERNEL_KEEP_SOURCES:-no}"
# Компилятор ЗАКРЕПЛЁН, и это не перестраховка.
#
# Исходники ядра L4T 4.9 писались под GCC 7 из bionic. На focal умолчание —
# GCC 9, и он валит сборку: в драйвере Wi-Fi Broadcom
#   drivers/net/wireless/bcmdhd_pcie/dhd_linux.c:5443
#   error: argument to 'sizeof' in 'strncpy' call is the same expression
#   as the source [-Werror=sizeof-pointer-memaccess]
# Замерено 2026-09-03: сборка умирает ровно здесь.
#
# GCC 8 выбран не наугад: рабочее ядро на живой машине собрано именно им —
#   Linux version 4.9.253-tegra-kvm (gcc version 8.4.0 (Ubuntu/Linaro 8.4.0-3ubuntu2))
# То есть это проверенное сочетание, а не «версия постарше, авось пройдёт».
#
# Подавлять предупреждение через -Wno-error НЕ стали: оно указывает на
# настоящий класс ошибок (sizeof от указателя вместо буфера), и глушить
# его на всём ядре ради одного драйвера — менять поломку на риск.
CC_BIN="${L4T_KERNEL_CC:-gcc-8}"

RELEASE_FILE=/etc/nv_tegra_release
EXTLINUX=/boot/extlinux/extlinux.conf
WORK=/usr/src/l4t-kernel-kvm

# --- 1. Это вообще Tegra? ----------------------------------------------------
if [[ ! -f "$RELEASE_FILE" ]]; then
    log_error "нет $RELEASE_FILE — это не L4T и не Jetson"
    log_error "расширение собирает ядро NVIDIA Tegra и на другой системе бессмысленно"
    exit 1
fi

# `# R32 (release), REVISION: 6.1, ...` -> 32 и 6.1
L4T_MAJOR="$(sed -n '1s/.*R\([0-9]\+\).*/\1/p' "$RELEASE_FILE")"
L4T_REV="$(sed -n '1s/.*REVISION: \([0-9.]\+\).*/\1/p' "$RELEASE_FILE")"
if [[ -z "$L4T_MAJOR" || -z "$L4T_REV" ]]; then
    log_error "не разобрал версию L4T из $RELEASE_FILE:"
    log_error "  $(head -1 "$RELEASE_FILE")"
    exit 1
fi
log_info "L4T R${L4T_MAJOR}.${L4T_REV}, сборка -j${JOBS}, суффикс ${LOCALVERSION}"

# --- 2. Исходники ------------------------------------------------------------
# Адрес собран по версии, а не прибит: на R32.7 он тот же с другими числами.
# Проверено 2026-09-03 для R32.6.1 — 161 774 820 байт, ровно тот же файл,
# что лежит в рабочем дереве на живой машине.
SRC_URL="https://developer.nvidia.com/embedded/l4t/r${L4T_MAJOR}_release_v${L4T_REV}/sources/t210/public_sources.tbz2"

apt-get update -q || exit 1
apt-get install -y -q --no-install-recommends \
    build-essential bc bison flex libssl-dev wget xz-utils bzip2 || exit 1

# Компилятор ставится отдельно: он может отсутствовать, и отказ должен
# называть причину, а не теряться среди прочих пакетов.
if ! command -v "$CC_BIN" >/dev/null 2>&1; then
    log_info "ставлю $CC_BIN"
    apt-get install -y -q --no-install-recommends "$CC_BIN" || {
        log_error "$CC_BIN не установился"
        log_error "исходники L4T 4.9 не собираются компилятором focal по умолчанию (GCC 9):"
        log_error "  -Werror=sizeof-pointer-memaccess в bcmdhd_pcie/dhd_linux.c"
        log_error "задайте другой через L4T_KERNEL_CC, если знаете рабочий"
        exit 1
    }
fi
log_info "компилятор: $("$CC_BIN" --version | head -1)"

rm -rf "$WORK"
mkdir -p "$WORK"
log_info "качаю исходники: $SRC_URL"
if ! wget -q -O "$WORK/public_sources.tbz2" "$SRC_URL"; then
    log_error "исходники не скачались: $SRC_URL"
    log_error "проверьте, публикует ли NVIDIA public_sources для R${L4T_MAJOR}.${L4T_REV}"
    exit 1
fi

tar -xjf "$WORK/public_sources.tbz2" -C "$WORK" || exit 1
rm -f "$WORK/public_sources.tbz2"

KERNEL_SRC_TBZ="$(find "$WORK" -name "kernel_src.tbz2" | head -1)"
if [[ -n "$KERNEL_SRC_TBZ" ]]; then
    tar -xjf "$KERNEL_SRC_TBZ" -C "$(dirname "$KERNEL_SRC_TBZ")"
fi

KERNEL_DIR="$(find "$WORK" -maxdepth 6 -type d -name "kernel-4.*" | head -1)"
HW_DIR="$(find "$WORK" -maxdepth 6 -type d -path "*hardware/nvidia" | head -1)"
if [[ -z "$KERNEL_DIR" ]]; then
    log_error "в архиве не нашёлся каталог ядра (kernel-4.*)"
    exit 1
fi
log_info "исходники ядра: $KERNEL_DIR"

# --- 3. Патч GIC -------------------------------------------------------------
# Штатное дерево описывает GICD и КУЦЫЙ GICC (0x0100). Для виртуализации
# нужны ещё GICH (0x50044000) и GICV (0x50046000) плюс maintenance-прерывание
# GIC_PPI 9. Без них ядро говорит
#   "GICV region size/alignment is unsafe, using trapping"
# и VGIC работает через ловушки, то есть медленно.
#
# Патч снят `diff` с рабочей машины, а не восстановлен по описанию.
DTSI="$(find "${HW_DIR:-$WORK}" -name "tegra210-soc-base.dtsi" | head -1)"
if [[ -z "$DTSI" ]]; then
    log_error "не нашёлся tegra210-soc-base.dtsi — дерево исходников иное, чем ожидалось"
    exit 1
fi

if grep -q "0x0 0x50046000 0x0 0x2000" "$DTSI"; then
    log_info "патч GIC уже наложен"
else
    cp -a "$DTSI" "${DTSI}.orig"
    python3 - "$DTSI" <<'PYEOF' || { log_error "патч GIC не наложился"; exit 1; }
import sys, pathlib
p = pathlib.Path(sys.argv[1])
s = p.read_text()
old = """		reg = <0x0 0x50041000 0x0 0x1000
		       0x0 0x50042000 0x0 0x0100>;"""
new = """		reg = <0x0 0x50041000 0x0 0x1000
		       0x0 0x50042000 0x0 0x2000
		       0x0 0x50044000 0x0 0x2000
		       0x0 0x50046000 0x0 0x2000>;
		interrupts = <GIC_PPI 9 (GIC_CPU_MASK_SIMPLE(4) | IRQ_TYPE_LEVEL_HIGH)>;"""
if old not in s:
    sys.exit(1)
p.write_text(s.replace(old, new, 1))
PYEOF
    log_info "патч GIC наложен на $DTSI"
fi

# Отказ, а не «продолжим без патча»: ядро без GICH/GICV соберётся и
# загрузится, но KVM будет работать через ловушки — то есть МОЛЧА медленно,
# ровно то, ради избавления от чего всё и затевалось.

# --- 4. Конфигурация ---------------------------------------------------------
export LOCALVERSION
TEGRA_KERNEL_OUT="$WORK/out"
mkdir -p "$TEGRA_KERNEL_OUT"

cd "$KERNEL_DIR"
make O="$TEGRA_KERNEL_OUT" CC="$CC_BIN" tegra_defconfig || exit 1

CFG="$TEGRA_KERNEL_OUT/.config"
set_cfg() {
    local key="$1" val="$2"
    sed -i "/^${key}[= ]/d; /^# ${key} is not set$/d" "$CFG"
    echo "${key}=${val}" >> "$CFG"
}
set_cfg CONFIG_KVM y
set_cfg CONFIG_VHOST_NET m
make O="$TEGRA_KERNEL_OUT" CC="$CC_BIN" olddefconfig || exit 1

for key in CONFIG_KVM CONFIG_VHOST_NET; do
    grep -qE "^${key}=[ym]" "$CFG" || {
        log_error "${key} не включился после olddefconfig — зависимости не выполнены"
        exit 1
    }
done
log_info "CONFIG_KVM и CONFIG_VHOST_NET включены"

# --- 5. Сборка ---------------------------------------------------------------
log_info "собираю ядро (-j${JOBS}); на Nano это часы"
make O="$TEGRA_KERNEL_OUT" CC="$CC_BIN" -j"$JOBS" Image dtbs modules || exit 1
make O="$TEGRA_KERNEL_OUT" CC="$CC_BIN" INSTALL_MOD_PATH=/ modules_install || exit 1

# --- 6. Установка ------------------------------------------------------------
install -m 0644 "$TEGRA_KERNEL_OUT/arch/arm64/boot/Image" /boot/Image.kvm
log_info "ядро установлено: /boot/Image.kvm"

# Имя DTB берём у ТЕКУЩЕЙ записи extlinux, а не угадываем по плате:
# у Nano их несколько (p3448-0000-p3449-0000 -a02/-b00), и промах даёт
# незагружаемую систему.
CUR_FDT="$(sed -n 's/^\s*FDT\s\+//p' "$EXTLINUX" | head -1)"
if [[ -z "$CUR_FDT" ]]; then
    # У записи по умолчанию FDT может отсутствовать — тогда загрузчик берёт
    # дерево из раздела DTB. Собираем имя по модели платы.
    CUR_FDT="/boot/$(basename "$(find "$TEGRA_KERNEL_OUT/arch/arm64/boot/dts" -name 'tegra210-p3448*.dtb' | head -1)")"
    log_warn "в extlinux.conf не было FDT — беру $CUR_FDT"
fi
SRC_DTB="$(find "$TEGRA_KERNEL_OUT/arch/arm64/boot/dts" -name "$(basename "${CUR_FDT%-kvm.dtb}.dtb")" | head -1)"
[[ -z "$SRC_DTB" ]] && SRC_DTB="$(find "$TEGRA_KERNEL_OUT/arch/arm64/boot/dts" -name 'tegra210-p3448*.dtb' | head -1)"
if [[ -z "$SRC_DTB" ]]; then
    log_error "собранный DTB не найден"
    exit 1
fi
NEW_FDT="/boot/$(basename "${SRC_DTB%.dtb}")-kvm.dtb"
install -m 0644 "$SRC_DTB" "$NEW_FDT"
log_info "дерево устройств установлено: $NEW_FDT"

# --- 7. extlinux.conf --------------------------------------------------------
# APPEND КОПИРУЕТСЯ, а не пишется. В нём root=PARTUUID=…, свой у каждого
# носителя; константа дала бы образ, грузящийся только на той плате, где
# его собрали.
APPEND_LINE="$(sed -n 's/^\s*APPEND\s\+//p' "$EXTLINUX" | head -1)"
if [[ -z "$APPEND_LINE" ]]; then
    log_error "в $EXTLINUX нет ни одной строки APPEND — брать нечего"
    exit 1
fi

if grep -q "^LABEL kvm$" "$EXTLINUX"; then
    log_info "запись kvm уже есть — обновляю"
    sed -i '/^LABEL kvm$/,/^$/d' "$EXTLINUX"
fi

cp -a "$EXTLINUX" "${EXTLINUX}.before-kvm"

# DEFAULT переключается на kvm, ПРЕЖНЯЯ ЗАПИСЬ ОСТАЁТСЯ в меню.
# Незагружаемое ядро на плате без монитора не чинится вовсе — только
# последовательной консолью или перепрошивкой. Запасная запись стоит ничего.
sed -i 's/^DEFAULT .*/DEFAULT kvm/' "$EXTLINUX"
grep -q "^DEFAULT kvm$" "$EXTLINUX" || sed -i '1i DEFAULT kvm' "$EXTLINUX"

cat >> "$EXTLINUX" <<EXTEOF

LABEL kvm
      MENU LABEL kvm kernel (${LOCALVERSION#-}, собрано bisquite)
      LINUX /boot/Image.kvm
      INITRD /boot/initrd
      FDT ${NEW_FDT}
      APPEND ${APPEND_LINE}
EXTEOF
log_info "extlinux.conf: запись kvm добавлена и назначена умолчанием"
log_info "прежний файл сохранён как ${EXTLINUX}.before-kvm"

# --- 8. Уборка ---------------------------------------------------------------
if [[ "$KEEP_SOURCES" == "yes" ]]; then
    log_warn "исходники оставлены в $WORK (около 11 ГБ) — L4T_KERNEL_KEEP_SOURCES=yes"
else
    rm -rf "$WORK"
    log_info "исходники удалены (освобождено около 11 ГБ)"
fi

log_info "готово; после загрузки проверьте: uname -r, ls -l /dev/kvm"
