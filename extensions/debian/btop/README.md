# btop

Ставит `btop` — TUI-монитор ресурсов (CPU, память, диски, сеть, процессы)
обычным пакетом из `universe`.

## Манифест

| Поле | Значение |
|---|---|
| `phase` | `build` |
| `arch` | `amd64`, `arm64` |
| `provides` | `system-monitor` |
| `requires` | пусто |
| `conflicts` | пусто |

## Проверено

Живая плата, Ubuntu 22.04 (jammy) arm64, 2026-09-12:

```
btop | 1.2.3-2 | http://ports.ubuntu.com/ubuntu-ports jammy/universe arm64 Packages
```

## Отношение к jetson-stats

Не конкурируют и не пересекаются: `btop` — общий монитор ОС (CPU/RAM/диск/
сеть/процессы), `jetson-stats` — специфичный для Tegra (GPU, питание,
частоты, `nvpmodel`), читает `tegrastats` и sysfs-узлы, которых на не-Jetson
нет. Ставятся вместе без конфликта — оба легитимно нужны на одном образе.
