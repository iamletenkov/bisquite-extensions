# l4t-opencv

OpenCV 4.8.0 для Jetson из репозитория NVIDIA: `cv2` с бэкендом
GStreamer, FFmpeg и V4L2. **Без CUDA.**

> **С 1.1.0 — раскладка 2.** Манифест объявляет `layout: 2`: каталог расширения
> в госте — `/opt/bisquite/l4t-opencv/` (был `/opt/vmsetup/l4t-opencv/`). Путей гостя
> расширение не прибивает, поэтому версия минорная; нужен bisquite
> с поддержкой `layout: 2`.

## Ветка R32 (Jetson Nano, JetPack 4.6) — с 1.2.0

Ветка выбирается по первой строке `/etc/nv_tegra_release` (`# R32 …`),
разбор общий — `lib/l4t` источника. Поведение на r36 не меняется.

В образе Q-engineering OpenCV 4.8.0 уже собран — **с CUDA 10.2** и GStreamer
1.16.3. Ничего не ставится; проверяется `import cv2` и строки
`NVIDIA CUDA: YES` и `GStreamer: YES` в `cv2.getBuildInformation()`.

**`OPENBLAS_CORETYPE=ARMV8`.** На Cortex-A57 OpenBLAS из numpy выбирает ядро,
которого у процессора нет, и `import numpy`/`cv2`/`torch` падают `Illegal
instruction` (замер на Nano: rc=132). Вендорский образ экспортировал
переменную из `.bashrc` учётки `jetson`, которую цепочка удаляет. Ветка R32
пишет её в `/etc/environment` (входы) и
`/etc/systemd/system.conf.d/<имя расширения>.conf` (`DefaultEnvironment=`,
службы) — идемпотентно, `l4t-opencv` и `l4t-pytorch` одним способом.
Проверка **не экспортирует переменную сама**: окружение собирается из
записанных файлов так, как их прочтут pam_env и systemd, и импорт идёт под
`env -i` с ним — опечатка в имени файла или ключа дала бы отказ. Падает ли
импорт без переменной, на сборке не проверить: appliance видит CPU машины
сборки (на AGX — Cortex-A78AE).

Проверено на живом Nano (L4T R32.6.1, 2026-09-15) прогоном `install.sh` на работающей системе.

## Манифест

| Поле | Значение |
|---|---|
| `phase` | `build` |
| `arch` | `arm64` |
| `provides` | `opencv` |
| `requires` | пусто (аппаратный путь с камер даёт `l4t-gstreamer`, но импорту он не нужен) |
| `conflicts` | пусто |

## Что ставится

`libopencv` и `libopencv-python` — оба явно. `libopencv-python` от NVIDIA
не объявляет зависимость от собственных библиотек: apt ставит один `cv2`,
и импорт падает с `libopencv_ml.so.408: cannot open shared object file`
(замер на плате 2026-09-14).

## Кадры с камеры в cv2 через аппаратный nvvidconv

Проверено на плате: 30 кадров 1920×1080 с камеры Sensing.

```python
import cv2

pipeline = (
    "v4l2src device=/dev/video6 ! video/x-raw,format=UYVY,width=1920,height=1080 "
    "! nvvidconv ! video/x-raw,format=BGRx ! videoconvert ! video/x-raw,format=BGR ! appsink"
)
cap = cv2.VideoCapture(pipeline, cv2.CAP_GSTREAMER)
ok, frame = cap.read()  # frame.shape == (1080, 1920, 3)
```

## Чего нет: CUDA

Модуля `cv2.cuda` в этой сборке нет. CUDA-сборка OpenCV под JetPack 6
готовой есть только в индексе jetson-ai-lab, а из сети сборки он файлы
не отдаёт: замер 2026-09-14 — каждая загрузка обрывается на 15 865 байтах
при 25 Б/с, при том что страница индекса отвечает. Своя сборка из
исходников — час-два компиляции на каждую пересборку образа.

На Jetson это обычно не мешает: преобразование кадра (масштаб, цвет) делает
`nvvidconv` на аппаратном блоке ещё до `cv2`, а сеть считают TensorRT или
PyTorch. Если нужны именно GPU-операции над изображениями — у NVIDIA для
этого VPI (`nvidia-vpi`, `python3.10-vpi3` в том же репозитории), в это
расширение он не входит.

## Два OpenCV в образе — и ловушка для C++

В образе остаётся убунтовский OpenCV 4.5.4 (`libopencv-*4.5d` и
`libopencv-dev`): его тянет `libgstreamer-plugins-bad1.0-dev`. Для Python
это не важно — `import cv2` отдаёт 4.8.0 от NVIDIA. Для C++ важно:
**`pkg-config opencv4` и `/usr/include/opencv4` — это 4.5.4.**

`libopencv-dev` от NVIDIA поставить нельзя: он объявлен `Conflicts`
с убунтовским, и apt снёс бы вместе с ним `libgstreamer-plugins-bad1.0-dev`
(симуляция удаляла 19 пакетов `-dev`).
