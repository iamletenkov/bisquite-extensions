# docker

Ставит Docker CE (engine, CLI, buildx, compose plugin) из официального
репозитория Docker и включает `docker.service`.

| Параметр (env) | По умолчанию | Описание |
|----------------|--------------|----------|
| `DOCKER_USERS` | `debian` | Пользователи в группу `docker` (через пробел) |

**ОС:** Debian ≥11, Ubuntu ≥22.04. **Зависимости:** нет.

## Использование в VMFILE

```dockerfile
COPY_IN extensions/docker:/opt/ext/docker
RUN_COMMAND DOCKER_USERS="debian admin" bash /opt/ext/docker/install.sh
```
