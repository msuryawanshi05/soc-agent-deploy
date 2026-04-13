import tempfile
# ============================================================
#  SOC Platform - Student Activity Monitor
#  Built for college SOC lab — monitors what students do
#  during practicals and exams.
#
#  Monitors:
#  1. BrowserMonitor   → active browser tabs & URLs visited
#  2. AppMonitor       → which applications are open/active
#  3. ScreenshotMonitor→ periodic screenshots (optional)
#  4. ClipboardMonitor → detects code copied from internet
# ============================================================

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
    # Don't exit here, let agent handle dependencies or pip install them
    pass


# ══════════════════════════════════════════════════════════════
#  CATEGORY DEFINITIONS
#  Add/remove domains from any category as needed
# ══════════════════════════════════════════════════════════════

BLOCKED_CATEGORIES = {

    "GAMING_ONLINE": [
        "miniclip.com", "poki.com", "coolmathgames.com", "friv.com",
        "y8.com", "kongregate.com", "addictinggames.com", "newgrounds.com",
        "armor games.com", "agame.com", "gameflare.com", "silvergames.com",
        "crazygames.com", "kizi.com", "unblocked-games.com",
        "chess.com", "lichess.org", "battleship-game.org",
        "steamcommunity.com", "store.steampowered.com",
    ],

    "GAMING_APP": [
        "steam", "epicgames", "origin", "battlenet", "uplay",
        "minecraft", "roblox", "fortnite", "valorant", "csgo",
        "leagueoflegends", "dota2", "pubg",
    ],

    "SOCIAL_MEDIA": [
        "facebook.com", "instagram.com", "twitter.com", "x.com",
        "snapchat.com", "tiktok.com", "pinterest.com", "reddit.com",
        "tumblr.com", "discord.com", "discord.gg",
        "whatsapp.com", "web.whatsapp.com", "telegram.org",
    ],

    "VIDEO_STREAMING": [
        "youtube.com", "youtu.be", "netflix.com", "primevideo.com",
        "hotstar.com", "jiocinema.com", "mx player.com", "voot.com",
        "zee5.com", "sonyliv.com", "twitch.tv", "dailymotion.com",
        "vimeo.com",
    ],

    "CHEATING_SITES": [
        "chegg.com", "coursehero.com", "studocu.com", "scribd.com",
        "slader.com", "bartleby.com", "brainly.com",
        "homework.com", "homeworklib.com",
        # Answer/code sharing that suggests copying
        "pastebin.com", "pastecode.io", "hastebin.com",
    ],

    "ALLOWED_CODING": [
        # These are ALLOWED during practicals — don't alert on these
        "stackoverflow.com", "github.com", "docs.python.org",
        "developer.mozilla.org", "w3schools.com", "geeksforgeeks.org",
        "cppreference.com", "linux.die.net", "man7.org",
        "google.com", "duckduckgo.com",   # Search engines are OK
    ],
}

# All forbidden domains flattened
ALL_BLOCKED = {
    domain: category
    for category, domains in BLOCKED_CATEGORIES.items()
    if category != "ALLOWED_CODING"
    for domain in domains
}


# ══════════════════════════════════════════════════════════════
#  1. BROWSER URL MONITOR
#     Reads Chrome/Firefox browser history databases directly
#     Works without any browser extension
# ══════════════════════════════════════════════════════════════
class BrowserMonitor:
    """
    Reads browser history SQLite databases directly from disk.
    Detects URLs visited in Chrome and Firefox.
    Checks them against the blocked categories list.

    No browser extension needed — reads the DB files directly.
    """

    def __init__(self):
        self._last_checked = {}   # { db_path: last_visit_time }
        self._db_paths     = []
        self._find_browsers()
        self._baseline()

    def _find_browsers(self):
        """Locate Chrome, Chromium, Brave, Edge, Firefox history database files."""
        import platform
        home = os.path.expanduser("~")
        os_type = platform.system()
        paths = []

        # ── Linux: Standard ~/.config paths ──
        if os_type == "Linux":
            chrome_search_paths = [
                f"{home}/.config/google-chrome/Default/History",
                f"{home}/.config/google-chrome/Profile 1/History",
                f"{home}/.config/chromium/Default/History",
                f"{home}/.config/BraveSoftware/Brave-Browser/Default/History",
                f"{home}/.config/BraveSoftware/Brave-Browser/Profile 1/History",
                f"{home}/.config/brave/Default/History",
                f"{home}/.config/microsoft-edge/Default/History",
            ]
            for p in chrome_search_paths:
                if os.path.exists(p):
                    bname = "brave" if "brave" in p.lower() else \
                            "chromium" if "chromium" in p.lower() else \
                            "edge" if "edge" in p.lower() else "chrome"
                    paths.append((bname, p))

            # ── Snap Brave — scans all version folders dynamically ──
            snap_brave_glob = glob.glob(
                f"{home}/snap/brave/*/.config/BraveSoftware/Brave-Browser/Default/History"
            ) + glob.glob(
                f"{home}/snap/brave/*/.config/BraveSoftware/Brave-Browser/Profile */History"
            )
            for p in snap_brave_glob:
                if "/current/" in p: continue
                if os.path.exists(p) and p not in [x[1] for x in paths]:
                    paths.append(("chrome", p))

        # ── Windows: AppData paths ──
        elif os_type == "Windows":
            appdata = os.getenv("LOCALAPPDATA")
            if appdata:
                win_chrome_paths = [
                    f"{appdata}\\Google\\Chrome\\User Data\\Default\\History",
                    f"{appdata}\\Microsoft\\Edge\\User Data\\Default\\History",
                    f"{appdata}\\BraveSoftware\\Brave-Browser\\User Data\\Default\\History",
                ]
                for p in win_chrome_paths:
                    if os.path.exists(p):
                        bname = "edge" if "edge" in p.lower() else "brave" if "brave" in p.lower() else "chrome"
                        paths.append((bname, p))

        # ── Firefox (all platforms) ──
        if os_type == "Darwin":
            ff_base = f"{home}/Library/Application Support/Firefox"
        elif os_type == "Windows":
            localappdata = os.getenv("APPDATA") # Roaming for FF
            ff_base = f"{localappdata}\\Mozilla\\Firefox" if localappdata else None
        else:  # Linux
            ff_base = f"{home}/.mozilla/firefox"

        if ff_base and os.path.exists(ff_base):
            for profile in glob.glob(f"{ff_base}/*.default*/places.sqlite"):
                if os.path.exists(profile):
                    paths.append(("firefox", profile))

        self._db_paths = paths

    def _baseline(self):
        """Record the latest visit time in each browser DB — only alert on NEW visits after this point."""
        for btype, path in self._db_paths:
            ts = self._get_latest_visit_time(btype, path)
            self._last_checked[path] = ts if ts else 0

    def _get_latest_visit_time(self, btype: str, db_path: str):
        """Get the most recent visit timestamp from the DB."""
        try:
            import shutil
            tmp = os.path.join(tempfile.gettempdir(), f"soc_browser_{os.path.basename(db_path)}_{abs(hash(db_path))}")
            shutil.copy2(db_path, tmp)
            conn = sqlite3.connect(tmp)
            if btype == "firefox":
                row = conn.execute("SELECT MAX(visit_date) FROM moz_historyvisits").fetchone()
            else:  # chrome, brave, chromium, edge
                row = conn.execute("SELECT MAX(last_visit_time) FROM urls").fetchone()
            conn.close()
            try: os.remove(tmp)
            except: pass
            return row[0] if row and row[0] else 0
        except:
            return 0

    def _extract_search_query(self, url: str) -> str | None:
        import urllib.parse
        try:
            parsed = urllib.parse.urlparse(url.lower())
            params = urllib.parse.parse_qs(parsed.query)
            search_engines = {"google.com": "q", "bing.com": "q", "duckduckgo.com": "q", "search.brave.com": "q"}
            domain = parsed.netloc.replace("www.", "")
            for engine, param in search_engines.items():
                if engine in domain and param in params:
                    return params[param][0]
        except: pass
        return None

    def _get_new_visits(self, btype: str, db_path: str, since: int) -> list:
        visits = []
        try:
            import shutil
            tmp = os.path.join(tempfile.gettempdir(), f"soc_browser_{os.path.basename(db_path)}_{abs(hash(db_path))}")
            shutil.copy2(db_path, tmp)
            conn = sqlite3.connect(tmp)
            if btype == "firefox":
                rows = conn.execute("SELECT p.url, p.title, v.visit_date FROM moz_places p JOIN moz_historyvisits v ON p.id = v.place_id WHERE v.visit_date > ? ORDER BY v.visit_date DESC LIMIT 50", (since,)).fetchall()
            else:
                rows = conn.execute("SELECT url, title, last_visit_time FROM urls WHERE last_visit_time > ? ORDER BY last_visit_time DESC LIMIT 50", (since,)).fetchall()
            conn.close()
            try: os.remove(tmp)
            except: pass
            visits = [(r[0] or '', r[1] or '', r[2] or 0) for r in rows]
        except: pass
        return visits

    def _extract_domain(self, url: str) -> str:
        url = url.lower().strip()
        for prefix in ['https://', 'http://', 'www.']:
            if url.startswith(prefix): url = url[len(prefix):]
        return url.split('/')[0].split('?')[0]

    def _check_url(self, url: str, title: str) -> tuple[str, str] | None:
        domain = self._extract_domain(url)
        if not domain: return None
        for blocked_domain, category in ALL_BLOCKED.items():
            if domain == blocked_domain or domain.endswith('.' + blocked_domain):
                return (category, domain)
        return None

    def check(self) -> list[str]:
        events = []
        seen_urls = set()
        for btype, db_path in self._db_paths:
            since = self._last_checked.get(db_path, 0)
            visits = self._get_new_visits(btype, db_path, since)
            max_time = since
            for url, title, visit_time in visits:
                if visit_time > max_time: max_time = visit_time
                url_key = url[:100]
                if url_key in seen_urls: continue
                seen_urls.add(url_key)
                query = self._extract_search_query(url)
                if query:
                    events.append(f"BROWSER_SEARCH: Student searched | Query={query} | URL={url[:80]} | Browser={btype}")
                result = self._check_url(url, title)
                if result:
                    category, domain = result
                    events.append(f"BROWSER_BLOCKED: Student visited restricted site | Category={category} | Domain={domain} | URL={url[:80]} | Browser={btype}")
                skip_prefixes = ("chrome://", "about:", "data:")
                if not any(url.startswith(p) for p in skip_prefixes) and not query:
                    domain = self._extract_domain(url)
                    if domain:
                        events.append(f"BROWSER_VISIT: Student visited URL | Domain={domain} | URL={url[:100]} | Browser={btype}")
            if max_time > since: self._last_checked[db_path] = max_time
        return events

class ActiveWindowMonitor:
    SUSPICIOUS_WINDOW_KEYWORDS = ["whatsapp", "telegram", "discord", "facebook", "instagram", "reddit", "netflix", "youtube", "chegg", "course hero"]
    def __init__(self):
        import platform
        self._last_window = ""
        self._os_type = platform.system()
        self._xdotool_ok = self._check_xdotool() if self._os_type == "Linux" else False

    def _check_xdotool(self) -> bool:
        try:
            return subprocess.run(["which", "xdotool"], capture_output=True).returncode == 0
        except: return False

    def _get_active_window_linux(self) -> str:
        if not self._xdotool_ok: return ""
        try:
            result = subprocess.run(["xdotool", "getactivewindow", "getwindowname"], capture_output=True, text=True, timeout=2, env={**os.environ, "DISPLAY": ":0"})
            return result.stdout.strip()
        except: return ""

    def check(self) -> list[str]:
        events = []
        title = self._get_active_window_linux() if self._os_type == "Linux" else ""
        if not title or title == self._last_window: return events
        title_lower = title.lower()
        for keyword in self.SUSPICIOUS_WINDOW_KEYWORDS:
            if keyword in title_lower:
                events.append(f"SUSPICIOUS_WINDOW: Student switched to off-task app | WindowTitle={title} | Keyword={keyword}")
                break
        self._last_window = title
        return events

class DNSMonitor:
    def __init__(self):
        self._seen_domains = set()
        self._baseline()

    def _get_active_connections(self) -> set:
        domains = set()
        try:
            for conn in psutil.net_connections(kind='inet'):
                if conn.status in ('ESTABLISHED', 'SYN_SENT') and conn.raddr:
                    ip = conn.raddr.ip
                    if ip.startswith(('127.', '10.', '192.168.', '172.')): continue
                    if conn.raddr.port not in (80, 443): continue
                    try:
                        hostname = socket.gethostbyaddr(ip)[0]
                        domains.add(hostname.lower())
                    except: pass
        except: pass
        return domains

    def _baseline(self): self._seen_domains = self._get_active_connections()

    def check(self) -> list[str]:
        events = []
        current = self._get_active_connections()
        new = current - self._seen_domains
        for domain in new:
            for blocked, category in ALL_BLOCKED.items():
                if domain == blocked or domain.endswith('.' + blocked):
                    events.append(f"DNS_BLOCKED: Network connection to restricted site | Category={category} | Domain={domain}")
        self._seen_domains = current
        return events

class LabUSBMonitor:
    def __init__(self):
        self._known_storage = self._get_usb_storage()

    def _get_usb_storage(self) -> dict:
        devices = {}
        usb_path = "/sys/bus/usb/devices"
        if not os.path.exists(usb_path): return devices
        try:
            for entry in os.listdir(usb_path):
                base = f"{usb_path}/{entry}"
                if os.path.exists(f"{base}/idVendor"):
                    devices[entry] = open(f"{base}/idVendor").read().strip()
        except: pass
        return devices

    def check(self) -> list[str]:
        events = []
        current = self._get_usb_storage()
        new_devs = {k: v for k, v in current.items() if k not in self._known_storage}
        for dev_id in new_devs:
            events.append(f"LAB_USB_INSERT: EXAM VIOLATION - USB device inserted! | DeviceID={dev_id}")
        self._known_storage = current
        return events

class ShellCommandMonitor:
    SOC_LOG = os.path.expanduser("~/.soc_cmd_log")
    def __init__(self):
        self._soc_log_size = 0
        self._inject_hooks()

    def _inject_hooks(self):
        home = os.path.expanduser("~")
        hook = f'\n# SOC_MONITOR_HOOK\nexport PROMPT_COMMAND=\'echo "$(date +%H:%M:%S) [bash] $(history 1 | sed "s/^[ 0-9]*//")" >> {self.SOC_LOG}\'\n'
        for rc in [f"{home}/.bashrc"]:
            try:
                if os.path.exists(rc) and "SOC_MONITOR_HOOK" not in open(rc).read():
                    with open(rc, "a") as f: f.write(hook)
            except: pass
        if os.path.exists(self.SOC_LOG): self._soc_log_size = os.path.getsize(self.SOC_LOG)

    def check(self) -> list[str]:
        events = []
        if not os.path.exists(self.SOC_LOG): return events
        try:
            size = os.path.getsize(self.SOC_LOG)
            if size > self._soc_log_size:
                with open(self.SOC_LOG, "rb") as f:
                    f.seek(self._soc_log_size)
                    text = f.read().decode("utf-8", errors="replace")
                for line in text.splitlines():
                    if line.strip(): events.append(f"SHELL_COMMAND: Student ran command | {line.strip()}")
                self._soc_log_size = size
        except: pass
        return events

class StudentActivityMonitor:
    def __init__(self):
        self.browser = BrowserMonitor()
        self.window = ActiveWindowMonitor()
        self.dns = DNSMonitor()
        self.usb = LabUSBMonitor()
        self.shell = ShellCommandMonitor()

    def collect(self) -> list[tuple[str, str]]:
        results = []
        for source, monitor in [("BROWSER", self.browser), ("WINDOW", self.window), ("DNS", self.dns), ("LAB_USB", self.usb), ("SHELL", self.shell)]:
            try:
                for event in monitor.check():
                    results.append((source, event))
            except: pass
        return results
