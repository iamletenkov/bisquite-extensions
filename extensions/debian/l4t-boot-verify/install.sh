#!/usr/bin/env bash
# Отмечать каждую загрузку L4T успешной — и только это.
#
# ЗАЧЕМ. UEFI Jetson считает попытки загрузки корневой системы
# (RootfsRetryCountMax = 3, замер на AGX Orin 2026-09-14). Загрузка, которую
# никто не отметил успешной, тратит попытку; после трёх подряд UEFI объявляет
# систему негодной и больше её не загружает — «логотип NVIDIA и чёрный экран»,
# нет сети. Состояние общее для платы: не грузится и внутренний NVMe.
# Лечится только прошивкой QSPI со станции (сбрасывает переменные UEFI).
#
# Отмечает загрузку штатно `nv-l4t-bootloader-config.service`: юнит зовёт
# `nv-l4t-bootloader-config.sh -v`, а тот в самом конце — `nvbootctrl verify`.
#
# ПОЧЕМУ СВОЯ СЛУЖБА, А НЕ ВЕНДОРСКАЯ. Вендорскую мы глушили с 2026-09-13
# и вместе с ней выключили отметку — отсюда отказ 2026-09-14 ровно на
# четвёртой загрузке с SSD. Прежний диагноз «служба обновляет QSPI и убивает
# плату» для AGX Orin НЕВЕРЕН: auto_update_qspi срабатывает только на Orin
# Nano Devkit SKU 0005 и IGX. Правдоподобное объяснение отказов 2026-09-13,
# когда служба работала, — скрипт выходил с ошибкой раньше `verify` при
# загрузке с USB-носителя (до `verify` он пишет переменные UEFI и монтирует
# ESP); подтверждено оно не было. Поэтому вендорская остаётся заглушенной,
# а отметка делается отдельно, без всего остального скрипта.
#
# Проверено на плате: служба отработала на четырёх перезагрузках подряд,
# RootfsStatusSlotA оставался 0.
set -euo pipefail
GREEN='\033[0;32m'; RED='\033[0;31m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} l4t-boot-verify: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} l4t-boot-verify: $*"; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

[[ -f /etc/nv_tegra_release ]] || { log_error "нет /etc/nv_tegra_release — это не образ L4T"; exit 1; }
[[ -x /usr/sbin/nvbootctrl ]] || { log_error "нет /usr/sbin/nvbootctrl — отмечать загрузку нечем (пакет nvidia-l4t-tools?)"; exit 1; }

# Вендорская служба лежит в /etc/systemd/system, и `systemctl mask` внутри
# сборки отказывает на существующем файле — маскируем руками.
rm -f /etc/systemd/system/multi-user.target.wants/nv-l4t-bootloader-config.service
ln -sf /dev/null /etc/systemd/system/nv-l4t-bootloader-config.service

install -m 0644 "$HERE/bisquite-l4t-boot-verify.service" /etc/systemd/system/
install -d /etc/systemd/system/multi-user.target.wants
ln -sf /etc/systemd/system/bisquite-l4t-boot-verify.service \
    /etc/systemd/system/multi-user.target.wants/bisquite-l4t-boot-verify.service
log_info "вендорская служба заглушена, bisquite-l4t-boot-verify.service включена"
