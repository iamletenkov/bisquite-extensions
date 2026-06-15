# Расширение Kiosk

Добавляет Chromium в режим киоска: браузер запускается в полный экран сразу после входа пользователя, поддерживает экранную клавиатуру и дополнительные флаги запуска.

## Возможности

- Ставит `chromium`, `dbus-x11`, `x11-xserver-utils`, `yq` и другие зависимости.
- Настраивает автозапуск Chromium через systemd unit `kiosk-chromium@<user>.service`.
- Определяет пользователя из cloud-init и активирует GNOME экранную клавиатуру (или иные варианты) по конфигурации.
- Поддерживает дополнительные параметры запуска Chromium и тип клавиатуры (`onboard`, `matchbox-keyboard`, `florence`).
- Готов к использованию с любым графическим окружением (GNOME, Xfce, LXDE).

## Требования

- Рабочее X11-окружение с автологином (см. расширения `gnome`, `xfce4`, `lxde`).
- Пользователь, создаваемый через cloud-init.
- Интернет при сборке (установка пакетов).

## Состав

- `install.sh` — ставит зависимости, копирует systemd units.
- `configure.sh` — читает `config.yaml`, определяет пользователя, включает сервис.
- `config.yaml` — параметры (URL, тип клавиатуры, DISPLAY, флаги Chromium).
- `configure-kiosk.service` — oneshot unit, вызывающий `configure.sh`.
- `kiosk-chromium@.service` — шаблон systemd-сервиса.

## Интеграция в VMFILE

```bash
UPLOAD files/kiosk/install.sh:/opt/vmsetup/kiosk/install.sh
UPLOAD files/kiosk/configure.sh:/opt/vmsetup/kiosk/configure.sh
UPLOAD files/kiosk/config.yaml:/opt/vmsetup/kiosk/config.yaml
UPLOAD files/kiosk/configure-kiosk.service:/opt/vmsetup/kiosk/configure-kiosk.service
UPLOAD files/kiosk/kiosk-chromium@.service:/opt/vmsetup/kiosk/kiosk-chromium@.service

RUN_COMMAND chmod +x /opt/vmsetup/kiosk/*.sh
RUN_COMMAND /opt/vmsetup/kiosk/install.sh
```

При необходимости замените `config.yaml` на свой перед запуском `install.sh`.

## Конфигурация (`config.yaml`)

```yaml
USER: ""                          # если пусто — имя берём из cloud-init
URL: "https://dashboard.example"  # целевая страница
DISPLAY: ":0"                     # X11-дисплей
KEYBOARD_ENABLED: true            # включить экранную клавиатуру
KEYBOARD_TYPE: "onboard"          # onboard | matchbox-keyboard | florence
CHROMIUM_FLAGS: "--disable-pinch --overscroll-history-navigation=0"
```

Добавьте собственные флаги Chromium (например, `--autoplay-policy=no-user-gesture-required`) через `CHROMIUM_FLAGS`.

## Как это работает

1. **Установка** — `install.sh` копирует сервисы, включает `configure-kiosk`, добавляет зависимости.
2. **Загрузка** — `configure-kiosk` ждёт появления пользователя, переносит конфиг, настраивает автозапуск клавиатуры, включает `kiosk-chromium@user.service`.
3. **Запуск** — сервис ожидает доступности X11 (`DISPLAY=:0`), затем запускает Chromium в kiosk-режиме.
4. **Изменения** — обновите `/opt/vmsetup/kiosk/config.yaml` и выполните `sudo systemctl restart configure-kiosk`.

## Экранная клавиатура

- `KEYBOARD_ENABLED: true` включает встроенную GNOME on-screen keyboard или выбранный тип.
- Для альтернатив (`matchbox-keyboard`, `florence`) пакеты ставятся по требованию.
- Автозапуск клавиатуры обеспечивается через `.desktop` файл в `~/.config/autostart/`.

## Диагностика

```bash
systemctl status configure-kiosk.service
systemctl status kiosk-chromium@<user>.service

journalctl -u configure-kiosk -f
journalctl -u kiosk-chromium@<user> -f

cat /var/lib/kiosk/config              # итоговая конфигурация
ls -la /home/<user>/.config/autostart  # автозапуск клавиатуры
```

Проблемы:

- **Chromium не стартует** — убедитесь, что отображение `:0` существует (`ls /tmp/.X11-unix/`), пользователь владеет файлом `.Xauthority`, а сервис успевает дождаться графики.
- **Клавиатура не появляется** — проверьте установку выбранного пакета (`which onboard`) и содержимое `.desktop` в автозапуске.
- **Нужно больше времени для X11** — отредактируйте unit `kiosk-chromium@.service`, увеличив таймаут в `ExecStartPre`.

## Сочетание с другими расширениями

- Установите одно из графических окружений (`gnome`, `xfce4`, `lxde`), затем добавьте `kiosk`.
- Для удалённого контроля добавьте `x11vnc`.
- Для хостов без клавиатуры используйте `KEYBOARD_ENABLED: true` и тач-драйверы.

## Лицензия

Расширение распространяется на условиях публичной некоммерческой лицензии Bisquite (PolyForm Noncommercial 1.0.0, см. `LICENSE`). Для коммерческого использования требуется отдельная платная лицензия — см. `COMMERCIAL-LICENSE.md`.
