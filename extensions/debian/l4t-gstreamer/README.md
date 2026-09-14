# l4t-gstreamer

GStreamer для Jetson (L4T 36.4): аппаратные плагины NVIDIA плюс набор
убунтовского GStreamer, нужный роботу, — камеры, RTSP, WebRTC, запись,
Python-конвейеры.

> **С 1.1.0 — раскладка 2.** Манифест объявляет `layout: 2`: каталог расширения
> в госте — `/opt/bisquite/l4t-gstreamer/` (был `/opt/vmsetup/l4t-gstreamer/`). Путей гостя
> расширение не прибивает, поэтому версия минорная; нужен bisquite
> с поддержкой `layout: 2`.

## Манифест

| Поле | Значение |
|---|---|
| `phase` | `build` |
| `arch` | `arm64` |
| `provides` | `gstreamer`, `hw-video-codec` |
| `requires` | пусто |
| `conflicts` | пусто |

## Зачем, если в рабочей станции GStreamer уже был

Убунтовский GStreamer приехал в рабочую станцию (тогда `jetson-orin-workstation`) случайно —
зависимостями GNOME и dev-пакетов. Безголовый робот поверх
тогдашнего `jetson-orin-camera` его не получил бы. И даже в рабочей станции (замер
на плате 2026-09-14) не было двух ключевых вещей:

- **`nvidia-l4t-gstreamer`** — нет `nvv4l2h264enc`/`nvv4l2h265enc`,
  `nvvidconv`, `nvarguscamerasrc`. Аппаратный кодек Orin простаивал,
  видео можно было жать только программным `x264enc`;
- **`gstreamer1.0-nice`** — `webrtcbin` регистрируется и виден
  в `gst-inspect-1.0`, но падает на первом же соединении: ICE ему нечем
  делать.

## Что ставится

| Группа | Пакеты | Зачем |
|---|---|---|
| NVIDIA | `nvidia-l4t-gstreamer` (версия = `nvidia-l4t-core`) | `nvv4l2h264enc`/`h265enc`/`decoder`, `nvvidconv`, `nvarguscamerasrc`, `nvv4l2camerasrc`, `nvcompositor`, `nvjpegenc`/`dec`, `nveglglessink` |
| ядро | `gstreamer1.0-tools`, `-plugins-base/good/bad/ugly`, `-libav` | `gst-launch-1.0`, `v4l2src`, `x264enc`, `avdec_*`, `splitmuxsink`, `srtsrc`, `rtmpsink`, `hlssink2` |
| экран | `gstreamer1.0-x`, `-gl` | `ximagesrc` (захват рабочего стола), `glimagesink` |
| звук | `gstreamer1.0-alsa`, `-pulseaudio` | `alsasrc`, `pulsesrc` |
| RTSP | `gstreamer1.0-rtsp`, `libgstrtspserver-1.0-0`, `gir1.2-gst-rtsp-server-1.0` | раздавать камеры по RTSP, в том числе из Python |
| WebRTC | `gstreamer1.0-nice` | ICE для `webrtcbin` |
| Python | `python3-gi`, `python3-gst-1.0`, `gir1.2-gstreamer-1.0`, `gir1.2-gst-plugins-base-1.0`, `gir1.2-gst-plugins-bad-1.0` | `Gst`, `GstWebRTC`, `GstSdp`, `GstRtspServer` |
| отладка | `v4l-utils` | `v4l2-ctl`: форматы и контролы камер |
| dev (`GSTREAMER_DEV=1`) | `libgstreamer1.0-dev`, `libgstreamer-plugins-base/bad1.0-dev`, `libgstrtspserver-1.0-dev`, `nvidia-l4t-jetson-multimedia-api` | свои приложения на C/C++, Jetson Multimedia API |

## Версия плагинов NVIDIA — по стеку, а не по apt

Репозиторий `r36.4` публикует обновления одной веткой: на 2026-09-14
кандидат `nvidia-l4t-gstreamer` — 36.4.7, а стек в образе — 36.4.3.
Зависимости у пакета мягкие (`nvidia-l4t-multimedia (>= 36.3.0)`), поэтому
apt без возражений поставил бы плагин 36.4.7 поверх `libnvbufsurface`
36.4.3. Расширение берёт ровно версию `nvidia-l4t-core`; нет её
в репозитории — отказ на сборке, а не смешанный стек. После установки
версия `nvidia-l4t-core` сверяется ещё раз.

## Проверено на плате (AGX Orin, 2026-09-14)

```bash
# тестовый поток 1080p → аппаратный H.264, 10 с
gst-launch-1.0 -e videotestsrc num-buffers=300 ! video/x-raw,width=1920,height=1080,framerate=30/1 \
  ! nvvidconv ! 'video/x-raw(memory:NVMM),format=NV12' ! nvv4l2h264enc ! h264parse ! mp4mux ! filesink location=t.mp4

# рабочий стол 3840×2160 → аппаратный H.264
DISPLAY=:0 gst-launch-1.0 -e ximagesrc use-damage=0 num-buffers=150 ! video/x-raw,framerate=30/1 \
  ! videoconvert ! nvvidconv ! 'video/x-raw(memory:NVMM),format=NV12' ! nvv4l2h264enc ! h264parse ! mp4mux ! filesink location=desk.mp4

# камера Sensing 1920×1080 → аппаратный H.265
gst-launch-1.0 -e v4l2src device=/dev/video6 num-buffers=150 ! video/x-raw,format=UYVY,width=1920,height=1080,framerate=30/1 \
  ! nvvidconv ! 'video/x-raw(memory:NVMM),format=NV12' ! nvv4l2h265enc ! h265parse ! mp4mux ! filesink location=cam.mp4
```

## Про Selkies и удалённый рабочий стол

Selkies (WebRTC-рабочий стол на GStreamer) с этим набором запускается:
`ximagesrc`, `webrtcbin`, `nicesrc`, `x264enc`, `opusenc`, `pulsesrc`
на месте. **Аппаратного кодирования он на Jetson сам не выберет:** его
аппаратные кодеры — `nvh264enc` (NVENC дискретных карт NVIDIA) и VA-API,
а на Jetson кодек — `nvv4l2h264enc`, другой элемент с другими свойствами.
Без правки конвейера Selkies пойдёт программным `x264enc`. Что аппаратный
путь для захвата экрана на Orin работает, показывает второй конвейер
выше — 4K рабочего стола через `nvv4l2h264enc`.

Сам Selkies (Python-пакет и веб-клиент) расширение не ставит.

## Внутри сборки `gst-inspect-1.0` не зовётся

В `virt-customize` гость не загружен: нет `/dev/nvhost-*` и
`/dev/v4l2-nvenc`, и плагины NVIDIA при сканировании реестра отваливаются
по причинам, которых на плате не будет. Проверка идёт по файлам плагинов
в `/usr/lib/aarch64-linux-gnu/gstreamer-1.0/`.

## Переменные окружения

| Переменная | Умолчание | Что делает |
|---|---|---|
| `GSTREAMER_DEV` | `1` | `0` — без заголовков GStreamer и Jetson Multimedia API (роботу в поле не нужны) |
