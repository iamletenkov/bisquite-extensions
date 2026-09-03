# code-server

[code-server](https://github.com/coder/code-server) в образе: установка на
сборке, выпуск локального TLS-сертификата и запуск под пользователем, которого
создаёт cloud-init, — на первой загрузке.

## Что делает

**Сборка** (`install.sh`)

- ставит `curl`, `wget`, `gnupg`, `yq`;
- ставит `mkcert` — бинарь из релиза v1.4.4 GitHub, ссылка собирается из
  `dpkg --print-architecture`, скачанное проверяется на магию ELF и на то,
  что `-version` отрабатывает;
- ставит code-server штатным установщиком `code-server.dev/install.sh`,
  с закреплённой версией или `latest`;
- перезаписывает `config.yaml` расширения значениями из VMFILE, если они
  заданы;
- кладёт и включает `configure-code-server.service`.

**Первая загрузка** (`configure.sh`)

- читает `config.yaml` рядом с собой;
- резолвит пользователя: `USER` из файла, иначе `get_cloud_user.sh`;
- выпускает `mkcert`-сертификат на `localhost 127.0.0.1 ::1` в
  `~/.local/share/code-server/certs/`;
- пишет `~/.config/code-server/config.yaml` и заводит
  `code-server@<пользователь>.service`.

## Параметры из VMFILE

Инструкция `EXTENSION` передаёт параметры переменными окружения, и они
**перекрывают** `config.yaml`:

```vmfile
EXTENSION code-server CODE_SERVER_PORT=9002 CODE_SERVER_VERSION=4.135.0
```

| Переменная | Что задаёт | Умолчание |
|---|---|---|
| `CODE_SERVER_PORT` | порт | `9001` |
| `CODE_SERVER_PASSWORD` | пароль; `none` означает «пароля нет» | `none` |
| `CODE_SERVER_USER` | пользователь; пусто — берётся из cloud-init | пусто |
| `CODE_SERVER_VERSION` | версия code-server | из `config.yaml` |

Не заданные переменные оставляют прежние значения файла, поэтому
`CODE_SERVER_PORT=9002` не сбрасывает закреплённую версию.

**`CODE_SERVER_VERSION` читается до разбора аргументов, а не после.** Раньше
на этом месте стояло безусловное затирание пустой строкой, и
`EXTENSION code-server CODE_SERVER_VERSION=4.135.0` **тихо** терял пин:
значение приходило в окружении и стиралось. Ключ `--version` по-прежнему
сильнее переменной — он и задумывался как явное указание руками.

**Почему не правкой `config.yaml` руками.** Файл лежит в каталоге
расширения, то есть в кеше источников, а кеш перезаписывается на каждом
`bs extension sync`. Правка держалась бы до первой синхронизации и пропадала
молча — ровно та болезнь «мёртвых ручек», из-за которой у расширения
`x11vnc` настройки переехали в переменные окружения.

## ⚠️ Пароль сегодня ничего не включает

`configure.sh` пишет пользовательский конфиг с `auth: none` и
`bind-addr: 0.0.0.0:<порт>` **всегда**, каким бы ни был `PASSWORD`.
То есть `CODE_SERVER_PASSWORD=секрет` меняет содержимое `config.yaml`
расширения и снимает предупреждение при сборке, но сервер всё равно
поднимается открытым: любой, кто достаёт до машины по сети, получает шелл
от имени пользователя code-server.

Само расширение это отчасти признаёт — при `PASSWORD != none`
`configure.sh` пишет в журнал `Note: PASSWORD is set in config but
authentication is disabled`. Читать этот журнал приходится уже на
устройстве, поэтому оговорка вынесена сюда.

Пока это так, единственные честные способы закрыть доступ — сетевой
(firewall, SSH-туннель) либо собственный `~/.config/code-server/config.yaml`,
положенный через cloud-init поверх сгенерированного.

Пароль вдобавок лежит в образе открытым текстом — и в `/opt/vmsetup`,
и в пользовательском конфиге. Кто получит образ, получит и пароль; установка
говорит об этом предупреждением, но сам пароль в журнал не печатает: журнал
сборки уезжает в CI и в переписку чаще, чем образ.

## Конфигурация (`config.yaml`)

| Параметр | Описание | По умолчанию |
| --- | --- | --- |
| `USER` | пользователь, от которого запускается code-server | пусто — из cloud-init |
| `PASSWORD` | см. оговорку выше | `none` |
| `PORT` | порт | `9001` |
| `VERSION` | версия code-server | `4.135.0` |

Файл читает **не** `install.sh` на сборке, а `configure.sh` на первой
загрузке — оттуда же берутся `bind-addr` и `auth`. Поэтому параметры из
VMFILE перезаписывают файл в фазе сборки, а не подменяют механизм.

Заменить его целиком можно через cloud-init:

```yaml
#cloud-config
write_files:
  - path: /opt/vmsetup/code-server/config.yaml
    content: |
      USER: developer
      PASSWORD: none
      PORT: 9443
      VERSION: 4.135.0
```

## Архитектуры

`amd64` и `arm64`. Ограничение вносил не code-server, а mkcert: ссылка была
прибита к `mkcert-v1.4.4-linux-amd64`, и проверка ELF роняла сборку на arm64.
Замер 2026-09-03: релиз v1.4.4 публикует и `-linux-arm64`, и `-linux-arm`, —
выбирать было из чего. Ссылка стала зависеть от `dpkg --print-architecture`
(у dpkg тот же словарь, что у релизов mkcert; `uname` пришлось бы переводить
таблицей), ограничение снято.

`armhf` в манифесте **нет**, хотя mkcert его публикует: 32-битные цели
проектом не собираются и не проверялись, а объявить архитектуру — значит
пообещать, что она работает.

## Подключение в VMFILE

```vmfile
EXTENSION code-server CODE_SERVER_PORT=9002
```

Прежняя запись продолжает работать:

```vmfile
COPY_IN <чекаут>/extensions/debian/code-server:/opt/vmsetup/
RUN_COMMAND chmod +x /opt/vmsetup/code-server/*.sh
RUN_COMMAND CODE_SERVER_PORT=9002 /opt/vmsetup/code-server/install.sh
```

`<чекаут>` — путь до чекаута этого репозитория **относительно каталога
VMFILE**; в примерах основного репозитория это `../../../../bisquite-extensions`,
и глубина зависит от того, насколько глубоко лежит сам VMFILE.

Версию можно задать и ключом — он сильнее переменной окружения:

```vmfile
RUN_COMMAND /opt/vmsetup/code-server/install.sh --version 4.135.0
```

## Требования

- Debian 12 / Ubuntu 22.04+ со `systemd` и `cloud-init`;
- сеть при сборке: и mkcert, и установщик code-server качаются;
- свободный TCP-порт на устройстве.

## Как это работает

1. **Сборка** — `install.sh` ставит зависимости, mkcert и code-server,
   перезаписывает `config.yaml` из VMFILE, включает oneshot-сервис.
2. **Первая загрузка** — `configure-code-server.service` ждёт сети, ждёт
   пользователя, выпускает сертификаты, пишет пользовательский конфиг
   и поднимает `code-server@<пользователь>.service`.
3. **Повторные загрузки** — `configure.sh` сверяет mtime
   `/var/lib/cloud/instance/user-data.txt` с меткой
   `/var/lib/code-server/last-config-time` и **ничего не делает**, если
   user-data не менялись. Это не идемпотентность ради идемпотентности:
   без такой сверки каждая загрузка перевыпускала бы сертификат.
4. **Переконфигурация вручную** — поправьте
   `/opt/vmsetup/code-server/config.yaml` **в госте** и выполните
   `sudo systemctl restart configure-code-server`. Правка того же файла
   в кеше источников на хосте не сделает ничего: в образе уже лежит копия.

## Диагностика

```bash
systemctl status configure-code-server.service
systemctl status code-server@<user>.service

journalctl -u configure-code-server -f
journalctl -u code-server@<user> -f

ls -la /home/<user>/.local/share/code-server/certs/
cat /home/<user>/.config/code-server/config.yaml
```

Не стартует — проверьте, что порт свободен (`ss -tlnp | grep 9001`)
и что в каталоге сертификатов лежат `localhost.crt` и `localhost.key`.

Сервис не переконфигурируется после правки — снимите метку:
`sudo rm /var/lib/code-server/last-config-time` и перезапустите
`configure-code-server`. Иначе сработает сверка из пункта 3.

## Лицензия

Расширение распространяется на условиях публичной некоммерческой лицензии
Bisquite (PolyForm Noncommercial 1.0.0, см. `LICENSE`). Для коммерческого
использования требуется отдельная платная лицензия — см. `COMMERCIAL-LICENSE.md`.
