#!/usr/bin/env bash
# Configure kiosk mode with Chromium and on-screen keyboard

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info(){ echo -e "${GREEN}[INFO]${NC} $*" >&2; }
log_warn(){ echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error(){ echo -e "${RED}[ERROR]${NC} $*" >&2; }

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_YAML="$SCRIPT_DIR/config.yaml"

check_prereqs(){
  if ! command -v yq >/dev/null 2>&1; then
    log_error "yq is not installed"
    exit 1
  fi
  if ! command -v chromium >/dev/null 2>&1; then
    log_error "chromium is not installed"
    exit 1
  fi
  if [[ ! -x "$SCRIPT_DIR/get_cloud_user.sh" ]]; then
    log_error "get_cloud_user.sh not found or not executable at $SCRIPT_DIR/get_cloud_user.sh"
    exit 1
  fi
  if [[ ! -f "$CONFIG_YAML" ]]; then
    log_error "Config file not found at $CONFIG_YAML"
    exit 1
  fi
}

resolve_user(){
  local user
  local attempts=0
  local max_attempts=40

  # Ключ USER из config.yaml ПЕРЕКРЫВАЕТ cloud-init.
  #
  # Раньше его не читал никто: configure.sh всегда шёл в get_cloud_user.sh,
  # а ключ стоял в config.yaml и в README как ручка, которой нет. Это та же
  # болезнь «мёртвых ручек», из-за которой у расширения x11vnc config.yaml
  # удалён целиком. Здесь выбран второй исход — ключ включён, а не удалён:
  #   * у соседнего code-server ровно этот ключ работает именно так
  #     (configure.sh: USER из файла, иначе get_cloud_user.sh), и два
  #     одноимённых ключа с разным поведением хуже любого из двух;
  #   * случай, который он закрывает, реален — киоск на образе, где сессию
  #     держит не тот пользователь, которого создал cloud-init.
  #
  # Молчаливого отката на cloud-init при заданном USER НЕТ: оператор назвал
  # пользователя, и подмена его другим вернула бы ту же немоту с другой
  # стороны. Ждём именно названного — cloud-init мог ещё не создать и его.
  local configured
  configured="$(read_config "USER")"
  if [[ -n "$configured" ]]; then
    log_info "Пользователь задан в config.yaml: $configured"
    while true; do
      if id "$configured" >/dev/null 2>&1; then
        echo "$configured"
        return 0
      fi
      attempts=$((attempts+1))
      if (( attempts >= max_attempts )); then
        log_error "пользователь '$configured' из config.yaml так и не появился"
        log_error "уберите ключ USER, чтобы взять пользователя из cloud-init"
        exit 1
      fi
      log_info "Waiting for user '$configured' (attempt $attempts/$max_attempts)..."
      sleep 3
    done
  fi

  # Wait up to 120s for cloud user to appear to avoid racing cloud-init
  while true; do
    if user="$("$SCRIPT_DIR"/get_cloud_user.sh 2>/dev/null || true)" && [[ -n "$user" ]]; then
      if id "$user" >/dev/null 2>&1; then
        log_info "Found user from cloud-init: $user"
        echo "$user"
        return 0
      fi
    fi

    attempts=$((attempts+1))
    if (( attempts >= max_attempts )); then
      log_error "Timeout waiting for cloud-init user to be created"
      exit 1
    fi

    log_info "Waiting for cloud-init user (attempt $attempts/$max_attempts)..."
    sleep 3
  done
}

read_config(){
  local key="$1"
  local value
  value=$(yq -r ".$key // empty" "$CONFIG_YAML" 2>/dev/null || echo "")
  echo "$value"
}

# Какой рабочий стол здесь на самом деле.
#
# Расширение kiosk десктоп не ставит (см. README) — его даёт gnome, xfce4 или
# lxde, и до этой правки две ветки настройки рассчитывали на РАЗНЫЕ окружения:
# экранная клавиатура — на GNOME, а конфиги, прячущие панель, раскладывались
# как Xfce4 безусловно, в том числе под GNOME и LXDE, где их не читает никто.
#
# Спрашиваем гостя о нём самом, а не объявляем таблицу «расширение десктопа ->
# что делать»: таблица устарела бы молча — тот же довод, по которому расширение
# docker смотрит на /boot/firmware/cmdline.txt и /etc/nv_tegra_release, а не на
# ID дистрибутива.
#
# Сначала — что РАБОТАЕТ: в образе может стоять и gnome, и xfce4, а решает
# дисплей-менеджер. Юнит стоит After=graphical.target ... display-manager.service,
# но автологин мог ещё не довести сессию до конца, поэтому есть и запасной
# признак — что установлено.
detect_desktop(){
  local user="$1"

  if pgrep -u "$user" -x xfce4-session >/dev/null 2>&1; then echo xfce4; return 0; fi
  if pgrep -u "$user" -x gnome-shell >/dev/null 2>&1 \
     || pgrep -u "$user" -x gnome-session-binary >/dev/null 2>&1; then echo gnome; return 0; fi
  if pgrep -u "$user" -x lxsession >/dev/null 2>&1; then echo lxde; return 0; fi

  if command -v xfce4-session >/dev/null 2>&1; then echo xfce4; return 0; fi
  if command -v gnome-shell >/dev/null 2>&1; then echo gnome; return 0; fi
  if command -v lxsession >/dev/null 2>&1; then echo lxde; return 0; fi

  echo unknown
}

enable_gnome_keyboard(){
  local cloud_user="$1"
  local keyboard_enabled="$2"
  local desktop="$3"

  if [[ "$keyboard_enabled" != "true" ]]; then
    log_info "On-screen keyboard is disabled in config"
    return 0
  fi

  # Ветка работает только под GNOME: gsettings пишет в схему
  # org.gnome.desktop.a11y, а читает её gnome-shell. Под Xfce и LXDE запись
  # проходила успешно и не давала НИЧЕГО — плюс в автозапуск ложился .desktop,
  # который выглядел как включённая клавиатура. Отказ вслух вместо этого.
  if [[ "$desktop" != "gnome" ]]; then
    log_warn "KEYBOARD_ENABLED: true, но рабочий стол — $desktop, а клавиатура здесь только GNOME"
    log_warn "экранной клавиатуры не будет; onboard/matchbox-keyboard расширение не ставит"
    return 0
  fi

  local user_home="/home/$cloud_user"
  local user_uid
  user_uid=$(id -u "$cloud_user")

  log_info "Enabling GNOME on-screen keyboard via gsettings"

  # Enable on-screen keyboard using gsettings as the user
  # This is more reliable than directly writing to dconf
  su - "$cloud_user" -c "DBUS_SESSION_BUS_ADDRESS=unix:path=/run/user/$user_uid/bus gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true" 2>/dev/null || \
    log_warn "Could not set gsettings via session bus, creating startup script"

  # Create autostart script to enable keyboard on session start
  local autostart_dir="$user_home/.config/autostart"
  mkdir -p "$autostart_dir"

  cat > "$autostart_dir/enable-keyboard.desktop" <<'EOF'
[Desktop Entry]
Type=Application
Name=Enable GNOME Keyboard
Exec=bash -c "gsettings set org.gnome.desktop.a11y.applications screen-keyboard-enabled true"
Hidden=false
NoDisplay=true
X-GNOME-Autostart-enabled=true
X-GNOME-Autostart-Delay=1
EOF

  chown -R "$cloud_user:$cloud_user" "$autostart_dir"
  log_info "GNOME on-screen keyboard enabled (will activate on next session)"
}

hide_desktop_ui(){
  local cloud_user="$1"
  local desktop="$2"
  local user_home="/home/$cloud_user"

  # Конфиги ниже — Xfce4-специфичные (xfconf-каналы xfce4-desktop и
  # xfce4-panel). Раньше они раскладывались безусловно; под GNOME и LXDE это
  # был мусор в ~/.config, выглядящий как настройка.
  if [[ "$desktop" != "xfce4" ]]; then
    log_info "рабочий стол — $desktop, Xfce4-конфиги не раскладываю"
    # Не «недоделка»: окно киоска и так полноэкранное поверх всего, а панель
    # под ним не видна. Прятать её у каждого окружения пришлось бы своим
    # способом, и ни один из них не проверялся.
    log_info "панель и иконки прячутся только под Xfce4 — см. README, раздел про окружение"
    return 0
  fi

  log_info "Hiding desktop UI for minimal kiosk experience"

  # Create XFCE4 config directory
  local xfce_config_dir="$user_home/.config/xfce4/xfconf/xfce-perchannel-xml"
  mkdir -p "$xfce_config_dir"

  # Set black wallpaper and hide desktop icons
  cat > "$xfce_config_dir/xfce4-desktop.xml" <<'XFCE_DESKTOP_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-desktop" version="1.0">
  <property name="backdrop" type="empty">
    <property name="screen0" type="empty">
      <property name="monitor0" type="empty">
        <property name="color-style" type="int" value="0"/>
        <property name="color1" type="array">
          <value type="uint" value="0"/>
          <value type="uint" value="0"/>
          <value type="uint" value="0"/>
          <value type="uint" value="65535"/>
        </property>
        <property name="image-style" type="int" value="0"/>
      </property>
    </property>
  </property>
  <property name="desktop-icons" type="empty">
    <property name="style" type="int" value="0"/>
  </property>
</channel>
XFCE_DESKTOP_EOF

  # Hide all panels
  cat > "$xfce_config_dir/xfce4-panel.xml" <<'XFCE_PANEL_EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-panel" version="1.0">
  <property name="panels" type="empty">
  </property>
</channel>
XFCE_PANEL_EOF

  chown -R "$cloud_user:$cloud_user" "$user_home/.config/xfce4"
  log_info "XFCE4 desktop UI hidden (black background, no panels)"
}

configure_kiosk_service(){
  local cloud_user="$1"

  log_info "Configuring kiosk service for user '$cloud_user'"

  # Read configuration from YAML
  local url display keyboard_enabled chromium_flags
  url=$(read_config "URL")
  display=$(read_config "DISPLAY")
  keyboard_enabled=$(read_config "KEYBOARD_ENABLED")
  chromium_flags=$(read_config "CHROMIUM_FLAGS")

  # Set defaults if not specified.
  #
  # Здесь стояло http://192.168.202.785 — адреса с октетом 785 не существует,
  # и Chromium показывал бы ошибку разрешения имени, то есть дефект читался бы
  # как неисправность сети. Умолчание НЕ приведено к 192.168.202.78 из
  # config.yaml: это адрес конкретной лаборатории, и для любого другого
  # оператора он ровно так же недостижим, просто молча. Взято то же значение,
  # что и в обёртке, — теперь во всей цепочке (config.yaml -> configure.sh ->
  # /var/lib/kiosk/config -> run-kiosk.sh) умолчание одно, а не три разных.
  # Значение из config.yaml по-прежнему сильнее и никуда не делось.
  url="${url:-https://github.com/iamletenkov/bisquite}"
  display="${display:-:0}"
  keyboard_enabled="${keyboard_enabled:-true}"
  chromium_flags="${chromium_flags:-}"

  log_info "Kiosk configuration:"
  log_info "  User: $cloud_user"
  log_info "  URL: $url"
  log_info "  Display: $display"
  log_info "  Keyboard enabled: $keyboard_enabled (GNOME on-screen keyboard)"
  log_info "  Chromium flags: ${chromium_flags:-<none>}"

  local desktop
  desktop="$(detect_desktop "$cloud_user")"
  log_info "  Desktop: $desktop"

  # Hide desktop UI for cleaner kiosk experience
  hide_desktop_ui "$cloud_user" "$desktop"

  # Enable GNOME on-screen keyboard
  enable_gnome_keyboard "$cloud_user" "$keyboard_enabled" "$desktop"

  # Create kiosk configuration file for the systemd service to read
  local kiosk_config_dir="/var/lib/kiosk"
  mkdir -p "$kiosk_config_dir"

  cat > "$kiosk_config_dir/config" <<EOF
# Kiosk configuration generated by configure-kiosk.service
USER=$cloud_user
URL=$url
DISPLAY=$display
CHROMIUM_FLAGS=$chromium_flags
EOF

  chmod 644 "$kiosk_config_dir/config"
  log_info "Created kiosk configuration at $kiosk_config_dir/config"

  # Enable and start kiosk-chromium service for user
  systemctl enable "kiosk-chromium@${cloud_user}.service" || true
  systemctl restart "kiosk-chromium@${cloud_user}.service" || true

  log_info "kiosk-chromium service enabled and started for user '$cloud_user'"
}

main(){
  check_prereqs
  local user
  user=$(resolve_user)

  log_info "Configuring kiosk mode for user '$user'"
  configure_kiosk_service "$user"
  log_info "Kiosk configuration completed for '$user'"
}

main "$@"
