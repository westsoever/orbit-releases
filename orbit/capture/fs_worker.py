"""Process FSEvents queue — link paths to nearest focus event within ±30s."""

from __future__ import annotations

import datetime
import logging
import os
import queue
import sqlite3
import threading

from orbit.storage.session import get_active_user_id, require_active_user_id

logger = logging.getLogger(__name__)

_CAPTURE_TIER = 3
_LINK_WINDOW_S = 30.0


def path_mtime(path: str) -> float | None:
    try:
        return os.path.getmtime(path)
    except OSError:
        return None


def find_linked_event(con: sqlite3.Connection, ts_iso: str, user_id: str | None = None) -> int | None:
    try:
        ts = datetime.datetime.fromisoformat(ts_iso.replace("Z", "+00:00"))
    except ValueError:
        return None
    lo = (ts - datetime.timedelta(seconds=_LINK_WINDOW_S)).isoformat()
    hi = (ts + datetime.timedelta(seconds=_LINK_WINDOW_S)).isoformat()
    uid = user_id or get_active_user_id()
    if uid:
        row = con.execute(
            """
            SELECT id FROM context_events
            WHERE user_id = ? AND timestamp >= ? AND timestamp <= ?
            ORDER BY ABS(julianday(timestamp) - julianday(?))
            LIMIT 1
            """,
            (uid, lo, hi, ts_iso),
        ).fetchone()
    else:
        row = con.execute(
            """
            SELECT id FROM context_events
            WHERE timestamp >= ? AND timestamp <= ?
            ORDER BY ABS(julianday(timestamp) - julianday(?))
            LIMIT 1
            """,
            (lo, hi, ts_iso),
        ).fetchone()
    return int(row[0]) if row else None


def record_fs_event(
    con: sqlite3.Connection,
    lock: threading.Lock,
    event: dict,
) -> int | None:
    ts = event.get("timestamp")
    path = event.get("path")
    event_type = event.get("event_type", "unknown")
    if not ts or not path:
        return None
    mtime = path_mtime(path)
    user_id = require_active_user_id()
    with lock:
        linked = find_linked_event(con, ts, user_id=user_id)
        cur = con.execute(
            """
            INSERT INTO fs_events
              (user_id, timestamp, path, event_type, mtime, linked_event_id, capture_tier)
            VALUES (?, ?, ?, ?, ?, ?, ?)
            """,
            (user_id, ts, path, event_type, mtime, linked, _CAPTURE_TIER),
        )
        row_id = cur.lastrowid
    if row_id:
        logger.info(
            "Recorded fs_event %d: %s %s (linked=%s)",
            row_id,
            event_type,
            path,
            linked or "none",
        )
    return row_id


def run_fs_worker(fs_queue: queue.Queue, con, lock) -> None:
    logger.info("FSEvents worker started")
    while True:
        try:
            event = fs_queue.get(timeout=1.0)
        except queue.Empty:
            continue
        if event is None:
            break
        try:
            record_fs_event(con, lock, event)
        except Exception:
            logger.exception("record_fs_event failed")
