#!/usr/bin/env bash
# Disable power saving and screen blanking for LXDE desktop

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

# Configure LXDE session to disable screensaver
LXDE_CONFIG_DIR="$USER_HOME/.config/lxsession/LXDE"
mkdir -p "$LXDE_CONFIG_DIR"
chown -R "$USER:$USER" "$USER_HOME/.config/lxsession" 2>/dev/null || true

# Create LXDE session configuration
cat > "$LXDE_CONFIG_DIR/desktop.conf" <<'EOF'
[Session]
window_manager=openbox-lxde

[Startup]
screensaver=disabled
EOF
chown "$USER:$USER" "$LXDE_CONFIG_DIR/desktop.conf"

log_info "Configured LXDE session to disable screensaver"

# Disable xscreensaver if present
if [[ -f "$USER_HOME/.xscreensaver" ]]; then
  sed -i 's/^mode:.*/mode: off/' "$USER_HOME/.xscreensaver"
  chown "$USER:$USER" "$USER_HOME/.xscreensaver"
  log_info "Disabled xscreensaver"
fi

# Create a script to apply settings at runtime (for already running sessions)
cat > "$USER_HOME/.config/disable-powersave-runtime.sh" <<'EOF'
#!/bin/bash
# Apply power saving disable settings to running LXDE session
export DISPLAY=:0

# Disable screen blanking
xset s off 2>/dev/null || true
xset s noblank 2>/dev/null || true
xset -dpms 2>/dev/null || true

# Disable xscreensaver if running
if pgrep xscreensaver >/dev/null 2>&1; then
  xscreensaver-command -exit 2>/dev/null || true
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
