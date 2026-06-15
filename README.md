# bisquite-extensions

Переиспользуемые «расширения» провизии для образов, собираемых
[bisquite](https://github.com/iamletenkov/bisquite). Каждое расширение — папка
со скриптами установки и конфигурации. Подключаются в сборку через `COPY_IN`
+ запуск `install.sh`.

## Структура

Все расширения лежат под `extensions/`:

```
extensions/
├── docker/          # Docker CE + добавление cloud-init пользователя в группу docker
├── code-server/     # VS Code в браузере
├── chromium-kiosk/  # полноэкранный Chromium (kiosk)
├── kiosk/           # kiosk-вариант (chromium через шаблонный unit)
├── gnome/           # GNOME-десктоп
├── xfce4/           # XFCE-десктоп
├── lxde/            # LXDE-десктоп
├── x11vnc/          # VNC-сервер поверх X
└── nvidia/          # драйверы NVIDIA
```

## Конвенция расширения

```
extensions/<name>/
├── install.sh                  # этап сборки: ставит софт, регистрирует configure-сервис
├── configure.sh                # первый запуск: до-настройка под конкретную ВМ
├── configure-<name>.service    # systemd-oneshot, гоняет configure.sh на загрузке
├── get_cloud_user.sh           # резолв cloud-init пользователя (общий помощник)
├── config.yaml                 # опциональный конфиг расширения
└── README.md
```

Двухфазная модель:
1. **Сборка (`install.sh`)** — ставит софт (apt/официальные скрипты, с ретраями),
   копирует/включает `configure-<name>.service`. Запускается внутри образа.
2. **Первый запуск (`configure.sh` через systemd-oneshot)** — доделывает то, что
   зависит от конкретной ВМ: например, резолвит cloud-init пользователя через
   `cloud-init query userdata | yq` и добавляет его в нужные группы. Идемпотентно.

Поэтому в образе должны быть `cloud-init` и `yq` (их ставит базовый VMFILE).

## Как подключить в VMFILE

Расширение копируется в `/opt/vmsetup/`, скрипты делаются исполняемыми, затем
запускается `install.sh` (некоторые принимают аргументы):

```dockerfile
COPY_IN extensions/docker:/opt/vmsetup/
RUN_COMMAND chmod +x /opt/vmsetup/docker/*.sh
RUN_COMMAND /opt/vmsetup/docker/install.sh

COPY_IN extensions/code-server:/opt/vmsetup/
RUN_COMMAND chmod +x /opt/vmsetup/code-server/*.sh
RUN_COMMAND /opt/vmsetup/code-server/install.sh --version 4.104.3
```

## Как доставить расширения в сборку (CI)

Это публичный репозиторий — клонируй его в контекст сборки image-проекта по тегу
(тег = версия набора расширений):

```yaml
variables:
  EXT_REPO: https://github.com/iamletenkov/bisquite-extensions.git
  EXT_VERSION: v1.0.0
before_script:
  - rm -rf bisquite-extensions
  - git clone --depth 1 --branch "$EXT_VERSION" "$EXT_REPO"
```

Тогда в VMFILE путь — `bisquite-extensions/extensions/<name>`:

```dockerfile
COPY_IN bisquite-extensions/extensions/docker:/opt/vmsetup/
RUN_COMMAND chmod +x /opt/vmsetup/docker/*.sh
RUN_COMMAND /opt/vmsetup/docker/install.sh
```

## Версионирование

Версия набора расширений — это git-тег этого репозитория; image-проект пинит её
через `EXT_VERSION`. Тегай по semver (`v1.0.0`, `v1.1.0`).

## Зависимости и применимость

Пока — по соглашению (в README конкретных расширений):
- десктопы (`gnome`/`xfce4`/`lxde`) обычно идут в паре с `x11vnc`;
- графические расширения требуют графической базы и (для `nvidia`) GPU.

Структурированные метаданные (ОС/версии/зависимости/параметры) — задел на будущий
OCI-«магазин расширений»; сейчас их нет.
