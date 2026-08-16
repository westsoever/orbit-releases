"""PID file helpers for the Orbit capture daemon."""
from __future__ import annotations

import os
import signal
from pathlib import Path

DEFAULT_PID_PATH = os.path.expanduser("~/.orbit/daemon.pid")


def default_pid_path() -> str:
    return DEFAULT_PID_PATH


def _ensure_parent(path: str) -> None:
    os.makedirs(os.path.dirname(os.path.expanduser(path)), exist_ok=True)


def write_pid(pid: int | None = None, path: str | None = None) -> None:
    """Record the running daemon PID (default: current process)."""
    pid_path = path or DEFAULT_PID_PATH
    _ensure_parent(pid_path)
    value = os.getpid() if pid is None else pid
    with open(pid_path, "w", encoding="utf-8") as fh:
        fh.write(f"{value}\n")


def read_pid(path: str | None = None) -> int | None:
    """Return PID from file, or None if missing/invalid."""
    pid_path = Path(os.path.expanduser(path or DEFAULT_PID_PATH))
    if not pid_path.is_file():
        return None
    try:
        return int(pid_path.read_text(encoding="utf-8").strip())
    except (OSError, ValueError):
        return None


def remove_pid(path: str | None = None) -> None:
    """Remove PID file if present."""
    pid_path = Path(os.path.expanduser(path or DEFAULT_PID_PATH))
    try:
        pid_path.unlink(missing_ok=True)
    except OSError:
        pass


def is_process_alive(pid: int) -> bool:
    """Return True if ``pid`` refers to a live process."""
    if pid <= 0:
        return False
    try:
        os.kill(pid, 0)
    except OSError:
        return False
    return True


def stop_pid(
    pid: int,
    *,
    timeout_s: float = 10.0,
    grace_signal: int = signal.SIGTERM,
    kill_signal: int = signal.SIGKILL,
) -> bool:
    """Send grace signal, then kill if needed. Returns True if process exited."""
    if not is_process_alive(pid):
        return True
    try:
        os.kill(pid, grace_signal)
    except OSError:
        return not is_process_alive(pid)

    import time

    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if not is_process_alive(pid):
            return True
        time.sleep(0.2)

    if not is_process_alive(pid):
        return True
    try:
        os.kill(pid, kill_signal)
    except OSError:
        pass
    time.sleep(0.2)
    return not is_process_alive(pid)
