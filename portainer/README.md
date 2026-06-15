# portainer

Ставит systemd-юнит, поднимающий Portainer CE как docker-контейнер. Образ
скачивается при первом старте ВМ. **Зависит от `docker`** — подключайте его раньше.

| Параметр (env) | По умолчанию | Описание |
|----------------|--------------|----------|
| `PORTAINER_PORT` | `9443` | HTTPS-порт UI |
| `PORTAINER_IMAGE` | `portainer/portainer-ce:latest` | Docker-образ |

**ОС:** Debian ≥11, Ubuntu ≥22.04. **Зависимости:** `docker`.

## Использование в VMFILE

```dockerfile
COPY_IN extensions/docker:/opt/ext/docker
RUN_COMMAND bash /opt/ext/docker/install.sh

COPY_IN extensions/portainer:/opt/ext/portainer
RUN_COMMAND PORTAINER_PORT=9443 bash /opt/ext/portainer/install.sh
```
