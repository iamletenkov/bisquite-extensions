# Расширение LXDE

Расширение устанавливает ультралёгкое окружение [LXDE](https://lxde.org/) в образах Bisquite и включает автологин пользователя через LightDM.

## Возможности

- Устанавливает LXDE метапакет (`lxde`), LightDM, Xorg, Firefox ESR и утилиты.
- Настраивает автологин для пользователя из cloud-init.
- Oneshot-сервис `configure-lxde` применяет конфигурацию при каждой загрузке.
- Подготавливает окружение для дополнительных расширений (kiosk, x11vnc и др.).

## Требования

- Debian 12 / Ubuntu 22.04+.
- `systemd`, `cloud-init`, интернет при сборке.
- Минимум 512 МБ RAM (рекомендуется ≥1 ГБ) и 2 ГБ свободного места.

## Состав

- `install.sh` — установка LXDE и LightDM.
- `configure.sh` — настройка автологина для пользователя.
- `get_cloud_user.sh` — поиск пользователя в cloud-init.
- `configure-lxde.service` — oneshot unit.
- `lightdm.conf` — шаблон конфигурации LightDM.

## Интеграция в VMFILE

```bash
UPLOAD files/lxde/install.sh:/opt/vmsetup/lxde/install.sh
UPLOAD files/lxde/configure.sh:/opt/vmsetup/lxde/configure.sh
UPLOAD files/lxde/get_cloud_user.sh:/opt/vmsetup/lxde/get_cloud_user.sh
UPLOAD files/lxde/lightdm.conf:/opt/vmsetup/lxde/lightdm.conf
UPLOAD files/lxde/configure-lxde.service:/opt/vmsetup/lxde/configure-lxde.service

RUN_COMMAND chmod +x /opt/vmsetup/lxde/*.sh
RUN_COMMAND /opt/vmsetup/lxde/install.sh
```

После установки LightDM автоматически включается, а `configure-lxde` применяет конфигурацию.

## Как это работает

1. **Сборка** — `install.sh` ставит пакеты, копирует unit-файлы, включает LightDM и сервис конфигурации.
2. **Загрузка** — `configure-lxde` ждёт пользователя (до 120 сек), подставляет имя в `lightdm.conf` и перезапускает дисплей-менеджер.
3. **Повторное применение** — при смене пользователя в cloud-init сервис обновляет настройку автоматически.

## Доступ к рабочему столу

- Proxmox console / noVNC.
- VNC/Spice (если добавлены соответствующие расширения).
- Локальный монитор/тачскрин.

## Диагностика

```bash
systemctl status lightdm
systemctl status configure-lxde.service

journalctl -u configure-lxde -f
journalctl -u lightdm -f

cat /etc/lightdm/lightdm.conf
```

При проблемах:

- **Нет логина** — убедитесь, что пользователь создан (`id <user>`), cloud-init завершился (`cloud-init status`).
- **Чёрный экран** — проверьте `Xorg.0.log` и ресурсы VM.
- **Нужно отключить автологин** — закомментируйте `autologin-user` в `/etc/lightdm/lightdm.conf` и перезапустите LightDM.

## Кастомизация

- Настройте LXDE через файлы `~/.config/lxsession/LXDE/`.
- Для отключения screensaver удалите `@xscreensaver` из `~/.config/lxsession/LXDE/autostart`.
- Для пользовательской темы или панели используйте cloud-init `write_files`/`runcmd`.

## Лицензия

Расширение распространяется на условиях публичной некоммерческой лицензии Bisquite (PolyForm Noncommercial 1.0.0, см. `LICENSE`). Для коммерческого использования требуется отдельная платная лицензия — см. `COMMERCIAL-LICENSE.md`.
