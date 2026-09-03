#!/usr/bin/env bash
# Включить модули cloud-init `growpart` и `resizefs`.
#
# ЗАЧЕМ. Без них корень не растёт до размера носителя, и это тихо:
# cloud-init отрабатывает успешно и рапортует SUCCESS, потому что со своей
# точки зрения делает всё, что ему поручено.
#
# ЗАМЕР 2026-09-03, Raspberry Pi OS Trixie на карте 58 ГБ. Корень остался
# 11.5 ГБ при 46 ГБ свободного места между ним и разделом `cidata`:
#
#   sdb2  start 1064960    size 24100864   <- корень
#                          ...46 ГБ дыры...
#   sdb3  start 121331712  size 204800     <- cidata
#
# Причина не в пакетах: `cloud-guest-utils`, `cloud-init` и `e2fsprogs`
# в образе стоят, `/usr/bin/growpart` и `/sbin/resize2fs` на месте.
# Дело в том, что список `cloud_init_modules` в /etc/cloud/cloud.cfg у Pi OS
# не содержит ни `growpart`, ни `resizefs` — значит `growpart:` и
# `resize_rootfs:` из seed читать некому.
#
# Своего механизма у образа тоже нет: `raspberrypi-sys-mods/firstboot`
# и `resize2fs_once` в нём отсутствуют, конкурента у cloud-init не будет.
set -euo pipefail

RED='\033[0;31m'; GREEN='\033[0;32m'; YELLOW='\033[1;33m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} cloud-growroot: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} cloud-growroot: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} cloud-growroot: $*"; }

CFG=/etc/cloud/cloud.cfg

[[ -f "$CFG" ]] || {
    log_error "нет $CFG — cloud-init не установлен"
    log_error "без него корень не вырастет, а seed не прочитается вовсе"
    exit 1
}

# Инструменты, которыми модули пользуются. Их отсутствие — отказ, а не
# предупреждение: включённый модуль без своей утилиты промолчит на
# устройстве, а это ровно тот исход, который мы и чиним.
missing=()
command -v growpart  >/dev/null 2>&1 || missing+=("growpart (пакет cloud-guest-utils)")
command -v resize2fs >/dev/null 2>&1 || missing+=("resize2fs (пакет e2fsprogs)")
if (( ${#missing[@]} )); then
    log_error "в образе нет: ${missing[*]}"
    log_error "поставьте их слоем INSTALL до этого расширения"
    exit 1
fi

if grep -qE '^\s*-\s*growpart\s*$' "$CFG" && grep -qE '^\s*-\s*resizefs\s*$' "$CFG"; then
    log_info "модули уже включены — ничего не меняю"
    exit 0
fi

# Правим САМ cloud.cfg, а не кладём файл в cloud.cfg.d, и это не лень.
#
# `util.read_conf_d` сливает фрагменты через `mergemanydict`, который списки
# НЕ склеивает: побеждает целиком тот, что старше по приоритету. Фрагмент
# с `cloud_init_modules: [growpart, resizefs]` заменил бы весь список и унёс
# бы `users_groups`, `ssh` и `set_passwords` — то есть карта пришла бы без
# пользователя и без ключей. Лечение оказалось бы хуже болезни.
#
# Вставляем после `write_files`/`write-files` (имя модуля менялось между
# версиями) — там же, где они стоят в каноническом cloud.cfg у Ubuntu,
# и до `disk_setup`/`mounts`: расширять раздел надо раньше, чем на него
# что-то смонтируют.
cp -a "$CFG" "$CFG.before-growroot"

awk '
  /^cloud_init_modules:/ { in_list = 1 }
  in_list && /^[^ \t-]/ && !/^cloud_init_modules:/ { in_list = 0 }
  { print }
  in_list && !done && /^[ \t]*-[ \t]*write[_-]files[ \t]*$/ {
      # Отступ берётся У СТРОКИ-ЯКОРЯ, а не пишется константой.
      # Замер: с жёстко вписанным одним пробелом получается смесь
      # одно- и двухпробельных элементов одного блока, а это НЕВАЛИДНЫЙ
      # YAML — cloud.cfg перестаёт разбираться целиком, и лечение
      # выходит хуже болезни.
      indent = $0
      sub(/-.*$/, "", indent)
      print indent "- growpart"
      print indent "- resizefs"
      done = 1
  }
  END { if (!done) exit 3 }
' "$CFG" > "$CFG.new" || {
    rm -f "$CFG.new"
    log_error "в $CFG не нашёлся якорь write_files внутри cloud_init_modules"
    log_error "список устроен иначе, чем ожидалось — впишите модули вручную"
    exit 1
}

mv "$CFG.new" "$CFG"
log_info "в cloud_init_modules добавлены growpart и resizefs"
log_info "прежний файл сохранён как $CFG.before-growroot"

# Сказать вслух про соседа: раздел seed создаётся В КОНЦЕ диска, и корень
# растёт только до его начала. Это не мешает — между ними обычно всё
# свободное место, — но знать об этом надо, иначе «вырос не до конца»
# выглядит как недоработка.
log_warn "корень вырастет до начала раздела cidata, а не до конца носителя"
