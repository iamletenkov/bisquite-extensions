# Станция прошивки Jetson AGX Orin

Эти скрипты установлены в `/opt/nvidia-jetpack/`. **Автоматически не
запускается ничего** — прошивка необратима для платы, начинать её должен
человек.

Цель: прошить **Jetson AGX Orin Developer Kit** (модуль p3701-0000,
носитель p3737-0000) на **JetPack 6.2 / L4T 36.4.3** с загрузкой с NVMe,
с окружением для GMSL2-камер Sensing `SG8A-AGON-G2Y-A1`.

## Нумерация — это порядок

| Скрипт | Что делает | Плата нужна |
|---|---|---|
| `01-fetch-l4t.sh` | BSP, sample rootfs, два оверлея; сверка SHA1 | нет |
| `02-fetch-camera-drivers.sh` | драйверы Sensing с GitHub | нет |
| `03-prepare-bsp.sh` | распаковка, `apply_binaries.sh`, оверлей камер | нет |
| `04-customize-rootfs.sh` | пользователь без `oem-config`, пакеты и драйверы в rootfs | нет |
| `05-generate-images.sh` | генерация образов (`--no-flash`) | **да, в recovery** |
| `06-flash.sh` | заливка (`--flash-only`) — **необратимо** | **да, в recovery** |
| `07-flash-rootfs-ssh.sh` | обход, если `06` оборвался на `system.img` | **да, в initrd** |
| `90-install-sdkmanager.sh` | NVIDIA SDK Manager (по желанию) | нет |

Рабочий каталог — `$WORK`, по умолчанию `/srv/jetson`. Переопределяется
переменной окружения: `WORK=/mnt/big sudo ./01-fetch-l4t.sh`.

## Быстрый путь

```bash
cd /opt/nvidia-jetpack

sudo ./01-fetch-l4t.sh                 # ~4 ГБ, минут 10-20
sudo ./02-fetch-camera-drivers.sh
sudo ./03-prepare-bsp.sh               # 20-45 минут
sudo ./04-customize-rootfs.sh -u jetson -p 'ВАШ_ПАРОЛЬ'

# дальше нужна плата в recovery — см. ниже
sudo ./05-generate-images.sh           # 15-40 минут
sudo ./06-flash.sh                     # 20-40 минут, необратимо
```

## Как перевести плату в recovery

```
обесточить → подать питание → зажать Force Recovery (средняя кнопка)
→ нажать и отпустить Reset (правая) → отпустить Recovery
```

Кабель — в **USB-C рядом с 40-пиновым разъёмом**. Второй USB-C (над
DC-гнездом) только питает, данных там нет.

Проверка: `lsusb | grep 0955` должно дать `0955:7023 … APX`. Слово **APX**
обязательно; `7020` — это загруженная система, а не recovery.

Часть AGX Orin входит в recovery **сама** от подключённого кабеля к этому
порту. Обратная сторона: с воткнутым кабелем плата уйдёт в APX вместо
обычной загрузки — после прошивки кабель надо отсоединить.

## Если `06-flash.sh` оборвался на `system.img`

Это **известная проблема L4T**, а не поломка станции: NFS-сервер перестаёт
отвечать под нагрузкой, и в журнале платы видно

```
nfs: server fc00:1:1:0::1 not responding, still trying
nfs: server ... timed out
```

Пользователи Orin сообщают об успехе после нескольких попыток. Но повторять
заливку целиком не нужно — к этому моменту записано уже всё, кроме корневой
файловой системы.

**Не обесточивайте плату.** Она остаётся в режиме `0955:7035` (initrd
flashing mode) и доступна по сети. Запустите:

```bash
sudo ./07-flash-rootfs-ssh.sh
```

Он разворачивает rootfs в APP-раздел SSH-потоком, минуя NFS. Тот же объём
(2.2 ГБ → 6.9 ГБ) этим путём проходит с первого раза.

## После успешной прошивки

1. Обесточить, **отсоединить USB-C**, подать питание.
2. На плате проверить:

```bash
cat /etc/nv_tegra_release   # ждём R36 (release), REVISION: 4.3
uname -r                    # ждём 5.15.148-tegra
lsblk                       # / должен быть на nvme0n1p1, НЕ на mmcblk0p1
sudo ldconfig               # кеш не собрался из-за qemu при сборке rootfs
```

3. Закрепить ядро, иначе `apt upgrade` затрёт ядро от Sensing:

```bash
sudo apt-mark hold nvidia-l4t-kernel nvidia-l4t-kernel-dtbs nvidia-l4t-initrd
```

## Камеры

Пакет драйверов уже лежит на плате в `/opt/sensing` — скачивать ничего
не нужно. Запускается **в два прогона с перезагрузкой между ними**:

```bash
cd /opt/sensing
sudo ./quick_bring_up.sh     # 1 -> sgx-yuv-gmsl2, ставит Image и DTB
sudo reboot
sudo ./quick_bring_up.sh     # 1 -> модель AR0233 -> порт 0..7
```

В меню модель называется **`SG2-AR0233-5300-GMSL2`**, хотя камеры `-5200-`:
средняя цифра — модель ISP (GW5200 против GW5300). Выбирать пункт с AR0233.

Проверка:

```bash
lsmod | grep -E 'max9295|max9296|sgx'
v4l2-ctl --list-devices
gst-launch-1.0 v4l2src device=/dev/video0 ! xvimagesink -ev

# по SSH без монитора:
gst-launch-1.0 v4l2src device=/dev/video0 num-buffers=10 ! jpegenc ! multifilesink location=frame_%02d.jpg
```

Номера I²C-шин на схеме платы **не совпадают** с номерами в софте — это
оговорено в документации Sensing. Порты перебирать `video0` … `video7`.
Стабильно работает только YUV422; RAW12 заявлен недоступным.

## Известные ограничения

- **Заливка флакует.** Причина в самом L4T, не в станции. Обход —
  `07-flash-rootfs-ssh.sh`, он проверен.
- **`mke2fs` может отсутствовать** в initrd платы. Тогда `07` предупредит
  и развернёт rootfs поверх прежнего содержимого — практически безвредно
  (тот же архив), но раздел не будет чистым.
- **`-S 40GiB`** в `05-generate-images.sh` вынесен в переменную `APP_SIZE`.
  Значение перенесено с прошлых попыток; дефолт L4T рассчитан на носитель
  ≥64 ГБ, и на терабайтном NVMe его стоит замерить, а не принимать на веру.
- **`flash.sh` напрямую в рабочем каталоге запускать нельзя** — он
  перезапишет промежуточные артефакты, и `l4t_initrd_flash.sh` потом падает
  на `Unexpected error in updating: ..._with_odm.dtb`.
- **SDK Manager не спасает от обрывов**: под капотом он зовёт тот же
  `l4t_initrd_flash.sh` с тем же NFS.
