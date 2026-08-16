"""task_log table helpers."""
from __future__ import annotations
import sqlite3
import threading
from datetime import datetime, timezone
from typing import Any

from orbit.storage.session import get_active_user_id, require_active_user_id

from .detector import Task


def _utc_today() -> str:
    """Today in UTC — matches the timestamps insert_task writes."""
    return datetime.now(timezone.utc).date().isoformat()


# Rows written before the ``confidence`` column existed (or written by any future
# caller that omits it) have NULL here. detect_tasks() already filters below 0.7
# (detector.py:_CONFIDENCE_THRESHOLD), so a row that made it into task_log at all
# cleared at least that bar — this is a historical floor, not a guess of 1.0.
_LEGACY_CONFIDENCE_FALLBACK = 0.7


def migrate(con: sqlite3.Connection) -> None:
    """Add columns introduced after initial schema creation."""
    cols = {row[1] for row in con.execute("PRAGMA table_info(task_log)")}
    if "description" not in cols:
        con.execute("ALTER TABLE task_log ADD COLUMN description TEXT")
    if "result_path" not in cols:
        con.execute("ALTER TABLE task_log ADD COLUMN result_path TEXT")
    if "result_preview" not in cols:
        con.execute("ALTER TABLE task_log ADD COLUMN result_preview TEXT")


def _user_filter(user_id: str | None) -> tuple[str, list]:
    if user_id:
        return " AND user_id = ?", [user_id]
    return "", []


def insert_task(con: sqlite3.Connection, lock: threading.Lock, task: Task) -> int:
    ts = datetime.now(timezone.utc).isoformat()
    user_id = require_active_user_id()
    with lock:
        cur = con.execute(
            "INSERT INTO task_log"
            " (user_id, timestamp, title, description, original_prompt, agent_type, status, confidence)"
            " VALUES (?, ?, ?, ?, ?, ?, 'detected', ?)",
            (
                user_id,
                ts,
                task.title,
                task.description,
                task.suggested_prompt,
                task.agent_type,
                task.confidence,
            ),
        )
        return cur.lastrowid


def update_status(
    con: sqlite3.Connection,
    lock: threading.Lock,
    log_id: int,
    status: str,
    approved_prompt: str | None = None,
    exit_code: int | None = None,
    result_path: str | None = None,
    result_preview: str | None = None,
) -> None:
    with lock:
        con.execute(
            "UPDATE task_log"
            " SET status = ?,"
            "     approved_prompt = COALESCE(?, approved_prompt),"
            "     exit_code = COALESCE(?, exit_code),"
            "     result_path = COALESCE(?, result_path),"
            "     result_preview = COALESCE(?, result_preview)"
            " WHERE id = ?",
            (status, approved_prompt, exit_code, result_path, result_preview, log_id),
        )


def get_task_status(
    con: sqlite3.Connection,
    lock: threading.Lock,
    log_id: int,
) -> dict[str, Any] | None:
    """Return status + bounded result fields for a task_log row, or None."""
    with lock:
        row = con.execute(
            "SELECT id, title, status, exit_code, result_path, result_preview"
            " FROM task_log WHERE id = ?",
            (log_id,),
        ).fetchone()
    if row is None:
        return None
    return {
        "id": row["id"],
        "title": row["title"],
        "status": row["status"],
        "exit_code": row["exit_code"],
        "result_path": row["result_path"],
        "result_preview": row["result_preview"],
    }


def get_skipped_today(
    con: sqlite3.Connection,
    lock: threading.Lock,
    report_date: str | None = None,
    user_id: str | None = None,
) -> list[tuple[int, Task]]:
    """Return (log_id, Task) pairs with status='skipped' from today (UTC)."""
    d = report_date or _utc_today()
    uid = user_id if user_id is not None else get_active_user_id()
    extra, params = _user_filter(uid)
    with lock:
        rows = con.execute(
            "SELECT id, title, description, original_prompt, agent_type, confidence"
            " FROM task_log"
            " WHERE status = 'skipped'"
            "   AND date(timestamp) = ?"
            + extra,
            [d, *params],
        ).fetchall()
    return [
        (row["id"], Task(
            title=row["title"],
            description=row["description"] or "",
            suggested_prompt=row["original_prompt"] or "",
            agent_type=row["agent_type"] or "admin",
            confidence=(
                row["confidence"] if row["confidence"] is not None
                else _LEGACY_CONFIDENCE_FALLBACK
            ),
        ))
        for row in rows
    ]


def get_all_tasks_today(
    con: sqlite3.Connection,
    lock: threading.Lock,
    report_date: str | None = None,
    user_id: str | None = None,
) -> list[dict[str, Any]]:
    """Return today's (UTC) task_log rows across all statuses, as dicts.

    Unlike ``get_pending_today``/``get_skipped_today`` this does not reconstruct
    a ``Task`` dataclass — it feeds ``TaskLogEntry`` (Swift) directly, so the
    row also carries ``timestamp``, ``status``, and ``exit_code``.
    """
    d = report_date or _utc_today()
    uid = user_id if user_id is not None else get_active_user_id()
    extra, params = _user_filter(uid)
    with lock:
        rows = con.execute(
            "SELECT id, timestamp, title, description, original_prompt,"
            "       agent_type, status, exit_code"
            " FROM task_log"
            "   WHERE date(timestamp) = ?"
            + extra,
            [d, *params],
        ).fetchall()
    return [
        {
            "id": row["id"],
            "timestamp": row["timestamp"],
            "title": row["title"],
            "description": row["description"],
            "original_prompt": row["original_prompt"],
            "agent_type": row["agent_type"],
            "status": row["status"],
            "exit_code": row["exit_code"],
        }
        for row in rows
    ]


def get_pending_today(
    con: sqlite3.Connection,
    lock: threading.Lock,
    report_date: str | None = None,
    user_id: str | None = None,
) -> list[tuple[int, Task]]:
    """Return (log_id, Task) pairs with status='detected' from today (UTC)."""
    d = report_date or _utc_today()
    uid = user_id if user_id is not None else get_active_user_id()
    extra, params = _user_filter(uid)
    with lock:
        rows = con.execute(
            "SELECT id, title, description, original_prompt, agent_type, confidence"
            " FROM task_log"
            " WHERE status = 'detected'"
            "   AND date(timestamp) = ?"
            + extra,
            [d, *params],
        ).fetchall()
    result = []
    for row in rows:
        task = Task(
            title=row["title"],
            description=row["description"] or "",
            suggested_prompt=row["original_prompt"] or "",
            agent_type=row["agent_type"] or "admin",
            confidence=(
                row["confidence"] if row["confidence"] is not None
                else _LEGACY_CONFIDENCE_FALLBACK
            ),
        )
        result.append((row["id"], task))
    return result
