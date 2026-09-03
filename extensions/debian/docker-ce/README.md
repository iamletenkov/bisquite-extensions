# docker-ce

Установка **Docker CE из репозитория Docker** для Debian, Ubuntu и
Raspberry Pi OS. Отличается от соседнего расширения `docker/`, которое ставит
тот же движок скриптом `get.docker.com`.

## Почему не `get.docker.com`

Позиция самого Docker, дословно из документации:

> The convenience script isn't recommended for production environments, but
> it's useful for creating a provisioning script tailored to your needs.

Плюс перечисленные там же ограничения: скрипт не настраивается, не
предназначен для обновления существующей установки и ничего не закрепляет по
версиям. Для образов, которые тиражируются на устройства, это неподходящий
инструмент — apt-репозиторий и есть документированный путь.

## Почему не `docker.io` из Debian

Пакет Debian заметно отстаёт от upstream и не даёт плагинов `docker buildx`
и `docker compose`. Это расширение ставит пять upstream-пакетов:

```
docker-ce  docker-ce-cli  containerd.io  docker-buildx-plugin  docker-compose-plugin
```

## Какой репозиторий для малины

Docker публикует два разных репозитория, и выбор делается по полю `ID`
в `/etc/os-release`:

| Система | `ID` | Репозиторий |
|---|---|---|
| Raspberry Pi OS **64-bit** | `debian` | `linux/debian` |
| Raspberry Pi OS **32-bit** | `raspbian` | `linux/raspbian` |

Существенно: в репозитории `raspbian` **нет сюиты `trixie`** (прямой запрос
даёт 404), там только `armhf`, и он остановился на Docker 28.x. При этом
`debian/trixie/arm64` живой и актуальный. Тот же вывод зашит в сам
`get.docker.com`:

```sh
# Docker does not publish a Raspbian Trixie repo; use Debian Trixie instead.
if [ "$lsb_dist" = "raspbian" ] && [ "$dist_version" = "trixie" ]; then
    apt_repo_lsb_dist="debian"
fi
```

Поэтому 64-битная Raspberry Pi OS обслуживается обычной debian-инструкцией —
и `install.sh` поступает так же, а для 32-битной `trixie` делает тот же
подмен репозитория, что и Docker.

## Ловушка малины, которой нет в документации Docker

Ядро Raspberry Pi **выключает memory cgroup** через DTB. Следствие:
`docker run --memory` молча не работает.

```
$ docker run --rm --memory 128m alpine true
WARNING: Your kernel does not support memory limit capabilities
         or the cgroup is not mounted. Limitation discarded.
```

`install.sh` дописывает в `/boot/firmware/cmdline.txt`:

```
cgroup_enable=memory
```

Три вещи, о которые легко споткнуться:

- **Всё должно остаться одной строкой** — требование загрузчика.
- **Параметры из `cmdline.txt` применяются ПОСЛЕ аргументов из DTB**, поэтому
  наш `cgroup_enable=memory` перебивает `cgroup_disable=memory`, которого
  в самом файле не видно. Отсюда путаница в баг-репортах.
- **Проверять надо `/sys/fs/cgroup/memory.max`, а не `/proc/cgroups`.**
  На ядрах 6.12+ строки `memory` в `/proc/cgroups` не будет никогда: в них нет
  `CONFIG_MEMCG_V1`, и это осознанное решение мейнтейнеров.

`cgroup_memory=1` намеренно **не** добавляется: на текущих ядрах он избыточен
и логируется как нераспознанный параметр.

Нужна **перезагрузка** — на собранном образе она случится сама при первом
запуске устройства.

## Использование в VMFILE

```vmfile
COPY_IN ../bisquite-extensions/extensions/debian/docker-ce:/opt/vmsetup/
RUN_COMMAND chmod +x /opt/vmsetup/docker-ce/*.sh
RUN_COMMAND /opt/vmsetup/docker-ce/install.sh
```

⚠️ Слои с выполнением кода в arm64-госте требуют **arm64-хоста**: на amd64
`virt-customize` отказывает с «host cpu (x86_64) and guest arch (aarch64) are
not compatible». Это ограничение libguestfs, а не бисквита.

## Что делает первый запуск

`configure-docker-ce.service` гоняет `configure.sh`, который добавляет
пользователя, созданного cloud-init, в группу `docker`. На этапе сборки это
невозможно: имя пользователя приходит из compose-манифеста.

Помните, что членство в группе `docker` равносильно root на этой машине.

## Про `get_cloud_user.sh`

Файл рядом — **сгенерированная копия** `lib/get_cloud_user.sh`, руками её
править нельзя: правь источник и запускай `tools/sync-lib.sh`, расхождение
ловит `tools/check-lib.sh`.

Копия существует не от небрежности: до гостя доезжает только каталог одного
расширения (`COPY_IN <ext>:/opt/vmsetup/`), поэтому соседний `lib/` там
недоступен, а `configure.sh` ищет файл как `$HERE/get_cloud_user.sh`.

Раньше здесь стояла запись про «восьмую разошедшуюся копию». Копий по-прежнему
восемь, но теперь они генерируются из одного источника, а расхождение —
падающая проверка. Замер, попутно снявший тревогу: два «разных варианта»
отличались только оформлением (отступы, имя локальной переменной, `else`
против раннего `exit`) — в поведении расхождений не было ни одного.
