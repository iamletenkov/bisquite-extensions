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


# Параметры приходят из VMFILE переменными окружения, потому что RUN_COMMAND
# отдаёт строку шеллу гостя целиком:
#
#   RUN_COMMAND X11VNC_PORT=5901 X11VNC_LISTEN=all /opt/vmsetup/x11vnc/install.sh
#
# Раньше на их месте лежал config.yaml, чьи ключи PORT/PASSWORD/DISPLAY
# читались и НИГДЕ не использовались — юнит хардкодил свои значения, а README
# обещал парольный доступ, которого не было. Файл удалён вместе с обещанием.
X11VNC_PORT="${X11VNC_PORT:-5900}"
X11VNC_DISPLAY="${X11VNC_DISPLAY:-:0}"
X11VNC_PASSWORD="${X11VNC_PASSWORD:-}"
X11VNC_LISTEN="${X11VNC_LISTEN:-localhost}"

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
# Ищем рядом с собой ($SCRIPT_DIR), а не по зашитому /opt/vmsetup/x11vnc/:
# проверка обязана отвечать на вопрос «файл приехал рядом со мной?», а не
# «раскладка EXTENSION всё ещё такая?». Скрипт запускается из того самого
# каталога, куда его скопировали, поэтому $SCRIPT_DIR верен при любой
# раскладке, и её смена не уронит все сборки разом. (Юниты ссылаются на
# /opt/vmsetup абсолютным путём и после смены раскладки правятся вместе
# с ней — но это правка одного файла, а не отказ конвейера.)
for f in x11vnc@.service configure-x11vnc.service run-x11vnc.sh \
         configure.sh get_cloud_user.sh; do
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
install -d -m 0755 /etc/default
{
  echo "X11VNC_PORT=${X11VNC_PORT}"
  echo "X11VNC_DISPLAY=${X11VNC_DISPLAY}"
  echo "X11VNC_LISTEN=${X11VNC_LISTEN}"
} > /etc/default/bisquite-x11vnc

if [[ -n "$X11VNC_PASSWORD" ]]; then
  # Файл пароля VNC, а не открытый пароль в окружении: у -rfbauth формат свой.
  #
  # Каталог остаётся 0755: пользователю, под которым работает сервер, нужно
  # пройти сквозь него к файлу. Секрет закрывают права файла, а не каталога.
  install -d -m 0755 /etc/x11vnc
  if x11vnc -storepasswd "$X11VNC_PASSWORD" /etc/x11vnc/passwd >/dev/null 2>&1; then
    # 0600, а не 0644. Формат `-rfbauth` — НЕ хеш: пароль в нём зашифрован
    # обратимо (DES с фиксированным ключом), поэтому файл, читаемый всеми,
    # отдаёт сам пароль любой локальной учётной записи. И отдаёт его ровно
    # тогда, когда пароль задали, — то есть когда сервер выставлен в сеть.
    # Соседний vino-vnc кладёт свой файл 0600 по тому же доводу
    # (vino-vnc/install.sh, раздел про vnc-password).
    #
    # ВЛАДЕЛЬЦА файл получает не здесь, а на первой загрузке. Сервер работает
    # юнитом `x11vnc@<пользователь>` с `User=%i`, то есть пароль читает НЕ
    # root, а учётка, которой на сборке ещё не существует (её создаёт
    # cloud-init). `chown` на найденного пользователя делает configure.sh.
    # Без этой пары ужесточение прав ОТКРЫЛО БЫ рабочий стол вместо того,
    # чтобы его закрыть: обёртка проверяет файл на читаемость и при отказе
    # прежде поднимала сервер с `-nopw`.
    chmod 0600 /etc/x11vnc/passwd
    echo "X11VNC_PASSFILE=/etc/x11vnc/passwd" >> /etc/default/bisquite-x11vnc
    log_info "пароль записан в /etc/x11vnc/passwd"
  else
    # Отказ, а не предупреждение: пароль просили, пароля не будет, а сервер
    # без `X11VNC_PASSFILE` поднимается с `-nopw`. Собранный образ выглядел
    # бы защищённым, а рабочий стол был бы открыт — узнать об этом можно
    # только на устройстве.
    log_error "не удалось записать файл пароля /etc/x11vnc/passwd"
    log_error "пароль задан, значит сервер без него поднимать нельзя"
    exit 1
  fi
fi
chmod 0644 /etc/default/bisquite-x11vnc

log_info "порт ${X11VNC_PORT}, дисплей ${X11VNC_DISPLAY}, слушает ${X11VNC_LISTEN}"
if [[ "$X11VNC_LISTEN" != "localhost" && -z "$X11VNC_PASSWORD" ]]; then
  log_warn "X11VNC_LISTEN=${X11VNC_LISTEN} без пароля: рабочий стол будет открыт всей сети"
fi

# Enable configuration service
systemctl daemon-reload || true
systemctl enable configure-x11vnc.service || true

log_info "x11vnc extension installation completed"
