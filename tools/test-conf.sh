#!/usr/bin/env bash
# shellcheck disable=SC2016,SC2054  # literal $(…) and comma lists are the test data
# Тесты lib/bisquite-conf на подменённом корне (BISQUITE_CONF_ROOT): root не
# нужен, systemd не нужен. Совместимость разбора с EnvironmentFile сверяется
# с настоящим systemd (`systemd-run --user`), если он доступен, иначе — с
# эталоном, снятым с systemd 257.
#
#   tools/test-conf.sh        код 0 — все проверки прошли

set -uo pipefail
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO="$(dirname "$HERE")"
LIB="$REPO/lib/bisquite-conf"

TMP="$(mktemp -d)"
trap 'rm -r -f -- "$TMP"' EXIT

pass=0; fail=0
ok(){ pass=$((pass + 1)); }
bad(){ fail=$((fail + 1)); echo "FAIL: $*" >&2; }
check(){ local what="$1"; shift; if "$@"; then ok; else bad "$what"; fi; }
check_not(){ local what="$1"; shift; if "$@"; then bad "$what"; else ok; fi; }
eq(){ local what="$1" want="$2" got="$3"; if [[ "$want" == "$got" ]]; then ok; else bad "$what: ждали [$want], получили [$got]"; fi; }

# A fresh scratch root per scenario.
new_root(){
    ROOT="$(mktemp -d "$TMP/root.XXXXXX")"
    export BISQUITE_CONF_ROOT="$ROOT"
    mkdir -p "$ROOT/ext" "$ROOT/bin"
}
conf(){ bash "$LIB" "$@"; }
lib(){ bash -c 'set -euo pipefail; source "$1"; shift; "$@"' _ "$LIB" "$@"; }
cfg(){ printf '%s/etc/bisquite/%s/config' "$ROOT" "$1"; }

# Fake systemctl: `is-system-running` answers $FAKE_STATE, the rest is logged.
fake_systemctl(){
    cat > "$ROOT/bin/systemctl" <<'EOF'
#!/usr/bin/env bash
if [[ "${1:-}" == is-system-running ]]; then echo "${FAKE_STATE:-running}"; [[ "${FAKE_STATE:-running}" == running ]]; exit; fi
echo "$*" >> "${BISQUITE_CONF_ROOT}/systemctl.log"
EOF
    chmod +x "$ROOT/bin/systemctl"
}

write_schema(){
    cat > "$ROOT/ext/knobs" <<'EOF'
# ключ          тип                          умолчание      описание
T_BOOL          bool                         0              булев
T_INT           int                          5              целое
T_PORT          port                         5900           порт
T_HOST          host                         127.0.0.1      адрес
T_PATH          path                         —              путь
T_STR           str                          "a b"          строка с пробелом в умолчании
T_ENUM          enum:localhost,all           localhost      перечисление
T_RE            "re:^[a-z]+( [a-z]+)?$"      —              шаблон с пробелом
T_LIST          list:port                    80,443         список портов
T_LISTENUM      list:enum:home,back          home           список из перечисления
T_SECRET        secret                       —              секрет
T_SECRE         secret:re:^[A-Za-z0-9]{8,}$  —              секрет с шаблоном
T_PASS          secret:hook                  —              пароль через хук
T_PASSFILE      ro:path                      —              файл пароля; только через хук
T_RO            ro:str                       —              только через --allow-ro
OPEN_*          str                          —              открытое пространство
OPEN_PORT       port                         8080           явный ключ внутри шаблона
EOF
}

# ===========================================================================
echo "== типы и проверка значений =="
new_root; write_schema
check "conf_init на тестовой схеме" lib conf_init t "$ROOT/ext/knobs"

valid=(
    T_BOOL=0 T_BOOL=1 T_INT=-3 T_INT=42 T_PORT=1 T_PORT=65535 T_HOST=::1
    T_HOST=robot.example.org T_PATH=/etc/x T_PATH= "T_STR=a b c" T_ENUM=all
    "T_RE=abc def" T_RE= T_LIST=1,2,3 T_LISTENUM=home,back
    'T_SECRET=p$ss`w"o\rd' T_SECRE=Abcdefgh1 OPEN_ANYTHING=x OPEN_PORT=9000
)
for p in "${valid[@]}"; do check "допустимо: $p" lib conf_validate t "$p"; done

invalid=(
    T_BOOL=2 T_BOOL=true T_INT=1.5 T_PORT=0 T_PORT=65536 T_PORT=http "T_HOST=a b"
    T_PATH=relative 'T_STR=$(id)' 'T_STR=`id`' T_ENUM=al "T_RE=Abc" T_LIST=1,,2
    T_LIST=1,x T_LIST= T_LISTENUM=home,up T_SECRE=short T_INT= T_ENUM= T_PORT=
    OPEN_PORT=http T_UNKNOWN=1 NOEQUALS
)
for p in "${invalid[@]}"; do check_not "отказ: $p" lib conf_validate t "$p" 2>/dev/null; done
check_not "отказ: перевод строки в str" lib conf_validate t $'T_STR=a\nb' 2>/dev/null
check_not "отказ: перевод строки в secret" lib conf_validate t $'T_SECRET=a\nT_BOOL=1' 2>/dev/null
check_not "отказ: CR в secret" lib conf_validate t $'T_SECRET=a\rb' 2>/dev/null

msg="$(lib conf_validate t T_ENUM=al 2>&1)"
check "текст отказа перечисляет допустимые значения" grep -q 'допустимо: localhost,all' <<< "$msg"
msg="$(lib conf_validate t T_NOPE=1 2>&1)"
check "текст отказа неизвестного ключа перечисляет ключи" grep -q 'есть: T_BOOL' <<< "$msg"
msg="$(conf set t T_RO=x 2>&1)"; rc=$?
check "ro-ключ через set — отказ" test "$rc" -ne 0
check "ro-ключ — текст из описания" grep -q 'только через --allow-ro' <<< "$msg"
check "ro-ключ через conf_set --allow-ro" lib conf_set t --allow-ro T_RO=x
msg="$(lib conf_validate t T_SECRE=short 2>&1)"
check_not "отказ секрета не печатает значение" grep -q short <<< "$msg"

echo "== схема: ошибки ловятся на загрузке =="
for broken in 'X_A bogus 1 d' 'X_A port http d' 'X_A "re:^(a$" — d' 'X_A secret:hook x d' \
              'x_lower str — d' 'X_A str' 'X_* str default d'; do
    new_root
    printf '%s\n' "$broken" > "$ROOT/ext/knobs"
    check_not "схема отвергнута: $broken" lib conf_init x "$ROOT/ext/knobs" 2>/dev/null
done
new_root
printf 'X_A str — d\nX_A int 1 d\n' > "$ROOT/ext/knobs"
check_not "схема отвергнута: ключ дважды" lib conf_init x "$ROOT/ext/knobs" 2>/dev/null
check_not "относительный путь схемы" lib conf_init x ext/knobs 2>/dev/null

# ===========================================================================
echo "== conf_init: регистрация, умолчания, повторная установка =="
new_root; write_schema
printf '#!/bin/sh\nexit 0\n' > "$ROOT/ext/knobs.apply"
printf '#!/bin/sh\nexit 0\n' > "$ROOT/ext/knobs.secret"
check "conf_init" lib conf_init t "$ROOT/ext/knobs"
eq "ссылка схемы" "$ROOT/ext/knobs" "$(readlink "$ROOT/opt/bisquite/knobs/t")"
eq "ссылка хука apply" "$ROOT/ext/knobs.apply" "$(readlink "$ROOT/opt/bisquite/knobs/t.apply")"
check "хук стал исполняемым" test -x "$ROOT/ext/knobs.apply"
eq "ссылка CLI" "$LIB" "$(readlink "$ROOT/usr/local/sbin/bisquite-conf")"
check "умолчание записано" grep -qx 'T_PORT=5900' "$(cfg t)"
check "умолчание с пробелом в кавычках" grep -qx 'T_STR="a b"' "$(cfg t)"
check_not "пустое умолчание не пишется" grep -q '^T_PATH=' "$(cfg t)"
check "описание ключа комментарием" grep -qx '# порт' "$(cfg t)"
eq "права 0600 при secret в схеме" 600 "$(stat -c %a "$(cfg t)")"

conf set --no-apply t T_PORT=5901 T_ENUM=all 2>/dev/null
echo '# правка оператора' >> "$(cfg t)"
check "повторный conf_init" lib conf_init t "$ROOT/ext/knobs"
eq "повторная установка не трогает заданное" 5901 "$(lib conf_get t T_PORT)"
check "комментарий оператора на месте" grep -qx '# правка оператора' "$(cfg t)"
eq "ключ не задублирован" 1 "$(grep -c '^T_PORT=' "$(cfg t)")"

# The new owner has no hooks: stale links must go (last installer wins).
mkdir -p "$ROOT/ext2"; grep -v '^T_PASS ' "$ROOT/ext/knobs" > "$ROOT/ext2/knobs"
check "регистрация другим владельцем" lib conf_init t "$ROOT/ext2/knobs"
eq "последний установивший побеждает" "$ROOT/ext2/knobs" "$(readlink "$ROOT/opt/bisquite/knobs/t")"
check_not "чужой хук apply снят" test -e "$ROOT/opt/bisquite/knobs/t.apply"
check_not "чужой хук secret снят" test -e "$ROOT/opt/bisquite/knobs/t.secret"

echo "== conf_init --env: параметры VMFILE поверх =="
new_root; write_schema
check "первая установка" lib conf_init t "$ROOT/ext/knobs"
conf set --no-apply t T_INT=7 2>/dev/null
check "--env" env T_PORT=6000 OPEN_EXTRA=yes T_RO=nope NOT_OURS=1 \
    bash -c 'set -euo pipefail; source "$1"; conf_init t "$2" --env 2>/dev/null' _ "$LIB" "$ROOT/ext/knobs"
eq "параметр окружения применён" 6000 "$(lib conf_get t T_PORT)"
eq "шаблонный параметр окружения применён" yes "$(lib conf_get t OPEN_EXTRA)"
eq "заданное оператором, но не переданное — осталось" 7 "$(lib conf_get t T_INT)"
check_not "ro-параметр окружения пропущен" grep -q '^T_RO=' "$(cfg t)"
check_not "чужая переменная не попала" grep -q NOT_OURS "$(cfg t)"
check_not "неэкспортированная переменная не берётся" \
    bash -c 'set -euo pipefail; T_PORT=1234; source "$1"; conf_init t "$2" --env; grep -q 1234 "$3"' _ "$LIB" "$ROOT/ext/knobs" "$(cfg t)"
check_not "--env с неверным значением — отказ" env T_ENUM=al \
    bash -c 'set -euo pipefail; source "$1"; conf_init t "$2" --env 2>/dev/null' _ "$LIB" "$ROOT/ext/knobs"
eq "после отказа значение прежнее" localhost "$(lib conf_get t T_ENUM)"

# ===========================================================================
echo "== запись: комментарии, порядок, дубликаты, продолжения строк =="
new_root; write_schema
lib conf_init t "$ROOT/ext/knobs"
cat > "$(cfg t)" <<'EOF'
# шапка
T_INT=1
; другой комментарий

T_PORT=1\
2
T_BOOL=0
# между
T_INT=2
UNRELATED=keep
EOF
before_order="$(grep -n '' "$(cfg t)" | grep -E 'шапка|другой|между|UNRELATED' | cut -d: -f2-)"
check "set трёх ключей" conf set --no-apply t T_INT=9 T_PORT=22 OPEN_NEW=v 2>/dev/null
after_order="$(grep -E 'шапка|другой|между|UNRELATED' "$(cfg t)")"
eq "комментарии и чужие строки на месте и в порядке" "$before_order" "$after_order"
eq "дубликат схлопнут в одну строку" 1 "$(grep -c '^T_INT=' "$(cfg t)")"
eq "ключ заменён на месте первого вхождения" 2 "$(grep -n '^T_INT=9$' "$(cfg t)" | cut -d: -f1)"
check_not "строка продолжения удалена" grep -qx '2' "$(cfg t)"
eq "новый ключ — в конце" OPEN_NEW=v "$(tail -n 1 "$(cfg t)")"
eq "продолжение прочитано до правки" 22 "$(lib conf_get t T_PORT)"
check_not "временных файлов не осталось" compgen -G "$ROOT/etc/bisquite/t/.config.*"

echo "== права: 0644 без секретов, не ослабляются =="
new_root
printf 'P_A port 1 порт\n' > "$ROOT/ext/knobs"
lib conf_init p "$ROOT/ext/knobs"
eq "без секретов — 0644" 644 "$(stat -c %a "$(cfg p)")"
chmod 600 "$(cfg p)"
conf set --no-apply p P_A=2 2>/dev/null
eq "закрытый оператором файл остаётся 0600" 600 "$(stat -c %a "$(cfg p)")"

# ===========================================================================
echo "== файл не исполняется =="
new_root; write_schema
lib conf_init t "$ROOT/ext/knobs"
marker="$ROOT/pwned"
printf 'T_STR=$(touch %s)\nT_PATH=`touch %s`\nOPEN_X=a;touch %s\n' "$marker" "$marker" "$marker" >> "$(cfg t)"
got="$(bash -c 'set -euo pipefail; source "$1"; conf_load t; printf "%s|%s|%s" "$T_STR" "$T_PATH" "$OPEN_X"' _ "$LIB")"
check_not "conf_load не исполнил \$(…), \`…\` и ;" test -e "$marker"
eq "значения прочитаны буквально" "\$(touch $marker)|\`touch $marker\`|a;touch $marker" "$got"
conf show t > /dev/null 2>&1
check_not "show не исполнил" test -e "$marker"
check "show помечает неверное значение" grep -q 'НЕВЕРНО' <<< "$(conf show t 2>/dev/null)"
check_not "conf_check находит неверные значения" lib conf_check t 2>/dev/null

echo "== экранирование: запись и обратное чтение =="
new_root; write_schema
lib conf_init t "$ROOT/ext/knobs"
tricky='sp  ace "dq" \back $dollar `tick'"'"'sq'
check "секрет со спецсимволами записан" lib conf_set t "T_SECRET=$tricky"
eq "прочитан библиотекой байт в байт" "$tricky" "$(lib conf_get t T_SECRET)"
check "в файле значение в двойных кавычках" grep -q '^T_SECRET="' "$(cfg t)"

# ===========================================================================
echo "== stdin: KEY=- =="
new_root; write_schema
lib conf_init t "$ROOT/ext/knobs"
printf 's3cr3t-from-stdin' | conf set --no-apply t T_SECRET=- 2>/dev/null
eq "значение со stdin без перевода строки" s3cr3t-from-stdin "$(lib conf_get t T_SECRET)"
printf 'with-newline\n' | conf set --no-apply t T_SECRET=- 2>/dev/null
eq "значение со stdin с переводом строки" with-newline "$(lib conf_get t T_SECRET)"
check_not "два значения со stdin — отказ" bash -c 'echo x | bash "$1" set --no-apply t T_SECRET=- T_STR=- 2>/dev/null' _ "$LIB"

# ===========================================================================
echo "== secret:hook =="
new_root; write_schema
cat > "$ROOT/ext/knobs.secret" <<'EOF'
#!/usr/bin/env bash
IFS= read -r -d '' v || true
echo "$1:$v" > "$BISQUITE_CONF_ROOT/hook.seen"
case "$v" in
    refuse) echo "хук: отказ" >&2; exit 3 ;;
    garbage) echo "T_UNKNOWN=1" ;;
    badvalue) echo "T_PASSFILE=relative" ;;
    "") echo "T_PASSFILE=" ;;
    *) echo "T_PASSFILE=/etc/t/passwd" ;;
esac
EOF
lib conf_init t "$ROOT/ext/knobs"
conf set --no-apply t T_BOOL=1 2>/dev/null
sum_before="$(sha256sum "$(cfg t)")"
printf 'hunter2' | conf set --no-apply t T_PASS=- 2>/dev/null
eq "хук получил ключ и значение по stdin" "T_PASS:hunter2" "$(cat "$ROOT/hook.seen")"
eq "производная пара записана" /etc/t/passwd "$(lib conf_get t T_PASSFILE)"
check_not "сам пароль в файл не попал" grep -q hunter2 "$(cfg t)"
check_not "ключ secret:hook в файл не попал" grep -q '^T_PASS=' "$(cfg t)"
for v in refuse garbage badvalue; do
    cp "$(cfg t)" "$ROOT/snap"
    printf '%s' "$v" | conf set --no-apply t T_PASS=- T_BOOL=0 2>/dev/null; rc=$?
    check "хук '$v': код ненулевой" test "$rc" -ne 0
    check "хук '$v': не записано ничего (и явный T_BOOL тоже)" cmp -s "$ROOT/snap" "$(cfg t)"
done
check_not "явный ключ и тот же ключ от хука — отказ" \
    bash -c 'printf x | bash "$1" set --no-apply t T_PASS=- T_PASSFILE=/y 2>/dev/null' _ "$LIB"
rm -f "$ROOT/opt/bisquite/knobs/t.secret"
check_not "хука нет — отказ" bash -c 'printf x | bash "$1" set --no-apply t T_PASS=- 2>/dev/null' _ "$LIB"
: "$sum_before"

# ===========================================================================
echo "== применение: хук, загрузка системы, --apply/--no-apply =="
new_root; write_schema; fake_systemctl
cat > "$ROOT/ext/knobs.apply" <<'EOF'
#!/usr/bin/env bash
echo "apply $*" >> "$BISQUITE_CONF_ROOT/apply.log"
[[ -e "$BISQUITE_CONF_ROOT/apply.fail" ]] && exit 4
exit 0
EOF
lib conf_init t "$ROOT/ext/knobs"
export PATH="$ROOT/bin:$PATH"
FAKE_STATE=running conf set t T_BOOL=1 T_INT=3 2>/dev/null
eq "running: хук вызван со списком ключей" "apply T_BOOL T_INT" "$(tail -n 1 "$ROOT/apply.log")"
rm -f "$ROOT/apply.log"
for st in starting initializing offline; do
    msg="$(FAKE_STATE=$st conf set t T_BOOL=0 2>&1)"; rc=$?
    eq "$st: set успешен" 0 "$rc"
    check_not "$st: хук не вызван" test -e "$ROOT/apply.log"
done
check "starting: сказано, что применится при старте служб" grep -q 'применится при старте служб' <<< "$msg"
FAKE_STATE=running conf set --no-apply t T_BOOL=1 2>/dev/null
check_not "--no-apply: хук не вызван" test -e "$ROOT/apply.log"
FAKE_STATE=starting conf set --apply t T_BOOL=0 2>/dev/null
check "--apply во время загрузки: хук вызван" test -e "$ROOT/apply.log"
touch "$ROOT/apply.fail"
FAKE_STATE=running conf set t T_BOOL=1 2>/dev/null; rc=$?
check "хук отказал — код ненулевой" test "$rc" -ne 0
eq "хук отказал — запись всё равно состоялась" 1 "$(lib conf_get t T_BOOL)"
FAKE_STATE=running conf set t T_ENUM=al 2>/dev/null; rc=$?
check "опечатка в значении — ненулевой код" test "$rc" -ne 0

# ===========================================================================
echo "== миграция config.yaml =="
new_root
cat > "$ROOT/ext/knobs" <<'EOF'
Y_USER    str                      —         пользователь
Y_PORT    port                     9001      порт
Y_FLAGS   str                      —         флаги
Y_NAV     enum:true,false          false     панель
Y_LIST    list:enum:home,back      home      кнопки
Y_URLS    list:str                 —         адреса
EOF
mkdir -p "$ROOT/etc/bisquite/y"
cat > "$ROOT/etc/bisquite/y/config.yaml" <<'EOF'
# comment
USER:
PORT: 9002   # port
FLAGS: "--a --b" # flags
IGNORED: 'x'
NAV_BAR:
  ENABLED: true
  BUTTONS: ['home', 'back']
URLS: []
EOF
check "миграция" lib conf_init y "$ROOT/ext/knobs" \
    --migrate-yaml USER=Y_USER,PORT=Y_PORT,FLAGS=Y_FLAGS,NAV_BAR.ENABLED=Y_NAV,NAV_BAR.BUTTONS=Y_LIST,URLS=Y_URLS 2>/dev/null
eq "скаляр с комментарием" 9002 "$(lib conf_get y Y_PORT)"
eq "строка в кавычках" "--a --b" "$(lib conf_get y Y_FLAGS)"
eq "вложенный ключ" true "$(lib conf_get y Y_NAV)"
eq "flow-список" home,back "$(lib conf_get y Y_LIST)"
check_not "config.yaml удалён" test -e "$ROOT/etc/bisquite/y/config.yaml"
new_root
printf 'Y_PORT port 9001 порт\n' > "$ROOT/ext/knobs"
mkdir -p "$ROOT/etc/bisquite/y"; printf 'PORT: http\n' > "$ROOT/etc/bisquite/y/config.yaml"
check_not "неверное значение в YAML — отказ" lib conf_init y "$ROOT/ext/knobs" --migrate-yaml PORT=Y_PORT 2>/dev/null
check "после отказа config.yaml на месте" test -e "$ROOT/etc/bisquite/y/config.yaml"

# ===========================================================================
echo "== совместимость с systemd EnvironmentFile =="
new_root
env_file="$ROOT/tricky.env"
{
    printf '# comment\n; semicolon comment\n'
    printf 'PLAIN=value\n'
    printf 'SPACED =  padded value   \n'
    printf 'DQ="a \\"quoted\\" \\\\ back \\$ dollar \\` tick \\n other"\n'
    printf "SQ='single \"x\" \\\\ raw'\n"
    printf 'MIXED="a"'"'b'"'c\n'
    printf 'CONT=first\\\nsecond\n'
    printf 'DQCONT="one \\\ntwo"\n'
    printf 'EMPTY=\nEMPTYQ=""\nHASH=a#b\nINNER=a "b" c\n'
    printf 'TRAIL="kept  "   \n\tTABKEY=tab\nDUP=1\nDUP=2\n'
    printf 'DOLLAR=$(touch /nonexistent)\nBACKTICK=`id`\nESC=a\\ b\\\\c\n'
    printf 'CRLF=value\r\n'
    printf '# comment ending in backslash \\\nAFTERCOMMENT=visible\n'
    printf 'SQMULTI='"'"'line1\nline2'"'"'\n'
    printf 'NOEOL=x'
} > "$env_file"

# Expected values, taken from systemd 257 (`systemd-run --user -p
# EnvironmentFile=`). AFTERCOMMENT follows v254+: see the parser's header.
declare -A expect=(
    [PLAIN]='value' [SPACED]='padded value' [DQ]='a "quoted" \ back $ dollar ` tick \n other'
    [SQ]='single "x" \ raw' [MIXED]='abc' [CONT]='firstsecond' [DQCONT]='one two'
    [EMPTY]='' [EMPTYQ]='' [HASH]='a#b' [INNER]='a "b" c' [TRAIL]='kept  ' [TABKEY]='tab'
    [DUP]='2' [DOLLAR]='$(touch /nonexistent)' [BACKTICK]='`id`' [ESC]='a b\c' [CRLF]='value'
    [AFTERCOMMENT]='visible' [SQMULTI]=$'line1\nline2' [NOEOL]='x'
)
declare -A got=()
while IFS= read -r -d '' rec; do
    got[${rec%%=*}]="${rec#*=}"
done < <(bash -c 'source "$1"; _conf_parse_file "$2"; for i in "${!_CONF_REC_KEY[@]}"; do printf "%s=%s\0" "${_CONF_REC_KEY[i]}" "${_CONF_REC_VAL[i]}"; done' _ "$LIB" "$env_file")
for k in "${!expect[@]}"; do eq "эталон: $k" "${expect[$k]}" "${got[$k]-<нет>}"; done

if command -v systemd-run >/dev/null 2>&1 \
   && systemd-run --user --wait --pipe -q /bin/true >/dev/null 2>&1; then
    declare -A sd=()
    while IFS= read -r -d '' rec; do
        [[ -n "${expect[${rec%%=*}]+x}" ]] && sd[${rec%%=*}]="${rec#*=}"
    done < <(systemd-run --user --wait --pipe -q -p EnvironmentFile="$env_file" /usr/bin/env -0 2>/dev/null)
    for k in "${!expect[@]}"; do eq "systemd $(systemctl --version | awk 'NR==1{print $2}'): $k" "${sd[$k]-<нет>}" "${got[$k]-<нет>}"; done

    # What the writer produces must come back unchanged through systemd.
    new_root; write_schema
    lib conf_init t "$ROOT/ext/knobs"
    lib conf_set t "T_SECRET=$tricky" "T_STR=two  spaces" 'OPEN_Q=a"b\c'
    declare -A sd2=()
    while IFS= read -r -d '' rec; do sd2[${rec%%=*}]="${rec#*=}"; done \
        < <(systemd-run --user --wait --pipe -q -p EnvironmentFile="$(cfg t)" /usr/bin/env -0 2>/dev/null)
    eq "systemd читает записанный секрет" "$tricky" "${sd2[T_SECRET]-<нет>}"
    eq "systemd читает строку с пробелами" "two  spaces" "${sd2[T_STR]-<нет>}"
    eq "systemd читает шаблонный ключ с кавычкой" 'a"b\c' "${sd2[OPEN_Q]-<нет>}"
else
    echo "  systemd-run --user недоступен — сверка только с эталоном"
fi

# ===========================================================================
echo "== схемы доменов в репозитории =="
while IFS= read -r schema; do
    case "$schema" in
        */lib/knobs/*) domain="$(basename "$schema")" ;;
        *) domain="$(basename "$(dirname "$schema")")" ;;
    esac
    check "схема разбирается: ${schema#"$REPO"/}" \
        bash -c 'source "$1"; _conf_schema_load "$2" "$3"' _ "$LIB" "$domain" "$schema"
done < <(find "$REPO/lib/knobs" "$REPO/extensions" \( -path '*/lib/knobs/*' -o -name knobs \) -type f ! -name '*.*' 2>/dev/null | sort)


echo
echo "проверок: $((pass + fail)), не прошло: $fail"
(( fail == 0 ))
