#!/usr/bin/env bash
# Build phase: make sure the image carries NetworkManager, so that a Wi-Fi
# interface declared in a device manifest actually comes up.
#
# ЗАЧЕМ ЭТО РАСШИРЕНИЕ ВООБЩЕ. `bs device write` при наличии секции `wifi`
# генерирует network-config с `renderer: NetworkManager` — systemd-networkd
# Wi-Fi не поддерживает (docs/guides/device.md, «WiFi интерфейсы»). Если
# NetworkManager в образе нет, cloud-init разложить профиль некуда, и
# устройство приходит БЕЗ СЕТИ молча: карта записалась, система загрузилась,
# ошибки нет нигде.
#
# ОСНОВНОЙ СЛУЧАЙ — «уже стоит», и он не считается лишней работой. Замерено
# в собранном образе Raspberry Pi OS (2026-09-03): network-manager,
# wpasupplicant и firmware-brcm80211 стоят, юнит включён. Расширение обязано
# сказать об этом и не тронуть ничего — иначе `apt-get install` переставил бы
# пакеты и в лучшем случае потратил время, а в худшем подтянул за собой
# обновления, которых автор образа не просил.
#
# ПРОШИВКУ Wi-Fi РАСШИРЕНИЕ НЕ СТАВИТ, и это решение, а не пропуск. Разбор
# в README, раздел «Прошивку не ставим»; коротко — выбор пакета прошивки
# требует сразу двух осей (какое железо И какой дистрибутив), а объявленная
# таблица в этом проекте отвергнута. Вместо установки — громкое
# предупреждение, если в образе не нашлось никакой прошивки вовсе.
set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} $*"; }

# Тот же повтор, что у расширения docker: индекс apt на сборочной машине
# отваливается достаточно часто, чтобы это стоило одной функции.
apt_retry(){
    local max=5 n=1 d
    while true; do
        if "$@"; then return 0; fi
        if (( n >= max )); then return 1; fi
        d=$(( n * 2 )); log_warn "apt не отработал, повтор через ${d}s ($n/$max)"
        sleep "$d"; n=$(( n + 1 ))
    done
}

export DEBIAN_FRONTEND=noninteractive
APT_OPTS=(-q -y -o Dpkg::Options::=--force-confnew)

pkg_installed(){ dpkg-query -W -f='${db:Status-Status}\n' "$1" 2>/dev/null | grep -qx installed; }

# `systemctl is-enabled` внутри virt-customize отвечать не обязан — systemd
# здесь не запущен, это chroot. Смотрим то, что `systemctl enable` физически
# создаёт: симлинк в multi-user.target.wants и dbus-алиас, которым Debian
# включает NetworkManager.
unit_enabled(){
    [[ -L /etc/systemd/system/multi-user.target.wants/NetworkManager.service ]] \
        || [[ -L /etc/systemd/system/dbus-org.freedesktop.NetworkManager.service ]]
}

# --- какая это система -------------------------------------------------------
# shellcheck disable=SC1091
. /etc/os-release
DISTRO_ID="${ID:-}"
case "$DISTRO_ID" in
    debian|ubuntu) ;;
    *)
        log_error "расширение network-manager рассчитано на debian и ubuntu, а здесь ID=$DISTRO_ID"
        log_error "OpenWrt обслуживается отдельно: там нет ни apt, ни systemd"
        exit 1
        ;;
esac
ARCH="$(dpkg --print-architecture)"
log_info "система $DISTRO_ID ${VERSION_CODENAME:-?} ($ARCH)"

# --- что уже есть ------------------------------------------------------------
# wpasupplicant объявлен ЯВНО, а не оставлен на Recommends пакета
# network-manager: образы собирают и с --no-install-recommends, и тогда
# ассоциация с точкой доступа отваливается уже на устройстве. Та же правка
# и по той же причине сделана у x11vnc (xauth, x11-utils).
missing=()
for pkg in network-manager wpasupplicant; do
    if pkg_installed "$pkg"; then
        log_info "$pkg уже установлен ($(dpkg-query -W -f='${Version}' "$pkg" 2>/dev/null))"
    else
        missing+=("$pkg")
    fi
done

if (( ${#missing[@]} == 0 )) && unit_enabled; then
    log_info "NetworkManager уже установлен и включён — не трогаю ничего"
else
    if (( ${#missing[@]} > 0 )); then
        log_info "ставлю: ${missing[*]}"
        apt_retry apt-get "${APT_OPTS[@]}" update
        # Гейт вместо таблицы поддерживаемых сюит: спрашиваем у самого
        # репозитория, есть ли пакет. Заодно ловит молча не отработавший
        # apt-get update.
        for pkg in "${missing[@]}"; do
            candidate="$(apt-cache policy "$pkg" 2>/dev/null | awk '/Candidate:/{print $2}')"
            if [[ -z "$candidate" || "$candidate" == "(none)" ]]; then
                log_error "в репозиториях образа нет пакета $pkg"
                log_error "проверьте /etc/apt/sources.list — на урезанных образах"
                log_error "компонент, где он лежит, бывает не подключён"
                exit 1
            fi
        done
        apt_retry apt-get "${APT_OPTS[@]}" install "${missing[@]}"
        log_info "установлено: ${missing[*]}"
    fi

    # Юнит включает сама упаковка (postinst через deb-systemd-helper), даже
    # при снятом policy-rc.d — то же наблюдение, что записано у docker.
    # Строка оставлена страховкой на случай упаковки, которая этого не делает,
    # и потому отказом не считается.
    systemctl enable NetworkManager.service 2>/dev/null || true
    if unit_enabled; then
        log_info "NetworkManager.service включён"
    else
        log_error "NetworkManager.service не включён — на устройстве сети не будет"
        log_error "проверьте вручную: ls -l /etc/systemd/system/multi-user.target.wants/"
        exit 1
    fi
fi

# --- кто ещё претендует на управление сетью ----------------------------------
# Не выключаем, а говорим вслух. Выключить systemd-networkd значило бы
# переписать сетевой стек чужого образа за его автора; а промолчать — оставить
# двух хозяев у одного интерфейса. cloud-init при наличии wifi в манифесте
# кладёт профили NetworkManager, и Ethernet, поднятый networkd, будет
# настроен по-старому.
if [[ -L /etc/systemd/system/multi-user.target.wants/systemd-networkd.service \
   || -L /etc/systemd/system/dbus-org.freedesktop.network1.service ]]; then
    log_warn "в образе включён и systemd-networkd — два менеджера на одних интерфейсах"
    log_warn "расширение его НЕ выключает: это сетевой стек вашего образа"
fi

# --- прошивка Wi-Fi ----------------------------------------------------------
# Ищем признаки, а не пакеты: на Ubuntu всё лежит в монолитном linux-firmware,
# на Debian — в отдельных firmware-*, а в pi-gen прошивка вообще может приехать
# файлами. Смотрим на то, что общее для всех трёх, — на /lib/firmware.
firmware_found=""
for probe in /lib/firmware/brcm /lib/firmware/iwlwifi-*.ucode /lib/firmware/rtlwifi \
             /lib/firmware/mediatek /lib/firmware/ath10k /lib/firmware/ath11k; do
    if [[ -e "$probe" ]]; then
        firmware_found="${firmware_found} $(basename "$probe")"
    fi
done

if [[ -n "$firmware_found" ]]; then
    log_info "прошивка Wi-Fi в образе есть:${firmware_found}"
else
    log_warn "в /lib/firmware не нашлось прошивки Wi-Fi ни для одного известного чипа"
    log_warn "расширение её НЕ ставит намеренно — см. README, «Прошивку не ставим»"
    log_warn "нужна конкретная — добавьте слоем INSTALL до этого расширения:"
    log_warn "  Debian: firmware-brcm80211 или firmware-iwlwifi (компонент non-free-firmware)"
    log_warn "  Ubuntu: linux-firmware (отдельных firmware-* пакетов там нет)"
fi

log_info "расширение network-manager отработало"
