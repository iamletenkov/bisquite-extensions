# gnome

GNOME на Xorg (Wayland выключен), менеджер входа gdm3. Даёт X-сервер
и сессию расширениям, которым они нужны, — `x11vnc`, `kiosk`.

**С 2.0.0 автологин, отключение автоблокировки и затемнения — ручки,
по умолчанию выключены.** Раньше расширение включало всё это безусловно.
Разбор ручек — [`docs/extensions.md`, «Ручки рабочего стола»](../../../docs/extensions.md#ручки-рабочего-стола).

## Манифест

| Поле | Значение |
|---|---|
| `arch` | `amd64`, `arm64` |
| `phase` | `build` (`install.sh`), `firstboot` (`bisquite-desktop.service` на каждой загрузке) |
| `provides` | `x11-server`, `display-manager`, `desktop-session` |
| `requires` | — |
| `conflicts` | `xfce4`, `lxde` |

## Что делает

**Сборка** (`install.sh`):

- ставит `task-gnome-desktop`, `gdm3`, `gnome-shell`, `gnome-session`, `xorg`,
  `xinput`, `dconf-cli`, `usbutils`, `dbus-x11`, `x11-xserver-utils`;
- пробует нативный `chromium` — только его, см. ниже;
- пишет конфигурацию gdm3 из `daemon.conf`: `WaylandEnable=false`,
  `AutomaticLoginEnable=false`;
- ставит `bisquite-desktop` (CLI, `/etc/default/bisquite-desktop`,
  `bisquite-desktop.service`) и записывает умолчания ручек из параметров;
- включает gdm3 и `graphical.target`.

**Каждая загрузка** (`bisquite-desktop.service`, до gdm3): вносит пользователя
cloud-init в группы видеоядра и применяет ручки.

## Параметры

| Переменная | Умолчание | Что делает |
|---|---|---|
| `DESKTOP_AUTOLOGIN` | `0` | `1` — вход без пароля |
| `DESKTOP_AUTOLOGIN_USER` | пусто | пусто — пользователь cloud-init |
| `DESKTOP_DISABLE_SCREEN_LOCK` | `0` | `1` — без автоблокировки; вручную заблокировать можно |
| `DESKTOP_DISABLE_SCREEN_BLANK` | `0` | `1` — без затемнения, гашения, DPMS и сна |

Параметр задаёт умолчание образа. На устройстве то же меняется командой,
она же применяет:

```bash
sudo bisquite-desktop set DESKTOP_AUTOLOGIN=1 DESKTOP_DISABLE_SCREEN_LOCK=1 DESKTOP_DISABLE_SCREEN_BLANK=1
```

## Подключение в VMFILE

Рабочий стол, который всегда на экране:

```vmfile
EXTENSION gnome
FIRSTBOOT_COMMAND "bisquite-desktop set DESKTOP_AUTOLOGIN=1 DESKTOP_DISABLE_SCREEN_LOCK=1 DESKTOP_DISABLE_SCREEN_BLANK=1"
```

`FIRSTBOOT_COMMAND` исполняется до gdm3, и ручки применяются уже на первой
загрузке. То же в compose — строкой в `firstboot_commands`. Ставите поверх
`x11vnc` или `kiosk` — рабочий стол идёт **первым**, и без
`DESKTOP_AUTOLOGIN=1` им не к чему подключаться: сессии пользователя нет.

## Какой файл читает gdm3

Решено при сборке **пакета**, дистрибутивы расходятся (замер 2026-09-03
распаковкой): Debian 13 — `/etc/gdm3/daemon.conf`, Ubuntu 22.04/24.04 —
`/etc/gdm3/custom.conf`. Запись в другой файл не ошибка и предупреждения
не даёт — gdm его просто не читает. `install.sh` пишет тот, что поставил
пакет, а если нет ни одного — оба; `bisquite-desktop` правит все, какие есть.

## Wayland выключен, и это несущая связь

`x11vnc`, `xset` и захват экрана (`ximagesrc`) работают только в X11.

## Браузер — только нативный

В Debian `chromium` — обычный deb. В Ubuntu пакета нет, а `chromium-browser` —
переходник на snap: он тянет `snapd`, а сам браузер внутри virt-customize
не ставится (замер 2026-09-12 на AGX Orin). Поэтому на Ubuntu браузера нет;
нужен — `epiphany-browser` или `falkon` своим `INSTALL`.

## Проверено

AGX Orin, Ubuntu 22.04 / L4T 36.4.3, 2026-09-14: ручки `0` — экран входа,
`bisquite-desktop.service` стартует перед gdm3, циклов упорядочения нет;
`set` в `1` на лету — сессия автологина, ключи dconf `false` и заблокированы,
`xset q` — `DPMS is Disabled`, x11vnc поднимается.

## Диагностика

```bash
bisquite-desktop status
journalctl -b -u bisquite-desktop
grep -E 'AutomaticLogin|WaylandEnable' /etc/gdm3/custom.conf /etc/gdm3/daemon.conf 2>/dev/null
journalctl -b | grep -E 'Failed to initialize the NVIDIA|Session never registered'
```

## Лицензия

Лицензия репозитория.
