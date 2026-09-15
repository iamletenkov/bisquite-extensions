#!/usr/bin/env bash
# Install x11vnc and prepare auto-configuration service

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info(){ >&2 echo -e "${GREEN}[INFO]${NC} $*"; }
log_warn(){ >&2 echo -e "${YELLOW}[WARN]${NC} $*"; }
log_error(){ >&2 echo -e "${RED}[ERROR]${NC} $*"; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"


# Параметры приходят из VMFILE переменными окружения: EXTENSION передаёт
# пары КЛЮЧ=ЗНАЧЕНИЕ в окружение install.sh как есть:
#
#   EXTENSION x11vnc X11VNC_PORT=5901 X11VNC_LISTEN=all
#
# Имена, типы и умолчания объявлены один раз — в схеме knobs рядом; пишет
# их библиотека bisquite-conf. Умолчаний здесь НЕТ намеренно: присвоение
# `X11VNC_PORT="${X11VNC_PORT:-5900}"` экспортированной переменной выглядело
# бы для conf_init --env как явный параметр VMFILE и затирало бы правку
# оператора при повторной установке.
[[ -f "$SCRIPT_DIR/lib/bisquite-conf" ]] || { log_error "рядом нет lib/bisquite-conf — сборка не доставила lib/ источника"; exit 1; }
# shellcheck source=/dev/null
source "$SCRIPT_DIR/lib/bisquite-conf"

log_info "Installing x11vnc and dependencies..."

apt-get update || exit 1
# xauth и x11-utils объявлены явно: обёртке нужен `xdpyinfo`, чтобы
# проверить кандидата в authority, а у пакета x11vnc он лишь в Recommends.
# Раньше они приезжали только потому, что десктопное расширение поставило
# `xorg`, — то есть работа зависела от порядка слоёв в VMFILE.
apt-get install -y \
  x11vnc \
  xauth \
  x11-utils || exit 1

# --- Файлы, без которых первой загрузки не будет -----------------------------
#
# Отсутствие любого из них — ОТКАЗ СБОРКИ, а не предупреждение. Раньше юниты
# «не нашлись» тихо (log_warn плюс `|| true`), сборка оставалась зелёной,
# а юнита в образе не было — и узнавал об этом тот, кто включил плату без
# монитора. Из двух отказов дешевле тот, который читает собиравший: он
# чинит за минуту на своей машине. То же направление у всей остальной
# инфраструктуры bisquite — fail-closed у детектора устройств, preflight
# утилит до `dd`. Образец — vino-vnc/install.sh.
#
# Ищем рядом с собой ($SCRIPT_DIR), а не по зашитому /opt/bisquite/x11vnc/:
# проверка обязана отвечать на вопрос «файл приехал рядом со мной?», а не
# «раскладка EXTENSION всё ещё такая?». Скрипт запускается из того самого
# каталога, куда его скопировали, поэтому $SCRIPT_DIR верен при любой
# раскладке, и её смена не уронит все сборки разом. (Юниты ссылаются на
# /opt/bisquite абсолютным путём и после смены раскладки правятся вместе
# с ней — но это правка одного файла, а не отказ конвейера.)
for f in x11vnc@.service configure-x11vnc.service run-x11vnc.sh \
         configure.sh knobs knobs.secret knobs.apply lib/get_cloud_user.sh; do
  if [[ ! -f "$SCRIPT_DIR/$f" ]]; then
    log_error "рядом нет $f — донастройка на первой загрузке не состоится,"
    log_error "а без неё x11vnc не запустится ни при каком параметре"
    exit 1
  fi
done

# Без `|| true`: файл нашёлся, а копирование провалилось — исход ровно тот же,
# что и у ненайденного файла, значит и отказ тот же.
install -m 0644 "$SCRIPT_DIR/x11vnc@.service" /etc/systemd/system/x11vnc@.service
install -m 0644 "$SCRIPT_DIR/configure-x11vnc.service" \
  /etc/systemd/system/configure-x11vnc.service

# Обёртка, которая ищет X authority в рантайме. Юнит зовёт её через
# `/bin/bash`, то есть бит исполнения ему не нужен; он нужен человеку,
# который запустит обёртку руками при диагностике (README учит этому).
chmod +x "$SCRIPT_DIR/run-x11vnc.sh"

# Параметры в EnvironmentFile, который читает юнит.
# The file moved from /etc/default/bisquite-x11vnc in 2.0.0. The old path is
# not read as a fallback; remove it so the image has one source of truth.
if [[ -e /etc/default/bisquite-x11vnc ]]; then
  log_info "удаляю /etc/default/bisquite-x11vnc: параметры теперь в /etc/bisquite/x11vnc/config"
  rm -f /etc/default/bisquite-x11vnc
fi

# Файл создаётся один раз и дальше не переписывается: недостающие ключи
# дописываются, заданные остаются. Параметры VMFILE (--env) ложатся поверх
# через проверку схемы — опечатка `X11VNC_LISTEN=al` роняет сборку здесь, а не
# службу на устройстве.
#
# Пароль — ключ secret:hook: в файл он не попадает, хук knobs.secret делает из
# него /etc/x11vnc/passwd (0600; владельца отдаёт configure.sh на первой
# загрузке) и пишет X11VNC_PASSFILE. Отказ хука — отказ сборки: пароль
# просили, а сервер без X11VNC_PASSFILE поднимается с -nopw — образ выглядел
# бы защищённым, а рабочий стол был бы открыт.
conf_init x11vnc "$SCRIPT_DIR/knobs" --env || { log_error "/etc/bisquite/x11vnc/config не записан"; exit 1; }
conf_load x11vnc

log_info "порт ${X11VNC_PORT}, дисплей ${X11VNC_DISPLAY}, слушает ${X11VNC_LISTEN}${X11VNC_PASSFILE:+, пароль в ${X11VNC_PASSFILE}}"
if [[ "$X11VNC_LISTEN" != "localhost" && -z "$X11VNC_PASSFILE" ]]; then
  log_warn "X11VNC_LISTEN=${X11VNC_LISTEN} без пароля: рабочий стол будет открыт всей сети"
fi

# Enable configuration service
systemctl daemon-reload || true
systemctl enable configure-x11vnc.service || true

log_info "x11vnc extension installation completed"
