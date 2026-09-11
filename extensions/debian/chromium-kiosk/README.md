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
| `HOME_PAGE` | `https://github.com/iamletenkov/bisquite` | стартовый URL — **своя страница подставляется своим `config.yaml`** |
| `IDLE_TIME` | `0` | секунды простоя до возврата на `HOME_PAGE`; `0` — выключено |
| `WHITE_LIST` | `ENABLED: false`, `URLS: []`, `IFRAME_ENABLED: true` | белый список адресов |
| `NAV_BAR` | `ENABLED: false`; кнопки `home`, `reload`, `back`, `forward`; `center`/`bottom`; `WIDTH: 100`, `HEIGHT: 5`, `UNDERLAY: false` | панель навигации |
| `VIRTUAL_KEYBOARD` | `ENABLED: true` | экранная клавиатура |
| `DISPLAY_ROTATION` | `normal` | `normal`, `left`, `right`, `inverted` |
| `EXTRA_ARGUMENTS` | `--disable-pinch --overscroll-history-navigation=0` | флаги браузера строкой |
| `ALLOWED_FEATURES` | `[]` — ни одного | разрешения (камера, микрофон, гео, невалидный сертификат) |
| `CURSOR` | `ENABLED: false` | показывать курсор |

Два прежних умолчания этого файла были дефектом, и обоих больше нет:

- **`HOME_PAGE` указывал на `http://192.168.202.78/`** — адрес частной сети,
  в которой файл когда-то писали. У любого другого оператора он недостижим,
  и недостижим молча: киоск показывает ошибку сети, то есть дефект
  конфигурации читается как неисправность железа. Теперь умолчание — то же,
  что у соседнего расширения `kiosk`, чтобы во всей цепочке оно было одно.
  Формально это **смена поведения**: кто полагался на прежнее умолчание,
  получит другую страницу — полагаться на него было нельзя;
- **`invalid-certificate` был включён** — браузер, который показывает одну
  страницу и целиком от неё зависит, принимал любой сертификат. Для стенда
  с самоподписанным HTTPS это осмысленно, но тогда это надо **написать**
  в своём `config.yaml`, а не получить вместе с умолчанием. Строка осталась
  в файле закомментированной, рядом с остальными возможностями.

`ALLOWED_FEATURES` задан явным пустым списком (`[]`), а не пустым ключом:
`ALLOWED_FEATURES:` без значения — это YAML `null`, то есть «значения нет»,
а не «ничего не разрешено».

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

**Путь `/opt/vmsetup/chromium-kiosk` прибит в `ExecStart` юнита**, и обе
формы подключения кладут каталог именно туда. Сам `install.sh` свои файлы
ищет **рядом с собой** (`$SCRIPT_DIR`) — он отвечает на вопрос «файл приехал
рядом со мной?», а не «раскладка всё ещё такая?», — и при отсутствии любого
из трёх (`configure-chromium-kiosk.service`, `configure.sh`, `config.yaml`)
**отказывает сборкой**, а не предупреждением. Цена именно здесь выше, чем
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
