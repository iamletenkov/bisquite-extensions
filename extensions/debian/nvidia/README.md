# nvidia

Проприетарные драйверы NVIDIA в образе: репозитории, драйвер, блокировка
`nouveau` и обновление initramfs. Рассчитано на ВМ с GPU passthrough.

## Поддерживаемые системы

- **Debian**: 12 (bookworm), 13 (trixie)
- **Ubuntu**: 20.04 (focal), 22.04 (jammy), 24.04 (noble)

Версия определяется `lsb_release`; пакет `lsb-release` ставится, если его нет.
Всё, что вне списка, — громкий отказ с указанием, что именно опознано.

## Только `amd64`, и это не лень

Манифест объявляет одну архитектуру, и обе ветки объясняют почему:

- **Debian**: `install_debian_drivers` прибивает метапакет
  `linux-headers-amd64`. Метапакет взят намеренно вместо
  `linux-headers-$(uname -r)`: сборка идёт в chroot, где `uname -r` вернул бы
  ядро **хоста** (например, Proxmox), а не гостя. Цена — имя с архитектурой
  внутри;
- **Ubuntu**: ветка идёт в PPA `graphics-drivers`, где arm64 не публикуется.

## Единственная фаза — `build`

`configure.sh` у расширения нет, и это законный случай: на первой загрузке
донастраивать нечего, нужна только перезагрузка после установки драйвера.
Пустой `configure.sh` был бы обещанием, которого никто не держит.

## Параметров нет

Расширение не читает переменных окружения: версия драйвера выбирается
`nvidia-detect` (Debian) или `ubuntu-drivers autoinstall` (Ubuntu), то есть
самой системой по установленному железу. Ручка «версия драйвера» означала бы
второй источник правды рядом с ответом, который точнее.

## Подключение в VMFILE

```vmfile
EXTENSION nvidia
```

Прежняя запись продолжает работать:

```vmfile
COPY_IN <чекаут>/extensions/debian/nvidia:/opt/vmsetup/
RUN_COMMAND chmod +x /opt/vmsetup/nvidia/*.sh
RUN_COMMAND /opt/vmsetup/nvidia/install.sh
```

`<чекаут>` — путь до чекаута этого репозитория **относительно каталога
VMFILE**; в примерах основного репозитория это `../../../../bisquite-extensions`,
и глубина зависит от того, насколько глубоко лежит сам VMFILE.

## Как это работает

1. **Определение ОС** — `lsb_release -si/-sr/-sc`.
2. **Репозитории**:
   - **Debian**: дописывает `contrib non-free non-free-firmware` в существующие
     строки `/etc/apt/sources.list`; если `sed` не нашёл знакомого формата —
     добавляет строки заново;
   - **Ubuntu**: кладёт `.list` на `ppa.launchpad.net/graphics-drivers/ppa`
     и тянет ключ `0x1118213C` с `keyserver.ubuntu.com` в
     `/etc/apt/trusted.gpg.d/`. Не вышло скачать ключ — предупреждение,
     не отказ: apt попробует сам.
3. **Драйверы**:
   - **Debian**: ставит `nvidia-detect` (опционально — отсутствие не фатально),
     затем `nvidia-driver`, `linux-headers-amd64`, `build-essential`, `dkms`;
   - **Ubuntu**: `ubuntu-drivers autoinstall`, с откатом на
     `nvidia-driver-535` → `525` → `470`.
4. **Блокировка nouveau** — `/etc/modprobe.d/blacklist-nouveau.conf`
   (`blacklist nouveau`, `options nouveau modeset=0`), плюс строка
   в `blacklist.conf`, если он есть.
5. **initramfs** — `update-initramfs -u -k all`, иначе `dracut --force`;
   нет ни того ни другого — предупреждение, и nouveau может загрузиться.
6. **Перезагрузка** — обязательна, скрипт говорит об этом в журнал.

У apt-команд стоит retry: пять попыток с задержкой 2, 4, 6, 8 секунд.

## Проверка

После перезагрузки:

```bash
lsmod | grep nvidia            # модули загружены
lsmod | grep nouveau           # должно быть ПУСТО
nvidia-smi                     # драйвер отвечает
cat /proc/driver/nvidia/version
cat /etc/modprobe.d/blacklist-nouveau.conf
```

## Диагностика

```bash
dpkg -l | grep nvidia
nvidia-detect                  # Debian: какой драйвер рекомендован
ubuntu-drivers list            # Ubuntu: какие доступны
dmesg | grep -iE "nvidia|nouveau"
```

- **Репозитории недоступны** — DNS/прокси и доступность зеркал.
- **`nvidia-detect` не найден** — нормально для части выпусков Debian,
  установка продолжается без него.
- **Ошибки сборки модулей** — проверьте `linux-headers-amd64`
  и `build-essential`. Метапакет здесь принципиален: с
  `linux-headers-$(uname -r)` в chroot приехали бы заголовки хоста.
- **nouveau загружен вместо nvidia** — проверьте, что
  `/etc/modprobe.d/blacklist-nouveau.conf` на месте, выполните
  `update-initramfs -u` и перезагрузитесь.
- **`nvidia-smi` не работает** — модули не загружены либо не было
  перезагрузки.

## Примечания

- Скрипт запускается от root в chroot гостя; `sudo` в нём нет намеренно.
- Для работы драйверов нужен GPU passthrough в гипервизоре.
- Драйвер тянет ядро и заголовки — под сборку заложите место с запасом.

## Лицензия

Расширение распространяется на условиях публичной некоммерческой лицензии
Bisquite (PolyForm Noncommercial 1.0.0, см. `LICENSE`). Для коммерческого
использования требуется отдельная платная лицензия — см. `COMMERCIAL-LICENSE.md`.
