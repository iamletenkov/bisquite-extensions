#!/usr/bin/env bash
# Заставить cloud-init читать seed с раздела, помеченного `cidata`.
#
# ЗАЧЕМ. `bs device write` кладёт NoCloud-seed (`user-data`, `meta-data`,
# `network-config`) на отдельный раздел с меткой `cidata`. Штатные образы
# эту метку не ищут, и причины у них РАЗНЫЕ — замерено на трёх реальных
# образах для Raspberry Pi (2026-08-30):
#
#   Raspberry Pi OS Trixie   seedfrom: file:///boot/firmware
#   Ubuntu 24.04.4           fs_label: system-boot
#   Debian raspi bookworm    cloud-init не поставляется вовсе
#
# У Ubuntu метка ЗАМЕНЯЕТСЯ, а не дополняется (`DataSourceNoCloud._get_data`:
# `label = self.ds_cfg.get("fs_label", "cidata")`), поэтому том `cidata` не
# сканируется. У Pi OS метка не задана, том читается — а следом `seedfrom`
# присваивает поверх, и наша конфигурация теряется.
#
# Итог одинаков и тих: карта запишется, устройство загрузится и придёт
# БЕЗ пользователя, без сети и без ключей. Этот файл закрывает оба случая.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} nocloud-cidata: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} nocloud-cidata: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} nocloud-cidata: $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE="$SCRIPT_DIR/zz-bisquite-nocloud.cfg"
TARGET_DIR=/etc/cloud/cloud.cfg.d

# cloud-init обязателен: без него файл не читает никто, и расширение
# изобразило бы работу. Отказ громкий и называет следствие — иначе оно
# обнаружится на устройстве, после `dd`, по отсутствию пользователя.
if [[ ! -d "$TARGET_DIR" ]]; then
    log_error "в образе нет $TARGET_DIR — cloud-init не установлен"
    log_error "без него seed с метки cidata не прочитает никто, и устройство"
    log_error "загрузится без пользователя, без сети и без ключей"
    log_error "поставьте cloud-init слоем INSTALL до этого расширения"
    exit 1
fi

[[ -f "$SOURCE" ]] || { log_error "рядом нет zz-bisquite-nocloud.cfg"; exit 1; }

# Имя файла начинается с `zz-`, а не с `99-`, и это не стиль.
# cloud-init сортирует cloud.cfg.d в ОБРАТНОМ порядке и берёт первый
# (`util.read_conf_d`), поэтому имя обязано быть лексикографически старше
# любого штатного: 'z' > любой цифры. С `99-` штатный `99_raspberry-pi.cfg`
# оказался бы равноправным, и порядок решал бы случай.
install -m 0644 "$SOURCE" "$TARGET_DIR/zz-bisquite-nocloud.cfg"
log_info "NoCloud переведён на метку cidata ($TARGET_DIR/zz-bisquite-nocloud.cfg)"

# Сказать вслух, что именно перекрыто: следующий читатель журнала иначе
# не свяжет отсутствие штатного seed с этим расширением.
for stock in "$TARGET_DIR"/*raspberry*.cfg "$TARGET_DIR"/*ubuntu*.cfg; do
    [[ -e "$stock" ]] || continue
    if grep -qE '^\s*(seedfrom|fs_label)' "$stock" 2>/dev/null; then
        log_warn "перекрыт штатный $(basename "$stock") — он задавал свой источник seed"
    fi
done
