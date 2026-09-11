#!/usr/bin/env bash
# Выбрать дерево устройств под конкретную плату Jetson.
#
# ЗАЧЕМ ОТДЕЛЬНОЕ РАСШИРЕНИЕ. Ядро L4T с KVM собирается два с четвертью
# часа, и до этой правки образ был привязан к одной паре «модуль +
# несущая плата»: `l4t-kernel-kvm` вписывал в extlinux.conf ровно одну
# строку FDT. Пар таких семь — семь двухчасовых сборок ради строки в
# текстовом файле.
#
# Теперь `l4t-kernel-kvm` кладёт в /boot ВСЕ пропатченные деревья и не
# пишет FDT вовсе, а выбор делает этот слой — за секунды, поверх готовой
# базы. Ядро от платы не зависит, и платить за него по разу на плату
# больше не приходится.
#
# ПОЧЕМУ НЕ ПАРА RUN_COMMAND В VMFILE. Из-за отказа ниже. Молча вписанный
# путь к несуществующему дереву даёт незагружаемую плату, а плата без
# монитора не чинится вовсе — только последовательной консолью или
# перепрошивкой QSPI. Проверку с внятным сообщением в две строки
# RUN_COMMAND не уложить, а размазать её по всем VMFILE значит завести
# копии, которые разъедутся.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} l4t-board-fdt: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} l4t-board-fdt: $*"; }

EXTLINUX=/boot/extlinux/extlinux.conf
BOARD="${L4T_BOARD:-}"

if [[ -z "$BOARD" ]]; then
    log_error "не задан L4T_BOARD — имя дерева устройств для этой платы"
    log_error "узнать своё на целевой плате:"
    log_error "  cat /proc/device-tree/compatible"
    log_error "например nvidia,p3449-0000-a02+p3448-0000-a02 означает"
    log_error "  L4T_BOARD=tegra210-p3448-0000-p3449-0000-a02"
    exit 1
fi

# Суффикс `-kvm` добавляет расширение, а не автор VMFILE: в VMFILE стоит
# имя ПЛАТЫ, и знать про внутреннюю раскладку /boot ему незачем.
FDT="/boot/${BOARD%.dtb}-kvm.dtb"

# ПОРЯДОК ПРОВЕРОК НЕСУЩИЙ, и держится он на одном: «собран ли базовый образ
# с l4t-kernel-kvm» отвечает запись `LABEL kvm` в extlinux.conf, а не маска
# имён файлов в /boot. Поэтому сначала идёт она.
#
# Пока отказ про ненайденное дерево стоял первым, он отвечал на этот вопрос
# сам — и отвечал маской `tegra210-*-kvm.dtb`. Маска прибита к семейству SoC,
# поэтому на образе другой Tegra список выходил пустым, а следующая строка
# объявляла «базовый образ собран без l4t-kernel-kvm» — утверждение о том,
# чего она не проверяла. Отказ здесь ради объяснения и заведён (см. шапку,
# «ПОЧЕМУ НЕ ПАРА RUN_COMMAND»): ложная подсказка обесценивает ровно то,
# ради чего файл существует.
if [[ ! -f "$EXTLINUX" ]]; then
    log_error "нет $EXTLINUX — это не L4T-образ"
    exit 1
fi

# Отступ незначащий — так же, как у разбора ниже и у l4t-kernel-kvm.
if ! grep -qE '^[[:space:]]*LABEL kvm[[:space:]]*$' "$EXTLINUX"; then
    log_error "в $EXTLINUX нет записи 'LABEL kvm'"
    log_error "базовый образ собран без l4t-kernel-kvm — выбирать нечего"
    exit 1
fi

if [[ ! -f "$FDT" ]]; then
    log_error "дерево $FDT в образе не найдено"
    # Маска — по суффиксу `-kvm`, который ставит l4t-kernel-kvm
    # (l4t-kernel-kvm/install.sh, шаг 6), а НЕ по семейству SoC: суффикс
    # наш и известен, семейство — нет.
    mapfile -t available < <(find /boot -maxdepth 1 -name '*-kvm.dtb' -printf '%f\n' 2>/dev/null \
                             | sed 's/-kvm\.dtb$//' | sort)
    if (( ${#available[@]} )); then
        log_error "в этом образе есть:"
        printf '  %s\n' "${available[@]}" >&2
        log_error "L4T_BOARD должен совпадать с одним из имён выше"
    else
        # Сюда приходят, когда `LABEL kvm` в загрузчике есть, а деревьев нет.
        # Это не «собран без l4t-kernel-kvm» — про это сказано выше и раньше;
        # это деревья, удалённые или переименованные после сборки базы.
        log_error "деревьев с суффиксом -kvm в /boot нет ни одного,"
        log_error "хотя запись 'LABEL kvm' в $EXTLINUX есть — значит ядро kvm"
        log_error "в образе стоит, а деревья из /boot удалены или переименованы"
    fi
    exit 1
fi

cp -a "$EXTLINUX" "${EXTLINUX}.before-board-fdt"

# Идемпотентность обязательна: слой применяют поверх варианта, у которого
# строка FDT уже есть. Поэтому сначала снимаем прежнюю строку внутри
# записи kvm, потом ставим свою — иначе их стало бы две, и загрузчик
# взял бы первую, то есть чужую.
python3 - "$EXTLINUX" "$FDT" <<'PYEOF' || { log_error "не удалось записать FDT"; exit 1; }
import sys, pathlib

path, fdt = pathlib.Path(sys.argv[1]), sys.argv[2]
lines = path.read_text().splitlines()
out, in_kvm, written = [], False, False


def emit_fdt() -> None:
    """Дописать строку FDT и запомнить, что она уже одна."""
    global written
    out.append(f"      FDT {fdt}")
    written = True


for line in lines:
    stripped = line.strip()

    # Ровное сравнение, а не startswith: строка `MENU LABEL kvm kernel`
    # содержит `LABEL kvm` и на startswith поймалась бы.
    if stripped == "LABEL kvm":
        in_kvm, written = True, False
        out.append(line)
        continue

    if in_kvm and stripped.startswith("LABEL "):
        # Запись кончилась. Если FDT в ней не было — дописываем, иначе
        # строка уехала бы в чужую запись.
        if not written:
            emit_fdt()
        in_kvm = False
        out.append(line)
        continue

    if in_kvm and stripped.startswith("FDT "):
        # Первую прежнюю FDT заменяем своей, ЛИШНИЕ ОТБРАСЫВАЕМ.
        # Иначе повторное применение слоя оставляло бы две строки,
        # и загрузчик взял бы первую — то есть чужую.
        if not written:
            emit_fdt()
        continue

    out.append(line)

# Запись kvm могла быть последней в файле — тогда её конец это конец файла.
if in_kvm and not written:
    emit_fdt()

if not written:
    sys.exit(1)
path.write_text("\n".join(out) + "\n")
PYEOF

log_info "плата: $BOARD"
log_info "дерево устройств записи kvm: $FDT"
log_info "прежний файл сохранён как ${EXTLINUX}.before-board-fdt"
