# l4t-boot-verify

Отмечает каждую загрузку Jetson (L4T) успешной — `nvbootctrl verify`.
**Без этого AGX Orin после трёх загрузок перестаёт грузиться вообще.**

## Манифест

| Поле | Значение |
|---|---|
| `phase` | `build` |
| `arch` | `arm64` |
| `provides` | `l4t-boot-verify` |
| `requires`, `conflicts` | пусто |

## Что происходит без отметки

UEFI Jetson считает попытки загрузки корневой системы. На AGX Orin
(L4T 36.4.3) `RootfsRetryCountMax = 3`. Каждая загрузка, которую никто не
отметил успешной, тратит попытку; после трёх подряд UEFI объявляет систему
негодной:

- логотип NVIDIA, затем чёрный экран, сети нет;
- не грузится и внутренний NVMe — состояние общее для платы;
- лечится **только** прошивкой QSPI со станции
  (`l4t_initrd_flash.sh --showlogs --network usb0 p3737-0000-p3701-0000-qspi internal`):
  она сбрасывает переменные UEFI.

Штатно отметку делает `nv-l4t-bootloader-config.service`: юнит зовёт
`nv-l4t-bootloader-config.sh -v`, а тот в самом конце — `nvbootctrl verify`.

## Почему своя служба, а не вендорская

С 2026-09-13 вендорская служба в `jetson-orin-camera`/`jetson-orin-base`
глушилась — диагноз был «она обновляет QSPI и убивает плату». **Для AGX Orin
он неверен**: `auto_update_qspi` в скрипте срабатывает только на Orin Nano
Devkit SKU 0005 и IGX. Заглушив службу, мы выключили отметку, и 2026-09-14
плата отказала ровно на четвёртой загрузке с SSD.

Отказы 2026-09-13, когда служба ещё работала, правдоподобно объясняются тем,
что при загрузке с USB-диска скрипт падал раньше отметки: до `verify` он
пишет переменные UEFI и монтирует ESP. Это не подтверждено, поэтому
вендорская остаётся заглушенной, а отметка делается отдельно и ничем больше.

## Проверено

AGX Orin после прошивки QSPI, 2026-09-14: пять загрузок с SSD подряд,
служба отработала на каждой, `RootfsStatusSlotA` оставался `00`.

## Диагностика

```bash
systemctl status bisquite-l4t-boot-verify
sudo nvbootctrl dump-slots-info
for v in RootfsRetryCountMax RootfsStatusSlotA; do
  sudo od -An -tx1 /sys/firmware/efi/efivars/$v-781e084c-a330-417c-b678-38e696380cb9
done
```
