# chromium-kiosk

Пакет [chromium-kiosk](https://github.com/salamek/chromium-kiosk) из
репозитория Salamek: полноэкранный браузер для стендов и терминалов, со
своей графической сессией. Расширение прописывает внешний репозиторий,
ставит пакет и на каждой загрузке собирает из ручек
`/etc/chromium-kiosk/config.yml` — до того, как пакет запустит
собственный наблюдатель за этим файлом.

> **С 3.0.0 — `KEY=VALUE` и библиотека настроек.** Настройки устройства —
> `/etc/bisquite/chromium-kiosk/config` (домен `chromium-kiosk` библиотеки
> `bisquite-conf`, схема `knobs`, ключи `CHROMIUM_KIOSK_*`) вместо копии
> YAML пакета. `configure.sh` **собирает** `/etc/chromium-kiosk/config.yml`
> из ручек; прежний `/etc/bisquite/chromium-kiosk/config.yaml` установка
> переносит (в части ручек) и удаляет. Манифесты вместо `sed` —
> `bisquite-conf set chromium-kiosk CHROMIUM_KIOSK_HOME_PAGE=…`.
>
> **С 2.0.0 — раскладка 2.** Каталог расширения в госте —
> `/opt/bisquite/chromium-kiosk/` (был `/opt/vmsetup/chromium-kiosk/`).

## Манифест

| Поле | Значение |
|---|---|
| `phase` | `build`, `firstboot` |
| `arch` | `amd64`, `arm64` — но проверен только amd64, см. «Архитектуры» |
| `provides` | `kiosk-browser` |
| `requires` | пусто, и это не пропуск — см. «Десктопное расширение не требуется» |
| `conflicts` | `kiosk` |

## Что делает

**Сборка** (`install.sh`)

- ставит `wget`, `gnupg`, `locales`;
- включает локаль `ru_RU.UTF-8` (`LANG=ru_RU.UTF-8`, `LC_MESSAGES=POSIX`);
- кладёт ключ в `/usr/share/keyrings/salamek-archive-keyring.gpg` и
  репозиторий `https://repository.salamek.cz/deb/pub` (suite `all`,
  компонент `main`) в `/etc/apt/sources.list.d/salamek.cz.list`;
- ставит пакет `chromium-kiosk`;
- регистрирует схему и создаёт `/etc/bisquite/chromium-kiosk/config` (`0644`)
  один раз; параметры VMFILE — поверх, через проверку;
- кладёт `configure-chromium-kiosk.service` и включает его.

**Каждая загрузка** (`configure.sh`)

- читает ручки библиотекой `bisquite-conf`, сверяет их со схемой и собирает
  `/etc/chromium-kiosk/config.yml` (атомарно, `0644`), создавая каталог,
  если его нет.

Юнит стоит `Before=chromium-kiosk_configwatcher.service` — конфигурация
обязана лечь до того, как пакет запустит собственный наблюдатель за файлом.
И это **каждая** загрузка, а не только первая: юнит `Type=oneshot` с
`RemainAfterExit=yes` включён в `multi-user.target`, то есть
`/etc/chromium-kiosk/config.yml` перезаписывается на каждом старте.

**`yq` расширению не нужен.** YAML пакета пишется генератором в
`configure.sh`, а не разбирается.

## Десктопное расширение не требуется

Манифест объявляет `requires: []`, и это не пропуск: пакет Salamek приносит
собственную графическую сессию, поэтому оба использующих его VMFILE ставят
его **без** `gnome`/`xfce4`/`lxde`. Этим он и отличается от расширения
`kiosk`, которому X-сервер и дисплей-менеджер обязан дать кто-то другой.

Взаимоисключающе с `kiosk`: оба автостартом на `graphical.target`
разворачивают полноэкранный браузер на одном месте. Конфликт объявлен
симметрично в обоих манифестах, но **сборка его не проверяет** —
топологической сортировки и отказа по конфликту у резолвера нет.

## Ручки

Имена, типы и умолчания — в схеме `knobs`; те же имена — параметры VMFILE
(`EXTENSION chromium-kiosk CHROMIUM_KIOSK_HOME_PAGE=https://…`).

| Ключ | Умолчание | Ключ пакета |
| --- | --- | --- |
| `CHROMIUM_KIOSK_HOME_PAGE` | `https://github.com/iamletenkov/bisquite` | `HOME_PAGE` — **сюда вписывают свою страницу** |
| `CHROMIUM_KIOSK_WINDOW_MODE` | `fullscreen` | `WINDOW_MODE`: `hidden`, `automaticvisibility`, `windowed`, `minimized`, `maximized`, `fullscreen` |
| `CHROMIUM_KIOSK_TOUCHSCREEN` | `true` | `TOUCHSCREEN` |
| `CHROMIUM_KIOSK_IDLE_TIME` | `0` | `IDLE_TIME`, секунды до возврата на стартовую; `0` — выключено |
| `CHROMIUM_KIOSK_WHITE_LIST_ENABLED` | `false` | `WHITE_LIST.ENABLED` |
| `CHROMIUM_KIOSK_WHITE_LIST_URLS` | пусто | `WHITE_LIST.URLS`, через запятую, glob |
| `CHROMIUM_KIOSK_WHITE_LIST_IFRAME_ENABLED` | `true` | `WHITE_LIST.IFRAME_ENABLED` |
| `CHROMIUM_KIOSK_NAV_BAR_ENABLED` | `false` | `NAV_BAR.ENABLED` |
| `CHROMIUM_KIOSK_NAV_BAR_BUTTONS` | `home,reload,back,forward` | `NAV_BAR.ENABLED_BUTTONS`, порядок важен |
| `CHROMIUM_KIOSK_VIRTUAL_KEYBOARD_ENABLED` | `true` | `VIRTUAL_KEYBOARD.ENABLED` |
| `CHROMIUM_KIOSK_DISPLAY_ROTATION` | пусто | `DISPLAY_ROTATION`: `normal`, `left`, `right`, `inverted`; пусто — `normal`, если не заданы два ключа ниже |
| `CHROMIUM_KIOSK_SCREEN_ROTATION` | пусто | `SCREEN_ROTATION` — только экран (при пустом `DISPLAY_ROTATION`) |
| `CHROMIUM_KIOSK_TOUCHSCREEN_ROTATION` | пусто | `TOUCHSCREEN_ROTATION` — только тач (при пустом `DISPLAY_ROTATION`) |
| `CHROMIUM_KIOSK_EXTRA_ARGUMENTS` | `--disable-pinch --overscroll-history-navigation=0` | `EXTRA_ARGUMENTS` |
| `CHROMIUM_KIOSK_ALLOWED_FEATURES` | пусто — ни одного | `ALLOWED_FEATURES`: `desktop-audio-video-capture`, `desktop-video-capture`, `geolocation`, `invalid-certificate`, `media-audio-capture`, `media-audio-video-capture`, `media-video-capture`, `mouse-lock`, `notifications` |
| `CHROMIUM_KIOSK_CURSOR_ENABLED` | `false` | `CURSOR.ENABLED` |

Прочие ключи пакета постоянны и заданы в `configure.sh`: панель навигации —
`center`/`bottom`, `WIDTH: 100`, `HEIGHT: 5`, `UNDERLAY: false`;
`ADDRESS_BAR`, `SCROLL_BARS`, `REMOTE_DEBUGGING`, `EXTRA_ENV_VARS` и
`PROFILE_NAME` не задаются. Понадобится один из них — это новая ручка в
схеме, а не правка сгенерированного файла.

Два прежних умолчания поставляемого `config.yaml` были дефектом, и обоих нет:

- **`HOME_PAGE` указывал на `http://192.168.202.78/`** — адрес частной сети,
  недостижимый у любого другого оператора, и молча: киоск показывает ошибку
  сети, дефект конфигурации читается как неисправность железа. Умолчание —
  то же, что у соседнего `kiosk`;
- **`invalid-certificate` был включён** — браузер, который показывает одну
  страницу, принимал любой сертификат. Для стенда с самоподписанным HTTPS это
  осмысленно, но тогда это надо **написать**:
  `CHROMIUM_KIOSK_ALLOWED_FEATURES=invalid-certificate`.

`ALLOWED_FEATURES` генератор пишет явным пустым списком (`[]`), а не пустым
ключом: `ALLOWED_FEATURES:` без значения — это YAML `null`, то есть «значения
нет», а не «ничего не разрешено».

## Что править на живой машине и чем применять

```bash
sudo bisquite-conf set chromium-kiosk CHROMIUM_KIOSK_HOME_PAGE=https://dashboard.example.org
bisquite-conf show chromium-kiosk
```

`set` проверяет значение, пишет файл, а хук ставит в очередь
`configure-chromium-kiosk.service` — тот пересобирает
`/etc/chromium-kiosk/config.yml`; подхватить изменения дальше — дело самого
пакета (`chromium-kiosk_configwatcher`), и если сессия не перечитала
конфигурацию, надёжный способ один — перезагрузка. Во время загрузки хук не
зовётся: служба при своём старте прочтёт файл сама.

Править `/etc/chromium-kiosk/config.yml` напрямую бессмысленно: его
перезапишет `configure.sh` на следующей загрузке.

## Архитектуры

Манифест объявляет `amd64` и `arm64`, но **проверен только amd64**
(`amd64/debian12/chromium-kiosk.vmfile`, `amd64/debian12/nuc-kiosk.vmfile`
основного репозитория). Репозиторий Salamek публикует suite `all`; что там
есть под arm64, не замерялось.

## Подключение в VMFILE

```vmfile
EXTENSION chromium-kiosk
```

Ручной формы через `COPY_IN` больше нет: сборка кладёт каталог в
`/opt/bisquite/chromium-kiosk/` и ставит рядом ссылку `lib` на общий код источника,
а это делает только `EXTENSION` (раскладка 2, см. `docs/extensions.md`).

**Путь `/opt/bisquite/chromium-kiosk` прибит в `ExecStart` юнита**, и
`EXTENSION` кладёт каталог именно туда. Сам `install.sh` свои файлы
ищет **рядом с собой** (`$SCRIPT_DIR`) — он отвечает на вопрос «файл приехал
рядом со мной?», а не «раскладка всё ещё такая?», — и при отсутствии любого
из своих файлов (`configure-chromium-kiosk.service`, `configure.sh`, `knobs`,
`knobs.apply`, `lib/bisquite-conf`) **отказывает сборкой**, а не предупреждением. Цена именно здесь выше, чем
у соседей: за юнитом стоит единственный производитель рабочего конфига —
`/etc/chromium-kiosk/config.yml` создаёт только наш `configure.sh`, а
запускает его только этот юнит. Нет юнита — нет конфига никогда, и киоск
приезжает с тем, что положил пакет Salamek.

## Требования

- Debian 12 / Ubuntu 22.04+ со `systemd`;
- доступ в интернет при сборке — репозиторий и ключ внешние;
- пакет `locales` в образе или доступный в apt: `install.sh` правит
  `/etc/locale.gen`, и при `set -e` отсутствие файла роняет сборку.

## Диагностика

```bash
journalctl -u configure-chromium-kiosk -f
bisquite-conf show chromium-kiosk
cat /etc/chromium-kiosk/config.yml
sudo systemctl restart configure-chromium-kiosk.service
```

Chromium не запускается — убедитесь, что дисплей `:0` существует
(`ls /tmp/.X11-unix/`) и что у пользователя есть права на X11.

## Работа с неподдерживаемыми тачскринами (поворот)

Посмотреть устройства:

```bash
export DISPLAY=:0
xinput list
```

Отредактировать сессионный скрипт пакета:

```bash
cat /var/lib/chromium-kiosk/.xinitrc

#!/bin/sh
xset -dpms      # disable DPMS (Energy Star) features.
xset s off      # disable screen saver
xset s noblank  # don't blank the video device

# Check if xscreensaver is installed, if it is run it

if command -v xscreensaver &> /dev/null
then
    xscreensaver -no-splash & # xscreensaver daemon
fi

unclutter &     # hides your cursor after inactivity
xfwm4 &
if [ -e ~/chromium-kiosk-prehook.sh ] # Check if prehook exists and run it
then
    ~/chromium-kiosk-prehook.sh
fi

/usr/bin/xinput set-prop "QDTECH̐MPI700 MPI7002" "Coordinate Transformation Matrix" 0 -1 1 1 0 0 0 0 1
exec chromium-kiosk run --config_prod --log_dir=$HOME && killall -u $USER
```

Файл принадлежит пакету, а не расширению: правка переживёт перезагрузку,
но не переустановку пакета.

## Лицензия

Расширение распространяется на условиях публичной некоммерческой лицензии
Bisquite (PolyForm Noncommercial 1.0.0, см. `LICENSE`). Для коммерческого
использования требуется отдельная платная лицензия — см. `COMMERCIAL-LICENSE.md`.
