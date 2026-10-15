# firewall

Файрвол машины: входящее — только разрешённое, исходящее — всё. Два
бэкенда с одними и теми же правилами по умолчанию:

- **nftables** — своя таблица `inet bisquite`, файлы `*.nft`;
- **iptables** (`iptables-legacy`) — своя цепочка `BISQUITE-INPUT` в таблице
  `filter` IPv4 и IPv6, файлы `*.rules` и `*.rules6`. Для ядер без `nft_ct` —
  прежде всего штатного ядра L4T r36.4.3 на Jetson.

Бэкенд выбирается **при сборке и на каждой загрузке** по списку модулей
ядра (раздел «Выбор бэкенда»). Правила — файлы в
`/etc/bisquite/firewall/rules.d/`, применяются службой `bisquite-firewall`
**при каждой загрузке** (до сети) и по `systemctl restart`.

> **С 1.2.0 — бэкенд iptables.** Раньше на ядре без `nft_ct` сборка
> отказывала; теперь при наличии модулей `iptables-legacy` выбирается он
> (`FIREWALL_BACKEND=auto`). Отказ остался для ядра, где нет ни того, ни
> другого.

## Что ставится

| Фаза | Что |
|---|---|
| build | выбор бэкенда по каждому ядру образа (отказ, если ядро не тянет ни один); пакеты `nftables` и `iptables`; `/etc/bisquite/firewall/rules.d/10-defaults.{nft,rules,rules6}` (если их ещё нет); `/var/lib/bisquite/firewall/backend` — выбор сборки; `bisquite-firewall.service` (включён, `WantedBy=sysinit.target`, `Before=network-pre.target`); команда `/usr/local/sbin/bisquite-firewall` |
| каждая загрузка | `configure.sh apply`: выбор бэкенда по работающему ядру; nftables — таблица заново одной транзакцией `nft -f`; iptables — цепочка заново одной транзакцией `iptables-legacy-restore --noflush` на семейство и один переход первым правилом `INPUT` |

Правила по умолчанию (`10-defaults.nft`; для iptables — `10-defaults.rules`
и `10-defaults.rules6` того же смысла):

- петля (`lo`) — всё;
- ответы на исходящие соединения (`ct state established,related`,
  `-m conntrack --ctstate ESTABLISHED,RELATED`), `invalid` — drop;
- UDP 7400–32000 на `127.0.0.1` (DDS/ROS 2);
- ICMPv6 обнаружения соседей (без них не работает IPv6, в т.ч. исходящий);
- остальное входящее — `policy drop` (iptables — последнее правило цепочки
  `-j DROP`); исходящее — `policy accept` (iptables — `OUTPUT` не трогается).

SSH, ping и прочие входящие закрыты: доступ к машине — через агент Teleport
(исходящий туннель) или своим файлом правил.

### Docker не задевается

`flush ruleset`, `iptables -F` и смена политик не делаются никогда: Docker
держит свои цепочки (`DOCKER`, `DOCKER-USER`, `FORWARD`, таблица `nat`) в
iptables-nft или iptables-legacy, и сброс отрезал бы контейнеры. nftables:
наша таблица добавляет только базовую цепочку на хуке `input`. iptables:
транзакция `--noflush` объявляет и заменяет только `BISQUITE-INPUT`, в
`INPUT` добавляется ровно одно правило `-j BISQUITE-INPUT` (первым;
повторный `apply` его не дублирует), политика `INPUT` остаётся как была.
В обоих случаях проброс портов (`-p 8080:80`) идёт через DNAT и `forward`, выход
контейнеров в сеть — через `forward` и masquerade. Ни то, ни другое в `input`
не попадает. Не пропускается только обращение контейнера к службам **самой
машины** по адресу моста — нужно — своим правилом (пример ниже).

`nftables.service` дистрибутива не включается: его `/etc/nftables.conf`
начинается с `flush ruleset`. Если его включили — `bisquite-firewall` стоит
после него и пересобирает свою таблицу, но цепочки Docker он уже снёс
(лечится `systemctl restart docker`).

## Настройки

Домен `firewall`, файл `/etc/bisquite/firewall/config`, схема — `knobs`.

| Ключ | Умолчание | Что |
|---|---|---|
| `FIREWALL_ENABLE` | `1` | `0` — таблица снимается, входящее не фильтруется |

| `FIREWALL_BACKEND` | `auto` | `auto` — nftables, если в ядре есть `nf_tables` и `nft_ct`, иначе iptables, если есть модули `iptables-legacy`; `nft`, `iptables` — явно |

Смена `FIREWALL_BACKEND` через `bisquite-conf set` перезапускает службу:
новый бэкенд применяется, и только после этого снимается таблица или
цепочка прежнего — окна без файрвола нет.

### Выбор бэкенда

| Бэкенд | Нужно ядру (модуль в `modules.dep` или встроен — `modules.builtin`) |
|---|---|
| nftables | `nf_tables`, `nft_ct` |
| iptables | `ip_tables`, `iptable_filter`, `ip6_tables`, `ip6table_filter`, `nf_conntrack`, `xt_conntrack`, `xt_tcpudp` |

- **Сборка** (`install.sh`, до apt): для каждого ядра образа
  (`/lib/modules/*/` с `modules.order`, не `uname -r` appliance) —
  `auto`: nftables, иначе iptables, иначе **отказ** с перечнем недостающих
  модулей; явное `nft`/`iptables` без своих модулей — тоже отказ. Выбор
  пишется в `/var/lib/bisquite/firewall/backend`. Ядра в образе нет
  (контейнер) — предупреждение, выбирает загрузка.
- **Каждая загрузка** (`configure.sh apply`): то же по ядру `uname -r`
  (`/lib/modules/$(uname -r)`). Списков модулей нет — бэкенд сборки, а без
  него nftables. Явный `FIREWALL_BACKEND`, которого ядро по спискам не
  тянет, всё равно пробуется (оператор так сказал) — с записью в журнал.
  `sudo bisquite-firewall backend` печатает, что выберет `apply`.

**Почему `iptables-legacy`, а не `iptables-nft`.** iptables-nft 1.8.7
(Ubuntu 22.04) не переводит `-m conntrack` в родное nft-выражение: это
`match name conntrack` через `nft_compat`, диапазон портов — `match name udp`
так же, и к каждому правилу добавляется `counter` (замер 2026-10-15,
`nft --debug=netlink`). В штатном ядре L4T нет ни `nft_compat`, ни
`nft_counter` — iptables-nft там правил по умолчанию не загрузит, а все семь
модулей legacy есть. Определить пригодность iptables-nft по спискам модулей
нельзя и в общем случае: на новых ядрах `counter` встроен в `nf_tables`
(на 6.1 `nft_counter.ko` нет).

### Файлы правил nftables (`*.nft`)

Включаются по алфавиту после пересоздания таблицы, в той же транзакции;
формат — команды nft к таблице `inet bisquite`:

```
# /etc/bisquite/firewall/rules.d/50-ssh.nft
add rule inet bisquite input tcp dport 22 accept
# ping
add rule inet bisquite input icmp type echo-request accept
# служба машины для контейнеров Docker (мост docker0 и сети compose)
add rule inet bisquite input iifname "docker0" tcp dport 8000 accept
add rule inet bisquite input iifname "br-*" tcp dport 8000 accept
```

### Файлы правил iptables (`*.rules`, `*.rules6`)

`*.rules` — IPv4 (`iptables-legacy-restore`), `*.rules6` — IPv6
(`ip6tables-legacy-restore`). По алфавиту, одна транзакция на семейство:
своя цепочка объявляется (то есть очищается), затем строки файлов, в конце
`-A BISQUITE-INPUT -j DROP`. Строка — правило **своей цепочки** в синтаксисе
`iptables-restore`, полной формой или краткой (префикс добавится):

```
# /etc/bisquite/firewall/rules.d/50-ssh.rules
-p tcp --dport 22 -j ACCEPT
# ping — то же полной формой
-A BISQUITE-INPUT -p icmp --icmp-type echo-request -j ACCEPT
# служба машины для контейнеров Docker
-i docker0 -p tcp --dport 8000 -j ACCEPT
-i br-+ -p tcp --dport 8000 -j ACCEPT
```

```
# /etc/bisquite/firewall/rules.d/50-ssh.rules6
-p tcp --dport 22 -j ACCEPT
```

Пустые строки и `#` пропускаются. **Ошибка файла** — любая другая команда
(`-A INPUT`, `-I`, `-D`, `-F`, `-X`, `-P`, `-N`, `-t`, `*filter`, `COMMIT`,
`:ЦЕПОЧКА`) или строка не с `-`: файлы не могут тронуть чужие цепочки.
Формат проверяется и при сборке (отказ), и на загрузке.

### Ошибка в файле

**Ошибка в любом файле выбранного бэкенда — не применяется ничего из
каталога:** грузится запасной набор (петля и ответы, входящее закрыто),
служба уходит в `failed`, причина — в `journalctl -u bisquite-firewall`.
Закрытая машина, а не открытая. Файлы другого бэкенда не читаются (`*.nft`
при iptables и наоборот), но при сборке проверяются оба набора.
`10-defaults.*` — тоже файлы оператора: повторная установка (дочерний образ)
их не перезаписывает, а предупреждает о расхождении.

## Сборка

```vmfile
EXTENSION firewall
EXTENSION firewall FIREWALL_ENABLE=0      # образ загрузится с выключенным файрволом
EXTENSION firewall FIREWALL_BACKEND=iptables   # iptables и на ядре с nft_ct
```

Свои файлы правил в образ — `COPY_IN`/`UPLOAD` в
`/etc/bisquite/firewall/rules.d/` после `EXTENSION firewall`.

### Ядро образа и Jetson

**Jetson / L4T: штатное ядро r36.4.3 (`5.15.148-tegra`) собрано без
`CONFIG_NFT_CT`** (а также без `NFT_REJECT`, `NFT_COUNTER`, `NFT_COMPAT`;
`nf_tables` — модулем, конфиг — встроенный в `Image` из `nvidia-l4t-kernel`),
зато все модули `iptables-legacy` есть. `EXTENSION firewall` выбирает там
iptables. Ядро Sensing (расширение `sensing-gmsl2-camera` подменяет
`/boot/Image`, а списки модулей в `/lib/modules/5.15.148-tegra/` остаются
от L4T) на живой плате ещё не проверено: если в нём есть `nft_ct`, сборка
этого не увидит (смотрит на списки), а загрузка — тоже нет, по той же
причине; бэкенд останется iptables, и это рабочий вариант. Узнать на плате:
`zcat /proc/config.gz | grep -E 'NFT_CT|IP_NF_IPTABLES'`.

Docker на том же ядре правилами `-m conntrack` и `-m addrtype` тоже требует
либо `iptables-legacy`, либо `nft_compat`; его цепочки наш бэкенд не
трогает ни в одном из фреймворков.

## Манифест записи / развёртывания

`write_files` cloud-init, если манифест его даёт, или строкой первой
загрузки (`firstboot-commands` записи, `firstboot_commands` ВМ):

```yaml
firstboot-commands:
  - "echo 'add rule inet bisquite input tcp dport 22 accept' > /etc/bisquite/firewall/rules.d/50-ssh.nft"
  # то же для бэкенда iptables (Jetson):
  - "echo '-p tcp --dport 22 -j ACCEPT' > /etc/bisquite/firewall/rules.d/50-ssh.rules"
  - "systemctl restart bisquite-firewall"
  # или выключить совсем:
  - "bisquite-conf set --apply firewall FIREWALL_ENABLE=0"
```

## На работающей машине

```bash
sudo bisquite-firewall show              # бэкенд и наши правила, как они в ядре
sudo bisquite-firewall backend           # какой бэкенд выберет apply и почему
sudoedit /etc/bisquite/firewall/rules.d/50-ssh.nft    # или 50-ssh.rules
sudo bisquite-firewall check             # проверить файлы (nft -c / restore --test), ничего не применяя
sudo systemctl restart bisquite-firewall # применить (атомарно, без открытого окна)
sudo bisquite-firewall off               # снять (таблицу и цепочки) до следующей загрузки
sudo bisquite-conf set firewall FIREWALL_ENABLE=0   # выключить насовсем (хук перезапускает службу)
```

`systemctl stop` таблицу не снимает намеренно: остановка внутри `restart`
была бы окном, когда машина открыта.

## Проверка

```bash
systemctl is-active bisquite-firewall           # active
sudo nft list table inet bisquite               # nftables: policy drop + правила
sudo iptables-legacy -S BISQUITE-INPUT          # iptables: правила, последним -j DROP
sudo iptables-legacy -S INPUT | head -2         # iptables: первым -j BISQUITE-INPUT
sudo nft list tables                            # таблицы Docker на месте
curl -m 3 http://<адрес машины>:<закрытый порт>  # с другой машины: таймаут
docker run --rm -p 8080:80 nginx:alpine          # с другой машины :8080 открыт
docker run --rm alpine wget -qO- http://deb.debian.org >/dev/null && echo ok
```

Проверено в systemd-контейнерах `ubuntu:24.04` (с Docker CE 29.9 из
расширения `docker`) и `debian:12`: порт без правила закрыт снаружи и
открыт с петли; проброс `-p 8080:80`, выход контейнеров в сеть и
`127.0.0.1:8080` работают при включённом файрволе, после
`systemctl restart bisquite-firewall` и после перезапуска dockerd; свой файл
открывает порт; битый файл — запасной набор и `failed`;
`FIREWALL_ENABLE=0/1` через `bisquite-conf`; таблица поднимается при загрузке.

Проверка ядра (1.1.0, 2026-10-15): `ubuntu:22.04` arm64 с раскладкой ядра
L4T r36.4.3 — отказ по `nft_ct` до apt; `debian:12` с ядрами
6.1.0-52/53-amd64 — `nf_tables`, `nft_ct` найдены; `ubuntu:24.04` без ядра —
предупреждение и установка дальше.

Проверка бэкенда iptables (1.2.0, 2026-10-15), `tools/test-firewall.sh` и
контейнерные прогоны:

- **arm64, сборка:** `ubuntu:22.04` arm64 (qemu-user) со списками модулей
  настоящего ядра L4T r36.4.3 (`nvidia-l4t-kernel` 36.4.3) — `auto` выбирает
  iptables, ставятся `nftables`, `iptables` arm64, в `backend` — `iptables`;
  `FIREWALL_BACKEND=nft` — отказ по `nft_ct`; ядро без `ip6_tables` — отказ
  с перечнем; файл `-A INPUT …` — отказ сборки; дочерний образ сохраняет
  правленый `10-defaults.rules`. Применить правила под qemu-user нельзя
  вовсе: он не пропускает ни `IPT_SO_*` (`iptables-legacy`), ни сокет
  netlink netfilter (`nft`) — замер того же дня.
- **применение, iptables:** privileged systemd-контейнер `ubuntu:22.04`
  amd64, где `/lib/modules/$(uname -r)` подменён списками L4T, а ядро хоста
  играет роль ядра робота: служба `active`, бэкенд `iptables`, переход первым
  в `INPUT` (v4, v6), порт без правила снаружи закрыт, с петли открыт,
  исходящее работает; свой `*.rules` открывает порт; два `restart` — переход
  не дублируется; битый файл и файл с `-A INPUT` — `failed` и запасной набор;
  `FIREWALL_BACKEND=nft` — таблица nft, цепочки сняты; `FIREWALL_ENABLE=0` —
  сняты оба; после перезапуска контейнера правила на месте. Подставные
  цепочки Docker (`DOCKER`, `DOCKER-USER`, `FORWARD`, `nat POSTROUTING`, чужое
  правило `INPUT`) в iptables-legacy, ip6tables-legacy и iptables-nft
  сравнивались до и после каждого шага — не изменились.
- **применение, nftables:** тот же контейнер с `/lib/modules` хоста
  (6.1.0-52/53-amd64, `nft_ct` есть) — бэкенд `nft`, прежнее поведение;
  `FIREWALL_BACKEND=iptables` — цепочка вместо таблицы.
