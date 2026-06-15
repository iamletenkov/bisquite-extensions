# bisquite-extensions

Переиспользуемые «расширения» провизии для образов, собираемых
[bisquite](https://github.com/iamletenkov/bisquite). Каждое расширение — папка
со скриптом установки и (опционально) конфигами/юнитами. Подключаются в сборку
через `COPY_IN` + `RUN_COMMAND`.

Это «задача минимум»: общие версионируемые файлы без отдельного пакетного
менеджера. Метаданные (`extension.yml`) пока документирующие, не enforced.

## Структура

```
bisquite-extensions/
├── docker/          # Docker CE (engine + compose)
├── portainer/       # Portainer CE (зависит от docker)
├── code-server/     # VS Code в браузере
└── chromium-kiosk/  # полноэкранный Chromium (cage/wayland)
```

Каждое расширение:
```
<name>/
├── install.sh       # ставится во время сборки, внутри образа, от root, идемпотентно
├── extension.yml    # метаданные: версия, ОС, зависимости, параметры
└── README.md        # что делает и какие параметры
```

## Конвенция

- **install.sh** запускается на этапе сборки внутри гостя (через `RUN_COMMAND`),
  от root, идемпотентно. Параметры читает из переменных окружения с дефолтами.
- **Сервисы рантайма** ставятся как systemd-юниты с `systemctl enable` (само
  включение работает offline в virt-customize; сервис стартует на реальной
  загрузке). Поэтому отдельный `FIRSTBOOT` обычно не нужен.
- **Параметры** — env-переменные, передаются перед вызовом install.sh.
- **Зависимости** — по соглашению: ставь зависимые расширения раньше (например
  `docker` перед `portainer`).

## Как подключить в образе

В CI-пайплайне image-проекта клонируй этот публичный репозиторий в контекст
сборки (см. шаблон bisquite `examples/ci/`):

```yaml
variables:
  EXT_REPO: https://github.com/iamletenkov/bisquite-extensions.git
  EXT_VERSION: v1.0.0          # тег = версия набора расширений
before_script:
  - rm -rf extensions
  - git clone --depth 1 --branch "$EXT_VERSION" "$EXT_REPO" extensions
```

В VMFILE ссылайся на пути внутри контекста и передавай параметры:

```dockerfile
FROM debian:12
LABEL os=linux

# docker
COPY_IN extensions/docker:/opt/ext/docker
RUN_COMMAND DOCKER_USERS=debian bash /opt/ext/docker/install.sh

# portainer (после docker)
COPY_IN extensions/portainer:/opt/ext/portainer
RUN_COMMAND PORTAINER_PORT=9443 bash /opt/ext/portainer/install.sh
```

Финальный образ загрузится с docker и автозапуском Portainer на `:9443`.

## Версионирование

Версия набора расширений — это **git-тег этого репозитория**. Image-проект
пинит её через `EXT_VERSION`. Тегай по semver (`v1.0.0`, `v1.1.0`).

## Как добавить расширение

1. Создай папку `<name>/` с `install.sh` (идемпотентный, читает env-параметры),
   `extension.yml` (метаданные) и `README.md`.
2. Если есть рантайм-сервис — ставь systemd-юнит и `systemctl enable`.
3. Поставь новый тег.

## Оговорки

- Большие бинари в git не клади — качай в install.sh (`curl`) или пеки в базовый образ.
- `chromium-kiosk` требует графической базы/GPU-seat и тюнинга под железо.
- `extension.yml` пока не парсится bisquite — это документация и задел на будущий
  OCI-«магазин расширений».
