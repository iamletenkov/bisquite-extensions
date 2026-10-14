# firewall

Файрвол машины на nftables: своя таблица `inet bisquite`, входящее —
только разрешённое, исходящее — всё. Правила — файлы в
`/etc/bisquite/firewall/rules.d/`, применяются службой `bisquite-firewall`
**при каждой загрузке** (до сети) и по `systemctl restart`.

## Что ставится

| Фаза | Что |
|---|---|
| build | пакет `nftables`; `/etc/bisquite/firewall/rules.d/10-defaults.nft` (если его ещё нет); `bisquite-firewall.service` (включён, `WantedBy=sysinit.target`, `Before=network-pre.target`); команда `/usr/local/sbin/bisquite-firewall` |
| каждая загрузка | `configure.sh apply`: таблица собирается заново одной транзакцией `nft -f` |

Правила по умолчанию (`10-defaults.nft`):

- петля (`lo`) — всё;
- ответы на исходящие соединения (`ct state established,related`), `invalid` — drop;
- UDP 7400–32000 на `127.0.0.1` (DDS/ROS 2);
- ICMPv6 обнаружения соседей (без них не работает IPv6, в т.ч. исходящий);
- остальное входящее — `policy drop`; исходящее — `policy accept`.

SSH, ping и прочие входящие закрыты: доступ к машине — через агент Teleport
(исходящий туннель) или своим файлом правил.

### Docker не задевается

`flush ruleset` не делается никогда: Docker держит свои цепочки в таблицах
iptables-nft (`ip filter`, `ip nat`, `ip raw`, …), и сброс всего набора отрезал
бы контейнеры. Наша таблица добавляет только базовую цепочку на хуке
`input`: проброс портов (`-p 8080:80`) идёт через DNAT и `forward`, выход
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

Сами правила — не ключи, а файлы `*.nft` в `/etc/bisquite/firewall/rules.d/`.
Они включаются по алфавиту после пересоздания таблицы, в той же
транзакции; формат — команды nft к таблице `inet bisquite`:

```
# /etc/bisquite/firewall/rules.d/50-ssh.nft
add rule inet bisquite input tcp dport 22 accept
# ping
add rule inet bisquite input icmp type echo-request accept
# служба машины для контейнеров Docker (мост docker0 и сети compose)
add rule inet bisquite input iifname "docker0" tcp dport 8000 accept
add rule inet bisquite input iifname "br-*" tcp dport 8000 accept
```

**Ошибка в любом файле — не применяется ничего из каталога:** грузится
запасной набор (петля и ответы, входящее закрыто), служба уходит в `failed`,
причина — в `journalctl -u bisquite-firewall`. Закрытая машина, а не
открытая. `10-defaults.nft` — тоже файл оператора: повторная установка
(дочерний образ) его не перезаписывает, а предупреждает о расхождении.

## Сборка

```vmfile
EXTENSION firewall
EXTENSION firewall FIREWALL_ENABLE=0      # образ загрузится с выключенным файрволом
```

Свои файлы правил в образ — `COPY_IN`/`UPLOAD` в
`/etc/bisquite/firewall/rules.d/` после `EXTENSION firewall`.

## Манифест записи / развёртывания

`write_files` cloud-init, если манифест его даёт, или строкой первой
загрузки (`firstboot-commands` записи, `firstboot_commands` ВМ):

```yaml
firstboot-commands:
  - "echo 'add rule inet bisquite input tcp dport 22 accept' > /etc/bisquite/firewall/rules.d/50-ssh.nft"
  - "systemctl restart bisquite-firewall"
  # или выключить совсем:
  - "bisquite-conf set --apply firewall FIREWALL_ENABLE=0"
```

## На работающей машине

```bash
sudo bisquite-firewall show              # таблица, как она в ядре
sudoedit /etc/bisquite/firewall/rules.d/50-ssh.nft
sudo bisquite-firewall check             # проверить файлы (nft -c), ничего не применяя
sudo systemctl restart bisquite-firewall # применить (атомарно, без открытого окна)
sudo bisquite-firewall off               # снять до следующей загрузки
sudo bisquite-conf set firewall FIREWALL_ENABLE=0   # выключить насовсем (хук перезапускает службу)
```

`systemctl stop` таблицу не снимает намеренно: остановка внутри `restart`
была бы окном, когда машина открыта.

## Проверка

```bash
systemctl is-active bisquite-firewall           # active
sudo nft list table inet bisquite               # policy drop + правила
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
