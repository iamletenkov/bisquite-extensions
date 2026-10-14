# locale

Системная локаль и раскладки клавиатуры — везде, где они читаются:
система, консоль, Xorg и экран входа GDM, умолчания GNOME. По умолчанию
`en_US.UTF-8` и раскладки `us,ru`.

## Что ставится и куда пишется

Пакеты: `locales`, `keyboard-configuration`, `console-setup`, `xkb-data`.
Работу делает `apply.sh` — один и тот же скрипт при сборке и хуком на
работающей машине:

| Файл | Кто читает |
|---|---|
| `/etc/locale.gen` + `locale-gen` | откомпилированная локаль (`locale -a`) |
| `/etc/default/locale` (`update-locale --reset LANG=…`) | PAM/сессии, systemd-localed |
| `/etc/default/keyboard` | консоль (`console-setup`, кэш обновляется `setupcon --save-only`), Xorg через udev, systemd-localed |
| `/etc/X11/xorg.conf.d/00-keyboard.conf` | Xorg и экран входа GDM (тот же формат, что пишет `localectl set-x11-keymap`) |
| `/etc/dconf/db/local.d/40-bisquite-locale` | GNOME: `org.gnome.desktop.input-sources` `sources`/`xkb-options` по умолчанию |
| `/etc/dconf/db/gdm.d/40-bisquite-locale` | экран входа GDM, если у gdm есть профиль dconf |

Умолчания GNOME — **без locks**: пользователь меняет раскладки в
«Настройках», и его выбор сильнее. Обратная сторона: у пользователя, который
уже выбрал свои источники ввода, умолчание не видно — так и задумано.
Профиль `/etc/dconf/profile/user` дополняется `system-db:local` по тому же
правилу, что в `lib/bisquite-desktop`. Нет `dconf` (не GNOME) — файлы
пишутся, база соберётся `dconf update`, когда он появится.

## Настройки

Домен `locale`, файл `/etc/bisquite/locale/config`, схема — `knobs`.

| Ключ | Умолчание | Что |
|---|---|---|
| `LOCALE` | `en_US.UTF-8` | `LANG`; только UTF-8 и только из `/usr/share/i18n/SUPPORTED` |
| `KEYBOARD_LAYOUTS` | `us,ru` | раскладки XKB через запятую, вариант в скобках: `us,ru(phonetic)`; первая — основная |
| `KEYBOARD_TOGGLE` | пусто | опция XKB переключения, например `grp:alt_shift_toggle`, `grp:caps_toggle`; пусто — без опции (в GNOME работает Super+Пробел, в консоли и голом Xorg переключения нет) |

## Сборка

```vmfile
EXTENSION locale
EXTENSION locale LOCALE=en_US.UTF-8 KEYBOARD_LAYOUTS=us,ru KEYBOARD_TOGGLE=grp:alt_shift_toggle
```

## Манифест записи / развёртывания

```yaml
firstboot-commands:
  - "bisquite-conf set --apply locale KEYBOARD_TOGGLE=grp:alt_shift_toggle"
```

(`firstboot_commands` в манифесте развёртывания ВМ.) Хук не зовёт
`systemctl`, поэтому `--apply` безопасен и на первой загрузке.

## На работающей машине

```bash
bisquite-conf show locale
sudo bisquite-conf set locale KEYBOARD_LAYOUTS='us,ru(phonetic)' KEYBOARD_TOGGLE=grp:caps_toggle
sudo bisquite-conf set locale LOCALE=ru_RU.UTF-8
```

Хук `knobs.apply` гоняет `apply.sh`: файлы переписаны, локаль
откомпилирована. Подхватывают их: локаль — новый вход в сессию;
консоль — `sudo setupcon` или перезагрузка; GNOME — сразу (база dconf
меняется на лету) у тех, кто не выбрал свои источники; экран входа —
перезапуск `gdm3` или перезагрузка.

## Проверка

```bash
locale                                   # LANG=en_US.UTF-8
localectl status                         # X11 Layout: us,ru
cat /etc/default/keyboard
gsettings get org.gnome.desktop.input-sources sources   # [('xkb', 'us'), ('xkb', 'ru')]
```

Проверено в контейнерах `ubuntu:24.04` и `debian:12`: установка с
`KEYBOARD_TOGGLE`, смена на `us,ru(phonetic)` и `ru_RU.UTF-8`, `dconf update`
(Ubuntu), отказ на локали не из `SUPPORTED`. GDM и живая сессия GNOME в
контейнере не проверялись.
