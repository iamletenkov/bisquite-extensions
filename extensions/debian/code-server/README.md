# Расширение code-server

Автоматизирует установку [code-server](https://github.com/coder/code-server) в образах Bisquite: HTTPS из коробки, автозапуск по systemd и подстановка пользователя из cloud-init.

## Возможности

- Ставит `code-server` и `mkcert`, поддерживает фиксацию версии (по умолчанию `4.104.3`).
- Генерирует локальный TLS-сертификат и конфигурирует HTTPS.
- Определяет пользователя из cloud-init (или использует явное значение в `config.yaml`).
- Создаёт oneshot-сервис `configure-code-server.service`, который готовит конфигурацию и включает user-сервис `code-server@<user>.service`.
- Идемпотентность и retry для скачивания артефактов.

## Требования

- Debian 12 / Ubuntu 22.04+ с `systemd` и `cloud-init`.
- Интернет при сборке (скачивание code-server и mkcert).
- Открытый TCP-порт (по умолчанию 9001).

## Состав расширения

- `install.sh` — установка mkcert, code-server и systemd unit.
- `configure.sh` — конфигурирование пользователя, сертификатов и user-сервиса.
- `get_cloud_user.sh` — извлечение пользователя из cloud-init.
- `configure-code-server.service` — oneshot unit, вызывающий `configure.sh`.
- `config.yaml` — файл настроек (порт, пароль, версия, пользователь).

## Интеграция в VMFILE

```bash
UPLOAD files/code-server/install.sh:/opt/vmsetup/code-server/install.sh
UPLOAD files/code-server/configure.sh:/opt/vmsetup/code-server/configure.sh
UPLOAD files/code-server/get_cloud_user.sh:/opt/vmsetup/code-server/get_cloud_user.sh
UPLOAD files/code-server/configure-code-server.service:/opt/vmsetup/code-server/configure-code-server.service
UPLOAD files/code-server/config.yaml:/opt/vmsetup/code-server/config.yaml

RUN_COMMAND chmod +x /opt/vmsetup/code-server/*.sh
RUN_COMMAND /opt/vmsetup/code-server/install.sh --version 4.104.3
```

`install.sh` копирует systemd unit в `/etc/systemd/system`, делает `daemon-reload` и включает сервис.

## Конфигурация (`config.yaml`)

| Параметр | Описание | По умолчанию |
| --- | --- | --- |
| `USER` | Пользователь, от которого запускается code-server | Автоизвлечение из cloud-init |
| `PASSWORD` | Пароль для входа, `none` отключает пароль | `none` |
| `PORT` | HTTP(S) порт | `9001` |
| `VERSION` | Версия code-server для установки | `4.104.3` |

Чтобы задать настройки через cloud-init, перезапишите файл в пользовательских данных:

```yaml
#cloud-config
write_files:
  - path: /opt/vmsetup/code-server/config.yaml
    content: |
      USER: developer
      PASSWORD: none
      PORT: 9443
      VERSION: 4.104.3
```

## Как это работает

1. **Сборка** — `install.sh` ставит зависимости, скачивает code-server, добавляет systemd unit.
2. **Первая загрузка** — `configure-code-server.service` ждёт появления пользователя, генерирует сертификаты через `mkcert`, создаёт `~/.config/code-server/config.yaml` и включает `code-server@user.service`.
3. **Запуск** — пользовательский сервис стартует по systemd, слушает на указанном порту и использует TLS.
4. **Повторная конфигурация** — измените `/opt/vmsetup/code-server/config.yaml` и выполните `sudo systemctl restart configure-code-server`.

## Диагностика

```bash
# Проверить статус сервисов
systemctl status configure-code-server.service
systemctl status code-server@<user>.service

# Логи
journalctl -u configure-code-server -f
journalctl -u code-server@<user> -f

# Проверить сертификаты и конфиг
ls -la /home/<user>/.local/share/code-server/certs/
cat /home/<user>/.config/code-server/config.yaml
```

Если код-сервер не стартует, убедитесь, что порт свободен (`ss -tlnp | grep 9001`) и сертификаты созданы (наличие `cert.pem`, `key.pem`).

## Полезно знать

- Для смены версии перезапустите установку: `RUN_COMMAND /opt/vmsetup/code-server/install.sh --version <версия>`.
- Пользователь должен существовать до старта `configure-code-server` (проверяется через cloud-init).
- Чтобы добавить пароль, укажите значение в `PASSWORD` или настройте собственный `config.yaml` по пути `~/.config/code-server/config.yaml`.

## Лицензия

Расширение распространяется на условиях публичной некоммерческой лицензии Bisquite (PolyForm Noncommercial 1.0.0, см. `LICENSE`). Для коммерческого использования требуется отдельная платная лицензия — см. `COMMERCIAL-LICENSE.md`.
