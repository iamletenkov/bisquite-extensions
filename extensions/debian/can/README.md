# can

Шина CAN на машине: утилиты `can-utils` (`candump`, `cansend`, …), `iproute2`
(`ip link set can0 type can bitrate …`), модули ядра CAN **для ядра образа** и
их автозагрузка через `/etc/modules-load.d/can.conf`.

## Что ставится (фаза build)

| Что | Откуда |
|---|---|
| `can-utils`, `iproute2`, `kmod` | apt дистрибутива |
| модули `can`, `can_raw`, `can_dev`, `vcan`, `slcan`, `gs_usb`, `peak_usb` | Ubuntu — `linux-modules-extra-<ядро>`, если их нет в образе; Debian — уже в `linux-image-*` |
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
