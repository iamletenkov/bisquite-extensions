#!/usr/bin/env bash
# yq — статический бинарь mikefarah/yq.
set -euo pipefail

GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} yq: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} yq: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} yq: $*"; }

# Версия прибита: `latest` означал бы, что тот же VMFILE завтра соберёт
# другой образ. Перекрывается параметром YQ_VERSION.
YQ_VERSION="${YQ_VERSION:-v4.45.1}"

# ПОЧЕМУ НЕ `apt install yq`, ХОТЯ ПАКЕТ БЫВАЕТ.
#
# Имя `yq` носят ДВА разных инструмента с несовместимыми языками
# запросов. В репозиториях Debian и Ubuntu лежит обёртка над jq
# (kislyuk/yq); отдельно существует mikefarah/yq на Go. Выражение
# `.x // empty` законно у первого и отвергается вторым:
#
#     Error: 1:19: invalid input text "empty"
#
# Пока расширения ставили пакет «когда он есть» и бинарь «когда нет»,
# один и тот же VMFILE давал разный инструмент на разных дистрибутивах,
# а расхождение вылезало не на сборке, а на первой загрузке устройства.
# Замер 2026-09-06 на Jetson Nano: три службы настройки упали с
# «не дождался пользователя cloud-init», хотя пользователь был на месте.
#
# Поэтому здесь ставится ровно один инструмент, всегда один и тот же.
# Запросы в расширениях написаны в форме `// ""`, законной у обоих, —
# но полагаться на это не приходится.
if command -v yq >/dev/null 2>&1; then
    have="$(yq --version 2>&1 | head -1)"
    case "$have" in
        *mikefarah*) log_info "уже установлен: $have"; exit 0 ;;
        *) log_warn "найден ДРУГОЙ yq ($have) — перекрываю своим в /usr/local/bin" ;;
    esac
fi

arch="$(dpkg --print-architecture)"
case "$arch" in
    arm64|amd64) ;;
    *) log_error "неподдерживаемая архитектура: $arch"; exit 1 ;;
esac

url="https://github.com/mikefarah/yq/releases/download/${YQ_VERSION}/yq_linux_${arch}"
log_info "качаю ${YQ_VERSION} для $arch"
if ! wget -nv -O /usr/local/bin/yq "$url"; then
    log_error "не скачался: $url"
    exit 1
fi
chmod 0755 /usr/local/bin/yq

# Полным путём: PATH гостевой оболочки virt-customize это
# /sbin:/usr/sbin:/bin:/usr/bin, без /usr/local/bin, и голое `yq`
# дало бы 127 — на этом уже спотыкались с btop.
if ! /usr/local/bin/yq --version >/dev/null 2>&1; then
    log_error "скачанный бинарь не запускается"
    exit 1
fi
log_info "установлен: $(/usr/local/bin/yq --version 2>&1 | head -1)"
