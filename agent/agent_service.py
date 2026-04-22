"""
SOC Agent — Windows Service Wrapper
====================================
Registers and runs agent.py as a Windows Service via pywin32.

Install:   python agent_service.py install
Remove:    python agent_service.py remove
Start:     python agent_service.py start
Stop:      python agent_service.py stop

Recommended: use deploy/install_service_windows.ps1 (handles everything automatically).
"""

import sys
import os
import subprocess

import win32serviceutil
import win32service
import win32event
import servicemanager


class SOCAgentService(win32serviceutil.ServiceFramework):
    _svc_name_         = "SOCAgent"
    _svc_display_name_ = "SOC Agent"
    _svc_description_  = (
        "Security Operations Center Monitoring Agent — "
        "collects and forwards security events to the SOC Manager."
    )

    def __init__(self, args):
        win32serviceutil.ServiceFramework.__init__(self, args)
        self._stop_event = win32event.CreateEvent(None, 0, 0, None)
        self._process    = None

    # ── Called by SCM when Stop is requested ────────────────
    def SvcStop(self):
        self.ReportServiceStatus(win32service.SERVICE_STOP_PENDING)
        win32event.SetEvent(self._stop_event)
        self._kill_agent()

    # ── Entry point when service starts ─────────────────────
    def SvcDoRun(self):
        servicemanager.LogMsg(
            servicemanager.EVENTLOG_INFORMATION_TYPE,
            servicemanager.PYS_SERVICE_STARTED,
            (self._svc_name_, ""),
        )
        self._run_agent()
        servicemanager.LogMsg(
            servicemanager.EVENTLOG_INFORMATION_TYPE,
            servicemanager.PYS_SERVICE_STOPPED,
            (self._svc_name_, ""),
        )

    # ── Helpers ──────────────────────────────────────────────
    def _build_env(self, project_root: str) -> dict:
        """Merge system env with variables from .env file (if present)."""
        env = os.environ.copy()
        env_file = os.path.join(project_root, ".env")
        if os.path.isfile(env_file):
            with open(env_file, encoding="utf-8") as fh:
                for raw in fh:
                    line = raw.strip()
                    if not line or line.startswith("#") or "=" not in line:
                        continue
                    key, _, val = line.partition("=")
                    # setdefault → system env takes priority
                    env.setdefault(key.strip(), val.strip())
        return env

    def _run_agent(self):
        # agent_service.py sits in  <project_root>/agent/
        # agent.py            sits in  <project_root>/agent/
        service_dir  = os.path.dirname(os.path.abspath(__file__))
        project_root = os.path.dirname(service_dir)
        agent_script = os.path.join(service_dir, "agent.py")
        python_exe   = sys.executable   # never hardcoded

        env = self._build_env(project_root)

        self._process = subprocess.Popen(
            [python_exe, agent_script],
            cwd=project_root,           # so dotenv lookup finds .env at root
            env=env,
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
        )

        # Block here until SvcStop() signals us
        win32event.WaitForSingleObject(self._stop_event, win32event.INFINITE)
        self._kill_agent()

    def _kill_agent(self):
        if self._process and self._process.poll() is None:
            self._process.terminate()
            try:
                self._process.wait(timeout=10)
            except subprocess.TimeoutExpired:
                self._process.kill()


# ── Entry point ──────────────────────────────────────────────
if __name__ == "__main__":
    if len(sys.argv) == 1:
        # Launched by the Service Control Manager — start dispatcher
        servicemanager.Initialize()
        servicemanager.PrepareToHostSingle(SOCAgentService)
        servicemanager.StartServiceCtrlDispatcher()
    else:
        # Called with install / remove / start / stop / etc.
        win32serviceutil.HandleCommandLine(SOCAgentService)
