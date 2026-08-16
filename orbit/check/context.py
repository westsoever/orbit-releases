"""Read context — from Orbit's own captures, a GitHub daily report, or a file."""
from __future__ import annotations
import shutil
import sqlite3
import subprocess
import threading
from datetime import date as _date
from pathlib import Path

_GITHUB_REPO = "westsoever/cos"
_GITHUB_BRANCH = "main"
_DAILY_REPORT_DIR = "06-wiki/daily_report"
LOCAL_DEFAULT = Path("~/.orbit/context.md").expanduser()


def read_github(
    repo: str = _GITHUB_REPO,
    branch: str = _GITHUB_BRANCH,
    date: str | None = None,
) -> str:
    """Fetch a daily report from GitHub using the gh CLI.

    Raises FileNotFoundError if gh is absent, the file doesn't exist, or the
    request fails for any reason.
    """
    if shutil.which("gh") is None:
        raise FileNotFoundError("gh CLI not found — install it or use --source local")

    d = date or _date.today().isoformat()
    path = f"{_DAILY_REPORT_DIR}/{d}.md"

    result = subprocess.run(
        ["gh", "api", f"repos/{repo}/contents/{path}",
         "-H", "Accept: application/vnd.github.v3.raw",
         "--method", "GET"],
        capture_output=True,
        text=True,
    )
    if result.returncode != 0:
        msg = result.stderr.strip() or f"HTTP error for {path}"
        raise FileNotFoundError(
            f"Daily report not found for {d} in {repo}/{branch}\n  {msg}"
        )
    return result.stdout.strip()


def read_local(path: str | Path | None = None) -> str:
    p = Path(path).expanduser() if path else LOCAL_DEFAULT
    if not p.exists():
        raise FileNotFoundError(
            f"Context file not found: {p}\n"
            f"Create it at {p} or use --source github"
        )
    return p.read_text(encoding="utf-8").strip()


def read_capture(
    con: sqlite3.Connection,
    lock: threading.Lock,
    since_hours: float = 8.0,
    *,
    user_id: str | None = None,
) -> tuple[str, str]:
    """Assemble context from Orbit's own capture store.

    ``user_id`` defaults to the active session (or the single-user legacy
    account when none is signed in) — never "every user in this database".

    Raises FileNotFoundError when the window holds no captured text, so callers
    can treat it like the other empty-source cases.
    """
    from orbit.storage.session import LEGACY_USER_ID, get_active_user_id

    from .window import build_context_window

    resolved_user_id = user_id or get_active_user_id() or LEGACY_USER_ID
    text, event_ids = build_context_window(
        con, lock, user_id=resolved_user_id, since_hours=since_hours
    )
    if not text.strip():
        raise FileNotFoundError(
            f"No captures in the last {since_hours:g}h.\n"
            "Start the daemon (`orbit start`) and use the machine for a while, "
            "or widen the window with --since-hours, "
            "or read a file instead with --source local"
        )
    return text, f"orbit capture · last {since_hours:g}h · {len(event_ids)} event(s)"


def read_context(
    local_path: str | Path | None = None,
    source: str = "capture",
    date: str | None = None,
    *,
    con: sqlite3.Connection | None = None,
    lock: threading.Lock | None = None,
    since_hours: float = 8.0,
    user_id: str | None = None,
) -> tuple[str, str]:
    """Return (context_text, source_label).

    source: "capture" | "github" | "local"
    "capture" requires an open DB connection (con, lock).
    Falls back to local if GitHub fetch fails and local_path/default exists.
    """
    if source == "capture":
        if con is None or lock is None:
            raise ValueError(
                "source='capture' requires an open DB connection (con, lock)"
            )
        return read_capture(con, lock, since_hours=since_hours, user_id=user_id)
    if source == "github":
        try:
            text = read_github(date=date)
            d = date or _date.today().isoformat()
            return text, f"{_GITHUB_REPO}/{_DAILY_REPORT_DIR}/{d}.md"
        except FileNotFoundError as e:
            # Try local fallback
            try:
                text = read_local(local_path)
                return text, str(local_path or LOCAL_DEFAULT)
            except FileNotFoundError:
                raise FileNotFoundError(
                    f"GitHub fetch failed and no local fallback found.\n  {e}"
                ) from None
    else:
        text = read_local(local_path)
        return text, str(local_path or LOCAL_DEFAULT)
