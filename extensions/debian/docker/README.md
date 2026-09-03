# docker

Docker CE из официального apt-репозитория Docker (`download.docker.com`).

## Что делает

**Сборка** (`install.sh`)

- прописывает ключ и репозиторий Docker в формате deb822;
- ставит ровно пять пакетов: `docker-ce`, `docker-ce-cli`, `containerd.io`,
  `docker-buildx-plugin`, `docker-compose-plugin`;
- на Raspberry Pi добавляет `cgroup_enable=memory` в `cmdline.txt`;
- на Jetson подключает репозиторий NVIDIA и настраивает среду выполнения.

**Первая загрузка** (`configure.sh`)

- добавляет пользователя cloud-init в группу `docker` — при сборке имя
  пользователя ещё неизвестно;
- на Jetson перезапускает демон, чтобы подхватилась среда выполнения NVIDIA.

## Почему один путь, а не два

Расширение слито с бывшим `docker-ce` 2026-09-03. Довод «на старых системах
нужен `get.docker.com`, на новых репозиторий» оказался неверен дважды:

- **скрипт ставит из того же репозитория**, только пишет однострочный `.list`
  вместо deb822 (`getdocker.sh:596,606`). Второго источника пакетов никогда
  не было;
- **на bionic скрипт ломает сборку**: `version_gte()` при пустом `VERSION`
  возвращает истину всегда (`getdocker.sh:230-234`), поэтому в список
  безусловно попадает `docker-model-plugin`, которого в репозитории bionic нет
  ни для amd64, ни для arm64. При `set -e` это фатально.

## Почему нет ветвления по дистрибутиву

Замеры 2026-09-03:

- deb822 с `Signed-By: <путь>` работает начиная с apt 1.6.17 (bionic).
  Встроенный ключ требует apt ≥ 2.4 и нигде не нужен;
- 64-битная Raspberry Pi OS объявляет `ID=debian` — её обслуживает
  `linux/debian`. Репозиторий `linux/raspbian` только armhf и без trixie;
- `${UBUNTU_CODENAME:-$VERSION_CODENAME}` покрывает оба семейства одним
  выражением — так написано в инструкциях самого Docker;
- пять имён пакетов одинаковы на всех целях, включая bionic.

Ветвления есть, но они **по признакам железа** и ортогональны системе:
`/boot/firmware/cmdline.txt` и `/etc/nv_tegra_release`. Pi 4 с Ubuntu и
Jetson с JetPack 6 оба дают `ID=ubuntu`.

## Гейт вместо таблицы

Перед установкой скрипт спрашивает `apt-cache policy docker-ce`. Нет
кандидата — **громкий отказ**, без отката на дистрибутивный `docker.io`.

Откат был бы тихим: VMFILE один, а на флот уехали бы образы с разными
движками (`download.docker.com` даёт 29.7.2, `docker.io` — 26.1.5 на
Debian 13 и 20.10.12 на Ubuntu 22.04). Это та же подмена гарантии надеждой,
из-за которой запрещён перенос `INSTALL` в фазу первой загрузки. Нужен
`docker.io` — заводите отдельное расширение под своим именем.

## Замороженные сюиты

Наличие пакета и его свежесть — разные вопросы. Репозиторий для bionic
существует и работает, но заморожен:

```
dists/bionic/Release   Date: 13 Jun 2023   docker-ce 24.0.2
dists/noble/Release    Date: 02 Sep 2026   docker-ce 29.7.2
```

Скрипт предупреждает об этом вслух. Это потолок цели, а не выбор способа.

## OpenWrt

Сюда не входит: там `opkg` (24.10) или `apk` (25.12) и нет systemd, то есть
фазы первой загрузки не существует. Вдобавок в 25.12 пакета `dockerd` нет
вовсе для `x86_64`, `aarch64_generic`, `aarch64_cortex-a53` и
`aarch64_cortex-a76` — проверено по шести точечным релизам.

## Подключение в VMFILE

```vmfile
COPY_IN ../bisquite-extensions/extensions/debian/docker:/opt/vmsetup/
RUN_COMMAND chmod +x /opt/vmsetup/docker/*.sh
RUN_COMMAND /opt/vmsetup/docker/install.sh
```

## Проверено на

| Система | Архитектура | Что получилось | Дата |
|---|---|---|---|
| Debian 13 trixie | amd64 | `docker-ce 5:29.7.2-1~debian.13~trixie`, `containerd.io 2.3.4`, плагины `buildx` и `compose` на месте | 2026-09-03 |

Проверялось не по коду возврата, а по содержимому образа: `virt-ls` нашёл
`docker`, `dockerd`, `containerd` в `/usr/bin` и оба плагина в
`/usr/libexec/docker/cli-plugins`, а `virt-cat` подтвердил, что
`/etc/apt/sources.list.d/docker.sources` указывает на
`download.docker.com/linux/debian` — то есть движок пришёл из репозитория
Docker, а не дистрибутивный `docker.io 26.1.5`.
