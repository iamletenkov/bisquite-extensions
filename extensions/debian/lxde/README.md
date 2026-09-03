# lxde

Ультралёгкий рабочий стол [LXDE](https://lxde.org/) с автологином через
LightDM. База для расширений, которым нужен X-сервер и дисплей-менеджер, —
`x11vnc` и `kiosk`.

## Что делает

**Сборка** (`install.sh`)

- ставит `lxde`, `lightdm`, `lightdm-gtk-greeter`, `xorg`, `xinput`,
  `firefox-esr`, `usbutils`, `dbus-x11`, `yq`;
- заводит `/etc/X11/xorg.conf.d`;
- включает `lightdm.service`, делает `graphical.target` умолчанием;
- кладёт и включает `configure-lxde.service`.

**Первая загрузка** (`configure.sh`)

- ждёт появления пользователя cloud-init — до 120 секунд, 40 попыток по 3 с;
- подставляет его имя в шаблон `lightdm.conf` и кладёт результат
  в `/etc/lightdm/lightdm.conf`;
- перезапускает LightDM (`try-restart`, то есть не поднимает остановленный);
- зовёт `disable_powersave.sh`.

Юнит стоит `Before=lightdm.service display-manager.service`: конфигурация
обязана лечь до старта дисплей-менеджера, иначе первая загрузка пройдёт
с гритером вместо автологина.

Шаблон задаёт `user-session=LXDE` — этим и отличается от `xfce4`, где та же
пара скриптов пишет `user-session=xfce`.

## Параметров нет

Расширение не читает переменных окружения: единственное, что в нём
изменяемо, — имя пользователя, а оно приходит из cloud-init на устройстве.

## Подключение в VMFILE

```vmfile
EXTENSION lxde
```

Прежняя запись продолжает работать:

```vmfile
COPY_IN <чекаут>/extensions/debian/lxde:/opt/vmsetup/
RUN_COMMAND chmod +x /opt/vmsetup/lxde/*.sh
RUN_COMMAND /opt/vmsetup/lxde/install.sh
```

`<чекаут>` — путь до чекаута этого репозитория **относительно каталога
VMFILE**; в примерах основного репозитория это `../../../../bisquite-extensions`,
и глубина зависит от того, насколько глубоко лежит сам VMFILE.

Ставите поверх `x11vnc` или `kiosk` — десктоп идёт **первым**:
топологической сортировки у резолвера нет, порядок держится этой строкой.

## Требования

- Debian 12 / Ubuntu 22.04+ со `systemd` и `cloud-init`;
- доступ к apt-репозиториям при сборке;
- минимум 512 МБ RAM (рекомендуется ≥1 ГБ), ≥2 ГБ диска.

Взаимоисключающе с `gnome` и `xfce4`: каждый ставит свой дисплей-менеджер
и делает его системным `display-manager.service`. Валидатор этого репозитория
требует симметрии конфликтов, но **сборка их не проверяет** — два десктопа
подряд она поставит молча.

## Доступ к рабочему столу

- консоль Proxmox / noVNC;
- `x11vnc` поверх — VNC на loopback, доступ через SSH-туннель;
- локальный монитор или тачскрин.

## Диагностика

```bash
systemctl status lightdm
systemctl status configure-lxde.service

journalctl -u configure-lxde -f
journalctl -u lightdm -f

cat /etc/lightdm/lightdm.conf
```

- **Нет логина** — проверьте, что пользователь создан (`id <user>`)
  и что cloud-init завершился (`cloud-init status`).
- **Чёрный экран** — `Xorg.0.log` и ресурсы ВМ.
- **Отключить автологин** — закомментируйте `autologin-user`
  в `/etc/lightdm/lightdm.conf` и перезапустите `lightdm`. Учтите, что
  `configure-lxde.service` при следующей загрузке отработает снова
  и вернёт автологин: файл пересобирается из шаблона каждый раз.

## Кастомизация

- настройки сессии — `~/.config/lxsession/LXDE/`;
- экранная блокировка и засыпание уже выключены `disable_powersave.sh`;
- тему и панель удобно раскладывать через cloud-init `write_files`/`runcmd`.

## Лицензия

Расширение распространяется на условиях публичной некоммерческой лицензии
Bisquite (PolyForm Noncommercial 1.0.0, см. `LICENSE`). Для коммерческого
использования требуется отдельная платная лицензия — см. `COMMERCIAL-LICENSE.md`.
