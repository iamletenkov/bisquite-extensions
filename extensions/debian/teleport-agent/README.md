# teleport-agent

Агент Teleport на машине: SSH-нода и веб-приложения, без входящих портов —
агент сам держит обратный туннель к прокси на 443.

> **С 3.0.0 агент — отдельный проект.** CLI `bisquite-teleport`, юниты и
> схема домена `teleport` переехали в открытый репозиторий
> [bisquite-teleport-agent](https://github.com/iamletenkov/bisquite-teleport-agent)
> и ставятся пакетом `bisquite-teleport-agent_<версия>_all.deb`. Документация
> агента (join, `bound_keypair`, метки с портала, `os_logins`, приложения,
> файлы) — в README того репозитория. Это расширение — тонкая обёртка: кладёт
> бинарь Teleport, как прежде, и ставит пакет агента по закреплённой версии и
> sha256. Пути `/etc/bisquite/teleport`, контракт `apps.d`, ключи `join` и
> метка `managed_by=bisquite-teleport-agent` не изменились; CLI теперь
> `/usr/sbin/bisquite-teleport` (`/usr/local/sbin/bisquite-teleport` у
> роботов 2.x остаётся ссылкой на него).

Образ **нейтрален к кластеру**: на сборке ставятся бинарь и пакет агента, а
адрес кластера, `env` и токен задаются на устройстве одной командой. Агент на
сборке **не запускается**; `install.sh` отказывает, если в образе уже есть
регистрация в `/var/lib/teleport`.

## Сборка

```
EXTENSION teleport-agent TELEPORT_VERSION=18.10.0 \
    TELEPORT_MIRROR=https://binaries.example.org
```

| Параметр | Умолчание | Что делает |
|---|---|---|
| `TELEPORT_VERSION` | `18.10.0` | версия Teleport; **не новее кластера**, не старше на мажор; для `bound_keypair` — не ниже 18.8.0 |
| `TELEPORT_MIRROR` | пусто | зеркало бинарей: `<база>/binaries/teleport/<версия>/teleport-v<версия>-linux-<arch>-bin.tar.gz`; пусто — `cdn.teleport.dev` |
| `TELEPORT_SHA256` | пусто | хеш tarball; пусто — `.sha256` с `cdn.teleport.dev` (второй канал, если tarball с зеркала) |
| `AGENT_VERSION` | `3.0.0` | версия пакета `bisquite-teleport-agent` |
| `AGENT_SHA256` | пин версии по умолчанию | sha256 `.deb`; для другой версии обязателен — без суммы пакет не скачивается |
| `AGENT_SHA256_<ARCH>` | пусто | сумма для архитектуры (`AMD64`, `ARM64`), сильнее `AGENT_SHA256`; пакет сейчас `_all`, сумма одна |
| `AGENT_MIRROR` | пусто | база зеркала: `<база>/bisquite-teleport-agent_<версия>_all.deb` (например, `/dist/teleport/` портала) |
| `AGENT_URL` | пусто | полный адрес `.deb`, сильнее `AGENT_MIRROR`; по умолчанию — релиз GitHub `…/releases/download/v<версия>/<файл>` |

Архитектура tarball — из `dpkg --print-architecture`: `amd64` или `arm64`.
32-битный `armhf` манифест не объявляет, и `install.sh` на нём отказывает.

**Своя сборка Teleport на зеркале.** Tarball пересобранного форка той же
версии — не тот, что описывает `.sha256` с CDN; для форка `TELEPORT_SHA256`
задают явно — хешем tarball зеркала под архитектуру образа. Агенту форк не
нужен, если патчи форка касаются только auth/proxy.

Ставится только `teleport` (308 МБ на arm64): `tsh`, `tctl`, `tbot` ноде не
нужны.

## Подключение — на устройстве

Из манифеста записи (`firstboot-commands`):

```yaml
firstboot-commands:
  - "echo '<токен>' | bisquite-teleport join TELEPORT_PROXY=teleport.example.org TELEPORT_TOKEN=- TELEPORT_ENV=dst"
  - "printf '%s' '<токен меток>' | bisquite-teleport labels-enable URL=https://<портал>/robot-api/v1/labels || true"
```

Ключи `join`, метод `bound_keypair` и метки с портала — README
[bisquite-teleport-agent](https://github.com/iamletenkov/bisquite-teleport-agent).

## Обновление на работающих роботах — `update.sh`

Робот, прошитый образом с teleport-agent 2.x, переходит на пакет без
пересборки образа и без новой регистрации:

```bash
git archive <коммит> extensions/debian/teleport-agent | gzip -n > teleport-agent.tar.gz
# на роботе, после сверки суммы архива:
mkdir /tmp/ta && tar -xzf teleport-agent.tar.gz -C /tmp/ta
sudo AGENT_MIRROR=https://<портал>/dist/teleport bash /tmp/ta/extensions/debian/teleport-agent/update.sh
```

Без `AGENT_MIRROR`/`AGENT_URL` пакет качается с GitHub; `AGENT_DEB=<файл>` —
готовый `.deb` рядом (сумма сверяется так же). `update.sh` сверяет sha256 до
установки и ставит пакет `dpkg -i`; его `postinst` переносит копии юнитов 2.x
из `/etc/systemd/system`, сохраняет включённые юниты и ссылку
`/usr/local/sbin/bisquite-teleport`, не трогает конфиг, регистрацию, токен
меток и работающий агент. Бинарь Teleport `update.sh` не меняет. Каталог
расширения 2.x (`/opt/bisquite/teleport-agent`) остаётся на диске.

## Контракт apps.d

Расширения публикуют свои веб-приложения файлом
`/etc/bisquite/teleport/apps.d/<имя>.conf` (`NAME=`, `URI=` на петле,
необязательный `ICON=`); формат и проверки — README агента. Сегодня
объявляют: `code-server` (с 1.1.0, `ICON=laptop` с 3.0.1), `selkies`
(с 2.1.0, `ICON=desktop` с 4.0.3).
