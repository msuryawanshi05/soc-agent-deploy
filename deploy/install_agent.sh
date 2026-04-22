#!/bin/bash
# ============================================================
#  SOC Agent — Ubuntu / Linux Installer (Protected Install)
# ============================================================

set -eE

GREEN='\033[0;32m'
YELLOW='\033[1;33m'
RED='\033[0;31m'
NC='\033[0m'

SERVICE_NAME="soc-agent"
INSTALL_DIR="/opt/soc-agent"
LOG_FILE="$INSTALL_DIR/install.log"
MIN_DISK_MB=200
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SOURCE_ROOT="$(dirname "$SCRIPT_DIR")"
ROLLED_BACK=false

log() {
    local color="${2:-$NC}"
    local ts="$(date '+%Y-%m-%d %H:%M:%S')"
    local line="[$ts] $1"
    echo -e "${color}${line}${NC}"
    if [ -d "$INSTALL_DIR" ]; then
        echo "$line" >> "$LOG_FILE" 2>/dev/null || true
    fi
}

rollback() {
    if [ "$ROLLED_BACK" = "true" ]; then return; fi
    ROLLED_BACK=true
    log "ERROR: Installation failed — rolling back..." "$RED"
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f /etc/systemd/system/${SERVICE_NAME}.service
    systemctl daemon-reload 2>/dev/null || true
    chmod -R 755 "$INSTALL_DIR" 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
    log "Rollback complete." "$YELLOW"
}

trap 'EC=$?; if [ $EC -ne 0 ] && [ "$ROLLED_BACK" = "false" ]; then rollback; fi' EXIT ERR

if [ "$(id -u)" != "0" ]; then
    echo -e "${RED}ERROR: Must run as root. Use: sudo bash $0 $*${NC}"
    exit 1
fi

if [ "$1" = "--uninstall" ]; then
    mkdir -p "$INSTALL_DIR"
    log "=== SOC Agent Uninstall ===" "$YELLOW"
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
    systemctl disable "$SERVICE_NAME" 2>/dev/null || true
    rm -f /etc/systemd/system/${SERVICE_NAME}.service
    systemctl daemon-reload 2>/dev/null || true
    log "Service removed." "$GREEN"
    chmod -R 755 "$INSTALL_DIR" 2>/dev/null || true
    rm -rf "$INSTALL_DIR"
    log "Install directory removed." "$GREEN"
    log "✅ SOC Agent fully uninstalled." "$GREEN"
    ROLLED_BACK=true
    exit 0
fi

echo -e "\n${GREEN}═══════════════════════════════════════════${NC}"
echo -e "${GREEN}  SOC Agent Installer (Ubuntu — Protected)${NC}"
echo -e "${GREEN}═══════════════════════════════════════════${NC}\n"

AGENT_ID=""
while [ -z "$AGENT_ID" ]; do
    read -r -p "Enter Agent ID (e.g. agent-lab-01): " AGENT_ID
    AGENT_ID="$(echo "$AGENT_ID" | xargs)"
done

SYS_HOSTNAME="$(hostname)"
read -r -p "Enter Agent Hostname (e.g. LAB-PC-01) [$SYS_HOSTNAME]: " HOSTNAME_INPUT
HOSTNAME_INPUT="$(echo "$HOSTNAME_INPUT" | xargs)"
MACHINE_NAME="${HOSTNAME_INPUT:-$SYS_HOSTNAME}"

read -r -p "Enter Manager IP [139.59.48.159]: " IP_INPUT
IP_INPUT="$(echo "$IP_INPUT" | xargs)"
MANAGER_IP="${IP_INPUT:-139.59.48.159}"

MANAGER_PORT=9000

echo -e "\n${YELLOW}─────────────────────────────────${NC}"
echo " Agent ID      : $AGENT_ID"
echo " Hostname      : $MACHINE_NAME"
echo " Manager IP    : $MANAGER_IP"
echo " Manager Port  : $MANAGER_PORT"
echo -e "${YELLOW}─────────────────────────────────${NC}\n"

read -r -p "Proceed with installation? [Y/n]: " CONFIRM
if [ "$CONFIRM" = "n" ] || [ "$CONFIRM" = "N" ]; then
    echo -e "${YELLOW}Installation aborted.${NC}"
    ROLLED_BACK=true
    exit 0
fi

mkdir -p "$INSTALL_DIR"

log "[1/10] Checking disk space..."
FREE_MB=$(df -BM "$INSTALL_DIR" | awk 'NR==2{gsub("M","",$4); print $4}')
if [ -n "$FREE_MB" ] && [ "$FREE_MB" -lt "$MIN_DISK_MB" ]; then
    log "ERROR: Insufficient disk space: need ${MIN_DISK_MB}MB, have ${FREE_MB}MB." "$RED"
    exit 1
fi
log "    Free space: ${FREE_MB}MB ✓" "$GREEN"

log "[2/10] Checking existing installation..."
ALREADY_INSTALLED=false
if systemctl is-active --quiet "$SERVICE_NAME" 2>/dev/null || [ -d "$INSTALL_DIR/agent" ]; then
    ALREADY_INSTALLED=true
fi
if [ "$ALREADY_INSTALLED" = "true" ]; then
    read -r -p "    SOC Agent already installed. Reinstall? [y/N] " response
    if [[ ! "$response" =~ ^[Yy]$ ]]; then
        log "Skipping — existing installation kept." "$YELLOW"
        ROLLED_BACK=true
        exit 0
    fi
    log "    Proceeding with reinstall..." "$YELLOW"
    systemctl stop "$SERVICE_NAME" 2>/dev/null || true
else
    log "    No existing installation found." "$GREEN"
fi

log "[3/10] Detecting Python..."
PYTHON=$(which python3 2>/dev/null || which python 2>/dev/null || true)
if [ -z "$PYTHON" ]; then
    log "    Python not found — installing via apt..." "$YELLOW"
    apt-get update -q
    apt-get install -y python3 python3-pip -q
    PYTHON=$(which python3)
fi
log "    Python: $PYTHON" "$GREEN"

log "[4/10] Copying agent files to $INSTALL_DIR..."
for folder in agent shared database; do
    if [ -d "$SOURCE_ROOT/$folder" ]; then
        cp -r "$SOURCE_ROOT/$folder" "$INSTALL_DIR/"
    fi
done
if [ -f "$SOURCE_ROOT/requirements.txt" ]; then
    cp "$SOURCE_ROOT/requirements.txt" "$INSTALL_DIR/"
fi

cat > "$INSTALL_DIR/.env" << EOF
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
log "    .env written." "$GREEN"

log "[5/10] Installing dependencies..."
$PYTHON -m pip install -r "$INSTALL_DIR/requirements.txt" --quiet
$PYTHON -m compileall "$INSTALL_DIR" -q

log "[6/10] Applying access restrictions..."
chown -R root:root "$INSTALL_DIR"
chmod -R 700 "$INSTALL_DIR"
log "    Owner: root:root | Permissions: 700" "$GREEN"

log "[7/10] Registering systemd service '$SERVICE_NAME'..."
rm -f /etc/systemd/system/${SERVICE_NAME}.service
cat > /etc/systemd/system/${SERVICE_NAME}.service << EOF
[Unit]
Description=SOC Platform Monitoring Agent
After=network.target
Wants=network-online.target

[Service]
Type=simple
User=root
WorkingDirectory=$INSTALL_DIR
EnvironmentFile=$INSTALL_DIR/.env
ExecStart=$PYTHON $INSTALL_DIR/agent/agent.py
Restart=always
RestartSec=5
StandardOutput=null
StandardError=null
SyslogIdentifier=$SERVICE_NAME

[Install]
WantedBy=multi-user.target
EOF

systemctl daemon-reload
systemctl enable $SERVICE_NAME
systemctl restart $SERVICE_NAME

log "[8/10] Checking manager connectivity..."
if nc -zv "$MANAGER_IP" 9000 -w 3 2>/dev/null; then
    log "    Reachable ✓" "$GREEN"
fi

log "[9/10] Verification..."
sleep 2
systemctl status $SERVICE_NAME --no-pager || true

ROLLED_BACK=true
log "✅ SOC Agent installed successfully." "$GREEN"
