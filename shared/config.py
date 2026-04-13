# SOC Platform - Shared Configuration
import os
from pathlib import Path
from dotenv import load_dotenv

load_dotenv()
BASE_DIR = Path(__file__).resolve().parent.parent

MANAGER_HOST = os.getenv("MANAGER_HOST", "168.144.73.18")
MANAGER_PORT = int(os.getenv("MANAGER_PORT", "9000"))
MANAGER_BUFFER_SIZE = 8192
MANAGER_MAX_CONNECTIONS = 100

API_HOST = os.getenv("API_HOST", "0.0.0.0")
API_PORT = int(os.getenv("API_PORT", "8000"))

DB_PATH = os.getenv("DB_PATH", str(BASE_DIR / "soc_platform.db"))

AGENT_SEND_INTERVAL = int(os.getenv("AGENT_SEND_INTERVAL", "2"))
AGENT_ID = os.getenv("AGENT_ID", "agent-001")
AGENT_HOSTNAME = os.getenv("AGENT_HOSTNAME", "agent-pc")
AGENT_RECONNECT_DELAY = 5
AGENT_HEARTBEAT_INTERVAL = 10

SEVERITY = {
    "LOW": 1,
    "MEDIUM": 2,
    "HIGH": 3,
    "CRITICAL": 4
}

LOG_SOURCES = [
    "/var/log/syslog",
    "/var/log/auth.log",
]

FIM_WATCH_PATHS = [
    "/etc/passwd",
    "/etc/shadow",
    "/etc/hosts",
]
