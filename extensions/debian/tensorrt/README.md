# tensorrt

Ставит TensorRT (движок инференса + Python-биндинги) на Jetson из
apt-репозитория `jetson/common`, уже подключённого базовым образом L4T.

> **С 1.1.0 — раскладка 2.** Манифест объявляет `layout: 2`: каталог расширения
> в госте — `/opt/bisquite/tensorrt/` (был `/opt/vmsetup/tensorrt/`). Путей гостя
> расширение не прибивает, поэтому версия минорная; нужен bisquite
> с поддержкой `layout: 2`.

## Ветка R32 (Jetson Nano, JetPack 4.6) — с 1.2.0

Ветка выбирается по первой строке `/etc/nv_tegra_release` (`# R32 …`),
разбор общий — `lib/l4t` источника. Поведение на r36 не меняется.

TensorRT 8.0.1.6 в образе Q-engineering уже есть. Ничего не ставится;
проверяется пакет `libnvinfer8`, исполняемый `/usr/src/tensorrt/bin/trtexec`
(`libnvinfer-bin`) и `libnvinfer.so.8` в кеше загрузчика.

**Python-модуля нет, и это не отказ**: JetPack 4.6 публикует `tensorrt`
только под Python 3.6, а в образе 3.8. Расширение говорит об этом
предупреждением; TensorRT доступен из C++ и `trtexec`.

Проверено на живом Nano (L4T R32.6.1, 2026-09-15) прогоном `install.sh` на работающей системе.

## Манифест

| Поле | Значение |
|---|---|
| `phase` | `build` |
| `arch` | `arm64` |
| `provides` | `tensorrt` |
| `requires` | пусто — зависимость от CUDA решает apt, не резолвер VMFILE |
| `conflicts` | пусто |

## Проверено

Живая плата, JetPack 6.2.1, L4T 36.4.3, 2026-09-12:

```
tensorrt   | 10.3.0.30-1+cuda12.5 | https://repo.download.nvidia.com/jetson/common r36.4/main arm64 Packages
```

## Что ставится

- `tensorrt` — мета-пакет: рантайм-библиотеки (`libnvinfer10`,
  `libnvinfer-plugin10`, …) и dev-заголовки одной согласованной версией;
- `python3-libnvinfer` — Python-биндинги отдельно: `tensorrt` их не тянет,
  а инференс на Jetson в большинстве случаев идёт из Python.

## Размер

`libnvinfer-dev` один занимает больше полугигабайта установленного —
вместе с рантаймом и заголовками TensorRT ощутимо утяжеляет образ.
Не кандидат в базовый образ флота, только в прикладной слой.
