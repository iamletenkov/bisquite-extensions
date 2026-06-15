# Расширение Docker

Устанавливает Docker CE в виртуальные машины Bisquite, добавляет пользователя из cloud-init в группу `docker` и готовит систему для запуска контейнеров без `sudo`.

## Возможности

- Использует официальный convenience-скрипт Docker (`https://get.docker.com`), который подбирает репозиторий и устанавливает `docker-ce`, `docker-ce-cli`, `containerd.io`, плагины `buildx` и `compose`.
- Oneshot-сервис `configure-docker` ждёт создания пользователя и добавляет его в группу `docker`.
- Скрипты защищены retry-механизмом для скачивания пакетов.

## Требования

- Debian 12 / Ubuntu 22.04+ (amd64 или arm64).
- `systemd`, `cloud-init`, интернет при сборке.
- Минимум 1 ГБ RAM (рекомендуется ≥2 ГБ) и 1 ГБ свободного места.

## Состав

- `install.sh` — запускает официальный convenience-скрипт Docker, обеспечивает наличие `curl` и регистрирует unit-файлы.
- `configure.sh` — добавление пользователя в группу `docker`, проверка `cloud-init`.
- `get_cloud_user.sh` — утилита извлечения пользователя.
- `configure-docker.service` — oneshot unit для запуска `configure.sh`.

## Интеграция в VMFILE

```bash
UPLOAD files/docker/install.sh:/opt/vmsetup/docker/install.sh
UPLOAD files/docker/configure.sh:/opt/vmsetup/docker/configure.sh
UPLOAD files/docker/get_cloud_user.sh:/opt/vmsetup/docker/get_cloud_user.sh
UPLOAD files/docker/configure-docker.service:/opt/vmsetup/docker/configure-docker.service

RUN_COMMAND chmod +x /opt/vmsetup/docker/*.sh
RUN_COMMAND /opt/vmsetup/docker/install.sh
```

`install.sh` копирует сервис в `/etc/systemd/system`, выполняет `daemon-reload`, активирует Docker и `configure-docker`.

## Как это работает

1. **Сборка** — скачивается и выполняется скрипт `get.docker.com`, который определяет дистрибутив, устанавливает Docker CE и плагины, затем активируется `docker.service`.
2. **Первая загрузка** — `configure-docker.service` ожидает пользователя (до 120 сек), добавляет его в `docker` и перезапускает демон при необходимости.
3. **Дальше** — пользователь может запускать контейнеры без `sudo`; при смене пользователя в cloud-init сервис выполняется повторно.

## Проверка

```bash
docker --version
systemctl status docker
groups <user>          # должна быть группа docker

su - <user> -c "docker run --rm hello-world"
```

## Диагностика

```bash
journalctl -u configure-docker -f
journalctl -u docker -f
systemctl status configure-docker.service docker.service
```

Распространённые проблемы:

- **Нет доступа к Docker** — пользователь ещё не добавлен в группу или не разлогинен/вошёл заново. Выполните `sudo usermod -aG docker <user>` и `sudo systemctl restart docker`.
- **Репозиторий недоступен** — проверьте DNS/прокси: `ping download.docker.com`.
- **Cloud-init не завершился** — `cloud-init status --wait`.

## Кастомизация

- Измените `/etc/docker/daemon.json` после установки и перезапустите сервис:

  ```bash
  sudo systemctl stop docker
  sudo nano /etc/docker/daemon.json
  sudo systemctl start docker
  ```

- Для дополнительных пользователей выполните: `sudo usermod -aG docker <user>`.

## Лицензия

Расширение распространяется на условиях публичной некоммерческой лицензии Bisquite (PolyForm Noncommercial 1.0.0, см. `LICENSE`). Для коммерческого использования требуется отдельная платная лицензия — см. `COMMERCIAL-LICENSE.md`.
