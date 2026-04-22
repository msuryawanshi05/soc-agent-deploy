#!/bin/bash
# ============================================================
#  SOC Agent — macOS Installer (with failsafes)
#  Usage: sudo bash install_service_mac.sh
#         sudo bash install_service_mac.sh --uninstall
#  Installs to: /Library/SocAgent/ (root:wheel, chmod 700)
# ============================================================

set -eE

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
CYAN='\033[0;36m'
NC='\033[0m'

PLIST_LABEL="com.soc.agent"
PLIST_PATH="/Library/LaunchDaemons/${PLIST_LABEL}.plist"
INSTALL_DIR="/Library/SocAgent"
MIN_DISK_MB=200

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(dirname "$SCRIPT_DIR")"   # parent of deploy/

ROLLED_BACK=false

# ── Logging ───────────────────────────────────────────────────────────────────
LOG_FILE="$INSTALL_DIR/install.log"

log() {
    local color="${2:-$NC}"
    local ts
    ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[$ts] $1"
    echo -e "${color}${line}${NC}"
    if [ -d "$INSTALL_DIR" ]; then
        echo "$line" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

# ── Rollback ──────────────────────────────────────────────────────────────────
rollback() {
    if [ "$ROLLED_BACK" = "true" ]; then return; fi
    ROLLED_BACK=true
    log "ERROR: Installation failed — rolling back..." "$RED"
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    rm -f "$PLIST_PATH"
    chmod -R 755 "$INSTALL_DIR" 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
    log "Rollback complete. Re-run the script to try again." "$YELLOW"
}

trap 'EC=$?; if [ $EC -ne 0 ] && [ "$ROLLED_BACK" = "false" ]; then rollback; fi' EXIT ERR

# ── Root check ────────────────────────────────────────────────────────────────
if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}ERROR: Must run as root. Use: sudo bash $0 $*${NC}"
    exit 1
fi

# ── Uninstall ─────────────────────────────────────────────────────────────────
if [ "$1" = "--uninstall" ]; then
    mkdir -p "$INSTALL_DIR"
    log "=== SOC Agent Uninstall ===" "$YELLOW"
    launchctl unload "$PLIST_PATH" 2>/dev/null && log "Daemon unloaded." "$GREEN" || true
    rm -f "$PLIST_PATH"
    log "Plist removed." "$GREEN"
    chmod -R 755 "$INSTALL_DIR" 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
    log "Install directory removed." "$GREEN"
    log "✅ SOC Agent fully uninstalled." "$GREEN"
    ROLLED_BACK=true
    exit 0
fi

# ── Interactive configuration prompts ─────────────────────────────────────────
echo ""
echo -e "${CYAN}════════════════════════════════════${NC}"
echo -e "${CYAN}  SOC Agent — Configuration${NC}"
echo -e "${CYAN}════════════════════════════════════${NC}"
echo ""

# 1. Agent ID (required — no default)
AGENT_ID=""
while [ -z "$AGENT_ID" ]; do
    read -r -p "Enter Agent ID (e.g. agent-lab-01): " AGENT_ID
    AGENT_ID="$(echo "$AGENT_ID" | xargs)"
    if [ -z "$AGENT_ID" ]; then
        echo -e "${RED}  Agent ID cannot be empty. Please try again.${NC}"
    fi
done

# 2. Agent Hostname (default: system hostname)
SYS_HOSTNAME="$(hostname)"
read -r -p "Enter Agent Hostname (e.g. LAB-PC-01) [$SYS_HOSTNAME]: " HOSTNAME_INPUT
HOSTNAME_INPUT="$(echo "$HOSTNAME_INPUT" | xargs)"
MACHINE_NAME="${HOSTNAME_INPUT:-$SYS_HOSTNAME}"

# 3. Manager Host IP (default: 139.59.48.159)
read -r -p "Enter Manager IP [139.59.48.159]: " IP_INPUT
IP_INPUT="$(echo "$IP_INPUT" | xargs)"
MANAGER_IP="${IP_INPUT:-139.59.48.159}"

# 4. Manager Port — hardcoded silently
MANAGER_PORT=9000

# ── Confirmation summary ──────────────────────────────────────────────────────
echo ""
echo -e "${CYAN} ─────────────────────────────────${NC}"
echo " Agent ID      : $AGENT_ID"
echo " Hostname      : $MACHINE_NAME"
echo " Manager IP    : $MANAGER_IP"
echo " Manager Port  : $MANAGER_PORT"
echo -e "${CYAN} ─────────────────────────────────${NC}"
echo ""
read -r -p "Proceed with installation? [Y/n]: " CONFIRM
if [ "$CONFIRM" = "n" ] || [ "$CONFIRM" = "N" ]; then
    echo -e "${YELLOW}Installation aborted.${NC}"
    ROLLED_BACK=true
    exit 0
fi
echo ""

# Create install dir early so logging works
mkdir -p "$INSTALL_DIR"

log "══════════════════════════════════════════" "$CYAN"
log "  SOC Agent — macOS Installer" "$CYAN"
log "══════════════════════════════════════════" "$CYAN"
log "Manager IP : $MANAGER_IP"
log "Agent ID   : $AGENT_ID"
log "Hostname   : $MACHINE_NAME"
log "Install dir: $INSTALL_DIR"
log "Source     : $SOURCE_ROOT"

# ── STEP 1: Disk space ────────────────────────────────────────────────────────
log "[1/10] Checking disk space..." "$YELLOW"
FREE_MB=$(df -m "$INSTALL_DIR" | awk 'NR==2{print $4}')
if [ -n "$FREE_MB" ] && [ "$FREE_MB" -lt "$MIN_DISK_MB" ]; then
    log "ERROR: Insufficient disk space: need ${MIN_DISK_MB}MB, have ${FREE_MB}MB." "$RED"
    exit 1
fi
log "    Free space: ${FREE_MB}MB ✓" "$GREEN"

# ── STEP 2: Already installed? ────────────────────────────────────────────────
log "[2/10] Checking existing installation..." "$YELLOW"
ALREADY=false
if launchctl list 2>/dev/null | grep -q "$PLIST_LABEL" || \
   [ -f "$INSTALL_DIR/agent/agent.py" ]; then
    ALREADY=true
fi

if [ "$ALREADY" = "true" ]; then
    read -r -p "    SOC Agent already installed. Reinstall? [y/N] " response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log "Skipping — existing installation kept." "$YELLOW"
        ROLLED_BACK=true
        exit 0
    fi
    log "    Proceeding with reinstall..." "$YELLOW"
    launchctl unload "$PLIST_PATH" 2>/dev/null || true
    chmod -R 755 "$INSTALL_DIR" 2>/dev/null || true
else
    log "    No existing installation found." "$GREEN"
fi

# ── STEP 3: Python ────────────────────────────────────────────────────────────
log "[3/10] Checking Python..." "$YELLOW"
PYTHON=$(which python3 2>/dev/null || which python 2>/dev/null || true)
if [ -z "$PYTHON" ]; then
    log "    Python not found — installing via brew..." "$YELLOW"
    if ! command -v brew &>/dev/null; then
        log "ERROR: Homebrew not found. Install from https://brew.sh then re-run." "$RED"
        exit 1
    fi
    brew install python3 --quiet
    PYTHON=$(which python3)
    log "    Python installed via brew." "$GREEN"
fi
log "    Python: $PYTHON ($($PYTHON --version 2>&1))" "$GREEN"

# Git
if ! command -v git &>/dev/null; then
    log "    Git not found — installing via xcode-select..." "$YELLOW"
    xcode-select --install 2>/dev/null || true
    sleep 5
    if ! command -v git &>/dev/null; then
        if command -v brew &>/dev/null; then
            brew install git --quiet
        else
            log "    WARNING: Git not found. Auto-update will be disabled." "$YELLOW"
        fi
    fi
fi
if command -v git &>/dev/null; then
    log "    Git: $(git --version)" "$GREEN"
fi

# ── STEP 4: Copy files ────────────────────────────────────────────────────────
log "[4/10] Copying agent files to $INSTALL_DIR..." "$YELLOW"
for folder in agent shared database; do
    if [ -d "$SOURCE_ROOT/$folder" ]; then
        cp -r "$SOURCE_ROOT/$folder" "$INSTALL_DIR/"
        log "    Copied: $folder/" "$GREEN"
    else
        log "    WARNING: Source folder '$folder' not found — skipping." "$YELLOW"
    fi
done

if [ -f "$SOURCE_ROOT/requirements.txt" ]; then
    cp "$SOURCE_ROOT/requirements.txt" "$INSTALL_DIR/"
    log "    Copied: requirements.txt" "$GREEN"
fi

# Write .env
cat > "$INSTALL_DIR/.env" << EOF
# Auto-generated by install_service_mac.sh for $MACHINE_NAME
MANAGER_HOST=$MANAGER_IP
MANAGER_PORT=9000
AGENT_ID=$AGENT_ID
AGENT_HOSTNAME=$MACHINE_NAME
AGENT_SEND_INTERVAL=1
MONITOR_BROWSER_HISTORY=true
MONITOR_ACTIVE_WINDOW=true
MONITOR_USB_DEVICES=true
MONITOR_SHELL_COMMANDS=true
MONITOR_PROCESSES=true
EOF
log "    Wrote: .env" "$GREEN"

# ── STEP 5: pip dependencies ──────────────────────────────────────────────────
log "[5/10] Installing Python dependencies..." "$YELLOW"
$PYTHON -m pip install -r "$INSTALL_DIR/requirements.txt" --quiet
log "    Dependencies installed." "$GREEN"

# Compile .py → .pyc
$PYTHON -m compileall "$INSTALL_DIR" -q
log "    .pyc compiled." "$GREEN"

# ── STEP 6: Permissions ───────────────────────────────────────────────────────
log "[6/10] Applying access restrictions..." "$YELLOW"
chown -R root:wheel "$INSTALL_DIR"
chmod -R 700 "$INSTALL_DIR"
log "    Owner: root:wheel | Mode: 700 (admin-only access)" "$GREEN"

# ── STEP 7: LaunchDaemon ─────────────────────────────────────────────────────
log "[7/10] Registering LaunchDaemon ($PLIST_LABEL)..." "$YELLOW"
launchctl unload "$PLIST_PATH" 2>/dev/null || true
rm -f "$PLIST_PATH"

cat > "$PLIST_PATH" << EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
    "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>${PLIST_LABEL}</string>

    <key>ProgramArguments</key>
    <array>
        <string>${PYTHON}</string>
        <string>${INSTALL_DIR}/agent/agent.py</string>
    </array>

    <key>WorkingDirectory</key>
    <string>${INSTALL_DIR}</string>

    <key>RunAtLoad</key>
    <true/>

    <key>KeepAlive</key>
    <true/>

    <key>ThrottleInterval</key>
    <integer>10</integer>

    <key>StandardOutPath</key>
    <string>/dev/null</string>

    <key>StandardErrorPath</key>
    <string>/dev/null</string>

</dict>
</plist>
EOF

chown root:wheel "$PLIST_PATH"
chmod 644 "$PLIST_PATH"
launchctl load "$PLIST_PATH"
log "    LaunchDaemon loaded (RunAtLoad + KeepAlive)." "$GREEN"

# ── STEP 8: Manager connectivity ─────────────────────────────────────────────
log "[8/10] Checking manager connectivity ($MANAGER_IP:9000)..." "$YELLOW"
if nc -zv "$MANAGER_IP" 9000 -w 3 2>/dev/null; then
    log "    Manager reachable ✓" "$GREEN"
else
    log "    WARNING: $MANAGER_IP:9000 not reachable. Agent will retry automatically." "$YELLOW"
fi

# ── STEP 9: Log install summary ───────────────────────────────────────────────
log "[9/10] Writing install summary..."
log "    Agent ID  : $AGENT_ID"
log "    Manager   : ${MANAGER_IP}:9000"
log "    Install   : $INSTALL_DIR"
log "    Daemon    : $PLIST_LABEL (KeepAlive)"
log "    Log file  : $LOG_FILE"

# ── STEP 10: Verify ───────────────────────────────────────────────────────────
log "[10/10] Verifying..." "$YELLOW"
sleep 2
RUNNING=$(launchctl list | grep "$PLIST_LABEL" || echo "")
if [ -n "$RUNNING" ]; then
    log "    Daemon active: $RUNNING" "$GREEN"
else
    log "    WARNING: Daemon not yet listed. Check: sudo tail -f /var/log/soc-agent.log" "$YELLOW"
fi

ROLLED_BACK=true   # prevent false rollback on normal exit

echo ""
log "✅ SOC Agent installed successfully." "$GREEN"
log "   Path   : $INSTALL_DIR (chmod 700 root:wheel)" "$GREEN"
log "   Daemon : $PLIST_LABEL — auto-start + auto-restart on crash" "$GREEN"
echo ""
echo -e "${YELLOW}Commands (root only):${NC}"
echo "  sudo launchctl list | grep $PLIST_LABEL"
echo "  sudo launchctl unload $PLIST_PATH    ← stop"
echo "  sudo tail -f /var/log/soc-agent.log  ← live logs"
echo "  sudo bash $0 --uninstall             ← remove"
