#!/bin/bash
# SOC Agent - Ubuntu Installation Script

echo "Installing SOC Agent (Ubuntu)..."

if ! command -v python3 &> /dev/null; then
    echo "Installing Python3..."
    sudo apt update && sudo apt install -y python3 python3-pip
fi

echo "Installing dependencies..."
pip3 install -r requirements.txt

if [ ! -f ".env" ]; then
    cp .env.example .env
    echo "Created .env - MANAGER_HOST is pre-set to 168.144.73.18"
fi

AGENT_DIR=$(pwd)
sudo bash -c "cat > /etc/systemd/system/soc-agent.service << EOF
[Unit]
Description=SOC Agent
After=network.target

[Service]
ExecStart=$(which python3) $AGENT_DIR/agent/agent.py
WorkingDirectory=$AGENT_DIR
Restart=always
RestartSec=5

[Install]
WantedBy=multi-user.target
EOF"

sudo systemctl daemon-reload
sudo systemctl enable soc-agent
echo "Done! Agent service is enabled."
echo "Start now with: sudo systemctl start soc-agent"
