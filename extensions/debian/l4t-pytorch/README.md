# l4t-pytorch

PyTorch и torchvision с CUDA для Jetson (JetPack 6, L4T 36.4, Orin).

## Манифест

| Поле | Значение |
|---|---|
| `phase` | `build` |
| `arch` | `arm64` |
| `provides` | `pytorch` |
| `requires` | `cuda` — `nvcc` для сборки torchvision и библиотеки тулкита для torch |
| `conflicts` | пусто |

## Что ставится и откуда

| Что | Версия | Откуда |
|---|---|---|
| torch | 2.5.0 nv24.08 | CDN NVIDIA, колесо под JetPack 6.1 (CUDA 12.6), sha256 закреплён |
| torchvision | 0.20.0 | **исходники** с GitHub (тег сверяется с коммитом), сборка с CUDA 8.7 |
| cuDNN | 9.3 | apt, `libcudnn9-cuda-12` |
| cuSPARSELt | 0.6.2.3 | архив NVIDIA redist `linux-aarch64`, sha256 закреплён, в `/usr/local/cusparselt` |
| numpy / scipy | 1.26.4 / 1.13.1 | PyPI |
| sympy, networkx, filelock, fsspec, mpmath, typing_extensions | `constraints.txt` | PyPI |

Проверено на плате 2026-09-14: `torch.cuda.is_available()`, свёртка на GPU,
`torchvision.ops.nms` на `cuda:0`, `resnet18` на GPU, мост numpy↔CUDA,
и вместе в одном процессе с `cv2` 4.8.0, TensorRT 10.3 и TensorFlow 2.16.

## Почему не новее

torch 2.8–2.10 с готовым torchvision под Jetson есть только в индексе
jetson-ai-lab, а из сети сборки он файлы не отдаёт (замер 2026-09-14:
каждая загрузка обрывается на 15 865 байтах). 2.5.0 nv24.08 — последнее,
что NVIDIA публикует на своём CDN: каталог `jp/v61/pytorch/` есть,
`jp/v62/` — нет.

## Почему torchvision из исходников

NVIDIA его под JetPack 6 не публикует, а колесо с PyPI собрано под
PyPI-torch, и его C++-операции с torch от NVIDIA несовместимы по ABI.
Сборка на самой плате (12 ядер) — 128 с.

**Внутри `bs image build` ресурсы appliance по умолчанию — 1 vCPU и 2 ГБ.**
Сборка пройдёт и так (число потоков компиляции расширение считает по
памяти, по ~1.5 ГБ на поток, чтобы не словить OOM), но долго. С ресурсами —
быстрее:

```bash
bs image build --smp 8 --memsize 16000 -f jetson-orin-base.vmfile ...
```

## numpy 1.26.4 перекрывает системный — и почему это правильно

torch nv24.08 собран под C-API numpy 0x10 (ветка 1.23+), а в jammy numpy
1.21.5. С системным numpy torch импортируется и считает на GPU, но любой
мост torch↔numpy падает: `RuntimeError: Numpy is not available`. 1.26.4 —
последняя 1.x; модули apt, собранные под 1.21 (Gst, jtop, TensorRT, cv2),
с ней работают — проверено. Вместе с numpy поднимается scipy: apt-овый
1.8.0 (его тянут matplotlib и pandas) с numpy 1.26 предупреждает на каждом
импорте.

## Сторож системного Python

pip под root ставит в `/usr/local`, и оттуда пакеты перекрывают apt-овые
для всех, кто зовёт `/usr/bin/python3`, — в том числе для cloud-init. Он
на первой загрузке создаёт пользователя и сеть, и сломанный cloud-init
на сборке не виден: образ собирается, плата приезжает без пользователя.

Поэтому:

- в `constraints.txt` закреплено **только то, что pip ставит в любом
  случае**. `jinja2` там нет: apt-овый 3.0.3 удовлетворяет torch, а
  закреплённая версия встала бы поверх — и cloud-init импортировал бы её;
- `check-system-python.py` после установки проверяет, что прямые
  зависимости cloud-init импортируются из apt, и что cloud-init рендерит
  jinja-шаблон. Нарушение — отказ сборки.

## Переменные окружения

| Переменная | Умолчание | Что делает |
|---|---|---|
| `TORCH_CUDA_ARCH_LIST` | `8.7` | архитектура CUDA для torchvision; 8.7 — Ampere во всех Orin, другой JetPack 6 не поддерживает |
