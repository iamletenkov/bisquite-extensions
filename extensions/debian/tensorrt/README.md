# tensorrt

Ставит TensorRT (движок инференса + Python-биндинги) на Jetson из
apt-репозитория `jetson/common`, уже подключённого базовым образом L4T.

> **С 1.1.0 — раскладка 2.** Манифест объявляет `layout: 2`: каталог расширения
> в госте — `/opt/bisquite/tensorrt/` (был `/opt/vmsetup/tensorrt/`). Путей гостя
> расширение не прибивает, поэтому версия минорная; нужен bisquite
> с поддержкой `layout: 2`.

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
