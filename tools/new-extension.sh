#!/usr/bin/env bash
# Scaffold a new extension.
#
# Without this, a new extension is written by copying a neighbour — together
# with its capabilities in the manifest and its paths in the unit file. Those
# copied values look deliberate and survive review, which is exactly how the
# eight diverging copies of get_cloud_user.sh happened.
#
# The scaffold also registers the directory in tools/lib-targets.txt right
# away: an author who has to add that line by hand will copy the shared code
# instead, and the copies start drifting again.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "$SCRIPT_DIR/.." && pwd)"

# The manifest field `family` is not the directory name: `deb` lives under
# extensions/debian/. The resolver behind `EXTENSION` finds an extension by the
# `name` field of its manifest, not by the directory — but the older `COPY_IN`
# form addresses the directory directly, and 22 such lines in 12 VMFILEs of the
# main repository still do (counted 2026-09-03). So the mapping stays explicit.
family_dir() {
    case "$1" in
        deb) echo debian ;;
        openwrt) echo openwrt ;;
        *) return 1 ;;
    esac
}

usage() {
    cat >&2 <<'USAGE'
Заводит скелет нового расширения.

  tools/new-extension.sh <имя> [ключи]

Ключи:
  --family <deb|openwrt>   семейство пакетов (умолчание: deb)
  --arch <список>          через запятую (умолчание: amd64,arm64)
  --no-firstboot           только фаза build: не создавать configure.sh и юнит
  --no-shared-user         не подключать общий resolve пользователя cloud-init
  -h, --help               эта справка

Пример:
  tools/new-extension.sh tailscale --arch amd64,arm64
USAGE
}

name=""
family="deb"
arch="amd64,arm64"
want_firstboot=1
want_shared_user=1

while [[ $# -gt 0 ]]; do
    case "$1" in
        -h|--help) usage; exit 0 ;;
        --family) family="${2:?--family требует значения}"; shift 2 ;;
        --arch) arch="${2:?--arch требует значения}"; shift 2 ;;
        --no-firstboot) want_firstboot=0; shift ;;
        --no-shared-user) want_shared_user=0; shift ;;
        -*) echo "Неизвестный ключ: $1" >&2; usage; exit 2 ;;
        *)
            [[ -n "$name" ]] && { echo "Имя уже задано: $name" >&2; exit 2; }
            name="$1"; shift ;;
    esac
done

[[ -n "$name" ]] || { echo "Не задано имя расширения." >&2; usage; exit 2; }

# The validator requires name == directory name, so reject anything that would
# not survive it rather than creating a directory that fails checks.
[[ "$name" =~ ^[a-z0-9][a-z0-9-]*$ ]] || {
    echo "Имя должно быть в нижнем регистре из букв, цифр и дефисов: '$name'" >&2
    exit 2
}

dir_name="$(family_dir "$family")" || {
    echo "Неизвестное семейство: '$family' (ожидается deb или openwrt)" >&2
    exit 2
}

ext_dir="$REPO_ROOT/extensions/$dir_name/$name"
[[ -e "$ext_dir" ]] && {
    echo "Уже существует: extensions/$dir_name/$name" >&2
    exit 1
}

# openwrt/ holds files delivered by UPLOAD, not extensions with install.sh —
# the validator skips it. Say so instead of producing something it ignores.
if [[ "$family" == "openwrt" ]]; then
    echo "Внимание: extensions/openwrt/ сегодня расширениями не является —" >&2
    echo "там файлы, доставляемые UPLOAD, и валидатор их пропускает." >&2
    echo "См. docs/extensions.md, раздел «extensions/openwrt/ расширениями не является»." >&2
fi

arch_yaml="[$(echo "$arch" | tr -d ' ' | sed 's/,/, /g')]"
# Префикс переменных окружения для примеров в README и install.sh: имя
# расширения заглавными, дефисы в подчёркивания (`code-server` ->
# `CODE_SERVER`). Так названы переменные у x11vnc и code-server.
env_prefix="$(echo "$name" | tr 'a-z-' 'A-Z_')"
if [[ "$want_firstboot" -eq 1 ]]; then
    phase_yaml="[build, firstboot]"
else
    phase_yaml="[build]"
fi

mkdir -p "$ext_dir"

cat > "$ext_dir/extension.yaml" <<EOF
name: $name
version: 0.1.0
family: $family
arch: $arch_yaml
phase: $phase_yaml
# Способности, а не имена расширений: на них ссылаются другие расширения.
# Выводи их ИЗ КОДА — из того, что install.sh реально ставит и что требуют
# юниты, — а не из головы. Словарь способностей в docs/extensions.md.
provides: []
requires: []
conflicts: []
EOF

cat > "$ext_dir/install.sh" <<'EOF'
#!/usr/bin/env bash
# Build phase: runs INSIDE the guest during image build, via virt-customize.
#
# systemd is not running here — this is a chroot. Anything that needs a live
# daemon belongs in configure.sh, which runs on first boot on the device.
#
# Packages installed here are baked into the image, so every device gets
# identical content. That is the point: moving an install to first boot trades
# a guarantee for a hope, because the repository may have moved on by then.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} $*"; }

# Placeholder used by the commented-out install below; drop the disable once
# the TODO is filled in.
# shellcheck disable=SC2034
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Параметры из VMFILE приезжают сюда ПЕРЕМЕННЫМИ ОКРУЖЕНИЯ как есть:
#
#   EXTENSION __NAME__ __ENVPREFIX___PORT=9002
#
# Таблицы соответствия «параметр VMFILE -> переменная скрипта» нет намеренно:
# она устарела бы молча. Единственный источник правды о том, какие переменные
# читает расширение, — этот файл, поэтому умолчания объявляются здесь, а README
# их перечисляет. Файл config.yaml рядом со скриптом такой ручкой НЕ является:
# он лежит в кеше источников, который `bs extension sync` перезаписывает
# целиком, и правка на хосте держится до первой синхронизации.
#
# TODO: объявить свои параметры, если они есть.
# __ENVPREFIX___PORT="${__ENVPREFIX___PORT:-9001}"

log_info "Installing __NAME__..."

# TODO: package names differ between targets. Branch on /etc/os-release here
# rather than declaring the distribution in the manifest — the guest knows
# itself, and a declared table goes stale silently.
apt-get update || exit 1
apt-get install -y \
  __NAME__ || exit 1

# TODO: install units and configs shipped next to this script, if any.
# if [[ -f "$SCRIPT_DIR/__NAME__.service" ]]; then
#     install -m 0644 "$SCRIPT_DIR/__NAME__.service" /etc/systemd/system/
# fi

log_info "__NAME__ installed"
EOF

if [[ "$want_firstboot" -eq 1 ]]; then
    cat > "$ext_dir/configure.sh" <<'EOF'
#!/usr/bin/env bash
# First-boot phase: runs ON THE DEVICE, started by configure-__NAME__.service.
#
# Only what genuinely belongs here: binding to the cloud-init user, generating
# keys, anything that depends on this particular machine. Installing packages
# here is not equivalent to installing them at build time.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EOF

    if [[ "$want_shared_user" -eq 1 ]]; then
        cat >> "$ext_dir/configure.sh" <<'EOF'

# Shared resolver, vendored from lib/ — do not copy it by hand.
# Placeholder until the TODO below uses it; drop the disable then.
# shellcheck disable=SC2034
CLOUD_USER="$("$SCRIPT_DIR/get_cloud_user.sh")" || {
    echo "Не удалось определить пользователя cloud-init" >&2
    exit 1
}
EOF
    fi

    cat >> "$ext_dir/configure.sh" <<'EOF'

# TODO: configure for this machine.

systemctl disable configure-__NAME__.service || true
EOF

    cat > "$ext_dir/configure-$name.service" <<EOF
[Unit]
Description=Configure $name on first boot
# cloud-init must have created the user before the resolver can find it.
After=cloud-init.service
Wants=cloud-init.service

[Service]
Type=oneshot
RemainAfterExit=yes
ExecStart=/opt/vmsetup/$name/configure.sh

[Install]
WantedBy=multi-user.target
EOF
fi

cat > "$ext_dir/README.md" <<EOF
# $name

<одна фраза: что это расширение даёт>

## Зачем

<чего не хватает без него и чем это заканчивается на устройстве. Ссылайся на
замер, а не на общее соображение: «замерено на собранном образе <такой-то>,
<дата>» — так написаны README расширений nocloud-cidata и docker.>

## Подключение

\`\`\`vmfile
EXTENSION $name
\`\`\`

Прежняя запись продолжает работать:

\`\`\`vmfile
COPY_IN <чекаут>/extensions/$dir_name/$name:/opt/vmsetup/
RUN_COMMAND chmod +x /opt/vmsetup/$name/*.sh
RUN_COMMAND /opt/vmsetup/$name/install.sh
\`\`\`

\`<чекаут>\` — путь до чекаута этого репозитория **относительно каталога
VMFILE**; в примерах основного репозитория это \`../../../../bisquite-extensions\`,
и глубина зависит от того, насколько глубоко лежит сам VMFILE.

## Параметры

<Если параметров нет — так и напиши: «Параметров нет», и убери таблицу.>

Инструкция \`EXTENSION\` передаёт параметры переменными окружения:

\`\`\`vmfile
EXTENSION $name ${env_prefix}_PORT=9002
\`\`\`

| Переменная | Что задаёт | Умолчание |
|---|---|---|
| \`${env_prefix}_PORT\` | <что> | <умолчание из install.sh> |

Таблицы соответствия «параметр VMFILE -> переменная скрипта» нет: VMFILE
называет переменные их собственными именами, а единственный источник правды —
\`install.sh\`. Значит, эта таблица обязана совпадать с ним, и правится вместе
с ним.

## Что делает

- **Сборка** (\`install.sh\`) — <какие пакеты, какие файлы>
EOF

if [[ "$want_firstboot" -eq 1 ]]; then
    cat >> "$ext_dir/README.md" <<EOF
- **Первая загрузка** (\`configure.sh\`) — <что настраивается на устройстве>
EOF
fi

cat >> "$ext_dir/README.md" <<EOF

## Отказы

<Что расширение отвергает и почему громко, а не молча. Пустой раздел здесь —
признак, что отказов нет ни одного, а это редко правда.>

## Ограничения

<Чего расширение НЕ делает и что обязан дать кто-то другой. Сюда же —
ограничение архитектуры: \`phase: build\` требует совпадения архитектур хоста
и образа, потому что libguestfs не выполняет код в госте чужой архитектуры.>

## Проверка

<Как убедиться, что оно отработало: команда на собранном образе
(\`virt-cat\`, \`virt-ls\`) и команда на устройстве после первой загрузки.>

## Проверено на

| Система | Архитектура | Дата |
|---|---|---|
| <заполни после первой настоящей сборки> | | |
EOF

chmod +x "$ext_dir/install.sh"
[[ -f "$ext_dir/configure.sh" ]] && chmod +x "$ext_dir/configure.sh"

# Substitute the name into the heredoc'd templates. Done after writing so the
# templates stay quoted — an unquoted heredoc would expand $SCRIPT_DIR and
# ${BASH_SOURCE} at scaffold time and produce broken scripts.
for f in "$ext_dir/install.sh" "$ext_dir/configure.sh"; do
    [[ -f "$f" ]] || continue
    sed -i "s/__NAME__/$name/g; s/__ENVPREFIX__/$env_prefix/g" "$f"
done

registered=0
if [[ "$want_firstboot" -eq 1 && "$want_shared_user" -eq 1 ]]; then
    printf '%-31s # configure.sh — пользователь cloud-init\n' \
        "extensions/$dir_name/$name" >> "$REPO_ROOT/tools/lib-targets.txt"
    bash "$SCRIPT_DIR/sync-lib.sh" >/dev/null
    registered=1
fi

echo
echo "Создано: extensions/$dir_name/$name"
echo
echo "  extension.yaml            заполни provides/requires ПО КОДУ"
echo "  install.sh                фаза сборки"
[[ "$want_firstboot" -eq 1 ]] && echo "  configure.sh              фаза первой загрузки"
[[ "$want_firstboot" -eq 1 ]] && echo "  configure-$name.service   юнит первой загрузки"
echo "  README.md                 заполни, чем это пользоваться"
[[ "$registered" -eq 1 ]] && echo "  get_cloud_user.sh         сгенерирован из lib/, руками не править"
echo
echo "Дальше: заполнить TODO, потом  bash tools/check.sh"
