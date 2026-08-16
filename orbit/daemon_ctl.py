"""Start/stop helpers for detached Orbit daemon processes."""
from __future__ import annotations

import contextlib
import fcntl
import os
import subprocess
import sys
import time
import urllib.error
import urllib.request
from typing import Iterator, Sequence

from orbit.daemon_pid import (
    default_pid_path,
    is_process_alive,
    read_pid,
    remove_pid,
    stop_pid,
)

DEFAULT_LOG_PATH = os.path.expanduser("~/.orbit/daemon.log")
DEFAULT_HEALTH_URL = "http://127.0.0.1:8765/health"
SPAWN_LOCK_PATH = os.path.expanduser("~/.orbit/daemon.lock")


def _health_ok(url: str = DEFAULT_HEALTH_URL, timeout: float = 0.5) -> bool:
    try:
        with urllib.request.urlopen(url, timeout=timeout) as resp:
            return resp.status == 200
    except (urllib.error.URLError, TimeoutError, OSError):
        return False


def wait_for_health(
    *,
    url: str = DEFAULT_HEALTH_URL,
    timeout_s: float = 10.0,
    interval_s: float = 0.25,
) -> bool:
    deadline = time.monotonic() + timeout_s
    while time.monotonic() < deadline:
        if _health_ok(url):
            return True
        time.sleep(interval_s)
    return False


def build_daemon_argv(cli_argv: Sequence[str]) -> list[str]:
    """Build ``python -m orbit.capture.daemon`` argv from forwarded CLI flags."""
    return [sys.executable, "-m", "orbit.capture.daemon", *cli_argv]


@contextlib.contextmanager
def daemon_spawn_lock() -> Iterator[None]:
    """Exclusive lock while deciding whether to spawn a new daemon."""
    os.makedirs(os.path.dirname(SPAWN_LOCK_PATH), exist_ok=True)
    fh = open(SPAWN_LOCK_PATH, "w", encoding="utf-8")
    try:
        fcntl.flock(fh.fileno(), fcntl.LOCK_EX)
        yield
    finally:
        fcntl.flock(fh.fileno(), fcntl.LOCK_UN)
        fh.close()


def is_daemon_healthy(health_url: str = DEFAULT_HEALTH_URL) -> bool:
    """Return True when the daemon HTTP health endpoint responds."""
    return _health_ok(health_url)


def is_daemon_running(health_url: str = DEFAULT_HEALTH_URL) -> bool:
    """Return True when the daemon is healthy (bridge up)."""
    return is_daemon_healthy(health_url)


def reap_stale_daemon(
    *,
    pid_file: str | None = None,
    health_url: str = DEFAULT_HEALTH_URL,
    timeout_s: float = 5.0,
) -> bool:
    """Kill and unpin a live PID when health is down. Returns True if a stale process was reaped."""
    if is_daemon_healthy(health_url):
        return False
    pid_path = pid_file or default_pid_path()
    pid = read_pid(pid_path)
    if pid is None or not is_process_alive(pid):
        remove_pid(pid_path)
        return False
    stopped = stop_pid(pid, timeout_s=timeout_s)
    if stopped:
        remove_pid(pid_path)
        return True
    return False


def running_daemon_pid(health_url: str = DEFAULT_HEALTH_URL) -> int | None:
    """Return the PID of a healthy daemon, or None if none is active."""
    if not is_daemon_healthy(health_url):
        return None
    pid = read_pid()
    if pid is not None and is_process_alive(pid):
        return pid
    return pid


def spawn_detached(
    daemon_argv: list[str],
    *,
    log_path: str = DEFAULT_LOG_PATH,
    health_url: str = DEFAULT_HEALTH_URL,
    wait_timeout_s: float = 10.0,
) -> tuple[int, bool]:
    """Spawn daemon in a new session if needed.

    Returns ``(pid, started_new)``. When a daemon is already running, returns its
    PID and ``started_new=False`` without spawning another process.
    """
    with daemon_spawn_lock():
        existing = running_daemon_pid(health_url)
        if existing is not None:
            return existing, False

        reap_stale_daemon(health_url=health_url)

        os.makedirs(os.path.dirname(os.path.expanduser(log_path)), exist_ok=True)
        log_fh = open(log_path, "a", encoding="utf-8")
        proc = subprocess.Popen(
            daemon_argv,
            stdout=log_fh,
            stderr=subprocess.STDOUT,
            start_new_session=True,
        )
        log_fh.close()

        if wait_for_health(url=health_url, timeout_s=wait_timeout_s):
            return proc.pid, True

        # Child may still be starting; fall back to pid file or process liveness.
        pid = read_pid() or proc.pid
        if is_process_alive(pid):
            return pid, True
        raise RuntimeError(
            f"Orbit daemon failed to start within {wait_timeout_s:.0f}s "
            f"(see {log_path})"
        )


def stop_daemon(
    *,
    pid_file: str | None = None,
    health_url: str = DEFAULT_HEALTH_URL,
    shutdown_url: str = "http://127.0.0.1:8765/api/shutdown",
    timeout_s: float = 10.0,
) -> bool:
    """Stop running daemon via HTTP shutdown when possible, else SIGTERM/SIGKILL."""
    pid_path = pid_file or default_pid_path()
    pid = read_pid(pid_path)

    if _health_ok(health_url):
        try:
            req = urllib.request.Request(shutdown_url, method="POST")
            with urllib.request.urlopen(req, timeout=timeout_s):
                pass
        except (urllib.error.URLError, TimeoutError, OSError):
            pass
        deadline = time.monotonic() + timeout_s
        while time.monotonic() < deadline:
            if not _health_ok(health_url):
                remove_pid(pid_path)
                return True
            time.sleep(0.2)

    if pid is None:
        if _health_ok(health_url):
            return False
        remove_pid(pid_path)
        return True

    if not is_process_alive(pid):
        remove_pid(pid_path)
        return True

    stopped = stop_pid(pid, timeout_s=timeout_s)
    if stopped:
        remove_pid(pid_path)
    return stopped
