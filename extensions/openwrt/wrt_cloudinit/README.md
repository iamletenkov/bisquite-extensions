# wrt.cloudinit

`wrt.cloudinit` — init-скрипт OpenWrt, имитирующий cloud-init (NoCloud) для образов,
развёртываемых в Proxmox. Читает ISO `cloudinit` (`/dev/sr0`), монтирует в
`/mnt/cidata` и настраивает систему по `meta-data` / `user-data` / `network-config`.

## Поведение: provision-once

Скрипт запускается на **каждом** буте (`START=47`), но **полный провижн выполняется
один раз на инстанс** — как настоящий cloud-init:

- `instance-id` берётся из `meta-data` и сохраняется в `/etc/wrt-cloudinit/instance-id`.
- **id совпал** → провижн пропускается (per-boot only). Ручные правки (Wi-Fi, firewall,
  доп. порты моста) **не затираются** на ребуте.
- **id отличается / нет файла** → полный провижн; маркер пишется **только при успехе**
  (сбой → повтор на следующем буте).
- Re-provision происходит только при смене `instance-id` (Proxmox меняет его при
  изменении cloud-init конфига ВМ).

## Возможности

- **user-data** — `hostname`/`fqdn`, `user`, `password`. Создаёт пользователя, хеширует
  пароль (`mkpasswd`/`openssl`/python) и выдаёт права в LuCI/ubus.
- **root в LuCI** — `ensure_root_rpcd_login` регистрирует `root` в `rpcd`, чтобы веб
  принимал пароль, пропечённый Bisquite через `virt-customize --root-password`.
- **network-config** (Proxmox NoCloud v1) — WAN (`eth0`) поднимается голым интерфейсом;
  каждый LAN — **через мост `br-lan`** (порт-ethernet), чтобы к нему можно было добавлять
  Wi-Fi AP (`phy*-ap*` с `network=lan` входит в мост сам) и доп. порты. Пересоздаёт
  `network`/`dhcp`/`firewall`/`uhttpd`, firewall-зона `lan` матчит `br-lan`, NAT на `wan`.
- **Валидация до purge** — если `network-config` не даёт хотя бы WAN, деструктивный
  `purge` не выполняется (рабочая сеть сохраняется).
- **DNS/search** — читает блок `nameserver`, формирует `/etc/resolv.conf`.
- **firstboot** — если есть `/usr/libexec/bisquite-firstboot.sh`, выполняет его после
  user-data и сетей, логирует через `logger`, удаляет файл.

## Структура

Чистые парсеры вынесены в библиотеку и подключаются на рантайме:

```
wrt_cloudinit/
├── wrt.cloudinit          → /etc/init.d/wrt.cloudinit   (init, сайд-эффекты, генерация uci)
├── lib/                   → /usr/lib/wrt-cloudinit/lib/  (чистые функции, без uci/mount)
│   ├── parse.sh           parse_netcfg, read_dns, get_seed_instance_id, validate_netcfg
│   └── state.sh           WRT_STATE_DIR, already_provisioned, mark_provisioned
└── tests/                 (в образ НЕ попадает; гоняется на билд-хосте)
    ├── run-tests.sh
    └── fixtures/          Proxmox NoCloud v1: wan-dhcp-lan-static, wan-static-lan-static, multi-lan
```

Init-скрипт сорсит **все `*.sh` из `/usr/lib/wrt-cloudinit/lib/`** (см. `WRT_LIBDIR`);
если библиотек нет — `FATAL` и выход **без** изменения сети.

## Как подключить к образу

В VMFILE (см. [openwrt.vmfile](../../../../examples/build/openwrt/openwrt.vmfile)):

```dockerfile
# Завершающий '/' в dest обязателен — иначе virt-customize --copy-in
# падает «target is not a directory» (билдер создаёт только этот каталог при '/').
COPY_IN bisquite-extensions/extensions/openwrt/wrt_cloudinit/lib:/usr/lib/wrt-cloudinit/
UPLOAD  bisquite-extensions/extensions/openwrt/wrt_cloudinit/wrt.cloudinit:/etc/init.d/wrt.cloudinit
RUN_COMMAND chmod +x /etc/init.d/wrt.cloudinit && \
            /etc/init.d/wrt.cloudinit enable
```

`COPY_IN` должен идти **до** `UPLOAD`/`enable` (lib обязана быть в образе к моменту
включения сервиса). `WRT_LIBDIR=/usr/lib/wrt-cloudinit/lib` в init-скрипте должен
совпадать с местом, куда `COPY_IN` кладёт `lib/`.

Bisquite сам подключает cloud-init ISO в Proxmox (`ide2: <storage>:cloudinit,media=cdrom`).

## Формат cloud-init

- `user-data`: минимальный YAML, совместимый с cloud-init NoCloud.
- `network-config`: **version 1** — список `type: physical` с вложенными `type: static`
  или `type: dhcp4`. Первый интерфейс — WAN, остальные — LAN (мост + DHCP-сервер при
  `static`). Этот формат генерит Proxmox при деплое.

## Тесты

```sh
sh tests/run-tests.sh
```
Гоняется на билд-хосте (POSIX sh + awk + shellcheck), без OpenWRT: `shellcheck -s dash`
+ `sh -n` по `wrt.cloudinit` и `lib/*.sh`, плюс юниты парсеров и state-хелперов на
фикстурах Proxmox NoCloud v1.

## Отладка

- Логи: `logread -e wrt.cloudinit` (решение provision/skip, какие интерфейсы/мосты).
- Состояние provision-once: `cat /etc/wrt-cloudinit/instance-id`.
- Библиотеки в образе: `ls /usr/lib/wrt-cloudinit/lib/` (должны быть `parse.sh`, `state.sh`;
  иначе в логе будет `FATAL: нет lib`).
- Смонтированный ISO — `/mnt/cidata` (отмонтируется после применения).
- Повторный прогон без ребута: `/etc/init.d/wrt.cloudinit start` (учти guard по
  `instance-id` — провижн повторится, только если id новый или удалить файл состояния).
