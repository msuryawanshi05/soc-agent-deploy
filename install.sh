#!/bin/bash
# SOC Agent - Ubuntu Installation Script (Enhanced)

echo "Installing SOC Agent (Ubuntu)..."

# 1. Check Python and Install Venv
if ! command -v python3 &> /dev/null; then
    echo "Installing Python3..."
    sudo apt update && sudo apt install -y python3 python3-pip python3-venv
else
    sudo apt update && sudo apt install -y python3-venv
fi

# 2. Setup Virtual Environment (Prevents 'externally-managed-environment' error)
if [ ! -d ".venv" ]; then
    echo "Creating virtual environment..."
    python3 -m venv .venv
fi

echo "Installing dependencies into virtual environment..."
./.venv/bin/pip install --upgrade pip
./.venv/bin/pip install -r requirements.txt

# 3. Setup .env
if [ ! -f ".env" ]; then
    cp .env.example .env
    echo "Created .env - MANAGER_HOST is pre-set to 168.144.73.18"
fi

# 4. Create Systemd Service
AGENT_DIR=$(pwd)
VENV_PYTHON="$AGENT_DIR/.venv/bin/python3"

echo "Creating systemd service..."
sudo bash -c "cat > /etc/systemd/system/soc-agent.service << EOF
[Unit]
Description=SOC Agent
After=network.target

[Service]
ExecStart=$VENV_PYTHON $AGENT_DIR/agent/agent.py
WorkingDirectory=$AGENT_DIR
Restart=always
RestartSec=10

[Install]
WantedBy=multi-user.target
EOF"

sudo systemctl daemon-reload
sudo systemctl enable soc-agent

echo "------------------------------------------------"
echo "Done! Agent service is configured and enabled."
echo "To start now: sudo systemctl start soc-agent"
echo "To check status: sudo systemctl status soc-agent"
echo "------------------------------------------------"
