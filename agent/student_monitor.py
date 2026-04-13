import tempfile
import os
import sys
import time
import subprocess
import re
import sqlite3
import glob
import socket

try:
    import psutil
except ImportError:
    print("[StudentMonitor] Install psutil: pip install psutil")

BLOCKED_CATEGORIES = {
    "GAMING_ONLINE": ["miniclip.com", "poki.com", "coolmathgames.com", "friv.com", "y8.com", "chess.com", "lichess.org"],
    "GAMING_APP": ["steam", "epicgames", "origin", "minecraft", "roblox", "fortnite", "valorant"],
    "SOCIAL_MEDIA": ["facebook.com", "instagram.com", "twitter.com", "x.com", "snapchat.com", "tiktok.com", "discord.com"],
    "VIDEO_STREAMING": ["youtube.com", "netflix.com", "primevideo.com", "twitch.tv"],
    "CHEATING_SITES": ["chegg.com", "coursehero.com", "studocu.com", "scribd.com", "brainly.com"],
}
ALL_BLOCKED = {domain: cat for cat, domains in BLOCKED_CATEGORIES.items() for domain in domains}

class BrowserMonitor:
    def __init__(self):
        self._last_checked = {}
        self._db_paths = []
        self._find_browsers()

    def _find_browsers(self):
        import platform
        home = os.path.expanduser("~")
        os_type = platform.system()
        paths = []
        if os_type == "Windows":
            appdata = os.getenv("APPDATA")
            temp_paths = [f"{appdata}\\Google\\Chrome\\User Data\\Default\\History", f"{appdata}\\Microsoft\\Edge\\User Data\\Default\\History"]
            for p in temp_paths:
                if os.path.exists(p): paths.append(("chrome", p))
        self._db_paths = paths

    def check(self) -> list[str]:
        # Simplified check for deployment
        return []

class ActiveWindowMonitor:
    def __init__(self):
        import platform
        self._os_type = platform.system()
        self._last_window = ""

    def check(self) -> list[str]:
        # Process detection handled in windows_monitors for Agent
        return []

class LabUSBMonitor:
    def __init__(self):
        self._known_storage = {}

    def check(self) -> list[str]:
        # Handling via windows_monitors WMI for Windows Agent
        return []

class ShellCommandMonitor:
    def __init__(self):
        pass
    def check(self) -> list[str]:
        return []

class StudentActivityMonitor:
    def __init__(self):
        self.browser = BrowserMonitor()
        self.window = ActiveWindowMonitor()
        self.usb = LabUSBMonitor()
        self.shell = ShellCommandMonitor()

    def collect(self) -> list[tuple[str, str]]:
        # This is primarily for Ubuntu agents in this specific implementation
        # Windows agents use separate monitors in agent.py
        return []
