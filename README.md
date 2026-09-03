# bisquite-extensions

Переиспользуемые «расширения» провизии для образов, собираемых
[bisquite](https://github.com/iamletenkov/bisquite). Расширения сгруппированы по
семейству ОС. Подключаются в сборку через `COPY_IN`/`UPLOAD`.

## Структура

```
extensions/
├── debian/                  # для Debian/Ubuntu (install.sh + configure)
│   ├── docker/  docker-ce/
│   ├── code-server/
│   ├── chromium-kiosk/  kiosk/
│   ├── gnome/  xfce4/  lxde/
│   ├── x11vnc/
│   └── nvidia/
└── openwrt/                 # для OpenWrt (конфиги, UPLOAD) — не расширения, см. docs/
    ├── uci-defaults/
    └── wrt_cloudinit/
lib/                         # общий код, источник истины (вендорится в расширения)
tools/                       # sync-lib.sh, check-lib.sh, validate-extensions.py, check.sh
docs/extensions.md           # конвенция целиком: манифест, фазы, способности
```

Ubuntu-образы используют расширения из `debian/` (Ubuntu — Debian-совместима).

**Раскладка каталогов — контракт.** На пути `extensions/debian/<имя>` ссылаются
20 строк `COPY_IN`/`UPLOAD` в 13 VMFILE основного репозитория, и переименование
ломает их молча на сборке и громко на устройстве: `configure.sh` запускает
firstboot-служба, а не сборка. Поэтому каталог называется `debian/`, а семейство
внутри манифеста — `deb`; это разные вещи, и совмещать их не надо.

## Конвенция

**Debian/Ubuntu** (`extensions/debian/<name>/`) — скриптовая, двухфазная:
```
<name>/
├── extension.yaml              # манифест: name/version/family/arch/phase/deps
├── install.sh                  # сборка: ставит софт, регистрирует configure-сервис
├── configure.sh                # первый запуск: до-настройка под конкретную ВМ
├── configure-<name>.service    # systemd-oneshot, гоняет configure.sh на загрузке
├── get_cloud_user.sh           # ВЕНДОРЕННАЯ копия lib/ — руками не править
├── config.yaml                 # опциональный конфиг
└── README.md
```
1. **Сборка (`install.sh`)** — ставит софт (с ретраями), включает `configure-<name>.service`.
2. **Первый запуск (`configure.sh`)** — резолвит cloud-init пользователя через
   `cloud-init query userdata | yq` и доделывает per-instance настройку (идемпотентно).

В образе нужны `cloud-init` и `yq` (их ставит базовый VMFILE).

**OpenWrt** (`extensions/openwrt/`) — конфиги, которые кладутся через `UPLOAD`
(uci-defaults, init.d-скрипты), без install.sh. По текущей конвенции это **не
расширения**: другой механизм доставки, и ни одна фаза не описывает их честно.
Манифестов у них нет намеренно — разбор в `docs/extensions.md`.

### Манифест

Рядом со скриптами лежит `extension.yaml` — восемь полей, набор закрыт:

```yaml
name: x11vnc
version: 1.0.0
family: deb                          # deb | rpm | apk | openwrt (НЕ имя каталога)
arch: [amd64, arm64]                 # единственная объявляемая ось применимости
phase: [build, firstboot]            # где выполняется работа
provides: [remote-desktop]
requires: [x11-server, display-manager]
conflicts: []
```

Значение каждого поля, словарь способностей и то, из какого кода они выведены, —
в `docs/extensions.md`.

### Общий код

`get_cloud_user.sh` нужен семи расширениям, а до гостя доезжает только каталог
одного расширения (`COPY_IN <ext>:/opt/vmsetup/`) — соседний `lib/` не приедет
никогда. Поэтому источник истины один (`lib/get_cloud_user.sh`), а копии рядом
со скриптами **генерируются** `tools/sync-lib.sh` и сверяются
`tools/check-lib.sh`. В копиях стоит шапка «сгенерировано, не править руками».

Куда вендорится — в `tools/lib-targets.txt`, по строке на каталог с указанием,
кто именно зовёт файл.

## Проверки

```bash
tools/check.sh                # сверка копий lib/ + валидация манифестов
tools/sync-lib.sh             # разложить копии из lib/
tools/sync-lib.sh --dry-run   # только показать расхождения
tools/validate-extensions.py  # только манифесты (нужен python3 + PyYAML)
```

Валидатор проверяет, что у каждого каталога с `install.sh` есть манифест, что
поля заполнены и осмысленны, что каждая способность из `requires` кем-то
предоставляется, что в графе нет циклов и что `conflicts` симметричны.

## Подключение в VMFILE

Debian/Ubuntu:
```dockerfile
COPY_IN bisquite-extensions/extensions/debian/docker:/opt/vmsetup/
RUN_COMMAND chmod +x /opt/vmsetup/docker/*.sh
RUN_COMMAND /opt/vmsetup/docker/install.sh
```

OpenWrt:
```dockerfile
UPLOAD bisquite-extensions/extensions/openwrt/uci-defaults/80-rootfs-resize:/etc/uci-defaults/80-rootfs-resize
```

## Доставка в сборку (CI)

Публичный репозиторий — клонируется в контекст сборки по тегу (тег = версия
набора расширений):

```yaml
variables:
  EXT_REPO: https://github.com/iamletenkov/bisquite-extensions.git
  EXT_VERSION: v1.1.0
before_script:
  - rm -rf bisquite-extensions
  - git clone --depth 1 --branch "$EXT_VERSION" "$EXT_REPO"
```

## Версионирование

Версия набора расширений — git-тег этого репозитория; image-проект пинит её через
`EXT_VERSION`. Тегай по semver.

## Зависимости и применимость

Объявлены в `extension.yaml` и проверяются `tools/validate-extensions.py`.
Полная таблица «кто что даёт и из какого кода это выведено» —
в `docs/extensions.md`. Коротко:

- `gnome`, `xfce4`, `lxde` дают `x11-server` + `display-manager` + `desktop-session`
  и взаимоисключающи;
- `x11vnc` и `kiosk` требуют `x11-server` и `display-manager` — то самое
  отношение, которое сегодня держится только порядком слоёв в VMFILE;
- `docker` и `docker-ce` дают один `container-runtime` разными путями и потому
  конфликтуют. **Слияние отложено намеренно**: на `docker-ce` не ссылается ни
  один VMFILE, а через `get.docker.com` сегодня идут три из четырёх сборок,
  включая две базовые. Умолчанием `docker-ce` станет после того, как соберётся
  на этих трёх базах, — разбор в `docs/extensions.md`.

**Читателя манифестов пока нет.** Резолвер, топологическая сортировка и отказ
по несовпадению архитектур — этап 2 спеки, и он в `bisquite`, не здесь. Сегодня
манифесты читает только валидатор, а порядок слоёв держится вниманием автора
VMFILE.
