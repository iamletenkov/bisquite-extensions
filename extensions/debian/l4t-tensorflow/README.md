# l4t-tensorflow

TensorFlow 2.16.1 с CUDA для Jetson (JetPack 6, L4T 36.4): колесо NVIDIA.

## Манифест

| Поле | Значение |
|---|---|
| `phase` | `build` |
| `arch` | `arm64` |
| `provides` | `tensorflow` |
| `requires` | `cuda` — TF грузит библиотеки тулкита |
| `conflicts` | пусто — с `l4t-pytorch` делит numpy 1.26.4 и scipy 1.13.1 |

## Прежде чем ставить: это последняя версия

NVIDIA публикует TF для Jetson на `developer.download.nvidia.com/compute/redist/jp/`,
и последний каталог с ним — `v61` (август 2024); `v62` нет. Индекс
jetson-ai-lab под именем `tensorflow` отдаёт обычные колёса PyPI
(cp313, без CUDA для Jetson). Новых сборок TF под Jetson не выходит.

Сегодня на Jetson модели обычно обучают в PyTorch, а на устройстве
запускают через ONNX → TensorRT. TF остаётся для уже написанного кода
и моделей на TF/Keras. Расширение закрывает этот случай и весит 1.9 ГБ
в образе — поэтому в `jetson-orin-base.vmfile` оно не включено
по умолчанию.

## Что ставится

| Что | Версия | Откуда |
|---|---|---|
| tensorflow | 2.16.1 nv24.08 | CDN NVIDIA, sha256 закреплён |
| keras | 3.3.3 | PyPI — та, с которой вышел TF 2.16; pip сам взял бы 3.12 |
| cuDNN | 9.3 | apt |
| numpy / scipy | 1.26.4 / 1.13.1 | PyPI, те же, что у `l4t-pytorch` |
| остальное | `constraints.txt` | PyPI |

Проверено на плате 2026-09-14: обучение модели Keras на GPU, и вместе
в одном процессе с torch, torchvision, `cv2` и TensorRT.

## Сторож системного Python

Тот же, что у `l4t-pytorch`, и по той же причине — см. его README.
Поверх apt TF законно перекрывает семь пакетов: `gast`, `markupsafe`,
`mpmath`, `numpy`, `protobuf`, `scipy`, `sympy`. `markupsafe` — зависимость
`jinja2` у cloud-init; с 3.0.3 cloud-init шаблоны рендерит (проверено).
`requests`, `urllib3`, `idna`, `certifi` в `constraints.txt` не закреплены
намеренно: apt-овые версии TF устраивают, и перекрывать их незачем.
