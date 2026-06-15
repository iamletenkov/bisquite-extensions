# Расширение Chromium Kiosk

Расширение устанавливает [chromium-kiosk](https://github.com/salamek/chromium-kiosk) и настраивает браузер в полноэкранном режиме для стендов и терминалов Bisquite.

## Возможности

- Устанавливает chromium-kiosk из репозитория Salamek вместе с зависимостями (`yq`, локали, требуемые сервисы).
- Подготавливает русскую локаль `ru_RU.UTF-8`.
- Копирует YAML-конфигурацию перед стартом дисплей-менеджера через systemd unit.
- Поддерживает настройку режима окна, списка разрешённых адресов, времени простоя и других параметров через `config.yaml`.
- Идемпотентна: повторный запуск установки/конфигурации не ломает окружение.

## Требования

- Debian 12 / Ubuntu 22.04+ с `systemd` и рабочим X11-дисплеем.
- Настроенный автологин пользователя (через расширение графической среды).
- Доступ к интернету при сборке для добавления внешнего репозитория.

## Состав расширения

- `install.sh` — установка пакетов, локали и systemd-юнита.
- `configure.sh` — применение конфигурации перед запуском графической сессии.
- `configure-chromium-kiosk.service` — oneshot-сервис, выполняющий `configure.sh`.
- `config.yaml` — шаблон настроек (можно заменить собственным).
- `README.md` — документация.

## Интеграция в VMFILE

```bash
# Файлы расширения
UPLOAD files/chromium-kiosk/install.sh:/opt/vmsetup/chromium-kiosk/install.sh
UPLOAD files/chromium-kiosk/configure.sh:/opt/vmsetup/chromium-kiosk/configure.sh
UPLOAD files/chromium-kiosk/config.yaml:/opt/vmsetup/chromium-kiosk/config.yaml
UPLOAD files/chromium-kiosk/configure-chromium-kiosk.service:/opt/vmsetup/chromium-kiosk/configure-chromium-kiosk.service

# Права и установка
RUN_COMMAND chmod +x /opt/vmsetup/chromium-kiosk/*.sh
RUN_COMMAND /opt/vmsetup/chromium-kiosk/install.sh
```

`install.sh` сам копирует systemd unit в `/etc/systemd/system`, выполняет `daemon-reload` и включает сервис.

## Как это работает

1. **Сборка** — `install.sh` ставит chromium-kiosk, включает локаль, регистрирует `configure-chromium-kiosk.service`.
2. **Первая загрузка** — systemd-сервис запускается до GDM/LightDM, копирует `config.yaml` в `/etc/chromium-kiosk/config.yml`.
3. **Графическая сессия** — после входа пользователя chromium-kiosk стартует автоматически с нужными параметрами.
4. **Изменения конфигурации** — обновите `/opt/vmsetup/chromium-kiosk/config.yaml` и перезапустите сервис:
   `sudo systemctl restart configure-chromium-kiosk`.

## Настройка

Основные параметры (`config.yaml`):

| Ключ | Описание |
| --- | --- |
| `WINDOW_MODE` | Режим окна (`fullscreen`, `windowed`, `kiosk`) |
| `HOME_PAGE` | URL для запуска |
| `WHITE_LIST` | Разрешённые хосты и схемы |
| `IDLE_TIME` | Таймаут автоматического обновления страницы |
| `VIRTUAL_KEYBOARD` | Включение экранной клавиатуры |
| `TOUCHSCREEN` | Поддержка тач-жестов |
| `DISPLAY_ROTATION` | Поворот экрана (например, `left`, `inverted`) |

Полный список — в шаблоне `config.yaml`.

## Диагностика

```bash
# Логи конфигурации
journalctl -u configure-chromium-kiosk -f

# Проверить актуальную конфигурацию
cat /etc/chromium-kiosk/config.yml

# Перезапустить сервис конфигурации
sudo systemctl restart configure-chromium-kiosk.service
```

Если chromium не запускается, убедитесь, что дисплей `:0` существует (`ls /tmp/.X11-unix/`) и пользователь имеет права на X11.


## Работа с неподдерживаемыми тач скринами (поворот)

Посмотреть устройства

```bash
export DISPLAY=:0
xinput list
```

Отредактировать скрипт

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


## Лицензия

Расширение распространяется на условиях публичной некоммерческой лицензии Bisquite (PolyForm Noncommercial 1.0.0, см. `LICENSE`). Для коммерческого использования требуется отдельная платная лицензия — см. `COMMERCIAL-LICENSE.md`.
