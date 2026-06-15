# Расширение x11vnc

Добавляет VNC-доступ к графической сессии Bisquite через [x11vnc](https://github.com/LibVNC/x11vnc). Сервис автоматически подстраивается под пользователя, созданного cloud-init, и стартует после входа в графическую оболочку.

## Возможности

- Устанавливает `x11vnc` и вспомогательные утилиты (`yq`, `x11-xserver-utils`).
- Определяет пользователя из cloud-init (или из `config.yaml`) и создаёт для него systemd-инстанс `x11vnc@user.service`.
- Oneshot-сервис `configure-x11vnc` настраивает автозапуск и перезапускает сервис при изменении конфигурации.
- Настройки (`порт`, `пароль`, `DISPLAY`) задаются через YAML.

## Требования

- X11-дисплей сессии (GDM, LightDM, XFCE, LXDE и т.п.).
- Debian 12 / Ubuntu 22.04+ с `systemd`.
- Автологин пользователя (например, через расширения GNOME/Xfce/LXDE).

## Состав

- `install.sh` — установка пакетов и регистрация systemd unit.
- `configure.sh` — настройка `x11vnc@.service` под конкретного пользователя.
- `get_cloud_user.sh` — утилита для получения пользователя из cloud-init.
- `configure-x11vnc.service` — oneshot unit для вызова `configure.sh`.
- `x11vnc@.service` — шаблон пользовательского сервиса.
- `config.yaml` — параметры (пользователь, порт, пароль, дисплей).

## Интеграция в VMFILE

```bash
UPLOAD files/x11vnc/install.sh:/opt/vmsetup/x11vnc/install.sh
UPLOAD files/x11vnc/configure.sh:/opt/vmsetup/x11vnc/configure.sh
UPLOAD files/x11vnc/get_cloud_user.sh:/opt/vmsetup/x11vnc/get_cloud_user.sh
UPLOAD files/x11vnc/config.yaml:/opt/vmsetup/x11vnc/config.yaml
UPLOAD files/x11vnc/x11vnc@.service:/opt/vmsetup/x11vnc/x11vnc@.service
UPLOAD files/x11vnc/configure-x11vnc.service:/opt/vmsetup/x11vnc/configure-x11vnc.service

RUN_COMMAND chmod +x /opt/vmsetup/x11vnc/*.sh
RUN_COMMAND /opt/vmsetup/x11vnc/install.sh
```

`install.sh` копирует unit-файлы в `/etc/systemd/system`, делает `daemon-reload` и включает `configure-x11vnc`.

## Конфигурация (`config.yaml`)

```yaml
USER: ""          # если пусто — пользователь из cloud-init
PASSWORD: none   # задайте строку для включения VNC-пароля
PORT: 5900       # порт RFB
DISPLAY: ":0"    # X11 дисплей
```

При указании `PASSWORD` создаётся файл `~/.vnc/passwd`, и сервис запускается с `-rfbauth`.

## Как это работает

1. **Сборка** — `install.sh` ставит пакеты, клонирует unit-файлы, включает `configure-x11vnc`.
2. **Первая загрузка** — oneshot-сервис ждёт появления пользователя (до 120 сек), подготавливает конфиги, создаёт пароль (если задан), активирует `x11vnc@user.service`.
3. **Старт VNC** — инстанс сервиса запускает `x11vnc` на указанном дисплее (`:0`) и порту.
4. **Повторная настройка** — обновите `/opt/vmsetup/x11vnc/config.yaml` и выполните `sudo systemctl restart configure-x11vnc`.

## Подключение

```bash
vncviewer <vm-ip>:5900        # TigerVNC
vncviewer <vm-ip>::5900       # RealVNC
```

Проверить, что сервис слушает порт:

```bash
ss -tlnp | grep 5900
```

## Диагностика

```bash
systemctl status configure-x11vnc.service
systemctl status x11vnc@<user>.service

journalctl -u configure-x11vnc -f
journalctl -u x11vnc@<user> -f

ls /tmp/.X11-unix/            # убедитесь, что DISPLAY существует
```

Распространённые проблемы:

- **Нет доступа к X11** — проверьте владельца `/run/gdm3/<user>/:0` или `/run/lightdm/<user>/:0`, убедитесь, что user входит в нужные группы.
- **Порт недоступен** — настройте firewall/Proxmox security groups, либо измените `PORT` и перезапустите сервис.
- **Нужен пароль** — установите `PASSWORD` в `config.yaml`.

## Лицензия

Расширение распространяется на условиях публичной некоммерческой лицензии Bisquite (PolyForm Noncommercial 1.0.0, см. `LICENSE`). Для коммерческого использования требуется отдельная платная лицензия — см. `COMMERCIAL-LICENSE.md`.
