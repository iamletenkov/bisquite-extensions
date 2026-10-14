# nvidia-container-toolkit

NVIDIA Container Toolkit для Docker: репозиторий NVIDIA с ключом, пакеты
тулкита и регистрация среды выполнения `nvidia` в `/etc/docker/daemon.json`
**без смены `default-runtime`** — контейнеры по умолчанию остаются на `runc`,
GPU получают только те, кого об этом попросили (`--gpus`, `--runtime=nvidia`).

## Что ставится

- ключ `https://nvidia.github.io/libnvidia-container/gpgkey` в
  `/etc/apt/keyrings/nvidia-container-toolkit.asc` — принимается, только если
  в файле ровно один основной ключ с отпечатком
  `C95B321B61E88C1809C4F759DDCAE044F796ECB0`; в keyring кладётся экспорт
  этого ключа, а не скачанный файл (лишний ключ в нём доверия apt не получит);
- источник `/etc/apt/sources.list.d/nvidia-container-toolkit.sources`
  (deb822, `stable/deb/amd64`); если образ уже несёт запись на этот
  репозиторий, своя не добавляется — две записи с разным `Signed-By` apt
  не читает вовсе;
- пакеты `nvidia-container-toolkit`, `nvidia-container-toolkit-base`,
  `libnvidia-container-tools`, `libnvidia-container1` — новейшие или все
  четыре строго версии `NVIDIA_CTK_VERSION` (они выпускаются вместе, и пин
  одного верхнего дал бы apt собрать его с более новым `-base`);
- `nvidia-ctk runtime configure --runtime=docker` — дописывает в
  `daemon.json` блок `runtimes.nvidia`; остальные ключи файла сохраняются.
  `--set-as-default` не передаётся, и `install.sh` это проверяет: если
  `default-runtime` до и после вызова различается — код 1.

Демон при сборке не работает: правка ложится в файл, и `dockerd` прочтёт её
при первом старте на машине. Перезапускать нечего.

## Порядок слоёв — проверяется

`install.sh` отказывает с подсказкой, если раньше не поставлены:

- Docker (`dockerd`; способность `container-runtime`, расширение `docker`);
- драйвер NVIDIA (`libnvidia-ml.so.1`; способность `gpu-driver-nvidia`,
  расширение `nvidia`).

## Настройки

| Переменная | Умолчание | Что |
|---|---|---|
| `NVIDIA_CTK_VERSION` | — (новейшая) | точная версия тулкита: `1.17.8` или `1.17.8-1`; нет такой в репозитории — ошибка со списком последних доступных |

Настройка только сборочная; на машине конфигурации у расширения нет —
среда выполнения описана в `/etc/docker/daemon.json`.

## Подключение в VMFILE

```vmfile
EXTENSION docker
EXTENSION nvidia
EXTENSION nvidia-container-toolkit
EXTENSION nvidia-container-toolkit NVIDIA_CTK_VERSION=1.17.8
```

### Как сменить версию драйвера

Драйвер ставит расширение `nvidia`, и меняется он пересборкой образа
с другой `NVIDIA_DRIVER_VERSION` в его строке. Тулкит от ветки драйвера не
зависит: он берёт библиотеки того драйвера, что стоит на машине.

## Манифест

| Поле | Значение |
|---|---|
| `version` | `1.0.0` |
| `phase` | `build` |
| `arch` | `[amd64]` — репозиторий публикует и arm64, но драйвер (`nvidia`) только amd64, а на Jetson тулкит ставит расширение `docker` из репозитория L4T |
| `provides` | `nvidia-container-runtime` |
| `requires` | `container-runtime`, `gpu-driver-nvidia` |
| `conflicts` | — |

## Проверка на машине

```bash
nvidia-smi                                              # драйвер отвечает
docker info --format '{{.Runtimes}}'                     # среди сред — nvidia
docker info --format '{{.DefaultRuntime}}'               # runc
docker run --rm --runtime=nvidia --gpus all ubuntu:24.04 nvidia-smi
cat /etc/docker/daemon.json
```

## Ограничения

- Secure Boot выключен — требование расширения `nvidia` (DKMS-модуль
  драйвера без регистрации MOK не загрузится), к тулкиту отдельных
  требований нет.
- Тулкит 1.18+ ставит `nvidia-cdi-refresh` — спецификация CDI
  (`/var/run/cdi/nvidia.yaml`) генерируется на машине, при сборке GPU нет.
  Для `docker run --gpus` она не нужна.
- Только Docker: containerd/CRI-O/podman расширение не настраивает.
