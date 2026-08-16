"""Work-session segmentation from the capture event stream.

Deterministic: a gap larger than ``idle_gap_minutes`` between consecutive
``context_events`` closes a session. Idempotent via UNIQUE(started_at).
"""
from __future__ import annotations

import sqlite3
import threading
from datetime import date, datetime, timedelta, timezone
from typing import Any


def _parse_ts(value: str) -> datetime:
    """Parse ISO timestamps written by capture workers (UTC, often with offset)."""
    text = value.strip()
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        # Fallback for space-separated SQLite datetime strings.
        dt = datetime.fromisoformat(text.replace(" ", "T"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def day_bounds(day: str | None) -> tuple[str, str]:
    """Return [start, end) ISO bounds for a local calendar day."""
    if day is None or day in ("today", ""):
        d = date.today()
    else:
        d = date.fromisoformat(day)
    local = datetime.now().astimezone()
    local_start = datetime(d.year, d.month, d.day, tzinfo=local.tzinfo)
    utc_start = local_start.astimezone(timezone.utc)
    utc_end = utc_start + timedelta(days=1)
    return utc_start.isoformat(), utc_end.isoformat()


def _session_stats(
    con: sqlite3.Connection, event_ids: list[int]
) -> tuple[str | None, str | None, int, int]:
    """primary_bundle_id, primary_app_name, atom_count, switch_count."""
    if not event_ids:
        return None, None, 0, 0
    placeholders = ",".join("?" * len(event_ids))
    rows = con.execute(
        f"""
        SELECT id, app_bundle_id, app_name
          FROM context_events
         WHERE id IN ({placeholders})
         ORDER BY timestamp ASC, id ASC
        """,
        event_ids,
    ).fetchall()
    atom_count = con.execute(
        f"""
        SELECT COUNT(*) FROM text_atoms WHERE event_id IN ({placeholders})
        """,
        event_ids,
    ).fetchone()[0]

    switch_count = 0
    prev_bundle: str | None = None
    for row in rows:
        bundle = row["app_bundle_id"]
        if prev_bundle is not None and bundle != prev_bundle:
            switch_count += 1
        prev_bundle = bundle

    # Prefer atom counts for primary app; fall back to event counts.
    atom_rows = con.execute(
        f"""
        SELECT e.app_bundle_id, e.app_name, COUNT(a.id) AS n
          FROM context_events e
          LEFT JOIN text_atoms a ON a.event_id = e.id
         WHERE e.id IN ({placeholders})
         GROUP BY e.app_bundle_id
         ORDER BY n DESC
        """,
        event_ids,
    ).fetchall()
    primary_bundle = atom_rows[0]["app_bundle_id"] if atom_rows else None
    primary_name = atom_rows[0]["app_name"] if atom_rows else None
    return primary_bundle, primary_name, int(atom_count), switch_count


def segment_sessions(
    con: sqlite3.Connection,
    lock: threading.Lock,
    *,
    since: str | None = None,
    idle_gap_minutes: float = 12.0,
    min_events: int = 3,
) -> list[int]:
    """Segment context_events into sessions. Returns session ids touched.

    Idempotent: re-running over the same range upserts on ``started_at`` and
    rebuilds ``session_events`` for those sessions.
    """
    gap = timedelta(minutes=idle_gap_minutes)
    with lock:
        if since:
            events = con.execute(
                """
                SELECT id, timestamp, app_bundle_id, app_name
                  FROM context_events
                 WHERE timestamp >= ?
                 ORDER BY timestamp ASC, id ASC
                """,
                (since,),
            ).fetchall()
        else:
            events = con.execute(
                """
                SELECT id, timestamp, app_bundle_id, app_name
                  FROM context_events
                 ORDER BY timestamp ASC, id ASC
                """
            ).fetchall()

        if not events:
            return []

        # Build provisional segments in memory.
        segments: list[list[sqlite3.Row]] = []
        current: list[sqlite3.Row] = [events[0]]
        for row in events[1:]:
            prev_ts = _parse_ts(current[-1]["timestamp"])
            cur_ts = _parse_ts(row["timestamp"])
            if cur_ts - prev_ts > gap:
                segments.append(current)
                current = [row]
            else:
                current.append(row)
        segments.append(current)

        session_ids: list[int] = []
        con.execute("BEGIN IMMEDIATE")
        try:
            for seg in segments:
                if len(seg) < min_events:
                    continue
                started_at = seg[0]["timestamp"]
                ended_at = seg[-1]["timestamp"]
                event_ids = [int(r["id"]) for r in seg]
                primary_bundle, primary_name, atom_count, switch_count = _session_stats(
                    con, event_ids
                )
                existing = con.execute(
                    "SELECT id FROM sessions WHERE started_at = ?",
                    (started_at,),
                ).fetchone()
                if existing:
                    sid = int(existing["id"])
                    con.execute(
                        """
                        UPDATE sessions
                           SET ended_at = ?,
                               primary_bundle_id = ?,
                               primary_app_name = ?,
                               event_count = ?,
                               atom_count = ?,
                               switch_count = ?
                         WHERE id = ?
                        """,
                        (
                            ended_at,
                            primary_bundle,
                            primary_name,
                            len(event_ids),
                            atom_count,
                            switch_count,
                            sid,
                        ),
                    )
                    con.execute(
                        "DELETE FROM session_events WHERE session_id = ?", (sid,)
                    )
                else:
                    cur = con.execute(
                        """
                        INSERT INTO sessions (
                          started_at, ended_at, primary_bundle_id, primary_app_name,
                          event_count, atom_count, switch_count
                        ) VALUES (?, ?, ?, ?, ?, ?, ?)
                        """,
                        (
                            started_at,
                            ended_at,
                            primary_bundle,
                            primary_name,
                            len(event_ids),
                            atom_count,
                            switch_count,
                        ),
                    )
                    sid = int(cur.lastrowid)
                con.executemany(
                    "INSERT OR IGNORE INTO session_events (session_id, event_id) "
                    "VALUES (?, ?)",
                    [(sid, eid) for eid in event_ids],
                )
                session_ids.append(sid)
            con.execute("COMMIT")
        except Exception:
            con.execute("ROLLBACK")
            raise
        return session_ids


def get_sessions(
    con: sqlite3.Connection,
    *,
    day: str | None = None,
    limit: int = 50,
) -> list[dict[str, Any]]:
    """Return sessions.

    When ``day`` is None, return the most recent sessions (no calendar filter).
    When ``day`` is set (including ``"today"``), filter to that local calendar day.
    """
    if day is None:
        rows = con.execute(
            """
            SELECT id, started_at, ended_at, primary_bundle_id, primary_app_name,
                   event_count, atom_count, switch_count, title, summary
              FROM sessions
             ORDER BY started_at DESC
             LIMIT ?
            """,
            (limit,),
        ).fetchall()
        return [dict(r) for r in rows]

    start, end = day_bounds(day)
    rows = con.execute(
        """
        SELECT id, started_at, ended_at, primary_bundle_id, primary_app_name,
               event_count, atom_count, switch_count, title, summary
          FROM sessions
         WHERE started_at >= ? AND started_at < ?
         ORDER BY started_at ASC
         LIMIT ?
        """,
        (start, end, limit),
    ).fetchall()
    return [dict(r) for r in rows]


def current_session(con: sqlite3.Connection) -> dict[str, Any] | None:
    """Most recently ended/open session, or None."""
    row = con.execute(
        """
        SELECT id, started_at, ended_at, primary_bundle_id, primary_app_name,
               event_count, atom_count, switch_count, title, summary
          FROM sessions
         ORDER BY ended_at DESC
         LIMIT 1
        """
    ).fetchone()
    return dict(row) if row else None


def sessions_to_hits(
    con: sqlite3.Connection, sessions: list[dict[str, Any]], *, limit: int = 8
) -> list:
    """Convert session sample atoms into search Hit objects for SSE sources."""
    from orbit.search.types import Hit
    from orbit.storage.links import atom_uri, event_uri

    hits: list[Hit] = []
    for sess in sessions:
        if len(hits) >= limit:
            break
        rows = con.execute(
            """
            SELECT a.id AS atom_id, a.event_id, a.role, a.label,
                   e.app_bundle_id, e.app_name, e.window_title, e.timestamp,
                   substr(a.text, 1, 240) AS snippet_html
              FROM session_events se
              JOIN text_atoms a ON a.event_id = se.event_id
              JOIN context_events e ON e.id = a.event_id
             WHERE se.session_id = ?
             ORDER BY length(a.text) DESC
             LIMIT 2
            """,
            (sess["id"],),
        ).fetchall()
        for r in rows:
            if len(hits) >= limit:
                break
            hits.append(
                Hit(
                    atom_id=r["atom_id"],
                    event_id=r["event_id"],
                    atom_uri=atom_uri(r["atom_id"]),
                    event_uri=event_uri(r["event_id"]),
                    app_bundle_id=r["app_bundle_id"] or "",
                    app_name=r["app_name"] or "",
                    window_title=r["window_title"],
                    timestamp=r["timestamp"],
                    role=r["role"],
                    label=r["label"],
                    snippet_html=r["snippet_html"] or "",
                    score=0.0,
                )
            )
    return hits
