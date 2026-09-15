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
lib/                         # общий код; сборка доставляет его в гостя (контракт)
                             #   bisquite-conf — библиотека и CLI настроек, knobs/ — общие схемы
tools/                       # check.sh, validate-extensions.py, test-conf.sh, new-extension.sh
.github/workflows/check.yml  # CI: гоняет tools/check.sh на push и pull request
docs/extensions.md           # конвенция целиком: манифест, фазы, способности
```

Ubuntu-образы используют расширения из `debian/` (Ubuntu — Debian-совместима).

**Каталог группировки — удобство автора, а не контракт резолвера.** Расширение
ищется по полю `name` манифеста, а не по имени каталога: bisquite обходит кеш
источника целиком (`rglob extension.yaml`) и берёт тот манифест, чьё `name`
совпало со ссылкой. Другой источник вправе разложить дерево иначе.

Каталог называется `debian/`, а семейство внутри манифеста — `deb`; это разные
вещи, и совмещать их не надо. Контрактом остаётся другое: **каталог `lib/` в
корне источника** — его сборка доставляет в гостя рядом с каждым расширением
(см. «Раскладка в госте»).

## Конвенция

**Debian/Ubuntu** (`extensions/debian/<name>/`) — скриптовая, двухфазная:
```
<name>/
├── extension.yaml              # манифест: name/version/layout/family/arch/phase/deps
├── install.sh                  # сборка: ставит софт, регистрирует configure-сервис
├── configure.sh                # первый запуск: до-настройка под конкретную ВМ
├── configure-<name>.service    # systemd-oneshot, гоняет configure.sh на загрузке
├── knobs                       # опционально: схема настроек домена (/etc/bisquite/<домен>/config)
├── knobs.apply, knobs.secret   # опционально: хуки применения и секретов
└── README.md

Общий код рядом НЕ лежит: в госте он виден как `$SCRIPT_DIR/lib/` (ссылка).
```
1. **Сборка (`install.sh`)** — ставит софт (с ретраями), включает `configure-<name>.service`.
2. **Первый запуск (`configure.sh`)** — резолвит cloud-init пользователя через
   `$SCRIPT_DIR/lib/get_cloud_user.sh` и доделывает per-instance настройку
   (идемпотентно).

**Где потом менять настройки.** Одной командой у всех:
`bisquite-conf show <домен>` / `sudo bisquite-conf set <домен> KEY=VALUE`.
Файлы — `/etc/bisquite/<домен>/config` в формате `KEY=VALUE` (грамматика systemd
`EnvironmentFile`), схема — `knobs` расширения; `set` проверяет значение,
пишет атомарно и применяет хуком домена. Таблица доменов —
[docs/extensions.md](docs/extensions.md#где-живут-параметры-времени-выполнения).

В образе нужны `cloud-init` и `yq`, и ставит их **не** расширение:
`cloud-init` приезжает с базовым образом, `yq` — отдельным `EXTENSION yq`,
который обязан стоять в VMFILE **выше** потребителей. Пакетом `apt install yq`
его заменять нельзя: под этим именем в репозиториях лежит другой инструмент
(kislyuk/yq, язык jq) с несовместимым языком запросов — разбор
в `extensions/debian/yq/README.md`.

Отсутствие `cloud-init` само по себе не отказ: у `lib/get_cloud_user.sh` есть
запасной путь — первая обычная учётка с домашним каталогом.

**OpenWrt** (`extensions/openwrt/`) — конфиги, которые кладутся через `UPLOAD`
(uci-defaults, init.d-скрипты), без install.sh. По текущей конвенции это **не
расширения**: другой механизм доставки, и ни одна фаза не описывает их честно.
Манифестов у них нет намеренно; вдобавок `OpenWrtBuilder` блокирует саму
инструкцию `EXTENSION` — разбор в `docs/extensions.md`.

### Манифест

Рядом со скриптами лежит `extension.yaml` — девять полей, набор закрыт:

```yaml
name: x11vnc
version: 3.0.0
layout: 2                            # раскладка в госте; без него bisquite откажет
family: deb                          # deb | rpm | apk | openwrt (НЕ имя каталога)
arch: [amd64, arm64]                 # единственная объявляемая ось применимости
phase: [build, firstboot]            # где выполняется работа
provides: [remote-desktop]
requires: [x11-server, display-manager]
conflicts: []
```

Значение каждого поля, что из него читает bisquite, а что только валидатор, —
в `docs/extensions.md`.

### Раскладка в госте (`layout: 2`)

Всё, что ставят расширения, лежит под одним именем, по назначению:

| Что | Где |
|---|---|
| настройки расширений (`config`, `apps.d`) | `/etc/bisquite/<домен>/` |
| код и данные расширения: `run-*.sh`, `configure.sh`, картинки | `/opt/bisquite/<имя>/` |
| общий код источника (`get_cloud_user.sh`, `bisquite-desktop`) | `/opt/bisquite/lib/<sha256>/`; расширение видит его как `/opt/bisquite/<имя>/lib` |
| состояние | `/var/lib/bisquite/<имя>/` |
| команды для человека | `/usr/local/sbin/bisquite-*` |

До раскладки 2 каталог расширения лежал в `/opt/vmsetup/<имя>`, настройки
`code-server`, `kiosk` и `chromium-kiosk` — там же, а состояние
`teleport-agent` — в `/var/lib/bisquite-teleport`. Переезд — мажорные версии
расширений; уже записанные устройства не мигрируют, образы пересобираются.

### Общий код: `lib/` — контракт доставки

`lib/` в корне источника доставляет **сборка**: считает sha256 дерева, кладёт
его в `/opt/bisquite/lib/<sha256>/` и ставит ссылку
`/opt/bisquite/<имя>/lib → /opt/bisquite/lib/<sha256>` рядом с каждым
расширением. Отсюда правило вызова:

- в `install.sh` и `configure.sh` — `"$SCRIPT_DIR/lib/get_cloud_user.sh"`;
- в юнитах — `/opt/bisquite/<имя>/lib/…`.

Копий в каталогах расширений нет и заводить их нельзя: копии расходятся, и
их приходилось сверять отдельным инструментом. Отпечаток вместо общего
`/opt/bisquite/lib` нужен цепочкам `FROM`: дочерний образ не перезаписывает
код, который зовут расширения базы. Ручной формы `COPY_IN` каталога поэтому
тоже нет — `lib` рядом с расширением ставит только `EXTENSION`.

## Проверки

```bash
tools/check.sh                # все проверки (сегодня — валидация манифестов)
tools/validate-extensions.py  # только манифесты (нужен python3 + PyYAML)
tools/new-extension.sh <имя>  # каркас нового расширения
```

Валидатор проверяет, что у каждого каталога с `install.sh` есть манифест, что
поля заполнены и осмысленны (`layout` — ровно `2`), что каждая способность из `requires` кем-то
предоставляется, что в графе нет циклов и что `conflicts` симметричны.

**Проверки автоматические.** `tools/check.sh` гоняет GitHub Actions на каждый
push и pull request — `.github/workflows/check.yml`. Локально перед пушем это
та же одна команда, и запускать её руками полезно ровно затем, чтобы не узнать
об ошибке из красного CI:

```bash
tools/check.sh
```

Из зависимостей нужен bash и Python 3 с PyYAML (`pip install pyyaml` или
`apt install python3-yaml`).

## Подключение в VMFILE

Для расширений `debian/` способ один — `EXTENSION`.

```vmfile
EXTENSION docker
EXTENSION core/x11vnc X11VNC_PORT=5901 X11VNC_LISTEN=all
```

Форма: `EXTENSION [источник/]имя [КЛЮЧ=ЗНАЧЕНИЕ ...]`. Bisquite разворачивает
её в одном вызове `virt-customize`: кладёт `lib/` источника в
`/opt/bisquite/lib/<sha256>/`, копирует каталог расширения в
`/opt/bisquite/<имя>`, ставит `0755` каждому `*.sh` верхнего уровня, ссылку
`/opt/bisquite/<имя>/lib` и запускает `install.sh`, положив `КЛЮЧ=ЗНАЧЕНИЕ`
в его окружение.

**Параметры уезжают в скрипт переменными окружения как есть, без таблицы
соответствия.** Единственный источник правды о том, какие переменные читает
расширение, — его собственный `install.sh`; таблица «параметр VMFILE →
переменная скрипта» устарела бы молча. Поэтому в README каждого расширения
параметры названы теми же именами, что в коде.

Два свойства, и оба несущие:

- права ставятся опцией `--chmod` инструментами appliance, а не
  `RUN_COMMAND chmod`: вторая форма поднимает гостя и на чужой архитектуре
  отказывает;
- применимость **вычисляется** из пары «архитектура хоста ↔ архитектура
  образа», а не предполагается. `phase: build` при несовпадении — отказ до
  сборки, а не тихая подмена на `firstboot`.

Прежняя ручная форма — `COPY_IN <расширение>:/opt/vmsetup/` плюс
`RUN_COMMAND …/install.sh` — с раскладкой 2 не работает: общий `lib` рядом
с расширением она не ставит, а юниты смотрят в `/opt/bisquite`.

OpenWrt подключается другой формой — `UPLOAD` конкретных файлов
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
остаётся нужен только для файлов OpenWrt, которые `UPLOAD` берёт из чекаута
рядом с VMFILE:

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
пинит поле `ref` источника в `extensions.yaml`, файлы OpenWrt через `UPLOAD` —
тег чекаута (`EXT_VERSION`). Тегай по semver.

`ref: main` неподвижной точкой не является: ветка мутабельна, а git-тег
переставляется `git tag -f`. Что фактически легло в кеш, записывает
`<DATA_DIR>/data/sources.lock`.

## Зависимости и применимость

Объявлены в `extension.yaml`. Читают их **двое, и по-разному**:

- **bisquite** при разборе `EXTENSION` берёт `name`, `layout`, `family`,
  `arch` и `phase`; `layout` не `2` — отказ до сборки. `family` сверяется с тем, что отвечает `virt-inspector` о самом
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
