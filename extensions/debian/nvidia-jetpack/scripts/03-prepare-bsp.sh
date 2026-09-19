#!/bin/bash
# Шаг 3: разворачивание BSP — распаковка, оверлей QSPI, apply_binaries.sh.
# Библиотеку ISP из оверлея камер NVIDIA здесь больше не подменяют: это
# делает расширение sensing-gmsl2-camera слоем bisquite.
#
#     sudo bash /opt/nvidia-jetpack/03-prepare-bsp.sh
#
# Здесь всё выполняется НАТИВНО на станции: она и есть Ubuntu 22.04, ради
# которой станцию заводили. Прежний обходной путь — jammy-chroot на Debian 13 —
# больше не нужен, и вложенности chroot тут нет ровно одной штукой меньше.
# Что осталось от той истории: apply_binaries.sh сам делает chroot внутрь
# aarch64-rootfs, поэтому qemu-user-static и binfmt нужны по-прежнему.
#
# Итог шага — дерево $WORK/Linux_for_Tegra с готовым rootfs. Повторный запуск
# по уже готовому дереву ОТКЛОНЯЕТСЯ: apply_binaries необратим.

set -euo pipefail

WORK="${WORK:-/srv/jetson}"
DL="$WORK/downloads"
LFT="$WORK/Linux_for_Tegra"

# Умолчания — AGX Orin (L4T 36.4.3). Другая плата подаётся профилем из
# boards/, теми же именами переменных, что и на шаге 01: имена файлов здесь
# обязаны совпасть с тем, что шаг 01 положил в $DL.
#
# Пустое имя оверлея — осмысленное значение: «этой плате оверлей не положен»
# (у AGX Xavier нет QSPI). Поэтому раскрытие через `-`, а не `:-`: последнее
# вернуло бы оринское умолчание на пустую строку.
BSP_FILE="${BSP_FILE:-Jetson_Linux_r36.4.3_aarch64.tbz2}"
RFS_FILE="${RFS_FILE:-Tegra_Linux_Sample-Root-Filesystem_r36.4.3_aarch64.tbz2}"
OV_QSPI_FILE="${OV_QSPI_FILE-overlay_mb1bct_36.x.tbz2}"

BSP_SHA1="${BSP_SHA1:-3eb3c5a19a417313383c3bce297e07274a237e36}"
RFS_SHA1="${RFS_SHA1:-0bdb4e655d48bdf7e7bd98d3b7b69480576bfd7e}"

# Что обязано появиться после наложения оверлея QSPI — имя dts модуля.
QSPI_OVERLAY_DTS="${QSPI_OVERLAY_DTS:-tegra234-mb1-bct-device-p3701-0000.dts}"

step() { echo; echo "=== $* ==="; }

# ГРАБЛЯ: TMPDIR, унаследованный от окружения оператора (или от sudo с
# приватным /tmp), указывает на путь, которого внутри chroot нет, и
# nvidia-l4t-initrd падает на mktemp с "failed to create directory".
# Лечится не подстановкой другого пути, а отсутствием переменной вовсе.
#
# И сразу оговорка, почему тут нет `env -i`: скрипты L4T проверяют $USER,
# и пустое окружение ломает их раньше, чем помогает. Чистим точечно.
unset TMPDIR || true
echo "TMPDIR = [${TMPDIR:-}]   (обязано быть пусто)"
export USER="${USER:-$(id -un)}"

[ "$(id -u)" -eq 0 ] || { echo "ОСТАНОВ: нужен root (sudo bash $0)"; exit 1; }

# ------------------------------------------- vendor image: BSP tree only
# ROOTFS_SOURCE=vendor-image: the system is a ready vendor image (Nano:
# Q-engineering), and the tree is needed only to package the bootloader.
# No sample rootfs, no apply_binaries, no binfmt: an empty rootfs/ with
# rootfs/etc is enough for nvmassflashgen.sh (built on the station
# 2026-09-19). Spec 2026-09-19-jetson-nano-mixed-pair.md.
if [ "${ROOTFS_SOURCE:-nvidia-bsp}" = vendor-image ]; then
    step "vendor-image: только дерево BSP — без sample rootfs и apply_binaries"
    [ -f "$DL/$BSP_FILE" ] || { echo "ОСТАНОВ: нет $DL/$BSP_FILE — сначала 01-fetch-l4t.sh"; exit 1; }
    got=$(sha1sum "$DL/$BSP_FILE" | cut -d' ' -f1)
    if [ "$got" != "$BSP_SHA1" ]; then
        echo "ОСТАНОВ: SHA1 $BSP_FILE = $got, ждали $BSP_SHA1"
        echo "    rm $DL/$BSP_FILE && bash 01-fetch-l4t.sh"
        exit 1
    fi
    # Skip only on the marker a completed unpack of THIS tarball writes. A tree
    # without it — unpacked by hand or cut short — is not trusted: the
    # manifest would otherwise claim bsp_sha1 for files nobody checked
    # against the tarball. Unpacking again over it restores every file.
    if [ -d "$LFT/bootloader" ] && [ "$(cat "$LFT/.bsp-sha1" 2>/dev/null)" = "$BSP_SHA1" ]; then
        echo "Linux_for_Tegra распакован из $BSP_FILE (метка .bsp-sha1) — пропускаю"
    else
        mkdir -p "$WORK"
        rm -f -- "$LFT/.bsp-sha1"
        tar -xpf "$DL/$BSP_FILE" -C "$WORK" || { echo "ОСТАНОВ: $BSP_FILE не распаковался"; exit 1; }
        echo "$BSP_SHA1" > "$LFT/.bsp-sha1"
    fi
    [ -x "$LFT/flash.sh" ] || { echo "ОСТАНОВ: нет $LFT/flash.sh"; exit 1; }
    # flash.sh copies nv_boot_control.conf to "${rootfs_dir}/etc"
    # (flash.sh:2701-2702); with an empty rootfs/ that makes a FILE named etc.
    [ -d "$LFT/rootfs/etc" ] || rm -f -- "$LFT/rootfs/etc"
    mkdir -p "$LFT/rootfs/etc"
    step "ГОТОВО"
    echo "Дальше — 11-package-bootloader.sh (пакет загрузчика)."
    exit 0
fi

# --------------------------------------------------- 0. барьеры до работы
step "0. Проверки перед долгими операциями"

# Барьер повторного запуска стоит ПЕРВЫМ. apply_binaries.sh распаковывает
# в rootfs десятки deb-пакетов и правит символические ссылки; накатывать
# его дважды — не «идемпотентно», а порча дерева. Начинать заново можно
# только с чистого места.
if [ -e "$LFT/rootfs/.applied-binaries" ]; then
    echo "ОСТАНОВ: apply_binaries уже накатан на это дерево"
    echo "  метка: $(cat "$LFT/rootfs/.applied-binaries")"
    echo
    echo "Повторять его нельзя. Чтобы собрать дерево начисто:"
    echo "    sudo rm -rf $LFT"
    echo "    sudo bash $0"
    exit 1
fi

for f in "$BSP_FILE" "$RFS_FILE" "$OV_QSPI_FILE"; do
    # Пустое имя = профиль объявил «этого оверлея плате не положено», и шаг 01
    # его не качал. Без этой строки "$DL/$f" вырождается в сам каталог загрузок,
    # `-f` на нём ложно, и шаг отказывает сообщением «нет .../downloads/» —
    # при том что каталог на месте. Поймано прогоном под Xavier 2026-09-18.
    [ -n "$f" ] || continue
    [ -f "$DL/$f" ] || {
        echo "ОСТАНОВ: нет $DL/$f — сначала 01-fetch-l4t.sh"
        exit 1
    }
done

# Суммы пересчитываются и здесь, хотя их считал шаг 01. Дёшево (десяток
# секунд на 2.4 GB) против получаса apply_binaries поверх мусора — и
# закрывает случай «между шагами файл дописали, обрезали или подменили».
echo "Пересчитываю SHA1 (~10 c)..."
recheck() {
    local got
    got=$(sha1sum "$DL/$1" | cut -d' ' -f1)
    printf '%-58s ' "$1"
    if [ "$got" = "$2" ]; then
        echo "OK"
    else
        echo "НЕ СОВПАЛА"
        echo "  ждали: $2"
        echo "  вышло: $got"
        echo "ОСТАНОВ: перекачай файл (rm $DL/$1 && bash 01-fetch-l4t.sh)"
        exit 1
    fi
}
recheck "$BSP_FILE" "$BSP_SHA1"
recheck "$RFS_FILE" "$RFS_SHA1"

# binfmt нужен потому, что apply_binaries.sh делает chroot в aarch64-дерево
# и зовёт там dpkg. Без регистрации это "Exec format error" — только позже
# и на полпути. На живой Ubuntu регистрацию держит systemd-binfmt, ей
# достаточно установленного qemu-user-static (его ставит install.sh).
#
# НА aarch64-ХОСТЕ ПРОВЕРЯТЬ НЕЧЕГО, и это не послабление: chroot в
# aarch64-дерево там нативен, эмулятор не участвует вовсе. Больше того,
# qemu-user-static нативную архитектуру в binfmt_misc и НЕ регистрирует —
# проверено на AGX Orin 2026-09-18: пакет поставлен, systemd-binfmt
# перезапущен, /proc/sys/fs/binfmt_misc/qemu-aarch64 так и не появился
# (в списке только cli, python2.7, python3.10). То есть безусловная проверка
# делала сборку базового образа НА САМОЙ ПЛАТЕ невозможной в принципе,
# хотя libguestfs, bisquite и всё остальное там работают.
if [ "$(uname -m)" = "aarch64" ]; then
    echo "binfmt: не требуется — хост aarch64, chroot в aarch64-дерево нативный"
else
    if [ ! -e /proc/sys/fs/binfmt_misc/qemu-aarch64 ]; then
        echo "ОСТАНОВ: qemu-aarch64 не зарегистрирован в binfmt_misc."
        echo "    sudo apt-get install -y qemu-user-static"
        echo "    sudo systemctl restart systemd-binfmt"
        exit 1
    fi
    grep -q '^enabled' /proc/sys/fs/binfmt_misc/qemu-aarch64 || {
        echo "ОСТАНОВ: регистрация qemu-aarch64 выключена:"
        cat /proc/sys/fs/binfmt_misc/qemu-aarch64
        exit 1
    }
    echo "binfmt: $(sed -n '2p' /proc/sys/fs/binfmt_misc/qemu-aarch64)"
fi

# Место: BSP + rootfs + результат apply_binaries — порядка 25 GB.
avail_gb=$(df -BG --output=avail "$WORK" | tail -1 | tr -dc '0-9')
echo "свободно в $WORK: ${avail_gb} GB"
[ "${avail_gb:-0}" -ge 30 ] \
    || echo "ВНИМАНИЕ: меньше 30 GB. Дереву нужно ~25 GB, образам на шаге 05 — ещё."

# ------------------------------------------------------------- 1. BSP
step "1. Распаковка BSP (~683 MB, bzip2 однопоточный — пара минут)"
mkdir -p "$WORK"
if [ -d "$LFT/bootloader" ]; then
    echo "Linux_for_Tegra уже распакован — пропускаю"
else
    # -p обязателен: в дереве есть файлы с выставленными правами и
    # владельцами, и без них flash.sh соберёт неправильный образ.
    tar -xpf "$DL/$BSP_FILE" -C "$WORK"
fi
[ -x "$LFT/apply_binaries.sh" ] || { echo "ОСТАНОВ: нет $LFT/apply_binaries.sh"; exit 1; }

# --------------------------------------------------------- 2. оверлей QSPI
step "2. Оверлей QSPI (фикс таймингов mb1)"
# Распаковывается в тот же родительский каталог, что и BSP: внутри архива
# путь начинается с ./Linux_for_Tegra/..., то есть он ложится поверх дерева
# сам. Операция чисто файловая, повторный прогон безвреден.
#
# Плате без QSPI (AGX Xavier — загрузчик у него в eMMC модуля) оверлея
# не положено вовсе, и профиль обнуляет имя файла. Это пропуск, а не отказ.
if [ -z "$OV_QSPI_FILE" ]; then
    echo "профиль оверлея QSPI не объявляет — пропуск"
else
    tar -xpf "$DL/$OV_QSPI_FILE" -C "$WORK"
    QSPI_DTS="$LFT/bootloader/generic/BCT/$QSPI_OVERLAY_DTS"
    [ -f "$QSPI_DTS" ] || {
        echo "ОСТАНОВ: после оверлея нет $QSPI_DTS"
        echo "Состав оверлея изменился — проверь его руками (tar tf)."
        exit 1
    }
    ls -l "$QSPI_DTS"
fi

# ------------------------------------------------------------ 3. rootfs
step "3. Распаковка sample rootfs (~1.8 GB, 5-10 минут)"
if [ -x "$LFT/rootfs/bin/bash" ]; then
    echo "rootfs уже распакован — пропускаю"
else
    mkdir -p "$LFT/rootfs"
    tar -xpf "$DL/$RFS_FILE" -C "$LFT/rootfs"
fi

step "4. Ранняя проверка эмуляции внутри целевого rootfs"
# Дешёвый отказ до получасовой операции: если тут ответ не aarch64,
# apply_binaries упадёт на том же самом, только позже и грязнее.
arch=$(chroot "$LFT/rootfs" /bin/bash -c "uname -m")
echo "uname -m внутри rootfs: $arch"
[ "$arch" = "aarch64" ] || { echo "ОСТАНОВ: ждали aarch64"; exit 1; }

# ------------------------------------------------------- 5. dev-узлы
step "5. Снимаю узлы, оставшиеся от прерванных прогонов"
# ГРАБЛЯ: apply_binaries делает mknod для /dev/random и /dev/urandom и
# падает с "mknod: File exists", если они уже есть. А есть они ровно
# после прерванного прогона — то есть отказ приходит именно тогда, когда
# оператор повторяет попытку. Снимаем ПЕРЕД каждым запуском.
rm -f "$LFT/rootfs/dev/random" "$LFT/rootfs/dev/urandom"
echo "rootfs/dev/{random,urandom} удалены"

step "6. apply_binaries.sh (10-30 минут под эмуляцией)"
echo "TMPDIR = [${TMPDIR:-}]   (обязано быть пусто)"
cd "$LFT"
./apply_binaries.sh

# ------------------------------------------------------------- 7. метка
step "7. Метка готовности дерева"
# Она же — барьер шага 0 при повторном запуске.
date -Iseconds > "$LFT/rootfs/.applied-binaries"
cat "$LFT/rootfs/.applied-binaries"

step "ГОТОВО"
du -sh "$LFT"
df -h "$WORK" | tail -1
echo
echo "Дальше — 04-customize-rootfs.sh (пользователь, oem-config, источник apt NVIDIA)."
