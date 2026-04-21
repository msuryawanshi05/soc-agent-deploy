"""
SOC Agent — Auto-Updater
========================
Called once at agent startup. Checks GitHub for new commits.

Behaviour:
  - Updates available  → git reset --hard, recompile .pyc, exit cleanly
                         (the service manager — systemd / Windows SCM / launchd — restarts the agent)
  - No updates         → log and continue normally
  - Git unreachable    → log and continue on current version (no crash)
  - Crash-loop guard   → if the same commit caused a restart-crash cycle, skip it
"""

import os
import sys
import subprocess
import compileall
import logging

logger = logging.getLogger("Updater")

# Written before applying an update; contains the target commit hash.
# If agent crashes repeatedly after an update this file lets us skip that commit.
_LOCK_FILE = ".update_lock"


def _project_root() -> str:
    """agent/updater.py → project root is one level up."""
    return os.path.dirname(os.path.dirname(os.path.abspath(__file__)))


def _run_git(args: list, cwd: str, timeout: int = 30) -> tuple[int, str]:
    """Run a git command; return (returncode, stdout+stderr)."""
    try:
        r = subprocess.run(
            ["git"] + args,
            cwd=cwd,
            capture_output=True,
            text=True,
            timeout=timeout,
        )
        return r.returncode, (r.stdout + r.stderr).strip()
    except FileNotFoundError:
        return -1, "git not found"
    except subprocess.TimeoutExpired:
        return -1, "git command timed out"
    except Exception as e:
        return -1, str(e)


def _local_commit(root: str) -> str:
    code, out = _run_git(["rev-parse", "HEAD"], root, timeout=10)
    return out if code == 0 else ""


def _remote_commit(root: str) -> str:
    """Fetch silently then return origin/main HEAD hash."""
    _run_git(["fetch", "origin", "--quiet"], root, timeout=30)
    code, out = _run_git(["rev-parse", "origin/main"], root, timeout=10)
    return out if code == 0 else ""


def _apply_update(root: str) -> bool:
    """Hard-reset working tree to origin/main (restores any deleted .py files)."""
    code, out = _run_git(["reset", "--hard", "origin/main"], root, timeout=60)
    if code != 0:
        logger.warning(f"[Updater] git reset failed: {out}")
        return False
    return True


def _recompile(root: str):
    """Compile all .py files to .pyc (placed in __pycache__ by Python)."""
    compileall.compile_dir(root, quiet=True, force=True, legacy=False)
    logger.info("[Updater] Recompile complete.")


def _read_lock(root: str) -> str:
    lock = os.path.join(root, _LOCK_FILE)
    if os.path.isfile(lock):
        with open(lock) as f:
            return f.read().strip()
    return ""


def _write_lock(root: str, commit: str):
    with open(os.path.join(root, _LOCK_FILE), "w") as f:
        f.write(commit)


def _clear_lock(root: str):
    lock = os.path.join(root, _LOCK_FILE)
    if os.path.isfile(lock):
        os.remove(lock)


def run_update_check() -> bool:
    """
    Returns True  → update was applied; caller should exit so service restarts.
    Returns False → no update needed or update failed; caller continues normally.
    """
    root = _project_root()

    # Not a git repo — skip silently
    if not os.path.isdir(os.path.join(root, ".git")):
        logger.info("[Updater] Not a git repo — skipping update check.")
        return False

    try:
        local  = _local_commit(root)
        remote = _remote_commit(root)

        if not remote:
            logger.info("[Updater] Cannot reach remote — running current version.")
            return False

        if local == remote:
            logger.info(f"[Updater] Up-to-date ({local[:8]}).")
            _clear_lock(root)   # Previous update is stable — clear crash-loop guard
            return False

        # Crash-loop guard: if this remote commit already locked us, skip it
        locked = _read_lock(root)
        if locked == remote:
            logger.warning(
                f"[Updater] Update to {remote[:8]} previously caused a crash loop — skipping."
            )
            return False

        logger.info(f"[Updater] Update available: {local[:8]} → {remote[:8]}. Applying…")

        # Write lock BEFORE applying (crash during apply → guard on next boot)
        _write_lock(root, remote)

        if not _apply_update(root):
            return False

        _recompile(root)

        logger.info("[Updater] Done. Exiting cleanly so the service manager restarts us.")
        return True     # ← caller should sys.exit(0)

    except Exception as e:
        logger.warning(f"[Updater] Unexpected error: {e} — continuing on current version.")
        return False
