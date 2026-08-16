"""Today-scoped activity digest for the chat backend.

Ports the read-only SQL patterns already implemented in Swift
(``OrbitAccessApp/IPC/OrbitDBReader.swift:130-228`` — ``fetchAtomsByHour``,
``computeScoreInputs``) into a Python module the chat handler can call
directly, without going through the Swift IPC bridge.

This module is additive: it supplements (does not replace) the existing
lexical/hybrid search in ``orbit.search.lexical`` / ``orbit.search.hybrid``
and the Swift reader. It is pure stdlib ``sqlite3`` — no ORM, no new
dependencies.

Multi-user note: unlike the plan's literal SQL snippets, every query here is
user-scoped. ``context_events``, ``task_log``, and ``fs_events`` all carry a
``user_id`` column (see ``orbit/storage/schema.sql``); ``text_atoms`` is
scoped transitively via its join to ``context_events``. This mirrors the
``_user_filter`` convention in ``orbit.check.log`` and the ``user_id`` params
already threaded through ``orbit.search.lexical`` / ``orbit.search.hybrid``.
"""
from __future__ import annotations

import sqlite3
from dataclasses import dataclass
from datetime import datetime, timezone

from orbit.search.types import Hit
from orbit.storage.session import get_active_user_id


def _utc_today() -> str:
    """Today's date in UTC — matches how every capture timestamp is written.

    See ``orbit.check.log._utc_today`` (same convention), and the writers at
    ``orbit/capture/daemon.py`` / ``orbit/capture/fsevents_listener.py``,
    which both call ``datetime.now(timezone.utc).isoformat()``.
    """
    return datetime.now(timezone.utc).date().isoformat()


def _user_filter(user_id: str | None, column: str = "user_id") -> tuple[str, list]:
    """Mirrors ``orbit.check.log._user_filter``.

    Returns an ``AND``-prefixed bound clause scoping to ``column`` when
    ``user_id`` is truthy, else an empty clause (no scoping — matches
    existing single-user/dev-mode behavior when there is no active session).
    """
    if user_id:
        return f" AND {column} = ?", [user_id]
    return "", []


@dataclass
class AppFocus:
    app_name: str
    app_bundle_id: str
    event_count: int
    top_windows: list[str]


@dataclass
class ActivityDigest:
    report_date: str
    apps: list[AppFocus]
    recent_atoms: list[Hit]
    tasks: list[dict]
    fs_events: list[dict]
    stats: dict


def fetch_activity_digest(
    con: sqlite3.Connection,
    report_date: str | None = None,
    atom_limit: int = 40,
    user_id: str | None = None,
) -> ActivityDigest:
    """Assemble a structured, user-scoped snapshot of one day's activity.

    ``report_date`` defaults to UTC-today (bound as a param — never the
    SQLite inline literal — for testability). ``user_id`` defaults to the active
    session's user (``get_active_user_id()``); pass an explicit id to scope
    to a different user, or rely on the empty-clause fallback when there is
    no active session.
    """
    d = report_date or _utc_today()
    uid = user_id if user_id is not None else get_active_user_id()

    # --- App focus (ported from Swift computeScoreInputs focusRows) -------
    app_extra, app_params = _user_filter(uid)
    app_rows = con.execute(
        f"""
        SELECT app_name, app_bundle_id, COUNT(*) AS event_count
          FROM context_events
         WHERE date(timestamp) = ?{app_extra}
         GROUP BY app_bundle_id
         ORDER BY event_count DESC
         LIMIT 10
        """,
        [d, *app_params],
    ).fetchall()

    apps: list[AppFocus] = []
    for row in app_rows:
        win_extra, win_params = _user_filter(uid)
        win_rows = con.execute(
            f"""
            SELECT window_title, COUNT(*) AS window_count
              FROM context_events
             WHERE date(timestamp) = ?
               AND app_bundle_id = ?
               AND window_title IS NOT NULL
               AND window_title != ''{win_extra}
             GROUP BY window_title
             ORDER BY window_count DESC
             LIMIT 3
            """,
            [d, row["app_bundle_id"], *win_params],
        ).fetchall()
        apps.append(
            AppFocus(
                app_name=row["app_name"] or "",
                app_bundle_id=row["app_bundle_id"] or "",
                event_count=row["event_count"],
                top_windows=[w["window_title"] for w in win_rows],
            )
        )

    # --- Recent atoms (ported from Swift fetchAtomsByHour, no hour filter) -
    atom_extra, atom_params = _user_filter(uid, column="e.user_id")
    atom_rows = con.execute(
        f"""
        SELECT a.id AS atom_id,
               a.event_id AS event_id,
               e.app_bundle_id AS app_bundle_id,
               e.app_name AS app_name,
               e.window_title AS window_title,
               e.timestamp AS timestamp,
               a.role AS role,
               a.label AS label,
               a.text AS snippet_html,
               0.0 AS score
          FROM text_atoms a
          JOIN context_events e ON e.id = a.event_id
         WHERE date(e.timestamp) = ?{atom_extra}
         ORDER BY e.timestamp DESC
         LIMIT ?
        """,
        [d, *atom_params, atom_limit],
    ).fetchall()
    recent_atoms = [Hit.from_row(row) for row in atom_rows]

    # --- Tasks (ported from Swift fetchPendingTasksToday, all statuses) ---
    task_extra, task_params = _user_filter(uid)
    task_rows = con.execute(
        f"""
        SELECT id, timestamp, title, description, agent_type, status
          FROM task_log
         WHERE date(timestamp) = ?{task_extra}
         ORDER BY timestamp DESC
        """,
        [d, *task_params],
    ).fetchall()
    tasks = [dict(row) for row in task_rows]

    # --- File events --------------------------------------------------------
    fs_extra, fs_params = _user_filter(uid)
    fs_rows = con.execute(
        f"""
        SELECT timestamp, path, event_type
          FROM fs_events
         WHERE date(timestamp) = ?{fs_extra}
         ORDER BY timestamp DESC
         LIMIT 20
        """,
        [d, *fs_params],
    ).fetchall()
    fs_events = [dict(row) for row in fs_rows]

    # --- Stats (mirrors Swift computeScoreInputs proxy signals) ------------
    stats_extra, stats_params = _user_filter(uid, column="e.user_id")
    stats_row = con.execute(
        f"""
        SELECT COUNT(*) AS atom_count,
               COUNT(DISTINCT e.app_bundle_id) AS app_count,
               COUNT(DISTINCT strftime('%H', e.timestamp)) AS active_hours
          FROM text_atoms a
          JOIN context_events e ON e.id = a.event_id
         WHERE date(e.timestamp) = ?{stats_extra}
        """,
        [d, *stats_params],
    ).fetchone()
    stats = {
        "atom_count": stats_row["atom_count"] if stats_row else 0,
        "app_count": stats_row["app_count"] if stats_row else 0,
        "active_hours": stats_row["active_hours"] if stats_row else 0,
    }

    return ActivityDigest(
        report_date=d,
        apps=apps,
        recent_atoms=recent_atoms,
        tasks=tasks,
        fs_events=fs_events,
        stats=stats,
    )


def digest_to_hits(digest: ActivityDigest) -> list[Hit]:
    """Return the digest's recent atoms as ``Hit`` objects for the SSE
    ``sources`` field.

    ``recent_atoms`` is already a list of ``Hit`` — this exists as the
    documented, stable entry point the chat handler should call (rather than
    reaching into ``digest.recent_atoms`` directly), and as the seam for
    later reshaping (e.g. de-duplication) without touching call sites. The
    result feeds the same shape ``_hit_to_dict`` (``asdict(hit)`` in
    ``orbit.browser_bridge.server``) already consumes.
    """
    return list(digest.recent_atoms)
