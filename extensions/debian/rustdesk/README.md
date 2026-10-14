# rustdesk

Удалённый доступ RustDesk: пакет `.deb` с GitHub по версии и sha256, служба
`rustdesk` в автозапуске, адреса **своего** сервера RustDesk — из настроек
устройства, а не из образа.

Образ один на флот и без секретов: **адресов и ключа сервера в образе нет**,
и **нет идентичности RustDesk** (`RustDesk.toml` с ID, парой ключей и
паролем). ID каждое устройство делает себе само при первом старте службы — из
`/etc/machine-id`, который сбрасывает завершающий `virt-sysprep` сборки.

## Что ставится

| Фаза | Что |
|---|---|
| build | `rustdesk-<версия>-x86_64.deb` (sha256 сверяется до установки, зависимости — apt); юнит `/usr/lib/systemd/system/rustdesk.service` (postinst пакета кладёт его только когда PID 1 — systemd, в appliance сборки — нет); `configure-rustdesk.service`; обе службы включены; удаляются `RustDesk*.toml` у `/root`, `/etc/skel` и пользователей с UID ≥ 1000 — **сборка отказывает**, если они остались |
| каждая загрузка | `configure-rustdesk.service` (после cloud-init, **до** `rustdesk.service`) пишет `[options]` в `RustDesk2.toml`; пока RustDesk не запускался у кого-то из пользователей (нет `RustDesk.toml`) или значения пришлось вернуть — повторная сверка через минуту, не больше 10 раз (первый запуск RustDesk на свежей машине переписывал `RustDesk2.toml` своими умолчаниями) |

Что пишется, если значение задано:

```toml
[options]
custom-rendezvous-server = 'rustdesk.example.com'
relay-server = 'rustdesk.example.com:21117'
api-server = 'http://rustdesk.example.com:21114'
key = '<открытый ключ сервера>'
```

в `/root/.config/rustdesk/RustDesk2.toml` (его читает служба) и в
`~/.config/rustdesk/RustDesk2.toml` каждого пользователя с UID 1000…65533 и
домашним каталогом. Владелец файла — пользователь: запись идёт **от его
имени** (`runuser`), подложенная в домашний каталог ссылка не заставит root
читать или писать чужой файл. Остальные ключи и таблицы файла остаются, как
их записал RustDesk. Изменился хоть один файл — `rustdesk.service`
перезапускается (`--no-block`), если он запущен.

Правила пустых значений:

- **все пусты и никогда не задавались** — ни один файл не создаётся и не
  меняется, RustDesk работает с публичными серверами;
- пустой ключ, который скрипт **сам** ставил раньше
  (`/var/lib/bisquite/rustdesk/managed`), из файлов убирается — так
  возвращаются к публичным умолчаниям;
- пустой ключ, который ставил не скрипт (руками в RustDesk), не трогается.

## Настройки

### Сборки (переменные `install.sh`, в устройство не попадают)

| Параметр | Умолчание | Что |
|---|---|---|
| `RUSTDESK_VERSION` | `1.5.0` | тег релиза `github.com/rustdesk/rustdesk` |
| `RUSTDESK_SHA256` | закреплён для `1.5.0` | sha256 `rustdesk-<версия>-x86_64.deb` (digest на странице релиза); для другой версии обязателен |
| `RUSTDESK_URL` | пусто | полный адрес `.deb` на зеркале; пусто — ассет релиза GitHub |

### Устройства: домен `rustdesk`

Файл `/etc/bisquite/rustdesk/config`, схема — `knobs`. Все умолчания пустые.

| Ключ | Поле RustDesk (Settings → Network) | Формат |
|---|---|---|
| `RUSTDESK_ID_SERVER` | ID server — `custom-rendezvous-server` | `хост[:порт]` |
| `RUSTDESK_RELAY_SERVER` | Relay server — `relay-server` | `хост[:порт]` |
| `RUSTDESK_API_SERVER` | API server — `api-server` | `http(s)://хост[:порт][/путь]` |
| `RUSTDESK_KEY` | Key — `key` | открытый ключ сервера (base64, `id_ed25519.pub` hbbs) — **не секрет**, задаётся аргументом |

Значения проверяются схемой: кавычки, пробелы и `$` в них невозможны.
Технически ключи можно передать и в `EXTENSION rustdesk RUSTDESK_ID_SERVER=…`,
но тогда адреса окажутся в образе — для образа рабочей машины так не делаем.

## Сборка

```vmfile
EXTENSION rustdesk
EXTENSION rustdesk RUSTDESK_VERSION=1.5.0 RUSTDESK_SHA256=<64 hex>
```

## Манифест записи / развёртывания

Строка первой загрузки (`firstboot-commands` манифеста записи,
`firstboot_commands` манифеста развёртывания ВМ); ключ — заглушка:

```yaml
firstboot-commands:
  - >-
    bisquite-conf set --apply rustdesk
    RUSTDESK_ID_SERVER=rustdesk.example.com
    RUSTDESK_RELAY_SERVER=rustdesk.example.com:21117
    RUSTDESK_API_SERVER=http://rustdesk.example.com:21114
    RUSTDESK_KEY=<открытый ключ сервера>
```

Хук `--apply` неблокирующий и идемпотентный: ставит в очередь
`systemctl --no-block restart configure-rustdesk`, тот переписывает файлы
(к этому моменту cloud-init уже создал пользователя) и перезапускает
`rustdesk`. Без `--apply` значения прочтутся на следующей загрузке.

## На работающей машине

```bash
bisquite-conf show rustdesk
sudo bisquite-conf set rustdesk RUSTDESK_ID_SERVER=rustdesk.example.com RUSTDESK_KEY=<ключ>
sudo systemctl restart configure-rustdesk     # перерендерить вручную (то же делает хук)
journalctl -u configure-rustdesk
```

Новый пользователь получит файл на следующей загрузке или после
`sudo systemctl restart configure-rustdesk`. Открытый у пользователя клиент
RustDesk держит настройки в памяти — увидит новые после перезапуска клиента.

## Проверка

```bash
systemctl is-active rustdesk                         # active
sudo grep -A4 '^\[options\]' /root/.config/rustdesk/RustDesk2.toml
grep -A4 '^\[options\]' ~/.config/rustdesk/RustDesk2.toml
rustdesk --get-id                                    # у каждого устройства свой
```

и в клиенте: Settings → Network → ID/Relay server — прописан свой сервер.

Проверено в контейнере `ubuntu:24.04`: установка 1.5.0 со сверкой sha256,
юнит и `enable` без systemd, удаление подложенных `RustDesk.toml`, отказ без
sha256 для чужой версии, рендер для root и пользователя UID 1000 (владелец,
`0600`, чужие ключи и таблицы целы), идемпотентность, снятие очищенных
ключей, отказ на ссылке в домашнем каталоге; в systemd-контейнере —
`bisquite-conf set --apply` из манифеста и рендер при загрузке.
