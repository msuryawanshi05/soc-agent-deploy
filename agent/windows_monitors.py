"""
Windows-specific monitors for USB, PowerShell, active windows, and processes.
"""

import os
import sys
import time
from datetime import datetime
from pathlib import Path
from typing import Dict, List, Optional

if sys.platform == "win32":
    import psutil
    import win32con
    import win32gui
    import win32process
    try:
        import wmi
    except ImportError:
        wmi = None
else:
    psutil = None
    wmi = None

TERMINAL_PROCESS_NAMES = {"cmd.exe", "conhost.exe", "powershell.exe", "pwsh.exe", "windows terminal.exe", "wt.exe", "bash.exe", "wsl.exe"}
SUSPICIOUS_PROCESS_NAMES = {"anydesk.exe", "filezilla.exe", "procexp.exe", "procmon.exe", "putty.exe", "teamviewer.exe", "wireshark.exe", "winscp.exe", "xftp.exe"}
APPLICATION_CATEGORY_RULES = {
    "TERMINAL": {"cmd.exe", "conhost.exe", "powershell.exe", "pwsh.exe", "wt.exe", "windows terminal.exe", "bash.exe", "wsl.exe"},
    "BROWSER": {"chrome.exe", "msedge.exe", "firefox.exe", "brave.exe", "opera.exe"},
    "COMMUNICATION": {"discord.exe", "telegram.exe", "slack.exe", "teams.exe", "whatsapp.exe", "zoom.exe"},
    "GAMING": {"steam.exe", "epicgameslauncher.exe", "riotclientservices.exe", "riotclientux.exe", "valorant.exe", "robloxplayerbeta.exe", "minecraft.exe"},
    "DEVELOPMENT": {"code.exe", "pycharm64.exe", "idea64.exe", "sublime_text.exe", "notepad++.exe"},
    "REMOTE_ACCESS": {"anydesk.exe", "teamviewer.exe", "winscp.exe", "putty.exe", "filezilla.exe"},
}
SUSPICIOUS_WINDOW_KEYWORDS = {"brainly", "chegg", "course hero", "discord", "facebook", "instagram", "minecraft", "netflix", "prime video", "pubg", "quizlet", "reddit", "roblox", "steam", "telegram", "tiktok", "twitter", "whatsapp", "youtube"}

def _clean_text(value: Optional[str], fallback: str = "Unknown") -> str:
    text = str(value or "").strip()
    return text or fallback

def _contains_storage_keywords(*values: Optional[str]) -> bool:
    haystack = " ".join(str(value or "").lower() for value in values)
    return any(keyword in haystack for keyword in ("storage", "mass", "disk", "flash", "thumb", "pendrive", "removable", "volume"))

def _categorize_application(process_name: Optional[str], window_title: Optional[str] = None) -> str:
    process_lower = str(process_name or "").lower()
    title_lower = str(window_title or "").lower()
    for category, names in APPLICATION_CATEGORY_RULES.items():
        if process_lower in names: return category
    if any(keyword in title_lower for keyword in SUSPICIOUS_WINDOW_KEYWORDS): return "OFFTASK_WINDOW"
    return "GENERAL"

class WindowsUSBMonitor:
    def __init__(self):
        if sys.platform != "win32": raise RuntimeError("WindowsUSBMonitor only works on Windows")
        if wmi is None: raise RuntimeError("WMI library not installed")
        self.wmi = wmi.WMI()
        self.known_devices, _ = self._get_connected_devices()

    def _get_connected_devices(self) -> tuple[Dict[str, Dict], List[str]]:
        devices: Dict[str, Dict] = {}
        errors: List[str] = []
        try:
            for entity in self.wmi.query("SELECT DeviceID, PNPDeviceID, Name, Description, Manufacturer, Status, PNPClass FROM Win32_PnPEntity WHERE PNPDeviceID LIKE 'USB%' OR PNPClass = 'USB'"):
                device_id = _clean_text(getattr(entity, "PNPDeviceID", None) or getattr(entity, "DeviceID", None))
                devices[device_id] = {
                    "device_id": device_id,
                    "description": _clean_text(getattr(entity, "Name", None) or getattr(entity, "Description", None)),
                    "status": _clean_text(getattr(entity, "Status", None)),
                    "manufacturer": _clean_text(getattr(entity, "Manufacturer", None)),
                    "class": _clean_text(getattr(entity, "PNPClass", None)),
                    "is_storage": _contains_storage_keywords(getattr(entity, "Name", None), getattr(entity, "Description", None), getattr(entity, "PNPClass", None)),
                }
        except Exception as e: errors.append(str(e))
        return devices, errors

    def check_new_devices(self) -> List[Dict]:
        events = []
        try:
            current_devices, _ = self._get_connected_devices()
            for device_id, device in current_devices.items():
                if device_id not in self.known_devices:
                    events.append({"timestamp": datetime.now().isoformat(), "event_type": "USB_CONNECTED", **device})
            for device_id, device in self.known_devices.items():
                if device_id not in current_devices:
                    events.append({"timestamp": datetime.now().isoformat(), "event_type": "USB_DISCONNECTED", **device})
            self.known_devices = current_devices
        except Exception: pass
        return events

class WindowsPowerShellMonitor:
    def __init__(self):
        if sys.platform != "win32": raise RuntimeError("WindowsPowerShellMonitor only works on Windows")
        appdata = os.getenv("APPDATA", "")
        self.history_file = Path(appdata) / "Microsoft" / "Windows" / "PowerShell" / "PSReadLine" / "ConsoleHost_history.txt"
        self.last_position = self.history_file.stat().st_size if self.history_file.exists() else 0
        self.last_inode = self.history_file.stat().st_ino if self.history_file.exists() else None

    def collect_new_commands(self) -> List[Dict]:
        events = []
        if not self.history_file.exists(): return events
        try:
            stat = self.history_file.stat()
            if self.last_inode is not None and stat.st_ino != self.last_inode:
                self.last_position = 0
                self.last_inode = stat.st_ino
            if stat.st_size > self.last_position:
                with open(self.history_file, "r", encoding="utf-8", errors="ignore") as handle:
                    handle.seek(self.last_position)
                    new_lines = handle.readlines()
                    self.last_position = handle.tell()
                for line in new_lines:
                    if line.strip():
                        events.append({"timestamp": datetime.now().isoformat(), "event_type": "POWERSHELL_COMMAND", "command": line.strip()})
        except Exception: pass
        return events

class WindowsActiveWindowMonitor:
    def __init__(self, check_interval: int = 5):
        if sys.platform != "win32": raise RuntimeError("WindowsActiveWindowMonitor only works on Windows")
        self.check_interval = check_interval
        self.last_window = None
        self.last_check = 0.0

    def get_active_window(self) -> Optional[Dict]:
        try:
            hwnd = win32gui.GetForegroundWindow()
            if hwnd == 0: return None
            window_title = win32gui.GetWindowText(hwnd).strip()
            _, pid = win32process.GetWindowThreadProcessId(hwnd)
            process_name = "Unknown"; username = "Unknown"
            try:
                process = psutil.Process(pid)
                process_name = _clean_text(process.name())
                username = _clean_text(process.username())
            except: pass
            app_category = _categorize_application(process_name, window_title)
            return {
                "timestamp": datetime.now().isoformat(),
                "event_type": "WINDOW_FOCUS_CHANGED",
                "window_title": window_title or "(No title)",
                "process_name": process_name,
                "username": username,
                "pid": pid,
                "app_category": app_category,
            }
        except: return None

    def check_window_change(self) -> Optional[Dict]:
        now = time.time()
        if now - self.last_check < self.check_interval: return None
        self.last_check = now
        current = self.get_active_window()
        if current is None: return None
        current_key = (current["window_title"], current["process_name"], current["pid"])
        if self.last_window == current_key: return None
        self.last_window = current_key
        return current

class WindowsProcessMonitor:
    def __init__(self):
        if sys.platform != "win32": raise RuntimeError("WindowsProcessMonitor only works on Windows")
        self.known_pids = {proc.pid for proc in psutil.process_iter(["pid"])}

    def check_new_processes(self) -> List[Dict]:
        events = []
        current_pids = set()
        try:
            for proc in psutil.process_iter(["pid", "name", "username"]):
                try:
                    pid = proc.info["pid"]
                    current_pids.add(pid)
                    if pid not in self.known_pids:
                        events.append({"timestamp": datetime.now().isoformat(), "event_type": "PROCESS_STARTED", "pid": pid, "name": proc.info["name"], "username": proc.info["username"]})
                        self.known_pids.add(pid)
                except: continue
            terminated = self.known_pids - current_pids
            for pid in terminated:
                events.append({"timestamp": datetime.now().isoformat(), "event_type": "PROCESS_TERMINATED", "pid": pid})
                self.known_pids.remove(pid)
        except: pass
        return events

def format_usb_event(event: Dict) -> str:
    device = event.get("description", "Unknown USB Device")
    if event["event_type"] == "USB_CONNECTED":
        return f"USB_CONNECT LAB_USB_INSERT: USB device inserted | Device={device} | Manufacturer={event.get('manufacturer', 'Unknown')}"
    return f"USB_DISCONNECT LAB_USB_REMOVE: USB device removed | Device={device}"

def format_powershell_event(event: Dict) -> str:
    return f"POWERSHELL_COMMAND: PowerShell history captured | Command={event['command']}"

def format_window_event(event: Dict) -> str:
    return f"WINDOW_FOCUS_CHANGED APP_ANALYSIS: Focus changed | WindowTitle={event['window_title']} | Process={event['process_name']} | Category={event.get('app_category', 'GENERAL')}"

def format_process_event(event: Dict) -> str:
    if event["event_type"] == "PROCESS_STARTED":
        return f"PROCESS_STARTED: Process started | Name={event['name']} | PID={event['pid']} | User={event.get('username', 'Unknown')}"
    return f"PROCESS_TERMINATED: Process ended | PID={event['pid']}"
