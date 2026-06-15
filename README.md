# bisquite-extensions

Переиспользуемые «расширения» провизии для образов, собираемых
[bisquite](https://github.com/iamletenkov/bisquite). Расширения сгруппированы по
семейству ОС. Подключаются в сборку через `COPY_IN`/`UPLOAD`.

## Структура

```
extensions/
├── debian/                  # для Debian/Ubuntu (install.sh + configure)
│   ├── docker/
│   ├── code-server/
│   ├── chromium-kiosk/  kiosk/
│   ├── gnome/  xfce4/  lxde/
│   ├── x11vnc/
│   └── nvidia/
└── openwrt/                 # для OpenWrt (конфиги, UPLOAD)
    ├── uci-defaults/
    └── wrt_cloudinit/
```

Ubuntu-образы используют расширения из `debian/` (Ubuntu — Debian-совместима).

## Конвенция

**Debian/Ubuntu** (`extensions/debian/<name>/`) — скриптовая, двухфазная:
```
<name>/
├── install.sh                  # сборка: ставит софт, регистрирует configure-сервис
├── configure.sh                # первый запуск: до-настройка под конкретную ВМ
├── configure-<name>.service    # systemd-oneshot, гоняет configure.sh на загрузке
├── get_cloud_user.sh           # резолв cloud-init пользователя
├── config.yaml                 # опциональный конфиг
└── README.md
```
1. **Сборка (`install.sh`)** — ставит софт (с ретраями), включает `configure-<name>.service`.
2. **Первый запуск (`configure.sh`)** — резолвит cloud-init пользователя через
   `cloud-init query userdata | yq` и доделывает per-instance настройку (идемпотентно).

В образе нужны `cloud-init` и `yq` (их ставит базовый VMFILE).

**OpenWrt** (`extensions/openwrt/`) — конфиги, которые кладутся через `UPLOAD`
(uci-defaults, init.d-скрипты), без install.sh.

## Подключение в VMFILE

Debian/Ubuntu:
```dockerfile
COPY_IN bisquite-extensions/extensions/debian/docker:/opt/vmsetup/
RUN_COMMAND chmod +x /opt/vmsetup/docker/*.sh
RUN_COMMAND /opt/vmsetup/docker/install.sh
```

OpenWrt:
```dockerfile
UPLOAD bisquite-extensions/extensions/openwrt/uci-defaults/80-rootfs-resize:/etc/uci-defaults/80-rootfs-resize
```

## Доставка в сборку (CI)

Публичный репозиторий — клонируется в контекст сборки по тегу (тег = версия
набора расширений):

```yaml
variables:
  EXT_REPO: https://github.com/iamletenkov/bisquite-extensions.git
  EXT_VERSION: v1.1.0
before_script:
  - rm -rf bisquite-extensions
  - git clone --depth 1 --branch "$EXT_VERSION" "$EXT_REPO"
```

## Версионирование

Версия набора расширений — git-тег этого репозитория; image-проект пинит её через
`EXT_VERSION`. Тегай по semver.

## Зависимости и применимость

Пока по соглашению (в README конкретных расширений): десктопы (`gnome`/`xfce4`/
`lxde`) обычно идут с `x11vnc`; графические/`nvidia` требуют GPU. Структурированные
метаданные — задел на будущий OCI-«магазин расширений».
