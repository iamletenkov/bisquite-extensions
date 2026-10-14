# nvidia

Драйвер NVIDIA **заданной ветки** (по умолчанию 580, открытые модули ядра)
в образе: пакеты драйвера, модуль ядра строго под ядро **образа**, блокировка
`nouveau`, initramfs и проверка результата в конце сборки.

> **2.0.0 — несовместимо с 1.x.** Убраны `ubuntu-drivers autoinstall` и тихие
> откаты на 535/525/470, убрана Ubuntu 20.04; появились настройки ветки,
> типа модулей и источника. Нужной ветки нет — сборка падает с объяснением,
> а не ставит «что нашлось».

## Что ставится

| Система | Источник | Пакеты | Модуль ядра |
|---|---|---|---|
| Ubuntu 22.04, 24.04 | архив Ubuntu (`restricted`) — `NVIDIA_SOURCE=archive` | `nvidia-driver-<ветка>[-open]` | предсобранный подписанный Canonical `linux-modules-nvidia-<ветка>[-open]-<ядро>` + метапакет флейвора, если они есть под ядро образа и сходятся с драйвером по версии; иначе DKMS: `nvidia-dkms-<ветка>[-open]` + `linux-headers-<ядро>` |
| Ubuntu 22.04, 24.04 | PPA `graphics-drivers` — `NVIDIA_SOURCE=ppa` | то же | всегда DKMS |
| Debian 12, 13 | репозиторий CUDA NVIDIA (`developer.download.nvidia.com/compute/cuda/repos/debian12` / `debian13`) | `nvidia-driver-pinning-<ветка>`, затем `nvidia-open` (open) или `cuda-drivers` (proprietary) | DKMS: `nvidia-kernel-open-dkms` / `nvidia-kernel-dkms` + `linux-headers-<ядро>` |

Ключи репозиториев скачиваются и принимаются, **только если в файле ровно
один основной ключ с отпечатком**, прибитым в `install.sh`; в keyring
кладётся экспорт этого ключа, а не скачанный файл; источники пишутся в формате deb822
с `Signed-By`. Если образ уже несёт запись на тот же репозиторий, своя не
добавляется (иначе apt отказывает на всём списке источников — урок
расширения `docker`).

### Почему на Debian — репозиторий CUDA, а не non-free

Замер 2026-10-14:

| | non-free Debian | репозиторий CUDA NVIDIA |
|---|---|---|
| Debian 12 | 535 (`bookworm`), 535 (`bookworm-backports`) | 580 (open и proprietary), а также 570–615 |
| Debian 13 | 550 (`trixie`, `trixie-backports`) | **590 и новее** (590, 595, 610, 615); 580 нет |

Ветки 580 в non-free нет ни у одного выпуска, а репозиторий NVIDIA даёт её
для Debian 12 и закрепляет пакетом `nvidia-driver-pinning-580` — это способ
самой NVIDIA держать все пакеты драйвера на одной ветке, в том числе при
последующих `apt upgrade` на машине. **На Debian 13 ветки 580 нет**:
умолчание даёт громкую ошибку со списком доступных веток —
`NVIDIA_DRIVER_VERSION=590` (или новее) это решает. RTX 5060 (Blackwell)
поддерживается начиная с 570, так что 590 open для неё годится.

### Ядро образа, а не `uname -r`

Сборка идёт внутри appliance libguestfs: `uname -r` там — ядро appliance,
которого в образе нет. Поэтому:

- ядра образа берутся из `/lib/modules/<версия>` при наличии
  `/boot/vmlinuz-<версия>` (каталог без образа ядра — остаток удалённого
  ядра — пропускается); ядер может быть несколько, всё делается под каждое;
- заголовки — `linux-headers-<ядро образа>`, DKMS собирает явно
  `dkms autoinstall -k <ядро образа>`;
- initramfs — `update-initramfs -u -k <ядро образа>`; initrd, который
  триггер пакетов создал под ядро appliance (замер: 23 МБ в
  `/boot/initrd.img-<ядро appliance>`), удаляется, если такого ядра в образе
  нет.

### Проверка в конце сборки

`install.sh` завершается кодом 1, если для **какого-либо** ядра образа:

- `modinfo -k <ядро> nvidia` не находит модуль;
- версия модуля не равна версии пользовательской части
  (`libnvidia-ml.so.<версия>` — с ней сверяется `nvidia-smi`; расхождение на
  машине дало бы «Driver/library version mismatch»);
- версия не из запрошенной ветки;
- лицензия модуля не та: `Dual MIT/GPL` у open, `NVIDIA` у proprietary.

## Настройки

Параметры строки `EXTENSION`, читаются только при сборке. На машине
настроек нет: драйвер — часть образа.

| Переменная | Умолчание | Значения | Что |
|---|---|---|---|
| `NVIDIA_DRIVER_VERSION` | `580` | номер ветки (`580`, `590`, …) | ветка драйвера; полная версия (`580.95.05`) не принимается — внутри ветки ставится новейшая из источника |
| `NVIDIA_KERNEL_MODULES` | `open` | `open`, `proprietary` | открытые или закрытые модули ядра. **Blackwell (RTX 50xx, в т.ч. RTX 5060) и новее — только `open`**; `proprietary` нужен лишь для карт до Turing (Maxwell, Pascal, Volta), и с ним скрипт предупреждает |
| `NVIDIA_SOURCE` | `archive` | `archive`, `ppa` | Ubuntu: архив Ubuntu или PPA `graphics-drivers` (там ветки появляются раньше; модуль — всегда DKMS). Debian: только `archive` (= репозиторий CUDA NVIDIA), `ppa` — ошибка |

Нет ветки в источнике — ошибка с подсказкой: на Ubuntu с `archive` —
«`NVIDIA_SOURCE=ppa`», на Debian — список веток, которые есть.

## Подключение в VMFILE

```vmfile
EXTENSION nvidia
EXTENSION nvidia NVIDIA_DRIVER_VERSION=580 NVIDIA_KERNEL_MODULES=open NVIDIA_SOURCE=archive
EXTENSION nvidia NVIDIA_DRIVER_VERSION=590          # Debian 13
```

Ставьте **после** слоёв, меняющих ядро (`UPDATE`, установка другого
`linux-image-*`): модуль собирается под ядро, которое лежит в образе
в момент запуска расширения. Обновление ядра после него оставит новое ядро
без модуля (на Ubuntu с предсобранными модулями метапакет флейвора потянет
их сам, с DKMS — соберёт DKMS-хук ядра, но проверки этого расширения
уже не будет).

### Как сменить версию драйвера

Только пересборкой образа: поменяйте `NVIDIA_DRIVER_VERSION` в строке
`EXTENSION` и соберите образ заново. Ставить другую ветку руками на
машине не нужно — тираж должен быть одинаковым, а на Debian ветку держит
`nvidia-driver-pinning-<ветка>`.

## Манифест

| Поле | Значение |
|---|---|
| `version` | `2.0.0` |
| `phase` | `build` — `configure.sh` нет, на первой загрузке донастраивать нечего |
| `arch` | `[amd64]` — модули Canonical, PPA и каталог `x86_64` репозитория CUDA; arm64-серверы не проверялись, Jetson обслуживает `nvidia-jetpack` |
| `provides` | `gpu-driver-nvidia` |
| `requires` | — |
| `conflicts` | — |

## Проверка на машине

```bash
nvidia-smi                              # драйвер отвечает, видна карта и версия 580.x
cat /proc/driver/nvidia/version         # «Open Kernel Module» у open
modinfo -F license nvidia               # Dual MIT/GPL (open) или NVIDIA
lsmod | grep -E '^nvidia'               # модули загружены
lsmod | grep nouveau                    # должно быть ПУСТО
cat /etc/modprobe.d/blacklist-nouveau.conf
```

## Диагностика

```bash
dpkg -l | grep -E 'nvidia|linux-modules-nvidia'
dkms status                             # если модуль шёл через DKMS
modinfo -k "$(uname -r)" nvidia         # модуль под загруженное ядро
dmesg | grep -iE 'nvidia|nouveau|NVRM'
```

- **`nvidia-smi`: No devices were found / NVRM: GPU … not supported** —
  у карты нет поддержки в выбранном типе модулей: Blackwell с
  `proprietary` не работает, нужен `open`.
- **Driver/library version mismatch** — ядро обновили после сборки, а модуль
  остался от другой версии; пересоберите образ.
- **Модуль не грузится, в `dmesg` про подпись (Lockdown / Key was rejected)** —
  включён Secure Boot, см. ниже.

## Ограничения

- **Secure Boot должен быть выключен.** Предсобранные модули Canonical
  подписаны и загрузятся и с SB, но DKMS-модуль (Debian всегда, Ubuntu с
  `ppa` или с ядром, под которое предсобранного нет) подписан в лучшем случае
  ключом MOK, созданным при сборке образа; чтобы ядро ему поверило, ключ надо
  зарегистрировать (`mokutil --import`) на **каждой** машине с подтверждением
  в консоли при загрузке. Для тиража это не годится — решение владельца:
  SB выключен.
- Внутри ветки ставится новейшая версия источника на момент сборки — две
  сборки в разные дни могут дать разные 580.x.
- Нужен GPU на машине (или passthrough в ВМ); в ВМ без GPU модуль есть, но
  `nvidia-smi` ответит «No devices were found».
- Драйвер с зависимостями (а с DKMS — ещё компилятор и заголовки) заметно
  увеличивают образ: закладывайте место под сборку с запасом.

