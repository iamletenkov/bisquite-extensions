# code-server

Ставит [code-server](https://github.com/coder/code-server) (VS Code в браузере)
официальным установщиком и включает сервис `code-server@<user>`.

| Параметр (env) | По умолчанию | Описание |
|----------------|--------------|----------|
| `CODE_SERVER_USER` | `debian` | Пользователь systemd-сервиса |
| `CODE_SERVER_VERSION` | (последняя) | Конкретная версия code-server |

**ОС:** Debian ≥11, Ubuntu ≥22.04. **Зависимости:** нет.

Пароль генерируется при первом старте в
`/home/<user>/.config/code-server/config.yaml`.

## Использование в VMFILE

```dockerfile
COPY_IN extensions/code-server:/opt/ext/code-server
RUN_COMMAND CODE_SERVER_USER=debian bash /opt/ext/code-server/install.sh
```
