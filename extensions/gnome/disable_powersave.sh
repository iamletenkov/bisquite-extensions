#!/usr/bin/env bash
# Disable power saving and screen blanking for GNOME desktop

set -euo pipefail

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
NC='\033[0m'

log_info(){ echo -e "${GREEN}[INFO]${NC} $*" >&2; }
log_warn(){ echo -e "${YELLOW}[WARN]${NC} $*" >&2; }
log_error(){ echo -e "${RED}[ERROR]${NC} $*" >&2; }

USER="${1:-}"

if [[ -z "$USER" ]]; then
  log_error "Usage: $0 <username>"
  exit 1
fi

if ! id "$USER" >/dev/null 2>&1; then
  log_error "User '$USER' does not exist"
  exit 1
fi

USER_HOME=$(eval echo "~$USER")

if [[ ! -d "$USER_HOME" ]]; then
  log_error "Home directory for user '$USER' not found: $USER_HOME"
  exit 1
fi

log_info "Disabling power saving features for user '$USER'"

# Disable X11 screen blanking and DPMS globally
cat > /etc/X11/Xsession.d/90-disable-dpms <<'EOF'
#!/bin/sh
# Disable DPMS and screen blanking
xset s off
xset s noblank
xset -dpms
EOF
chmod +x /etc/X11/Xsession.d/90-disable-dpms

log_info "Created X11 session script to disable DPMS and screen blanking"

# Create autostart directory for user
USER_AUTOSTART="$USER_HOME/.config/autostart"
mkdir -p "$USER_AUTOSTART"
chown -R "$USER:$USER" "$USER_HOME/.config" 2>/dev/null || true

# Create autostart entry to disable screen blanking on session start
cat > "$USER_AUTOSTART/disable-screensaver.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Disable Screen Blanking
Exec=sh -c 'xset s off; xset s noblank; xset -dpms'
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF
chown "$USER:$USER" "$USER_AUTOSTART/disable-screensaver.desktop"

log_info "Created autostart entry for screen blanking disable"

# Configure GNOME settings via gsettings
USER_CONFIG_DIR="$USER_HOME/.config/dconf"
mkdir -p "$USER_CONFIG_DIR"
chown -R "$USER:$USER" "$USER_HOME/.config/dconf" 2>/dev/null || true

# Create dconf user configuration to disable power saving
cat > "$USER_CONFIG_DIR/user" <<'EOF'
[org/gnome/settings-daemon/plugins/power]
sleep-inactive-ac-type='nothing'
sleep-inactive-battery-type='nothing'
sleep-inactive-ac-timeout=0
sleep-inactive-battery-timeout=0

[org/gnome/desktop/session]
idle-delay=uint32 0

[org/gnome/desktop/screensaver]
idle-activation-enabled=false
lock-enabled=false

[org/gnome/desktop/lockdown]
disable-lock-screen=true

[org/gnome/shell]
disable-user-extensions=false
EOF
chown "$USER:$USER" "$USER_CONFIG_DIR/user"

log_info "Configured GNOME settings to disable power saving"

# Create a script to apply settings at runtime (for already running sessions)
cat > "$USER_HOME/.config/disable-powersave-runtime.sh" <<'EOF'
#!/bin/bash
# Apply power saving disable settings to running GNOME session
export DISPLAY=:0

# Disable screen blanking
xset s off 2>/dev/null || true
xset s noblank 2>/dev/null || true
xset -dpms 2>/dev/null || true

# Configure GNOME via gsettings if available
if command -v gsettings >/dev/null 2>&1; then
  gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-type 'nothing' 2>/dev/null || true
  gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-type 'nothing' 2>/dev/null || true
  gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-ac-timeout 0 2>/dev/null || true
  gsettings set org.gnome.settings-daemon.plugins.power sleep-inactive-battery-timeout 0 2>/dev/null || true
  gsettings set org.gnome.desktop.session idle-delay 0 2>/dev/null || true
  gsettings set org.gnome.desktop.screensaver idle-activation-enabled false 2>/dev/null || true
  gsettings set org.gnome.desktop.screensaver lock-enabled false 2>/dev/null || true
  gsettings set org.gnome.desktop.lockdown disable-lock-screen true 2>/dev/null || true
fi
EOF

chmod +x "$USER_HOME/.config/disable-powersave-runtime.sh"
chown "$USER:$USER" "$USER_HOME/.config/disable-powersave-runtime.sh"

log_info "Created runtime power-saving disable script"

# Add runtime script to autostart
cat > "$USER_AUTOSTART/disable-powersave-runtime.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Disable Power Saving Runtime
Exec=$USER_HOME/.config/disable-powersave-runtime.sh
Hidden=false
NoDisplay=false
X-GNOME-Autostart-enabled=true
EOF
chown "$USER:$USER" "$USER_AUTOSTART/disable-powersave-runtime.desktop"

log_info "Added runtime script to autostart"

# Fix permissions recursively
chown -R "$USER:$USER" "$USER_HOME/.config" 2>/dev/null || true

log_info "Successfully disabled all power saving features for user '$USER'"
log_info "Screen will remain active and will not blank, dim, or sleep"
