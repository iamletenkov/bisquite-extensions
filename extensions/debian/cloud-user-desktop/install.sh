#!/usr/bin/env bash
# Фаза сборки: убрать вендорскую учётку и погасить автологин.
set -euo pipefail
GREEN='\033[0;32m'; YELLOW='\033[1;33m'; RED='\033[0;31m'; NC='\033[0m'
log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} cloud-user-desktop: $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} cloud-user-desktop: $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} cloud-user-desktop: $*"; }

HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REMOVE_USER="${CLOUD_USER_DESKTOP_REMOVE:-}"

# --- вендорская учётка --------------------------------------------------------
#
# УДАЛЯЕТСЯ НА СБОРКЕ, А НЕ НА ПЕРВОЙ ЗАГРУЗКЕ, и это выбор.
#
# Первая редакция ждала cloud-init и удаляла учётку только после того,
# как убедится в новой. Звучит осторожнее, а на деле хуже: до первой
# загрузки образ ВСЁ РАВНО несёт вендорского пользователя с публично
# известным паролем. У Q-engineering это `jetson`/`jetson`; замер
# 2026-09-06 на живой плате: `passwd -S jetson` отвечает `P`, пароль
# задан. Образ, который такое возит, скомпрометирован в момент сборки,
# а не в момент неудачной загрузки.
#
# Терять при этом нечего: тот же замер показал, что `/home/jetson`
# состоит из пустых Public/Pictures/Music/Downloads по 4 КБ, а все
# процессы от этого пользователя — сессия автологина, то есть следствие
# самого автологина.
#
# ЦЕНА НАЗВАНА ПРЯМО. Если seed cloud-init не прочитается, интерактивных
# учётных записей на устройстве не останется — только root с вендорским
# паролем. Пароль root расширение не трогает намеренно: снять его
# значило бы превратить неудачную загрузку в кирпич.
if [[ -n "$REMOVE_USER" ]]; then
    if id "$REMOVE_USER" >/dev/null 2>&1; then
        log_info "удаляю вендорскую учётку '$REMOVE_USER' вместе с домашним каталогом"
        userdel -r "$REMOVE_USER" 2>/dev/null || {
            log_warn "userdel отказал, пробую без домашнего каталога"
            userdel "$REMOVE_USER" 2>/dev/null || log_warn "учётка осталась"
        }
        id "$REMOVE_USER" >/dev/null 2>&1 \
            && log_warn "'$REMOVE_USER' всё ещё существует" \
            || log_info "'$REMOVE_USER' удалён"
    else
        log_info "учётки '$REMOVE_USER' в образе нет — удалять нечего"
    fi
else
    log_info "удаление вендорской учётки не запрошено (CLOUD_USER_DESKTOP_REMOVE)"
fi

# --- автологин ----------------------------------------------------------------
#
# Гасится здесь же: он указывал на удалённого пользователя, и менеджер
# входа при следующей загрузке пытался бы войти под несуществующим.
# Обратно его включит служба первой загрузки, когда узнает имя
# пользователя cloud-init.
#
# Правятся оба менеджера: вендорские сборки нередко несут конфиг того,
# который не запущен. На Jetson Nano автологин был прописан И в
# lightdm.conf, И в gdm3/custom.conf, а работал gdm3.
if [[ -f /etc/gdm3/custom.conf ]]; then
    sed -i "s/^\s*AutomaticLoginEnable\s*=.*/AutomaticLoginEnable=False/" /etc/gdm3/custom.conf
    log_info "gdm3: автологин выключен до первой загрузки"
fi
for conf in /etc/lightdm/lightdm.conf /etc/lightdm/lightdm.conf.d/*.conf; do
    [[ -f "$conf" ]] || continue
    sed -i "s/^\s*autologin-user\s*=.*/autologin-user=/" "$conf"
    log_info "lightdm: автологин выключен до первой загрузки ($conf)"
done

# --- служба первой загрузки ---------------------------------------------------
if [[ -f "$HERE/configure-cloud-user-desktop.service" ]]; then
    install -m 0644 "$HERE/configure-cloud-user-desktop.service" \
        /etc/systemd/system/configure-cloud-user-desktop.service
    systemctl enable configure-cloud-user-desktop.service >/dev/null 2>&1 || \
        log_warn "служба не включилась — проверьте на первой загрузке"
    log_info "служба первой загрузки установлена"
else
    log_error "рядом нет configure-cloud-user-desktop.service"
    exit 1
fi
