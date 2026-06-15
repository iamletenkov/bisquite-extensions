# Расширение GNOME для Bisquite

Расширение автоматизирует установку GNOME Desktop и настраивает автоматический вход пользователя, созданного через cloud-init. Оно подходит для образов на базе Debian/Ubuntu, собираемых Bisquite.

## Возможности

- Устанавливает полный стек GNOME (`task-gnome-desktop`, `gdm3`, `gnome-shell`, Chromium и сопутствующие пакеты).
- Включает автологин для пользователя, заданного в cloud-init (`user` или `users[0].name`).
- Создаёт systemd-службу, которая повторно применяет конфигурацию перед запуском GDM.
- Отключает энергосбережение и блокировку экрана через `disable_powersave.sh`.
- Идемпотентно: перезапуск сервисов или повторный вызов `configure.sh` не ломает систему.

## Состав расширения

- `install.sh` — ставит GNOME, включает `gdm3`, регистрирует сервис `configure-gnome.service`.
- `configure.sh` — выполняется при загрузке, находит cloud-init пользователя, генерирует `/etc/gdm3/daemon.conf` и вызывает `disable_powersave.sh`.
- `get_cloud_user.sh` — утилита поиска пользователя в cloud-init user-data (требует `yq`).
- `disable_powersave.sh` — отключает DPMS, скринсейвер, idle-delay и создаёт автозагрузку для пользователя.
- `configure-gnome.service` — oneshot-служба systemd, запускающая `configure.sh` до старта GDM.
- `daemon.conf` — шаблон конфигурации GDM c плейсхолдером `USER`.

## Требования

- Образ Debian 12 / Ubuntu 22.04+ со `systemd` и `cloud-init`.
- Доступ к APT-репозиториям при сборке (устанавливаются пакеты GNOME и `yq`).
- Выполнение скриптов от имени root внутри `RUN_COMMAND` или эквивалента Bisquite.

## Интеграция в VMFILE

Добавьте в VMFILE секцию загрузки файлов и запуск установщика:

```bash
# Загружаем файлы расширения
UPLOAD files/gnome/install.sh:/opt/vmsetup/gnome/install.sh
UPLOAD files/gnome/configure.sh:/opt/vmsetup/gnome/configure.sh
UPLOAD files/gnome/get_cloud_user.sh:/opt/vmsetup/gnome/get_cloud_user.sh
UPLOAD files/gnome/disable_powersave.sh:/opt/vmsetup/gnome/disable_powersave.sh
UPLOAD files/gnome/daemon.conf:/opt/vmsetup/gnome/daemon.conf
UPLOAD files/gnome/configure-gnome.service:/opt/vmsetup/gnome/configure-gnome.service

# Делаем скрипты исполняемыми и запускаем установку
RUN_COMMAND chmod +x /opt/vmsetup/gnome/*.sh
RUN_COMMAND /opt/vmsetup/gnome/install.sh
```

`install.sh` копирует сервис в `/etc/systemd/system/configure-gnome.service`, выполняет `daemon-reload`, включает `gdm3` и помечает `graphical.target` как default. Дополнительно вы можете развернуть собственные настройки (wallpaper, расширения GNOME) следующими командами Bisquite.

## Как это работает

1. **Сборка**: `install.sh` ставит пакеты, добавляет systemd-службу и включает её.
2. **Первая загрузка**: `configure-gnome.service` выполняется до запуска GDM.
3. **Поиск пользователя**: `configure.sh` читает cloud-init user-data через `get_cloud_user.sh` и `yq`, ожидая появления учётной записи (до 120 секунд).
4. **Настройка GDM**: шаблон `daemon.conf` обновляется именем пользователя, автологин и Xorg включаются.
5. **Отключение энергосбережения**: `disable_powersave.sh` создаёт dconf-профиль, скрипты автозапуска и Xsession-хук для постоянного включённого экрана.
6. **Повторные загрузки**: служба остаётся `RemainAfterExit=yes` и при каждом старте проверяет, не поменялся ли пользователь cloud-init; конфигурация обновляется автоматически.

## Проверка и отладка

```bash
# Статус и журнал службы настройки
systemctl status configure-gnome.service
journalctl -u configure-gnome -f

# Проверка состояния GDM и графического таргета
journalctl -u gdm3 -f
systemctl status graphical.target

# Файл автологина
cat /etc/gdm3/daemon.conf

# Логи Xorg и GNOME Shell
cat /var/log/Xorg.0.log
journalctl -b | grep gnome-shell
```

Если автологин не сработал, убедитесь, что пользователь существует (`id <user>`), а cloud-init содержит поле `user` или `users[0].name`.

## Изменение поведения

- **Отключить автологин** — закомментируйте `AutomaticLoginEnable` и `AutomaticLogin` в `/etc/gdm3/daemon.conf` и перезапустите GDM (`systemctl restart gdm3`).
- **Настроить GNOME через dconf/gsettings** — добавляйте команды в `disable_powersave.sh` или создавайте отдельные скрипты, загруженные через VMFILE.
- **Добавить приложения** — после установки можно выполнить дополнительные `RUN_COMMAND apt-get install gnome-tweaks ...`.

## Производительность

- Рекомендуется минимум 4 ГБ RAM и 2 vCPU (лучше 4).
- Для комфортной графики выделите не менее 64–128 МБ видеопамяти и включите 3D-ускорение, если гипервизор поддерживает.
- Используйте SSD/быстрое хранилище: GNOME активно обращается к диску при первом запуске.

## Известные ограничения

- Wayland отключён ради совместимости с VNC/Spice — работает Xorg.
- Первая загрузка может занять несколько минут из-за инициализации GNOME и cloud-init.
- Скрипты рассчитаны на Debian/Ubuntu; для других дистрибутивов потребуются правки.

## Лицензия

Расширение распространяется на условиях публичной некоммерческой лицензии Bisquite (PolyForm Noncommercial 1.0.0, см. `LICENSE`). Для коммерческого использования требуется отдельная платная лицензия — см. `COMMERCIAL-LICENSE.md`.
