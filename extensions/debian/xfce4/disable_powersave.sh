#!/usr/bin/env bash
# Disable power saving and screen blanking for Xfce4 desktop

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

# Create xfce4 power manager configuration directory
XFCE_CONFIG_DIR="$USER_HOME/.config/xfce4/xfconf/xfce-perchannel-xml"
mkdir -p "$XFCE_CONFIG_DIR"
chown -R "$USER:$USER" "$USER_HOME/.config/xfce4" 2>/dev/null || true

# Configure xfce4-power-manager to disable all power saving
cat > "$XFCE_CONFIG_DIR/xfce4-power-manager.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-power-manager" version="1.0">
  <property name="xfce4-power-manager" type="empty">
    <property name="blank-on-ac" type="int" value="0"/>
    <property name="blank-on-battery" type="int" value="0"/>
    <property name="dpms-enabled" type="bool" value="false"/>
    <property name="dpms-on-ac-off" type="uint" value="0"/>
    <property name="dpms-on-ac-sleep" type="uint" value="0"/>
    <property name="dpms-on-battery-off" type="uint" value="0"/>
    <property name="dpms-on-battery-sleep" type="uint" value="0"/>
    <property name="lock-screen-suspend-hibernate" type="bool" value="false"/>
    <property name="logind-handle-lid-switch" type="bool" value="false"/>
    <property name="brightness-on-ac" type="uint" value="100"/>
    <property name="brightness-on-battery" type="uint" value="100"/>
    <property name="inactivity-on-ac" type="uint" value="0"/>
    <property name="inactivity-on-battery" type="uint" value="0"/>
    <property name="inactivity-sleep-mode-on-ac" type="uint" value="1"/>
    <property name="inactivity-sleep-mode-on-battery" type="uint" value="1"/>
    <property name="lid-action-on-ac" type="uint" value="0"/>
    <property name="lid-action-on-battery" type="uint" value="0"/>
    <property name="power-button-action" type="uint" value="3"/>
    <property name="show-tray-icon" type="bool" value="true"/>
  </property>
</channel>
EOF
chown "$USER:$USER" "$XFCE_CONFIG_DIR/xfce4-power-manager.xml"

log_info "Configured xfce4-power-manager to disable power saving"

# Configure xfce4-session to disable screensaver
cat > "$XFCE_CONFIG_DIR/xfce4-session.xml" <<'EOF'
<?xml version="1.0" encoding="UTF-8"?>
<channel name="xfce4-session" version="1.0">
  <property name="general" type="empty">
    <property name="LockCommand" type="string" value=""/>
    <property name="SaveOnExit" type="bool" value="false"/>
  </property>
  <property name="startup" type="empty">
    <property name="screensaver" type="empty">
      <property name="enabled" type="bool" value="false"/>
    </property>
  </property>
  <property name="shutdown" type="empty">
    <property name="LockScreen" type="bool" value="false"/>
  </property>
</channel>
EOF
chown "$USER:$USER" "$XFCE_CONFIG_DIR/xfce4-session.xml"

log_info "Configured xfce4-session to disable screensaver"

# Disable xscreensaver if present
if [[ -f "$USER_HOME/.xscreensaver" ]]; then
  sed -i 's/^mode:.*/mode: off/' "$USER_HOME/.xscreensaver"
  chown "$USER:$USER" "$USER_HOME/.xscreensaver"
  log_info "Disabled xscreensaver"
fi

# Create a script to apply settings at runtime (for already running sessions)
cat > "$USER_HOME/.config/disable-powersave-runtime.sh" <<'EOF'
#!/bin/bash
# Apply power saving disable settings to running session
export DISPLAY=:0

# Disable screen blanking
xset s off 2>/dev/null || true
xset s noblank 2>/dev/null || true
xset -dpms 2>/dev/null || true

# Configure xfce4-power-manager via xfconf if available
if command -v xfconf-query >/dev/null 2>&1; then
  xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-ac -n -t int -s 0 2>/dev/null || true
  xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/blank-on-battery -n -t int -s 0 2>/dev/null || true
  xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-enabled -n -t bool -s false 2>/dev/null || true
  xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-ac-off -n -t uint -s 0 2>/dev/null || true
  xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-ac-sleep -n -t uint -s 0 2>/dev/null || true
  xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-battery-off -n -t uint -s 0 2>/dev/null || true
  xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/dpms-on-battery-sleep -n -t uint -s 0 2>/dev/null || true
  xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/inactivity-on-ac -n -t uint -s 0 2>/dev/null || true
  xfconf-query -c xfce4-power-manager -p /xfce4-power-manager/inactivity-on-battery -n -t uint -s 0 2>/dev/null || true
  xfconf-query -c xfce4-session -p /startup/screensaver/enabled -n -t bool -s false 2>/dev/null || true
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
