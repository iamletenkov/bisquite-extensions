# bisquite-extensions

Переиспользуемые «расширения» провизии для образов, собираемых
[bisquite](https://github.com/iamletenkov/bisquite). Расширения сгруппированы по
семейству ОС. Подключаются инструкцией `EXTENSION` в VMFILE.

## Структура

```
extensions/
├── debian/                  # для Debian/Ubuntu (install.sh + configure)
│   ├── docker/
│   ├── code-server/
│   ├── chromium-kiosk/  kiosk/
│   ├── gnome/  xfce4/  lxde/
│   ├── x11vnc/  vino-vnc/
│   ├── network-manager/  nocloud-cidata/  cloud-growroot/
│   └── nvidia/  jetson-stats/
└── openwrt/                 # для OpenWrt (конфиги, UPLOAD) — не расширения, см. docs/
    ├── uci-defaults/
    └── wrt_cloudinit/
lib/                         # общий код, источник истины (вендорится в расширения)
tools/                       # sync-lib.sh, check-lib.sh, validate-extensions.py, check.sh
.github/workflows/check.yml  # CI: гоняет tools/check.sh на push и pull request
docs/extensions.md           # конвенция целиком: манифест, фазы, способности
```

Ubuntu-образы используют расширения из `debian/` (Ubuntu — Debian-совместима).

**Каталог группировки — удобство автора, а не контракт резолвера.** Расширение
ищется по полю `name` манифеста, а не по имени каталога: bisquite обходит кеш
источника целиком (`rglob extension.yaml`) и берёт тот манифест, чьё `name`
совпало со ссылкой. Другой источник вправе разложить дерево иначе.

Контракт держит **инструкция `COPY_IN`** — вторая, продолжающая работать форма
подключения: на путь `extensions/debian/<имя>` ссылаются 22 строки
`COPY_IN`/`UPLOAD` в 12 VMFILE основного репозитория, и переименование ломает
их молча на сборке и громко на устройстве, потому что `configure.sh` запускает
firstboot-служба, а не сборка. Поэтому каталог называется `debian/`,
а семейство внутри манифеста — `deb`; это разные вещи, и совмещать их не надо.

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
Манифестов у них нет намеренно; вдобавок `OpenWrtBuilder` блокирует саму
инструкцию `EXTENSION` — разбор в `docs/extensions.md`.

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

Значение каждого поля, что из него читает bisquite, а что только валидатор, —
в `docs/extensions.md`.

### Общий код

`get_cloud_user.sh` нужен семи расширениям, а до гостя доезжает только каталог
одного расширения (`/opt/vmsetup/<имя>`) — соседний `lib/` не приедет никогда.
Так работают обе формы подключения: `EXTENSION` копирует ровно каталог
расширения, `COPY_IN <ext>:/opt/vmsetup/` — тоже. Поэтому источник истины один
(`lib/get_cloud_user.sh`), а копии рядом со скриптами **генерируются**
`tools/sync-lib.sh` и сверяются `tools/check-lib.sh`. В копиях стоит шапка
«сгенерировано, не править руками».

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

**Проверки автоматические.** `tools/check.sh` гоняет GitHub Actions на каждый
push и pull request — `.github/workflows/check.yml`. Локально перед пушем это
та же одна команда, и запускать её руками полезно ровно затем, чтобы не узнать
о расхождении из красного CI:

```bash
tools/check.sh
```

Из зависимостей нужен bash и Python 3 с PyYAML (`pip install pyyaml` или
`apt install python3-yaml`). Разошлась копия `lib/` — чинится
`tools/sync-lib.sh`, а не правкой копии.

## Подключение в VMFILE

Способов два, и оба рабочие.

### `EXTENSION` — основной

```vmfile
EXTENSION docker
EXTENSION core/x11vnc X11VNC_PORT=5901 X11VNC_LISTEN=all
```

Форма: `EXTENSION [источник/]имя [КЛЮЧ=ЗНАЧЕНИЕ ...]`. Bisquite разворачивает
её в то же, что автор писал руками тремя строками: копирует каталог расширения
в `/opt/vmsetup/<имя>`, ставит `0755` каждому `*.sh` верхнего уровня и
запускает `install.sh`, положив `КЛЮЧ=ЗНАЧЕНИЕ` в его окружение.

**Параметры уезжают в скрипт переменными окружения как есть, без таблицы
соответствия.** Единственный источник правды о том, какие переменные читает
расширение, — его собственный `install.sh`; таблица «параметр VMFILE →
переменная скрипта» устарела бы молча. Поэтому в README каждого расширения
параметры названы теми же именами, что в коде.

Два отличия от ручной записи, и оба несущие:

- права ставятся опцией `--chmod` инструментами appliance, а не
  `RUN_COMMAND chmod`: вторая форма поднимает гостя и на чужой архитектуре
  отказывает;
- применимость **вычисляется** из пары «архитектура хоста ↔ архитектура
  образа», а не предполагается. `phase: build` при несовпадении — отказ до
  сборки, а не тихая подмена на `firstboot`.

### `COPY_IN` — прежняя запись, она не устарела

```vmfile
COPY_IN <чекаут>/extensions/debian/docker:/opt/vmsetup/
RUN_COMMAND chmod +x /opt/vmsetup/docker/*.sh
RUN_COMMAND /opt/vmsetup/docker/install.sh
```

Так написаны все VMFILE в `examples/build/` основного репозитория, и это
продолжает работать. Разница одна: `COPY_IN` привязывает VMFILE к раскладке
каталогов на конкретной машине — путь считается от каталога VMFILE, значит
чекаут этого репозитория обязан лежать рядом. `EXTENSION` берёт то же дерево
из кеша источников, где оно уже есть.

`<чекаут>` — путь до чекаута этого репозитория **относительно каталога
VMFILE**; в примерах основного репозитория это `../../../../bisquite-extensions`,
и глубина зависит от того, насколько глубоко лежит сам VMFILE.

Параметры при этой форме задаются той же строкой, потому что `RUN_COMMAND`
отдаёт её шеллу гостя целиком:

```vmfile
RUN_COMMAND X11VNC_PORT=5901 X11VNC_LISTEN=all /opt/vmsetup/x11vnc/install.sh
```

OpenWrt подключается только третьей формой — `UPLOAD` конкретных файлов
по конкретным путям:

```vmfile
UPLOAD <чекаут>/extensions/openwrt/uci-defaults/80-rootfs-resize:/etc/uci-defaults/80-rootfs-resize
```

## Доставка в сборку: источники расширений

Сборка в сеть за расширением **не ходит**. `EXTENSION` берёт его из локального
кеша `<DATA_DIR>/extensions/<источник>/`, а кеш наполняет отдельный явный шаг —
`bs extension sync` — по объявлению в `<DATA_DIR>/data/extensions.yaml`:

```yaml
sources:
  - name: core
    type: git
    url: https://github.com/iamletenkov/bisquite-extensions.git
    ref: v1.1.0                  # ветка, тег или коммит
  - name: lab
    type: path
    path: /srv/lab-extensions    # только абсолютный путь
```

Источник `core` — этот репозиторий — поставляется с пакетом уже объявленным,
поэтому первый шаг оператора обычно не «напиши файл», а `bs extension sync`.
Свой `extensions.yaml` в каталоге данных **замещает** поставляемый целиком,
а не дополняет его: объявил один свой источник — `core` пропал, допиши его
руками, если он нужен.

```bash
bs extension sources     # что объявлено и в каком состоянии кеш
bs extension sync        # привести кеш в соответствие с объявлением
bs extension ls          # что в кеше лежит — расширения, а не источники
bs extension check core/docker   # применимо ли здесь; при отказе код возврата 1
bs extension new my-ext  # каркас нового расширения (вне кеша — внутри откажет)
```

Типов источников три: `git` и `path` работают, `oci` отказывает явно —
не решён вопрос, каким `mediaType` расширения лежат в реестре, а заглушка,
рапортующая успехом, отложила бы новость до момента, когда `EXTENSION`
не найдётся в середине сборки.

Имя источника необязательно в ссылке: `EXTENSION docker` ищет по всем
источникам в порядке объявления и берёт первый, как `PATH`. Затенение
поставляемого `core` своим источником — рабочий приём, и о нём пишется
строка в журнал (`extensions.shadowed`), потому что «взяли не то, что
думали» иначе видно только по содержимому образа.

Прежний способ доставки — `git clone` этого репозитория в контекст сборки —
остаётся нужен только для формы `COPY_IN`, которой требуется чекаут рядом
с VMFILE:

```yaml
variables:
  EXT_REPO: https://github.com/iamletenkov/bisquite-extensions.git
  EXT_VERSION: v1.1.0
before_script:
  - rm -rf bisquite-extensions
  - git clone --depth 1 --branch "$EXT_VERSION" "$EXT_REPO"
```

## Версионирование

Версия набора расширений — git-тег этого репозитория. Через `EXTENSION` его
пинит поле `ref` источника в `extensions.yaml`, через `COPY_IN` — тег чекаута
(`EXT_VERSION`). Тегай по semver.

`ref: main` неподвижной точкой не является: ветка мутабельна, а git-тег
переставляется `git tag -f`. Что фактически легло в кеш, записывает
`<DATA_DIR>/data/sources.lock`.

## Зависимости и применимость

Объявлены в `extension.yaml`. Читают их **двое, и по-разному**:

- **bisquite** при разборе `EXTENSION` берёт `name`, `family`, `arch` и
  `phase`. `family` сверяется с тем, что отвечает `virt-inspector` о самом
  образе (`<package_format>`), `arch` и `phase` — с парой архитектур;
- **`tools/validate-extensions.py`** проверяет `provides`, `requires`
  и `conflicts` — граф способностей, циклы и симметрию конфликтов.

Топологической сортировки и отказа по конфликту в bisquite **нет**: он эти три
поля только печатает (`bs extension ls`, `bs extension check`). Порядок слоёв
по-прежнему держится вниманием автора VMFILE. Коротко, что объявлено:

- `gnome`, `xfce4`, `lxde` дают `x11-server` + `display-manager` + `desktop-session`
  и взаимоисключающи;
- `x11vnc`, `vino-vnc` и `kiosk` требуют `x11-server` и `display-manager` —
  то самое отношение, которое держится только порядком слоёв в VMFILE.
  `x11vnc` и `vino-vnc` дают одну способность `remote-desktop`, но конфликта
  не объявляют: мешают друг другу их умолчания (порт 5900), а это лечится
  параметром — разбор в `extensions/debian/vino-vnc/README.md`;
- `jetson-stats` даёт `jetson-monitor` и объявляет только `arm64`: Jetson
  бывает только aarch64, и вдобавок расширение отказывает на образе без
  `/etc/nv_tegra_release`;
- `docker` даёт `container-runtime` и ни с чем не конфликтует: расширения
  слиты 2026-09-03, когда замер показал, что `get.docker.com` ставит из того
  же `download.docker.com` и вдобавок ломает сборку на bionic. Разбор —
  в `extensions/debian/docker/README.md`.

Полная таблица «кто что даёт и из какого кода это выведено» —
в `docs/extensions.md`.
