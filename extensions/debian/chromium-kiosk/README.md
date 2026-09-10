# chromium-kiosk

Пакет [chromium-kiosk](https://github.com/salamek/chromium-kiosk) из
репозитория Salamek: полноэкранный браузер для стендов и терминалов, со
своей графической сессией. Расширение прописывает внешний репозиторий,
ставит пакет и на каждой загрузке раскладывает поставляемый `config.yaml`
в `/etc/chromium-kiosk/config.yml` — до того, как пакет запустит
собственный наблюдатель за этим файлом.

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
- кладёт `configure-chromium-kiosk.service` и включает его.

**Каждая загрузка** (`configure.sh`)

- копирует `config.yaml` из каталога расширения в
  `/etc/chromium-kiosk/config.yml` (`install -m 0644`), создавая каталог,
  если его нет.

Юнит стоит `Before=chromium-kiosk_configwatcher.service` — конфигурация
обязана лечь до того, как пакет запустит собственный наблюдатель за файлом.
И это **каждая** загрузка, а не только первая: юнит `Type=oneshot` с
`RemainAfterExit=yes` включён в `multi-user.target`, то есть
`/etc/chromium-kiosk/config.yml` перезаписывается на каждом старте.

**`yq` расширению не нужен.** Ни `install.sh`, ни `configure.sh` его не
зовут и YAML не разбирают вовсе — `config.yaml` копируется файлом как есть.
Порядок относительно `EXTENSION yq` здесь поэтому безразличен, в отличие от
`code-server` и расширений, чей `configure.sh` ходит в `get_cloud_user.sh`.

## Десктопное расширение не требуется

Манифест объявляет `requires: []`, и это не пропуск: пакет Salamek приносит
собственную графическую сессию, поэтому оба использующих его VMFILE ставят
его **без** `gnome`/`xfce4`/`lxde`. Этим он и отличается от расширения
`kiosk`, которому X-сервер и дисплей-менеджер обязан дать кто-то другой.

Взаимоисключающе с `kiosk`: оба автостартом на `graphical.target`
разворачивают полноэкранный браузер на одном месте. Конфликт объявлен
симметрично в обоих манифестах, но **сборка его не проверяет** —
топологической сортировки и отказа по конфликту у резолвера нет.

## Переменных окружения нет

`install.sh` не разбирает ни одной переменной и не принимает аргументов:
вся настройка живёт в `config.yaml`. Ручки в окружении тут означали бы
второй источник правды рядом с файлом, который пакет и так читает целиком.

Файл лежит в каталоге расширения, то есть в кеше источников, а кеш
перезаписывается на каждом `bs extension sync` — правка в кеше на хосте
держится до первой синхронизации.

## Что править на живой машине и чем применять

Правится **`/opt/vmsetup/chromium-kiosk/config.yaml`** в госте — это
источник, с которого `configure.sh` копирует. Применить:

```bash
sudo systemctl restart configure-chromium-kiosk.service
```

Перезапуск только перекладывает файл в `/etc/chromium-kiosk/config.yml`;
подхватить изменения дальше — дело самого пакета (`chromium-kiosk_configwatcher`),
и если сессия не перечитала конфигурацию, надёжный способ один —
перезагрузка.

Править `/etc/chromium-kiosk/config.yml` напрямую бессмысленно: его
перезапишет `configure.sh` на следующей загрузке.

Способы задать свою конфигурацию заранее:

- при форме `COPY_IN` — положить свой файл поверх отдельным `UPLOAD`
  после копирования каталога и до `install.sh`;
- на устройстве — cloud-init `write_files` по пути
  `/opt/vmsetup/chromium-kiosk/config.yaml`.

## Конфигурация (`config.yaml`)

Формат — самого пакета chromium-kiosk, расширение его только копирует.
Значения в таблице — те, что лежат в поставляемом файле:

| Ключ | В поставляемом файле | Что задаёт |
| --- | --- | --- |
| `WINDOW_MODE` | `fullscreen` | `hidden`, `automaticvisibility`, `windowed`, `minimized`, `maximized`, `fullscreen` |
| `TOUCHSCREEN` | `true` | поддержка тач-ввода |
| `HOME_PAGE` | `http://192.168.202.78/` | стартовый URL — **адрес чужой локальной сети, править обязательно** |
| `IDLE_TIME` | `0` | секунды простоя до возврата на `HOME_PAGE`; `0` — выключено |
| `WHITE_LIST` | `ENABLED: false`, `URLS: []`, `IFRAME_ENABLED: true` | белый список адресов |
| `NAV_BAR` | `ENABLED: false`; кнопки `home`, `reload`, `back`, `forward`; `center`/`bottom`; `WIDTH: 100`, `HEIGHT: 5`, `UNDERLAY: false` | панель навигации |
| `VIRTUAL_KEYBOARD` | `ENABLED: true` | экранная клавиатура |
| `DISPLAY_ROTATION` | `normal` | `normal`, `left`, `right`, `inverted` |
| `EXTRA_ARGUMENTS` | `--disable-pinch --overscroll-history-navigation=0` | флаги браузера строкой |
| `ALLOWED_FEATURES` | только `invalid-certificate` | разрешения (камера, микрофон, гео, невалидный сертификат) |
| `CURSOR` | `ENABLED: false` | показывать курсор |

Два умолчания поставляемого файла стоит назвать вслух, потому что они
заметны только на устройстве:

- **`HOME_PAGE` указывает на `192.168.202.78`** — адрес из сети, в которой
  файл когда-то писали. Собранный без правки образ покажет на стенде ошибку
  загрузки, а не ваш интерфейс;
- **`invalid-certificate` включён** — браузер принимает любой сертификат.
  Для стенда с самоподписанным HTTPS это и нужно, но это снятая проверка,
  а не удобство по умолчанию.

`WHITE_LIST`, `NAV_BAR`, `VIRTUAL_KEYBOARD` и `CURSOR` — **блоки, а не
скаляры**: `VIRTUAL_KEYBOARD: true` пакет не поймёт. Закомментированные
в шаблоне `SCREEN_ROTATION`, `TOUCHSCREEN_ROTATION`, `ADDRESS_BAR`,
`SCROLL_BARS`, `REMOTE_DEBUGGING`, `EXTRA_ENV_VARS` и `PROFILE_NAME`
поддерживаются пакетом, но по умолчанию не заданы.

## Архитектуры

Манифест объявляет `amd64` и `arm64`, но **проверен только amd64**
(`amd64/debian12/chromium-kiosk.vmfile`, `amd64/debian12/nuc-kiosk.vmfile`
основного репозитория). Репозиторий Salamek публикует suite `all`; что там
есть под arm64, не замерялось.

## Подключение в VMFILE

```vmfile
EXTENSION chromium-kiosk
```

Прежняя запись продолжает работать:

```vmfile
COPY_IN <чекаут>/extensions/debian/chromium-kiosk:/opt/vmsetup/
RUN_COMMAND chmod +x /opt/vmsetup/chromium-kiosk/*.sh
RUN_COMMAND /opt/vmsetup/chromium-kiosk/install.sh
```

`<чекаут>` — путь до чекаута этого репозитория **относительно каталога
VMFILE**; в примерах основного репозитория это `../../../../bisquite-extensions`,
и глубина зависит от того, насколько глубоко лежит сам VMFILE.

**Путь `/opt/vmsetup/chromium-kiosk` прибит в трёх местах** — в `install.sh`
(откуда он берёт юнит), в `ExecStart` юнита и, как следствие, в том, где
`configure.sh` ищет `config.yaml` рядом с собой. Обе формы подключения
кладут каталог именно туда, так что переименование каталога расширения
сломает фазу первой загрузки молча: `install.sh` всего лишь скажет
`configure-chromium-kiosk.service not found` предупреждением и продолжит.

## Требования

- Debian 12 / Ubuntu 22.04+ со `systemd`;
- доступ в интернет при сборке — репозиторий и ключ внешние;
- пакет `locales` в образе или доступный в apt: `install.sh` правит
  `/etc/locale.gen`, и при `set -e` отсутствие файла роняет сборку.

## Диагностика

```bash
journalctl -u configure-chromium-kiosk -f
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
