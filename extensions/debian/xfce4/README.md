# Расширение Xfce4

Лёгкое графическое окружение Xfce4 для Bisquite: установка, настройка LightDM с автологином и подготовка рабочего стола для последующих расширений (x11vnc, kiosk и т.п.).

## Возможности

- Устанавливает полный стек Xfce4 (`xfce4`, `xfce4-goodies`, `lightdm`, `xorg`, `firefox-esr`).
- Настраивает автологин для пользователя из cloud-init (или заданного в конфигурации).
- Создаёт oneshot-сервис `configure-xfce4`, который подготавливает LightDM каждый раз при загрузке.
- Включает утилиту `yq` для интеграции с другими расширениями.

## Требования

- Debian 12 / Ubuntu 22.04+.
- `systemd`, `cloud-init`, доступ в интернет при сборке.
- Свободные ресурсы: ≥2 ГБ RAM (минимум 1 ГБ), ≥3 ГБ диска.

## Состав

- `install.sh` — установка пакетов и LightDM.
- `configure.sh` — настройка автологина.
- `get_cloud_user.sh` — определение пользователя из cloud-init.
- `configure-xfce4.service` — oneshot unit, выполняющий `configure.sh`.
- `lightdm.conf` — шаблон конфигурации LightDM.

## Интеграция в VMFILE

```bash
UPLOAD files/xfce4/install.sh:/opt/vmsetup/xfce4/install.sh
UPLOAD files/xfce4/configure.sh:/opt/vmsetup/xfce4/configure.sh
UPLOAD files/xfce4/get_cloud_user.sh:/opt/vmsetup/xfce4/get_cloud_user.sh
UPLOAD files/xfce4/lightdm.conf:/opt/vmsetup/xfce4/lightdm.conf
UPLOAD files/xfce4/configure-xfce4.service:/opt/vmsetup/xfce4/configure-xfce4.service

RUN_COMMAND chmod +x /opt/vmsetup/xfce4/*.sh
RUN_COMMAND /opt/vmsetup/xfce4/install.sh
```

`install.sh` копирует systemd unit в `/etc/systemd/system`, делает `daemon-reload`, включает `configure-xfce4` и LightDM.

## Как это работает

1. **Сборка** — ставится Xfce4, LightDM, создаётся шаблон конфигурации.
2. **Первая загрузка** — `configure-xfce4` ждёт пользователя (до 120 секунд), заполняет `autologin-user` и перезапускает LightDM.
3. **Каждый старт** — сервис остаётся `RemainAfterExit=yes` и повторно применяет конфиг при изменении пользователем (через cloud-init).

## Доступ к рабочему столу

- Proxmox console / noVNC.
- VNC/Spice (если установлены соответствующие расширения).
- Дополнительные расширения (kiosk, x11vnc) можно ставить поверх Xfce4.

## Диагностика

```bash
# Проверить LightDM и сервис конфигурации
systemctl status lightdm
systemctl status configure-xfce4.service

# Логи
journalctl -u lightdm -f
journalctl -u configure-xfce4 -f

# Проверка конфигурации
cat /etc/lightdm/lightdm.conf
```

Проблемы и решения:

- **Нет автологина** — убедитесь, что нужный пользователь существует (`id <user>`), и посмотрите логи `configure-xfce4`.
- **Чёрный экран** — проверьте `Xorg.0.log` и выделенные ресурсы VM.
- **Нужно отключить автологин** — закомментируйте в `/etc/lightdm/lightdm.conf` строки `autologin-user` и перезапустите `systemctl restart lightdm`.

## Кастомизация

- Измените тему/панель через `xfconf-query` или подготовьте файлы в cloud-init (`write_files`).
- Чтобы отключить экранную блокировку, добавьте в cloud-init:
  `xfconf-query -c xfce4-screensaver -p /saver/enabled -s false`.

## Лицензия

Расширение распространяется на условиях публичной некоммерческой лицензии Bisquite (PolyForm Noncommercial 1.0.0, см. `LICENSE`). Для коммерческого использования требуется отдельная платная лицензия — см. `COMMERCIAL-LICENSE.md`.
