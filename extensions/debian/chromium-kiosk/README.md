# chromium-kiosk

Пакет [chromium-kiosk](https://github.com/salamek/chromium-kiosk) из
репозитория Salamek: полноэкранный браузер для стендов и терминалов,
со своей графической сессией.

## Что делает

**Сборка** (`install.sh`)

- ставит `wget`, `gnupg`, `locales`, `yq`;
- включает локаль `ru_RU.UTF-8` (`LANG=ru_RU.UTF-8`, `LC_MESSAGES=POSIX`);
- прописывает ключ и репозиторий `repository.salamek.cz` (suite `all`);
- ставит пакет `chromium-kiosk`;
- кладёт и включает `configure-chromium-kiosk.service`.

**Первая загрузка** (`configure.sh`)

- копирует `config.yaml` из каталога расширения в
  `/etc/chromium-kiosk/config.yml`.

Юнит стоит `Before=chromium-kiosk_configwatcher.service` — конфигурация
обязана лечь до того, как пакет запустит собственный наблюдатель за файлом.

## Десктопное расширение не требуется

Манифест объявляет `requires: []`, и это не пропуск: пакет Salamek приносит
собственную графическую сессию, поэтому оба использующих его VMFILE ставят
его **без** `gnome`/`xfce4`/`lxde`. Этим он и отличается от расширения
`kiosk`, которому X-сервер и дисплей-менеджер обязан дать кто-то другой.

Взаимоисключающе с `kiosk`: оба автостартом на `graphical.target`
разворачивают полноэкранный браузер на одном месте. Сборка этого **не
проверяет** — топологической сортировки и отказа по конфликту у резолвера
нет.

## Параметров окружения нет

Расширение читает только `config.yaml`; ни одной переменной окружения
`install.sh` не разбирает. Файл лежит в каталоге расширения, то есть
в кеше источников, а кеш перезаписывается на каждом `bs extension sync` —
правка на хосте держится до первой синхронизации.

Рабочие способы задать свою конфигурацию:

- при форме `COPY_IN` — положить свой файл поверх отдельным `UPLOAD`
  после копирования каталога и до `install.sh`;
- на устройстве — cloud-init `write_files` по пути
  `/opt/vmsetup/chromium-kiosk/config.yaml` плюс
  `systemctl restart configure-chromium-kiosk`;
- либо править `/etc/chromium-kiosk/config.yml` напрямую — но его
  перезапишет `configure.sh` на следующей загрузке.

## Конфигурация (`config.yaml`)

Формат — самого пакета chromium-kiosk, расширение его только копирует.
Ключи верхнего уровня в поставляемом шаблоне:

| Ключ | Что задаёт |
| --- | --- |
| `WINDOW_MODE` | `hidden`, `automaticvisibility`, `windowed`, `minimized`, `maximized`, `fullscreen` |
| `HOME_PAGE` | стартовый URL |
| `TOUCHSCREEN` | поддержка тач-ввода |
| `IDLE_TIME` | секунды до возврата на `HOME_PAGE`; `0` — выключено |
| `WHITE_LIST` | вложенный блок: `ENABLED`, `URLS`, `IFRAME_ENABLED` |
| `NAV_BAR` | вложенный блок: `ENABLED`, `ENABLED_BUTTONS`, позиция, размеры |
| `VIRTUAL_KEYBOARD` | вложенный блок: `ENABLED` |
| `DISPLAY_ROTATION` | `normal`, `left`, `right`, `inverted` |
| `EXTRA_ARGUMENTS` | флаги браузера строкой |
| `ALLOWED_FEATURES` | список разрешений (камера, гео, невалидный сертификат) |
| `CURSOR` | вложенный блок: `ENABLED` |

`WHITE_LIST`, `NAV_BAR`, `VIRTUAL_KEYBOARD` и `CURSOR` — **блоки, а не
скаляры**: `VIRTUAL_KEYBOARD: true` пакет не поймёт. Закомментированные
в шаблоне `SCREEN_ROTATION`, `TOUCHSCREEN_ROTATION`, `ADDRESS_BAR`,
`SCROLL_BARS`, `REMOTE_DEBUGGING`, `EXTRA_ENV_VARS` и `PROFILE_NAME`
поддерживаются пакетом, но по умолчанию не заданы.

## Архитектуры

Манифест объявляет `amd64` и `arm64`, но **проверен только amd64**
(`amd64/debian12/chromium-kiosk.vmfile`, `amd64/debian12/nuc-kiosk.vmfile`
основного репозитория). Репозиторий
Salamek публикует suite `all`; что там есть под arm64, не замерялось.

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

## Требования

- Debian 12 / Ubuntu 22.04+ со `systemd`;
- доступ в интернет при сборке — репозиторий и ключ внешние.

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
