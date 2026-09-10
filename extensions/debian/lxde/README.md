# lxde

Ультралёгкий рабочий стол [LXDE](https://lxde.org/) с автологином через
LightDM. База для расширений, которым нужен X-сервер и дисплей-менеджер, —
`x11vnc` и `kiosk`.

## Манифест

| Поле | Значение |
|---|---|
| `arch` | `amd64`, `arm64` |
| `phase` | `build` (`install.sh`), `firstboot` (`configure.sh`) |
| `provides` | `x11-server`, `display-manager`, `desktop-session` |
| `requires` | — |
| `conflicts` | `gnome`, `xfce4` |

`provides` выведены из кода: `xorg`/`xinput` → `x11-server`, `lightdm` плюс
`systemctl set-default graphical.target` → `display-manager`, `lxde` →
`desktop-session`.

## Что делает

**Сборка** (`install.sh`)

- ставит `lxde`, `lightdm`, `lightdm-gtk-greeter`, `xorg`, `xinput`,
  `firefox-esr`, `usbutils`, `dbus-x11` — **одним списком с `|| exit 1`**;
- заводит `/etc/X11/xorg.conf.d`;
- включает `lightdm.service`, делает `graphical.target` умолчанием;
- кладёт `/etc/systemd/system/configure-lxde.service` из `/opt/vmsetup/lxde/`
  и включает его. Файла рядом нет — только предупреждение, и тогда первая
  загрузка пройдёт без автологина.

**`yq` расширение не ставит**, хотя `configure.sh` без него отказывает, —
см. «Порядок в VMFILE».

**Первая загрузка** (`configure.sh`, юнит `configure-lxde.service`)

- проверяет предпосылки и при нехватке любой отказывает (код 1): `yq`
  в `PATH`, исполняемый `get_cloud_user.sh` рядом, шаблон `lightdm.conf`
  рядом;
- ждёт появления пользователя cloud-init — 40 попыток по 3 с, то есть
  до 120 секунд, потом отказ;
- подставляет его имя в шаблон `lightdm.conf` и кладёт результат
  в `/etc/lightdm/lightdm.conf` **целиком перезаписывая** файл;
- перезапускает LightDM через `try-restart`, то есть остановленный
  дисплей-менеджер не поднимает;
- зовёт `disable_powersave.sh`. Его отказ — **предупреждение**, а не отказ
  юнита: автологин к этому моменту уже записан.

Юнит стоит `Before=lightdm.service display-manager.service`: конфигурация
обязана лечь до старта дисплей-менеджера, иначе первая загрузка пройдёт
с гритером вместо автологина. Привязка — `WantedBy=lightdm.service
display-manager.service`, то есть юнит отрабатывает **на каждой** загрузке.

Шаблон задаёт `user-session=LXDE` — этим и отличается от `xfce4`, где та же
пара скриптов пишет `user-session=xfce`. Плюс `autologin-user-timeout=0`
и `greeter-session=lightdm-gtk-greeter`.

## Параметров нет

Расширение не читает ни одной переменной окружения: единственное, что в нём
изменяемо, — имя пользователя, а оно приходит из cloud-init на устройстве.

## Порядок в VMFILE: `EXTENSION yq` обязан стоять выше

`configure.sh` первым делом зовёт `check_prereqs`, а тот при отсутствии `yq`
делает `exit 1`. Расширение `yq` не ставит, и **сборка об этом не
сообщает**: образ собирается зелёным, а отказ приезжает на первой загрузке
устройства — после записи носителя.

```vmfile
EXTENSION yq
EXTENSION lxde
```

Нужен именно бинарь [mikefarah/yq](https://github.com/mikefarah/yq), который
ставит `EXTENSION yq`. Имя `yq` носят **два разных инструмента** с
несовместимыми языками запросов — в apt лежит kislyuk/yq, — и `command -v yq`
их не различает: проверка отвечает лишь на вопрос «хоть какой-то `yq` есть».
Чем это кончается, записано замером 2026-09-06 на Jetson Nano: три службы
настройки упали с «не дождался пользователя cloud-init», хотя пользователь
существовал с первых секунд. Разбор — в `../yq/README.md`.

Отдельная тонкость: у `get_cloud_user.sh` есть запасной путь — образ без
`cloud-init` или без `yq` настраивается на первую учётку с uid 1000..65533
и домашним каталогом. Здесь до него **не доходит**: `check_prereqs`
отказывает раньше, на самом `command -v yq`. То есть в этом расширении
`yq` — жёсткое требование, а не предпочтение.

## Что выключает `disable_powersave.sh`

Скрипт зовётся с именем пользователя и раскладывает:

- `/etc/X11/Xsession.d/90-disable-dpms` — `xset s off`, `xset s noblank`,
  `xset -dpms` на каждую X-сессию;
- `~/.config/autostart/disable-screensaver.desktop` и
  `disable-powersave-runtime.desktop` — то же изнутри сессии;
- `~/.config/disable-powersave-runtime.sh` — `xset` плюс выход
  `xscreensaver`, если тот запущен;
- `~/.config/lxsession/LXDE/desktop.conf` — `window_manager=openbox-lxde`
  и `screensaver=disabled`;
- `~/.xscreensaver` — `mode: off`, но **только если файл уже существует**.

**Ловушка.** `~/.config/lxsession/LXDE/desktop.conf` записывается
безусловно, а `configure-lxde.service` отрабатывает на каждой загрузке, —
значит всё, что вы там поправили руками, при следующей загрузке пропадёт
вместе с файлом. Это не настройка пользователя, а артефакт расширения;
своё кладите другим файлом или поверх, через cloud-init.

## Что править и чем перезапускать

| Что менять | Где лежит на устройстве | Чем применить |
|---|---|---|
| автологин, сессия, гритер | `/etc/lightdm/lightdm.conf` | `systemctl restart lightdm` |
| энергосбережение сессии | `~<user>/.config/lxsession/LXDE/desktop.conf`, `~/.config/autostart/*.desktop` | новый вход в сессию |
| что делает донастройка | `/opt/vmsetup/lxde/configure.sh`, шаблон `/opt/vmsetup/lxde/lightdm.conf` | `systemctl restart configure-lxde.service` |

Все три пересобираются на каждой загрузке: `/etc/lightdm/lightdm.conf`
пишется из шаблона, `desktop.conf` и `.desktop` — из
`disable_powersave.sh`. Правка на живой машине держится до перезагрузки;
чтобы держалась всегда — правьте шаблон в `/opt/vmsetup/lxde/`, он остался
в образе.

## Подключение в VMFILE

```vmfile
EXTENSION yq
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

Слой выполняет код внутри гостя (`EXTENSION` входит в `GUEST_CODE_LAYERS`),
поэтому `LABEL arch` обязан совпасть с архитектурой машины сборки.

## Требования

- Debian 12 / Ubuntu 22.04+ со `systemd` и `cloud-init`;
- `yq` (mikefarah) в госте к моменту первой загрузки — его даёт
  `EXTENSION yq`, **не** это расширение;
- доступ к apt-репозиториям при сборке;
- дистрибутив, в котором есть пакет `firefox-esr`. Список `apt-get install`
  один и стоит с `|| exit 1`, поэтому отсутствующий браузер роняет установку
  **всего** десктопа. В Debian пакет есть; в Ubuntu браузер поставляется
  снапом `firefox`, и там эта строка — единственное, что мешает. У соседнего
  `gnome` та же беда уже разведена отдельным перебором имён пакетов (замер
  2026-09-10 на jammy, `chromium`), здесь — нет;
- минимум 512 МБ RAM (рекомендуется ≥1 ГБ), ≥2 ГБ диска.

Взаимоисключающе с `gnome` и `xfce4`: каждый ставит свой дисплей-менеджер
и делает его системным `display-manager.service`. Валидатор этого репозитория
требует симметрии конфликтов, но **сборка их не проверяет** — два десктопа
подряд она поставит молча.

## Чего оно не делает

- не ставит `yq` и не проверяет его на сборке;
- не проверяет, что `firefox-esr` вообще существует в дистрибутиве;
- не трогает темы, панель и раскладки LXDE: выключено только
  энергосбережение;
- не выключает автологин «навсегда» — юнит возвращает его на каждой
  загрузке.

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
cat ~/.config/lxsession/LXDE/desktop.conf
```

- **в журнале `yq is not installed`** — в VMFILE не было `EXTENSION yq`
  выше; пересоберите образ;
- **`Timeout waiting for cloud-init user to be created`** — проверьте
  `cloud-init status` и что seed задаёт `user` или `users[0].name`;
- **нет логина** — проверьте, что пользователь создан (`id <user>`);
- **чёрный экран** — `Xorg.0.log` и ресурсы ВМ;
- **отключить автологин** — закомментируйте `autologin-user`
  в `/etc/lightdm/lightdm.conf` и перезапустите `lightdm`. Учтите, что
  `configure-lxde.service` при следующей загрузке отработает снова
  и вернёт автологин: файл пересобирается из шаблона каждый раз.

## Кастомизация

- настройки сессии — `~/.config/lxsession/LXDE/`, но `desktop.conf` там
  перезаписывается на каждой загрузке (см. выше);
- экранная блокировка и засыпание уже выключены `disable_powersave.sh`;
- тему и панель удобно раскладывать через cloud-init `write_files`/`runcmd`.

## Лицензия

Расширение распространяется на условиях публичной некоммерческой лицензии
Bisquite (PolyForm Noncommercial 1.0.0, см. `LICENSE`). Для коммерческого
использования требуется отдельная платная лицензия — см. `COMMERCIAL-LICENSE.md`.
