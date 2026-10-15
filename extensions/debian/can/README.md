# can

Шина CAN на машине: утилиты `can-utils` (`candump`, `cansend`, …), `iproute2`
(`ip link set can0 type can bitrate …`), модули ядра CAN **для ядра образа** и
их автозагрузка через `/etc/modules-load.d/can.conf`.

## Что ставится (фаза build)

| Что | Откуда |
|---|---|
| `can-utils`, `iproute2`, `kmod` | apt дистрибутива |
| модули `can`, `can_raw`, `can_dev`, `vcan`, `slcan`, `gs_usb`, `peak_usb` | Ubuntu — `linux-modules-extra-<ядро>`, если их нет в образе; Debian — уже в `linux-image-*`; L4T — `nvidia-l4t-kernel`, без `slcan`/`gs_usb`/`peak_usb` (см. «Jetson / L4T») |
| `/etc/modules-load.d/can.conf` | из настройки `CAN_MODULES_LOAD` (по умолчанию `can`, `can_raw`, `vcan`) |

**Ядро — образа, а не `uname -r`.** Внутри appliance `virt-customize`
`uname -r` — ядро самого appliance. `install.sh` перебирает ядра в
`/lib/modules/*/` (с `modules.order`) и для каждого проверяет
`modinfo -k <ядро> <модуль>`; на Ubuntu недостающее ставит пакетом
`linux-modules-extra-<ядро>`. Модуля нет и после этого (облачное ядро Debian,
`linux-kvm` Ubuntu) — **отказ сборки** со списком модулей, а не немой образ
без CAN.

Если в Ubuntu-образе нет метапакета `linux-image-generic*` (база на
`linux-image-virtual`), `install.sh` предупреждает: следующее ядро из
`apt upgrade` придёт без `linux-modules-extra`, и CAN после перезагрузки
пропадёт. Образ рабочей машины на `linux-generic` (Ubuntu Desktop) этого
не касается.

## Jetson / L4T

Ядро L4T (`<версия>-tegra`, например `5.15.148-tegra` у r36.4.3 / JetPack 6.2)
ставится пакетами NVIDIA, `linux-modules-extra` для него нет — `install.sh`
его и не ищет: проверяет модули для ядра образа (`modinfo -k`, встроенные —
ещё и по `modules.builtin`) и не трогает apt ядра.

Фактический состав ядра r36.4.3 (`nvidia-l4t-kernel` и
`nvidia-l4t-kernel-oot-modules` 5.15.148-tegra-36.4.3, конфиг — встроенный
в `Image`):

| Модуль | В ядре L4T r36.4.3 |
|---|---|
| `can`, `can_raw`, `can_dev`, `vcan` | модули (`kernel/net/can/`, `kernel/drivers/net/can/`) |
| `mttcan` — родной контроллер CAN Orin | модуль вне дерева: `updates/drivers/net/can/mttcan/` (`nvidia-l4t-kernel-oot-modules`), зависит от `can_dev` |
| `slcan`, `gs_usb`, `peak_usb` | **нет**: `CONFIG_CAN_SLCAN`, `CONFIG_CAN_GS_USB`, `CONFIG_CAN_PEAK_USB` не заданы, ни встроенными, ни модулями |

Поэтому для ядра `*-tegra`:

- `can`, `can_raw`, `can_dev`, `vcan` и всё из `CAN_MODULES_LOAD` —
  обязательны, как везде: нет — **отказ сборки**;
- `slcan`, `gs_usb`, `peak_usb` — **громкое предупреждение**, а не отказ.
  Ни один пакет их не доставит: нужно ядро, пересобранное с этими опциями.
  Отказ сделал бы расширение непригодным на любом Jetson, хотя основной
  интерфейс платы — `mttcan`, а USB/serial-адаптеры (`gs_usb` —
  candleLight/CANable, `peak_usb` — PCAN-USB, `slcan` — адаптеры с
  последовательным протоколом) — дополнительный. Нужен такой адаптер —
  впишите его модуль в `CAN_MODULES_LOAD`: тогда отсутствие станет отказом,
  а не предупреждением. Пункт `modinfo -n vcan gs_usb peak_usb slcan` из
  чек-листа рабочей машины на штатном ядре L4T не пройдёт.

Для AGX Orin с ядром Sensing на L4T 36.4.3 эти три модуля собирает при
сборке образа расширение [`can-usb`](../can-usb/README.md) — слоем после
`sensing-gmsl2-camera`; с ним пункт чек-листа проходит.

Рекомендованный список автозагрузки для Jetson (не умолчание —
умолчание общее для всех платформ):

```vmfile
EXTENSION can CAN_MODULES_LOAD="can can_raw vcan mttcan"
```

`mttcan` — драйвер контроллеров CAN самого SoC (интерфейсы `can0`, `can1`;
трансивер на шину — внешний).

## Настройки

Домен `can`, файл `/etc/bisquite/can/config`, схема — `knobs`.

| Ключ | Умолчание | Что |
|---|---|---|
| `CAN_MODULES_LOAD` | `can can_raw vcan` | модули автозагрузки через пробел; каждый проверяется для ядра образа; пусто — `can.conf` удаляется |

## Сборка

```vmfile
EXTENSION can
EXTENSION can CAN_MODULES_LOAD="can can_raw vcan gs_usb"
```

## Манифест записи / развёртывания

Обычно ничего не нужно: модули и автозагрузка уже в образе. Свой список —
строкой первой загрузки (`firstboot-commands` манифеста записи,
`firstboot_commands` манифеста развёртывания ВМ):

```yaml
firstboot-commands:
  - 'bisquite-conf set can CAN_MODULES_LOAD="can can_raw vcan peak_usb"'
```

Во время загрузки `set` только пишет файл; `systemd-modules-load` прочтёт
его на следующей загрузке (`--apply` — загрузить модули сразу).

## На работающей машине

```bash
bisquite-conf show can
sudo bisquite-conf set can CAN_MODULES_LOAD="can can_raw vcan gs_usb"
```

Хук `knobs.apply` переписывает `/etc/modules-load.d/can.conf` и ставит в
очередь `systemctl restart systemd-modules-load` — новые модули грузятся
сразу. Убранные из списка остаются загруженными до перезагрузки или
`sudo modprobe -r <модуль>`.

## Проверка

```bash
which candump cansend                         # обе утилиты
modinfo -n vcan gs_usb peak_usb slcan         # четыре пути к модулям
cat /etc/modules-load.d/can.conf
lsmod | grep vcan                             # после перезагрузки
sudo ip link add dev vcan0 type vcan && sudo ip link set vcan0 up
candump vcan0 &  cansend vcan0 123#DEADBEEF   # кадр виден в candump
```

Проверено в контейнерах `ubuntu:24.04` (ядро 6.8.0-147-generic, модули
доставлены `linux-modules-extra`) и `debian:12` (6.1.0-53-amd64).

arm64 / L4T (1.1.0, 2026-10-15) — контейнер `ubuntu:22.04` arm64 (qemu-user)
с раскладкой ядра L4T r36.4.3: `/lib/modules/5.15.148-tegra` из
`nvidia-l4t-kernel` плюс `updates/` из `nvidia-l4t-kernel-oot-modules`
(`modules.dep` пакета уже знает `mttcan`). Умолчание — успех, три
предупреждения (`slcan`, `gs_usb`, `peak_usb`), `linux-modules-extra` не
ставится, `can.conf` = `can can_raw vcan`; `CAN_MODULES_LOAD` с `mttcan` —
успех; с `gs_usb` — отказ; `can_raw`, перенесённый во встроенные
(`modules.builtin`, без файла `.ko`), — найден; удалённый `vcan` — отказ.
Повтор на amd64: `debian:12` с ядрами 6.1.0-52/53 — без изменений; `mttcan`
в `CAN_MODULES_LOAD` на amd64 — отказ. На самой плате не запускалось.
