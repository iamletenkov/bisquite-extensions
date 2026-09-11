# xfce4

Лёгкий рабочий стол Xfce4 с автологином через LightDM. База для расширений,
которым нужен X-сервер и дисплей-менеджер, — `x11vnc` и `kiosk`.

## Манифест

| Поле | Значение |
|---|---|
| `phase` | `[build, firstboot]` |
| `provides` | `x11-server`, `display-manager`, `desktop-session` |
| `requires` | — |
| `conflicts` | `gnome`, `lxde` |

`provides` расписано по строкам `install.sh`: `xorg` и `xinput` дают
`x11-server`, `lightdm` вместе с `systemctl set-default graphical.target` —
`display-manager`, а `xfce4` с `xfce4-goodies` — `desktop-session`. Именно
эти три способности ищут в `requires` расширения `x11vnc` и `kiosk`.

`requires` пуст, и обязательных зависимостей у расширения действительно
нет: `yq` перестал быть условием работы (следующий раздел), а всё
остальное — пакеты из apt.

## Порядок в VMFILE: `EXTENSION yq` стоит выше, но отказом больше не грозит

```vmfile
EXTENSION yq
EXTENSION xfce4
```

**Что изменилось.** `configure.sh` начинал с `command -v yq` и при его
отсутствии выходил кодом 1 — то есть **автологин не настраивался вовсе**,
а узнавали об этом на уже записанном устройстве. Проверка была мёртвой:
`yq` этот скрипт не вызывает ни разу, он нужен единственному потребителю,
`get_cloud_user.sh`, а тот объявил его необязательным и без него уходит
в `fallback_user()`.

**Почему строку всё равно стоит держать.** Без `yq` имя пользователя берётся
запасным путём: первая учётка с uid 1000..65533 и домашним каталогом. На
образе с вендорской учёткой это может оказаться **не тот** пользователь;
запасной путь говорит об этом вслух, в stderr
(`Note: cloud-init user unavailable; falling back to '<имя>'`). То есть `yq`
остался условием того, что настроят именно пользователя cloud-init.

Расширение `xfce4` само `yq` **не ставит**; ставит его отдельное расширение
`yq`, и нужен именно mikefarah/yq (пакет из apt — другой инструмент
с другим языком запросов, разбор в его README).

## Что делает

**Сборка** (`install.sh`)

- ставит `xfce4`, `xfce4-goodies`, `lightdm`, `lightdm-gtk-greeter`,
  `xorg`, `xinput`, `usbutils`, `dbus-x11`;
- ставит браузер **отдельно и необязательно**: перебирает `firefox-esr`,
  затем `firefox` (так он называется в Ubuntu, где это переходник на snap),
  ставит первое доступное, а промах по всем — только предупреждение.
  Пока браузер стоял в общем списке с `|| exit 1`, один необязательный
  пакет ронял установку **всего** десктопа; у соседнего `gnome` это уже
  замерено (jammy 2026-09-10, `E: Package 'chromium' has no installation
  candidate`), имя пакета там другое, механизм отказа тот же;
- заводит `/etc/X11/xorg.conf.d`;
- включает `lightdm.service`, делает `graphical.target` умолчанием;
- **отказывает (код 1)**, если рядом с ним нет `configure-xfce4.service`,
  `configure.sh`, `get_cloud_user.sh` или `lightdm.conf`, и только потом
  кладёт и включает `configure-xfce4.service`.

**Первая загрузка** (`configure.sh`)

- отказывает сразу, если нет `get_cloud_user.sh` или шаблона
  `lightdm.conf` рядом;
- ждёт появления пользователя cloud-init — до 120 секунд, 40 попыток по 3 с;
- подставляет его имя в шаблон `lightdm.conf` и кладёт результат
  в `/etc/lightdm/lightdm.conf`;
- перезапускает LightDM (`try-restart`, то есть не поднимает остановленный);
- зовёт `disable_powersave.sh`.

Юнит стоит `Before=lightdm.service display-manager.service`: конфигурация
обязана лечь до старта дисплей-менеджера, иначе первая загрузка пройдёт
с гритером вместо автологина. Пользователя он ждёт **циклом**, а не
упорядочиванием по `cloud-final.service`: запас — те самые 120 секунд,
и в журнале нехватка видна строкой «Timeout waiting for cloud-init user».

Шаблон задаёт `user-session=xfce` — этим и отличается от `lxde`, где та же
пара скриптов пишет `user-session=LXDE`.

**Каталог `/opt/vmsetup/xfce4` обязан остаться в образе.**
`configure-xfce4.service` зовёт `configure.sh` по этому пути в рантайме,
шаблон `lightdm.conf` и `disable_powersave.sh` скрипт ищет рядом с собой.
Инструкция `EXTENSION` кладёт каталог именно туда.

Сам `install.sh` к этому пути больше не привязан: файлы он ищет **рядом
с собой** (`$SCRIPT_DIR`), поэтому `COPY_IN` в другое место он переживёт.
А вот отсутствие любого из них — теперь **отказ сборки**, а не
предупреждение: прежде сборка проходила зелёной, юнита в образе не было,
и узнать об этом можно было только на устройстве.

### Что отключает `disable_powersave.sh`

Вызывается с именем пользователя и пишет в пять мест:

| Куда | Что |
|---|---|
| `/etc/X11/Xsession.d/90-disable-dpms` | `xset s off`, `xset s noblank`, `xset -dpms` на каждую сессию |
| `~/.config/autostart/disable-screensaver.desktop` | то же самое при входе |
| `~/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-power-manager.xml` | гашение экрана, DPMS, действия по крышке и кнопке питания |
| `~/.config/xfce4/xfconf/xfce-perchannel-xml/xfce4-session.xml` | `LockCommand` пустой, хранитель экрана выключен |
| `~/.config/disable-powersave-runtime.sh` + `.desktop` в автозапуске | те же значения через `xfconf-query` в уже открытой сессии |

Если в образе есть `~/.xscreensaver`, в нём правится `mode: off`.

## Параметров нет

Расширение не читает переменных окружения: единственное, что в нём
изменяемо, — имя пользователя, а оно приходит из cloud-init на устройстве.
Задавать его при сборке нечем и незачем.

## Подключение в VMFILE

```vmfile
EXTENSION xfce4
```

Прежняя запись продолжает работать:

```vmfile
COPY_IN <чекаут>/extensions/debian/xfce4:/opt/vmsetup/
RUN_COMMAND chmod +x /opt/vmsetup/xfce4/*.sh
RUN_COMMAND /opt/vmsetup/xfce4/install.sh
```

`<чекаут>` — путь до чекаута этого репозитория **относительно каталога
VMFILE**; в примерах основного репозитория это `../../../../bisquite-extensions`,
и глубина зависит от того, насколько глубоко лежит сам VMFILE.

Ставите поверх `x11vnc` или `kiosk` — десктоп идёт **первым**:
топологической сортировки у резолвера нет, порядок держится этой строкой.

## Требования

- Debian 12 / Ubuntu 22.04+ со `systemd` и `cloud-init`;
- доступ к apt-репозиториям при сборке;
- ≥2 ГБ RAM (минимум 1 ГБ), ≥3 ГБ диска.

Взаимоисключающе с `gnome` и `lxde`: каждый ставит свой дисплей-менеджер
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
systemctl status configure-xfce4.service

journalctl -u lightdm -f
journalctl -u configure-xfce4 -f

cat /etc/lightdm/lightdm.conf
```

- **Нет автологина** — проверьте, что пользователь существует (`id <user>`),
  и посмотрите журнал `configure-xfce4`: он печатает имя, которое нашёл.
- **Чёрный экран** — `Xorg.0.log` и выделенные ресурсы ВМ.
- **Отключить автологин** — закомментируйте `autologin-user`
  в `/etc/lightdm/lightdm.conf` и перезапустите `lightdm`. Учтите, что
  `configure-xfce4.service` при следующей загрузке отработает снова
  и вернёт автологин: файл пересобирается из шаблона каждый раз.

## Кастомизация

- тема и панель — `xfconf-query` либо файлы через cloud-init `write_files`;
- **автологин и сессия** задаются шаблоном `lightdm.conf` рядом со скриптом,
  а не правкой `/etc/lightdm/lightdm.conf`: результат пересобирается
  из шаблона при каждой загрузке. Менять надо
  `/opt/vmsetup/xfce4/lightdm.conf` (тогда правка применится со следующей
  загрузки) либо выключить `configure-xfce4.service` вовсе;
- **гашение экрана уже выключено** `disable_powersave.sh`. Вернуть его одной
  командой не получится: значения записаны в `xfce4-session.xml`
  и `xfce4-power-manager.xml`, а поверх них стоят две записи автозапуска,
  которые накатывают те же значения при каждом входе. Чтобы вернуть,
  уберите из `~/.config/autostart/` файлы `disable-screensaver.desktop`
  и `disable-powersave-runtime.desktop`, снимите
  `/etc/X11/Xsession.d/90-disable-dpms` и поправьте нужные ключи
  (`xfconf-query -c xfce4-session -p /startup/screensaver/enabled -s true`).
  Канала `xfce4-screensaver` расширение не трогает вовсе.

## Лицензия

Расширение распространяется на условиях публичной некоммерческой лицензии
Bisquite (PolyForm Noncommercial 1.0.0, см. `LICENSE`). Для коммерческого
использования требуется отдельная платная лицензия — см. `COMMERCIAL-LICENSE.md`.
