# ============================================================
#  SOC PLATFORM - DEPLOYMENT GUIDE FOR 60 MACHINES
# ============================================================

## SERVER REQUIREMENTS (Manager Machine)

### Minimum Specs for 60 Agents:
| Resource | Minimum | Recommended |
|----------|---------|-------------|
| CPU      | 2 cores | 4 cores     |
| RAM      | 4 GB    | 8 GB        |
| Disk     | 20 GB   | 50 GB SSD   |
| Network  | 100 Mbps| 1 Gbps      |

### Software Requirements:
- Python 3.8+
- pip packages: psutil, fastapi, uvicorn

---

## QUICK START

### 1. On Manager (Your Laptop/Server):

```bash
# Install dependencies
pip install psutil fastapi uvicorn

# Start the manager
cd soc-platform
python manager/manager.py &

# Start the dashboard API
python dashboard/api.py &

# Access dashboard
open http://localhost:8000
```

### 2. On Each Student Machine:

```bash
# Install psutil
pip install psutil

# Edit shared/config.py and set:
#   MANAGER_HOST = "192.168.x.x"  (your manager IP)
#   AGENT_ID = "agent-001"        (unique per machine)
#   AGENT_HOSTNAME = "lab-pc-1"   (machine name)

# Run the agent
python agent/agent.py
```

---

## CONFIGURATION CHECKLIST

### Manager (config.py):
```python
MANAGER_HOST = "0.0.0.0"          # Listen on all interfaces
MANAGER_PORT = 9000               # Default port
AGENT_SEND_INTERVAL = 1           # 1 second for low-latency dashboard updates
```

### Each Agent (config.py):
```python
MANAGER_HOST = "192.168.245.129"  # Your manager's IP
AGENT_ID = "agent-XXX"            # Unique: 001, 002, ... 060
AGENT_HOSTNAME = "lab-machine-X"  # Descriptive name
```

---

## BULK DEPLOYMENT OPTIONS

### Option A: Manual (Small Lab)
1. Copy soc-platform folder to each machine
2. Edit config.py on each machine
3. Run: `python agent/agent.py`

### Option B: Script (Recommended)
```bash
# On each machine, run:
./deploy/install_agent.sh 192.168.245.129 1 lab-machine-1
./deploy/install_agent.sh 192.168.245.129 2 lab-machine-2
# ... etc
```

### Option C: SSH Loop (Advanced)
```bash
# From manager, deploy to all machines:
for i in {1..60}; do
  ssh student@lab-pc-$i "cd ~/soc && python agent/agent.py &"
done
```

---

## FIREWALL RULES

### On Manager:
```bash
# Allow agent connections
sudo ufw allow 9000/tcp

# Allow dashboard access
sudo ufw allow 8000/tcp
```

### On Student Machines:
```bash
# Allow outbound to manager (usually allowed by default)
sudo ufw allow out to 192.168.245.129 port 9000
```

---

## MONITORING & TROUBLESHOOTING

### Check Manager Status:
```bash
# See connected agents
netstat -an | grep 9000 | grep ESTABLISHED | wc -l

# Check manager logs
tail -f manager.log
```

### Check Agent Status:
```bash
# On student machine
ps aux | grep agent.py

# Test connection to manager
nc -zv 192.168.245.129 9000
```

### Common Issues:

| Problem | Solution |
|---------|----------|
| Agent can't connect | Check firewall, verify manager IP |
| Dashboard slow | Increase server RAM, check DB size |
| Missing alerts | Restart manager to reload rules |
| High CPU on manager | Increase AGENT_SEND_INTERVAL to 3-5 |

---

## PERFORMANCE TUNING

### For 60+ Machines:
1. Set `AGENT_SEND_INTERVAL = 1` for faster event visibility
2. Use SSD for database
3. Run manager with: `nice -n -10 python manager/manager.py`
4. Consider log rotation for old alerts

### Database Maintenance:
```sql
-- Clean old logs (keep last 7 days)
DELETE FROM logs WHERE timestamp < strftime('%s', 'now') - 604800;

-- Clean acknowledged alerts (keep last 30 days)
DELETE FROM alerts WHERE acknowledged=1 
  AND timestamp < strftime('%s', 'now') - 2592000;

-- Optimize database
VACUUM;
```

---

## PROTECTED INSTALL PATHS, PERMISSIONS & AUTO-START

Each install script does everything in one command: clones the repo, writes `.env`,
installs dependencies, compiles `.py` → `.pyc`, locks permissions, and registers the system service.

> **Protection note:** The install directory is root-owned with mode `700`. Regular users get
> `Permission denied` on every file. `.py` files are compiled to `.pyc` for obfuscation; both
> stay inside the locked directory (Python's import system requires the `.py` files to be present).


### 🪟 Windows — Windows Service

**Requirements:** Run PowerShell as Administrator.

```powershell
# Navigate to the deploy folder
cd \path\to\soc-agent-deploy

# Install and start the service (auto-detects Python, installs pywin32 if needed)
.\deploy\install_service_windows.ps1

# Verify
sc query SOCAgent
# Expected: STATE : 4  RUNNING
```

**Uninstall:**
```powershell
.\deploy\install_service_windows.ps1 -Uninstall
```

**What it does:**
- Auto-detects Python path (no hardcoding)
- Installs `pywin32` if not already present
- Registers `agent_service.py` as a Windows Service (`SOCAgent`)
- Sets startup type to **Automatic** — survives reboots
- Only root/Administrator can stop the service

**Day-to-day commands:**
```powershell
sc query SOCAgent                        # status
Stop-Service SOCAgent                    # stop
Start-Service SOCAgent                   # start
Get-EventLog -LogName System -Source SOCAgent  # logs
```

---

### 🐧 Ubuntu / Linux — systemd Service

**Requirements:** Run as root (`sudo`).

```bash
# One-command install: sets up .env, installs deps, registers systemd service
sudo bash deploy/install_agent.sh <MANAGER_IP> <AGENT_NUM> <MACHINE_NAME>

# Example:
sudo bash deploy/install_agent.sh 192.168.1.100 5 lab-machine-5

# Verify
sudo systemctl status soc-agent
# Expected: Active: active (running)
```

**What it does:**
- Auto-detects Python path
- Installs pip dependencies from `requirements.txt`
- Writes `.env` with manager IP, agent ID, and hostname
- Creates `/etc/systemd/system/soc-agent.service` with:
  - `Restart=always` — auto-restarts on crash
  - `RestartSec=5` — 5-second delay between restarts
  - `After=network.target` — waits for network before starting
- Enables service so it auto-starts on every boot

**Day-to-day commands:**
```bash
sudo systemctl status  soc-agent      # status
sudo systemctl stop    soc-agent      # stop (root only)
sudo systemctl start   soc-agent      # start
sudo systemctl restart soc-agent      # restart
sudo journalctl -u     soc-agent -f   # live logs
```

---

### 🍎 macOS — LaunchDaemon

**Requirements:** Run as root (`sudo`).

```bash
# One-command install
sudo bash deploy/install_service_mac.sh <MANAGER_IP> <AGENT_NUM> <MACHINE_NAME>

# Example:
sudo bash deploy/install_service_mac.sh 192.168.1.100 3 mac-lab-3

# Verify
sudo launchctl list | grep soc-agent
# Expected: line appears with PID (not dash)
```

**Uninstall:**
```bash
sudo bash deploy/install_service_mac.sh --uninstall
```

**What it does:**
- Auto-detects Python path
- Installs pip dependencies
- Writes `.env` with agent configuration
- Creates `/Library/LaunchDaemons/com.soc.agent.plist` with:
  - `RunAtLoad = true` — starts on boot
  - `KeepAlive = true` — auto-restarts on crash
  - `ThrottleInterval = 10` — prevents rapid crash loops
- Logs stdout/stderr to `/var/log/soc-agent.log`

**Day-to-day commands:**
```bash
sudo launchctl list | grep com.soc.agent          # status
sudo launchctl unload /Library/LaunchDaemons/com.soc.agent.plist  # stop
sudo launchctl load   /Library/LaunchDaemons/com.soc.agent.plist  # start
sudo tail -f /var/log/soc-agent.log               # live logs
```

---

## ESTIMATED RESOURCE USAGE (60 Machines)

| Metric | Value |
|--------|-------|
| Network traffic | ~50-100 KB/s total |
| Events per second | ~60-120 events/sec |
| DB growth | ~50-100 MB/day |
| Memory usage | ~500 MB - 1 GB |
| CPU usage | ~10-30% (4 cores) |

---

## READY TO DEPLOY! ✓

1. ✅ Manager configured for 100 connections
2. ✅ Database optimized with indexes
3. ✅ SQLite WAL mode for concurrent access
4. ✅ Thread-per-agent architecture
5. ✅ Keepalive for connection reliability
6. ✅ Auto-start on boot — Windows, Ubuntu, macOS

