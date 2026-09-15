# xfce4

Xfce4 с менеджером входа lightdm. Даёт X-сервер и сессию расширениям, которым
они нужны, — `x11vnc`, `kiosk`.

> **С 4.0.0 — раскладка 2.** Каталог расширения в госте — `/opt/bisquite/xfce4/`
> (был `/opt/vmsetup/xfce4/`); CLI `bisquite-desktop` ставится ссылкой
> `/usr/local/sbin/bisquite-desktop` →
> `/opt/bisquite/xfce4/lib/bisquite-desktop` из общего `lib/` источника, а не
> копией; прежний `/usr/local/lib/bisquite-desktop` установка удаляет.
> Нужен bisquite с поддержкой `layout: 2`.

> **С 4.1.0 — библиотека настроек.** Ручки — домен `desktop` библиотеки
> `bisquite-conf` (схема `lib/knobs/desktop` источника): значения проверяет
> схема, запись атомарная, повторная установка правок не стирает.
> `bisquite-desktop set` — то же, что `sudo bisquite-conf set --apply desktop`,
> а `bisquite-conf show desktop` показывает ключи с умолчаниями.

**С 3.0.0 файл ручек — `/etc/bisquite/desktop/config`** (был
`/etc/default/bisquite-desktop`). Прежний путь не читается; если файл
по нему остался в базовом образе, установка его удаляет.

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
| `conflicts` | `gnome`, `lxde` |

## Что делает

**Сборка** (`install.sh`): ставит `xfce4 xfce4-goodies`, `lightdm`, `lightdm-gtk-greeter`,
`xorg`, `xinput`, `x11-xserver-utils`, `dconf-cli`; пробует браузер
(`firefox-esr`/`firefox`, необязательно); пишет `/etc/lightdm/lightdm.conf`
из шаблона (сессия и приветствие, без автологина); ставит `bisquite-desktop`;
включает lightdm и `graphical.target`.

**Каждая загрузка** (`bisquite-desktop.service`, до lightdm): группы
пользователя cloud-init и ручки — `autologin-user` в lightdm, xfconf
`xfce4-power-manager` и `xfce4-screensaver`, lxsession `screensaver=disabled`,
X DPMS через `Xsession.d`, `xserver-command=X -s 0 -dpms` для экрана входа.

## Параметры

Те же четыре, что у `gnome`: `DESKTOP_AUTOLOGIN`, `DESKTOP_AUTOLOGIN_USER`,
`DESKTOP_DISABLE_SCREEN_LOCK`, `DESKTOP_DISABLE_SCREEN_BLANK` — все `0`
по умолчанию. На устройстве:

```bash
sudo bisquite-desktop set DESKTOP_AUTOLOGIN=1 DESKTOP_DISABLE_SCREEN_LOCK=1 DESKTOP_DISABLE_SCREEN_BLANK=1
```

## Подключение в VMFILE

```vmfile
EXTENSION xfce4
FIRSTBOOT_COMMAND "bisquite-desktop set DESKTOP_AUTOLOGIN=1 DESKTOP_DISABLE_SCREEN_LOCK=1 DESKTOP_DISABLE_SCREEN_BLANK=1"
```

## Не проверено

С новым механизмом xfce4 на железе не собирался и не загружался: проверен
`gnome` на Jetson AGX Orin (2026-09-14). Общий код тот же, но ключи lightdm,
xfconf и lxsession подтверждены только разбором.

## Диагностика

```bash
bisquite-desktop status
journalctl -b -u bisquite-desktop
grep -E 'autologin-user|xserver-command|user-session' /etc/lightdm/lightdm.conf
```
