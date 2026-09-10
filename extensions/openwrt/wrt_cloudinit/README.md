# wrt.cloudinit

`wrt.cloudinit` — init-скрипт OpenWrt, имитирующий cloud-init (NoCloud).
Монтирует seed в `/mnt/cidata` и настраивает систему по
`meta-data` / `user-data` / `network-config`: имя хоста, пользователей,
пароль root, SSH-ключи, сеть с мостовыми LAN, firewall, LuCI и команды
первой загрузки.

Это **не расширение** в смысле `docs/extensions.md`: манифеста `extension.yaml`
и `install.sh` у каталога нет, инструкция `EXTENSION` к нему не применима
(разбор — в разделе «Как подключить к образу»). Доставка — `COPY_IN` и
`UPLOAD` по конкретным путям.

## Два источника seed и два формата

**Источников seed два, и оба проверяются по очереди:**

1. `/dev/sr0` — ISO, который вешает Proxmox (`ide2: …:cloudinit,media=cdrom`);
2. блочное устройство с меткой `cidata` — FAT32-раздел в конце носителя,
   который создаёт `bs device write`. Раньше он не искался вовсе, и карта,
   записанная бисквитом, приезжала без пользователя, пароля и сети.
   Устройство ищется через `block info` (пакет `block-mount`, есть всегда)
   и через `blkid` (есть не всегда).

Seed не нашёлся — в журнал уходит `cidata not found – skip`, и **сеть
не трогается**: это не отказ, а «настраивать нечего».

**Форматов seed тоже два, и поддержаны оба.** Это существенно: раньше
читался только диалект Proxmox, и у двух форматов пересекался ровно один
ключ — `hostname`. Поэтому карта от `bs device write` давала имя хоста
и больше ничего: пользователь, пароль и сеть молча не применялись.

| | диалект Proxmox | формат bisquite |
|---|---|---|
| кто пишет | сам гипервизор при `bs compose up` | `bs device write` (`CloudInitGenerator`) |
| пользователь | плоские `user:` и `password:` | список `users:` с `hashed_passwd` |
| пароль root | — | `chpasswd: list: - root:<хеш>` |
| SSH-ключи | `ssh_authorized_keys` внутри `users:` | то же |
| команды | `/usr/libexec/bisquite-firstboot.sh` от адаптера Proxmox | `runcmd:` |
| `network-config` | **version 1** (`type: physical`) | **version 2** (`ethernets:`) |

Версия `network-config` определяется по содержимому (`netcfg_version`:
`version: 2` плюс `ethernets:`), а не задаётся снаружи, и дальше разбор идёт
через `parse_netcfg_any` / `read_dns_any`. Вызывающий код версий не различает
вовсе — оба парсера отдают один и тот же вид строк `iface|proto|ip|mask|gw`.

**Одна асимметрия, про которую надо знать.** Ветка плоских ключей
(`user:`/`password:`) заканчивает разбор `user-data` сразу после установки
ключей: `chpasswd` и `runcmd` в этом случае **не обрабатываются**. Они
читаются только на ветке списка `users:`. Практически это не мешает —
Proxmox таких ключей и не пишет, — но сид, смешавший оба диалекта, получит
не всё.

## Поведение: provision-once

Скрипт запускается на **каждом** буте (`START=47`), но **полный провижн
выполняется один раз на инстанс** — как настоящий cloud-init:

- `instance-id` берётся из `meta-data` (нет — подставляется `nocloud`)
  и сохраняется в `/etc/wrt-cloudinit/instance-id`;
- **id совпал** → провижн пропускается (per-boot only). Ручные правки
  (Wi-Fi, firewall, доп. порты моста) **не затираются** на ребуте;
- **id отличается / нет файла** → полный провижн; маркер пишется **только
  при успехе** (сбой сети → повтор на следующем буте, и команды `runcmd`
  в этот прогон не выполняются тоже);
- Re-provision происходит только при смене `instance-id` (Proxmox меняет его
  при изменении cloud-init конфига ВМ).

Каталог состояния переопределяется переменной `WRT_STATE_DIR` — это сделано
для тестов, в госте его менять незачем.

В конце любого пути (включая `FATAL` и «seed не найден») скрипт ставит флаг
`/run/wrt-cloudinit.ready`. Он означает «агент отработал, больше сеть
не изменится»; потребителя в этом репозитории у флага нет — он для внешних
ожидающих.

## Что именно применяется

### `user-data`

- **`hostname` / `fqdn`** → `uci set system.@system[0].hostname` **и
  `uci commit system`**. Коммит обязателен: без него имя остаётся в staging,
  а staging лежит в tmpfs — и пропадает на ближайшей перезагрузке, которых
  образ по замыслу делает до двух (`70-rootpt-resize`, `80-rootfs-resize`).
- **Пользователи.** Плоская пара `user:`/`password:` либо список `users:`
  (предпочитается `hashed_passwd`, затем `passwd`). Готовый хеш — всё, что
  начинается с `$` — пропускается как есть; открытый пароль хешируется
  первым доступным из `mkpasswd -m sha512`, `openssl passwd -6`, `python3`
  (`crypt` со своей солью). Пользователь без пароля не создаётся — только
  строка в журнал.
- **Что значит «создать пользователя»**: запись в `/etc/passwd`
  (shell `/bin/ash`, дом `/home/<имя>`, uid и gid с 1000), запись
  в `/etc/shadow`, домашний каталог с правами `750`, и секция
  `rpcd.<имя>` типа `login` с ACL `read`/`write` `*` — без неё в LuCI
  и ubus пароль не принимается. Имя `root` и имена с символами вне
  `[a-zA-Z0-9_-]`, а также длиннее 32 символов отвергаются.
- **Пароль root** — из `chpasswd: list: - root:<хеш>`. Бисквит пишет его
  именно так, а не в списке `users:`; раньше это не читалось, и устройство
  приезжало с **пустым** паролем root, то есть в дефолтном состоянии
  OpenWrt, хотя манифест просил другое. Плюс `ensure_root_rpcd_login`
  регистрирует `root` в `rpcd` — чтобы веб принимал пароль, пропечённый
  через `virt-customize --root-password`.
- **SSH-ключи** — `ssh_authorized_keys` пользователя. Кладутся в два места:
  `~/.ssh/authorized_keys` и `/etc/dropbear/authorized_keys`, потому что
  dropbear на OpenWrt читает оба. Записываются **дописыванием**: при
  re-provision (смена `instance-id`) ключи продублируются.
- **`runcmd`** — выгружается в `/usr/libexec/bisquite-firstboot.sh`, то есть
  в тот же файл, который наполняет адаптер Proxmox; отдельного механизма для
  команд нет намеренно. Если файл уже непустой (его положил адаптер),
  `runcmd` не перетирает его. Выполняется он **после** user-data и сети,
  логируется через `logger` и удаляется после запуска.

### `network-config`

- **Валидация до purge.** Если разбор не даёт хотя бы одного интерфейса
  (WAN), деструктивный `purge` не выполняется — рабочая сеть сохраняется,
  в журнал уходит строка, провижн считается неудачным и повторится
  на следующем буте.
- **DNS/search** — первый `nameserver` и первый домен поиска, в
  `/etc/resolv.conf.head` и копией в `/etc/resolv.conf`. Второй и дальше
  адреса игнорируются.
- **WAN — первый интерфейс списка** (`eth0`), поднимается голым устройством:
  `static` с адресом, маской и шлюзом либо `dhcp`. При заданном DNS ему
  ставится `peerdns=0`.
- **LAN — все остальные**, и каждый **через мост**: `br-lan`, `br-lan1`,
  `br-lan2`… (uci-секции `br_lan`, `br_lan1` — без дефисов, netdev с дефисом).
  Мост нужен, чтобы к LAN можно было добавлять Wi-Fi AP (`phy*-ap*`
  с `network=lan` входит в мост сам) и дополнительные порты.
  `static` → плюс DHCP-сервер (`start 10`, `limit 150`, `leasetime 12h`);
  `dhcp4` → клиент.
- **`network`, `dhcp`, `firewall` пересоздаются целиком** (`purge_package`),
  а `uhttpd` переписывается в части адресов. Это и есть причина, по которой
  провижн делается один раз: иначе ручные правки сети терялись бы на каждом
  ребуте.

### Firewall и LuCI: устройство открыто со стороны WAN

Сказать это прямо важнее, чем кратко. Пересобранный firewall выглядит так:

| Что | Значение |
|---|---|
| `defaults` | `input ACCEPT`, `output ACCEPT`, `forward DROP`, `synflood_protect=1` |
| зона `lan` | `input/output/forward ACCEPT`, устройства — все `br-lan*` |
| зона `wan` | **`input ACCEPT`**, `output ACCEPT`, `forward DROP`, `masq=1`, `mtu_fix=1` |
| правило | `Allow-LuCI-from-WAN`: tcp 80/443 из `wan` → ACCEPT |
| `uhttpd` | слушает `0.0.0.0:80` и `0.0.0.0:443`, `rfc1918_filter=0` |

То есть **службы роутера доступны из WAN-сети, а не только из LAN**, и LuCI
в том числе. Для стенда на Proxmox, где WAN — это внутренняя сеть
гипервизора, это осознанный выбор: иначе до свежеразвёрнутого роутера
не дотянуться вовсе. Для устройства, которое смотрит в недоверенную сеть,
это **не то, что нужно**: закрывайте зону `wan` (`input DROP`) и снимайте
правило LuCI после первой настройки — провижн-once их больше не вернёт,
пока не сменится `instance-id`.

Сертификат для HTTPS генерируется `keygen.sh`, если его нет. Не получилось —
`redirect_https=0` и `listen_https` снимается, то есть LuCI остаётся на HTTP,
а не становится недоступной.

## Структура

Чистые парсеры вынесены в библиотеку и подключаются на рантайме:

```
wrt_cloudinit/
├── wrt.cloudinit          → /etc/init.d/wrt.cloudinit   (init, сайд-эффекты, генерация uci)
├── lib/                   → /usr/lib/wrt-cloudinit/lib/  (чистые функции, без uci/mount)
│   ├── parse.sh           разбор обоих форматов seed
│   └── state.sh           WRT_STATE_DIR, already_provisioned, mark_provisioned
└── tests/                 (в образ НЕ попадает; гоняется на билд-хосте)
    ├── run-tests.sh
    └── fixtures/          wan-dhcp-lan-static, wan-static-lan-static, multi-lan (Proxmox v1)
                           bisquite-device-write (формат bisquite: users, chpasswd, v2)
```

Что есть в `lib/parse.sh`:

| Функция | Отдаёт |
|---|---|
| `parse_netcfg` | v1 Proxmox → `iface\|proto\|ip\|mask\|gw` |
| `parse_netcfg_v2` | v2 bisquite, тот же вид строк (префикс `/24` разворачивается в маску) |
| `netcfg_version`, `parse_netcfg_any` | выбор версии по содержимому и разбор |
| `read_dns`, `read_dns_v2`, `read_dns_any` | `DNS\|search` |
| `validate_netcfg` | есть ли хотя бы один интерфейс |
| `get_seed_instance_id` | `instance-id` из `meta-data` |
| `parse_users` | `name\|hash` из списка `users:` |
| `parse_ssh_keys` | ключи конкретного пользователя |
| `parse_root_password` | хеш из `chpasswd: list: - root:…` |
| `parse_runcmd` | строки из `runcmd:` |

Init-скрипт сорсит **все `*.sh` из `/usr/lib/wrt-cloudinit/lib/`** (см. `WRT_LIBDIR`);
если библиотек нет — `FATAL` и выход **без** изменения сети.

## Как подключить к образу

Инструкция `EXTENSION` здесь **не применима**: `OpenWrtBuilder` блокирует её
целиком — расширения рассчитаны на apt и systemd, а `wrt.cloudinit` вообще
доставляется не каталогом в `/opt/vmsetup`, а файлами по конкретным путям.
Манифеста `extension.yaml` у каталога поэтому нет; разбор — в
`docs/extensions.md`.

В VMFILE (живой пример — `examples/build/amd64/openwrt/openwrt.vmfile`
основного репозитория):

```vmfile
# Завершающий '/' в dest обязателен — иначе virt-customize --copy-in
# падает «target is not a directory» (билдер создаёт только этот каталог при '/').
COPY_IN <чекаут>/extensions/openwrt/wrt_cloudinit/lib:/usr/lib/wrt-cloudinit/
UPLOAD  <чекаут>/extensions/openwrt/wrt_cloudinit/wrt.cloudinit:/etc/init.d/wrt.cloudinit
RUN_COMMAND chmod +x /etc/init.d/wrt.cloudinit && \
            /etc/init.d/wrt.cloudinit enable
```

`<чекаут>` — путь до чекаута этого репозитория **относительно каталога
VMFILE**; в `examples/build/amd64/openwrt/openwrt.vmfile` это
`../../../../bisquite-extensions`.

`COPY_IN` должен идти **до** `UPLOAD`/`enable` (lib обязана быть в образе к моменту
включения сервиса). `WRT_LIBDIR=/usr/lib/wrt-cloudinit/lib` в init-скрипте должен
совпадать с местом, куда `COPY_IN` кладёт `lib/`.

Библиотека обязательна: без неё `wrt.cloudinit` на первой загрузке пишет
`FATAL: нет lib` и выходит **не трогая сеть**, а не настраивает её наполовину.

Bisquite сам подключает cloud-init ISO в Proxmox (`ide2: <storage>:cloudinit,media=cdrom`).

## Тесты

```sh
sh tests/run-tests.sh
```

Гоняется на билд-хосте (POSIX sh + awk + shellcheck), без OpenWrt:
`shellcheck -s dash` и `sh -n` по `wrt.cloudinit` и `lib/*.sh`, плюс юниты
парсеров и state-хелперов.

Покрыты: `parse_netcfg` на трёх фикстурах Proxmox, `netcfg_version` и
`parse_netcfg_any` на обеих версиях, `parse_users` и `parse_ssh_keys`
на фикстуре bisquite (плюс контроль «у сида Proxmox списка `users:` нет —
парсер обязан молчать, а не выдумывать пользователя»), `read_dns`,
`get_seed_instance_id`, `validate_netcfg`, `already_provisioned` /
`mark_provisioned`.

Не покрыты: `parse_root_password`, `parse_runcmd` и `read_dns_v2` — юнитов
на них нет, хотя фикстура `bisquite-device-write` нужные данные содержит.
Фикстура снята с настоящего `CloudInitGenerator`, а не написана руками:
иначе тест проверял бы представление автора о формате, а не сам формат.

## Отладка

- Логи: `logread -e wrt.cloudinit` (решение provision/skip, какие
  интерфейсы/мосты, каждый созданный пользователь).
- Состояние provision-once: `cat /etc/wrt-cloudinit/instance-id`.
- Флаг «агент отработал»: `ls /run/wrt-cloudinit.ready`.
- Библиотеки в образе: `ls /usr/lib/wrt-cloudinit/lib/` (должны быть `parse.sh`, `state.sh`;
  иначе в логе будет `FATAL: нет lib`).
- Смонтированный seed — `/mnt/cidata` (отмонтируется после применения;
  если каталог остался смонтированным, провижн оборвался на середине).
- Проверить разбор своего сида, не загружая плату:
  `sh -c '. lib/parse.sh; parse_netcfg_any путь/network-config; parse_users путь/user-data'`.
- Повторный прогон без ребута: `/etc/init.d/wrt.cloudinit start` (учти guard по
  `instance-id` — провижн повторится, только если id новый или удалить файл состояния).
