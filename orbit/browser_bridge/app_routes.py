"""Orbit Access App data routes (additive to server.py) — Plan 51 Phase 3A.

Decision D1 (plan 51 §0): **the Python daemon owns ``~/.orbit/orbit.db``.** The
database is SQLCipher-encrypted and only this process holds the key, so the Swift
app can no longer read it directly (GRDB over SPM is built against system SQLite
and cannot decrypt — plan 51 §0.3). Every read the app used to perform through
``OrbitAccessApp/IPC/OrbitDBReader.swift`` therefore needs an HTTP route here.

Each handler below is a **verbatim port** of the SQL from the Swift method named in
its docstring; the filtering, ordering and ``LIMIT`` semantics are deliberately
unchanged so the app renders exactly what it rendered before. Where the Swift code
deliberately used a UTC day (``date(e.timestamp) = date('now')``) instead of a local
one, that is preserved too — see ``OrbitDBReader.swift:333-346``.

Route shapes: JSON keys are snake_case, matching the proven ``/api/search`` ↔
``Models/SearchHit.swift:19-29`` contract. Atom-returning routes reply with a bare
JSON array of ``orbit.search.types.Hit`` dicts, i.e. byte-identical in shape to
``/api/search``, so the Swift client decodes them as ``[SearchHit]`` unchanged.

Auth: **every** route here requires the ``Authorization: Bearer <token>`` header
(``~/.orbit/bridge.token``), including the GETs. That is stricter than the
already-open ``/api/search`` / ``/api/sessions`` reads; it is applied because these
routes serve full captured atom text and one of them (``POST /api/users``) mutates
the store. See ``docs/bridge-api-additions.md``.

User scoping mirrors Swift's ``OrbitDBReader.userEventFilter`` exactly: the active
user id comes from ``~/.orbit/session.json`` (Python: ``get_active_user_id()``;
Swift: ``UserSessionService.loadSessionUserId()`` — the same file), and when there
is no active session the filter is omitted entirely rather than matching nothing.
``llm_calls`` and ``text_atoms`` have no ``user_id`` column, so they are never
filtered directly (plan 33 anti-pattern 7).
"""
from __future__ import annotations

import json
import logging
import re
import secrets
import sqlite3
import uuid
from datetime import date, datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler
from typing import Any
from urllib.parse import parse_qs, urlparse

from orbit.storage.links import atom_uri, event_uri
from orbit.storage.session import get_active_user_id

logger = logging.getLogger(__name__)

DbRef = tuple[sqlite3.Connection, Any]

_USER_RE = re.compile(r"^/api/user/([^/]+)$")

# Defaults copied from the Swift signatures they replace.
NOTES_DEFAULT_LIMIT = 10          # fetchRecentNotes / fetchRecentNotesTail (:51, :76)
ATOMS_BY_DEFAULT_LIMIT = 20       # fetchAtomsByApp / fetchAtomsByHour (:142, :167)
ATOMS_RANGE_DEFAULT_LIMIT = 100   # fetchAtomsInRange (:225)
LATEST_APP_SCAN = 20              # latestAppBundleId (:251)
SNAPSHOT_DEFAULT_DAYS = 182       # loadUsageSnapshot (:409)
SNAPSHOT_DEFAULT_BREAKDOWN_DAYS = 30
SNAPSHOT_DEFAULT_APP_LIMIT = 8

# Guard rails so a bad client cannot ask for an unbounded scan. The Swift call
# sites all pass small values; these caps only bound hostile/typo'd input.
MAX_LIMIT = 500
MAX_DAYS = 3650

_ATOM_COLUMNS = """
                    a.id AS atom_id,
                    a.event_id AS event_id,
                    e.app_bundle_id AS app_bundle_id,
                    e.app_name AS app_name,
                    e.window_title AS window_title,
                    e.timestamp AS timestamp,
                    a.role AS role,
                    a.label AS label,
                    a.text AS snippet_html,
                    0.0 AS score
"""


# --------------------------------------------------------------------------- #
# helpers (same shapes as server.py:174-189 / privacy_routes.py)
# --------------------------------------------------------------------------- #

def _send_json(handler: BaseHTTPRequestHandler, status: int, payload: Any) -> None:
    body = json.dumps(payload).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def _read_json_body(
    handler: BaseHTTPRequestHandler, max_size: int = 65536
) -> dict[str, Any] | None:
    length = int(handler.headers.get("Content-Length", 0))
    if length < 0 or length > max_size:
        handler.send_error(400, "invalid body size")
        return None
    if length == 0:
        return {}
    try:
        payload = json.loads(handler.rfile.read(length).decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError):
        handler.send_error(400, "invalid json")
        return None
    if not isinstance(payload, dict):
        handler.send_error(400, "expected object")
        return None
    return payload


def _require_db(handler: BaseHTTPRequestHandler, server: Any) -> DbRef | None:
    db_ref: DbRef | None = getattr(server, "db_ref", None)
    if db_ref is None:
        _send_json(handler, 503, {"error": "database unavailable"})
        return None
    return db_ref


def _check_bridge_auth(handler: BaseHTTPRequestHandler, server: Any) -> bool:
    token = getattr(server, "bridge_token", None)
    if not token:
        return False
    auth = handler.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return False
    supplied = auth[7:].strip()
    return bool(supplied) and secrets.compare_digest(supplied, token)


def _query(handler: BaseHTTPRequestHandler) -> dict[str, list[str]]:
    return parse_qs(urlparse(handler.path).query)


class _BadParam(ValueError):
    """Invalid query parameter — the caller turns this into a 400."""


def _int_param(
    params: dict[str, list[str]], name: str, default: int, *, minimum: int, maximum: int
) -> int:
    raw = (params.get(name) or [str(default)])[0]
    try:
        value = int(raw)
    except (TypeError, ValueError):
        raise _BadParam(f"invalid {name}") from None
    if value < minimum or value > maximum:
        raise _BadParam(f"{name} out of range")
    return value


def _str_param(params: dict[str, list[str]], name: str) -> str | None:
    value = (params.get(name) or [None])[0]
    if value is None:
        return None
    value = value.strip()
    return value or None


def _user_filter(column: str = "e.user_id") -> tuple[str, list[Any]]:
    """Port of ``OrbitDBReader.userEventFilter`` (`OrbitDBReader.swift:26-29`)."""
    user_id = get_active_user_id()
    if not user_id:
        return "", []
    return f" AND {column} = ?", [user_id]


def _hit(row: sqlite3.Row) -> dict[str, Any]:
    """Port of ``OrbitDBReader.searchHit(from:)`` (`:779-794`).

    The ``or ""`` coalescing matches the Swift `?? ""` defaults — ``app_bundle_id``,
    ``app_name`` and ``snippet_html`` are non-optional in ``Models/SearchHit.swift``
    but nullable in the schema.
    """
    atom_id = row["atom_id"]
    ev_id = row["event_id"]
    return {
        "atom_id": atom_id,
        "event_id": ev_id,
        "atom_uri": atom_uri(atom_id),
        "event_uri": event_uri(ev_id),
        "app_bundle_id": row["app_bundle_id"] or "",
        "app_name": row["app_name"] or "",
        "window_title": row["window_title"],
        "timestamp": row["timestamp"],
        "role": row["role"],
        "label": row["label"],
        "snippet_html": row["snippet_html"] or "",
        "score": float(row["score"] or 0.0),
    }


def _utc_now() -> str:
    """Same shape as ``server.py:_utc_now`` and ``log.py``'s stored timestamps."""
    return datetime.now(timezone.utc).isoformat()


def _local_day_bounds(day: str | None) -> tuple[str, str]:
    """``[start, end)`` UTC ISO bounds for a local calendar day.

    Port of ``OrbitDBReader.localDayBounds(for:calendar:)`` (`:628-632`) +
    ``utcISOBound(_:)`` (`:640-647`) combined: the bound string must carry six
    fractional digits and an explicit ``+00:00`` because the comparison SQLite
    performs against ``context_events.timestamp`` is *textual* (see the Swift
    comment at `:634-639`). Same idea as ``orbit/memory/sessions.py:day_bounds``.
    """
    if day is None or day in ("today", ""):
        d = date.today()
    else:
        try:
            d = date.fromisoformat(day)
        except ValueError:
            raise _BadParam("invalid day") from None
    local_tz = datetime.now().astimezone().tzinfo
    local_start = datetime(d.year, d.month, d.day, tzinfo=local_tz)
    utc_start = local_start.astimezone(timezone.utc)
    utc_end = utc_start + timedelta(days=1)
    return (
        utc_start.isoformat(timespec="microseconds"),
        utc_end.isoformat(timespec="microseconds"),
    )


# --------------------------------------------------------------------------- #
# queries — one per orphaned OrbitDBReader method
# --------------------------------------------------------------------------- #

def _recent_notes(con: sqlite3.Connection, after_id: int, limit: int) -> list[dict[str, Any]]:
    """``OrbitDBReader.fetchRecentNotes`` (`:51-74`)."""
    filter_sql, filter_args = _user_filter()
    rows = con.execute(
        f"""
                SELECT{_ATOM_COLUMNS}
                FROM text_atoms a
                JOIN context_events e ON e.id = a.event_id
                WHERE a.id > ? AND length(trim(a.text)) > 10{filter_sql}
                ORDER BY a.id DESC
                LIMIT ?
        """,
        [after_id, *filter_args, limit],
    ).fetchall()
    return [_hit(r) for r in rows]


def _recent_notes_tail(con: sqlite3.Connection, limit: int) -> list[dict[str, Any]]:
    """``OrbitDBReader.fetchRecentNotesTail`` (`:76-99`)."""
    filter_sql, filter_args = _user_filter()
    rows = con.execute(
        f"""
                SELECT{_ATOM_COLUMNS}
                FROM text_atoms a
                JOIN context_events e ON e.id = a.event_id
                WHERE length(trim(a.text)) > 10{filter_sql}
                ORDER BY a.id DESC
                LIMIT ?
        """,
        [*filter_args, limit],
    ).fetchall()
    return [_hit(r) for r in rows]


def _atoms_by_app(con: sqlite3.Connection, app_name: str, limit: int) -> list[dict[str, Any]]:
    """``OrbitDBReader.fetchAtomsByApp`` (`:142-165`)."""
    filter_sql, filter_args = _user_filter()
    rows = con.execute(
        f"""
                SELECT{_ATOM_COLUMNS}
                FROM text_atoms a
                JOIN context_events e ON e.id = a.event_id
                WHERE e.app_name LIKE ?{filter_sql}
                ORDER BY e.timestamp DESC
                LIMIT ?
        """,
        [f"%{app_name}%", *filter_args, limit],
    ).fetchall()
    return [_hit(r) for r in rows]


def _atoms_by_hour(
    con: sqlite3.Connection, hour: str | None, limit: int
) -> list[dict[str, Any]]:
    """``OrbitDBReader.fetchAtomsByHour`` (`:167-214`).

    UTC day (``date('now')``) on purpose — see the Swift note at `:337-339`.
    """
    filter_sql, filter_args = _user_filter()
    if hour:
        normalized = f"0{hour}" if len(hour) == 1 else hour[:2]
        rows = con.execute(
            f"""
                    SELECT{_ATOM_COLUMNS}
                    FROM text_atoms a
                    JOIN context_events e ON e.id = a.event_id
                    WHERE date(e.timestamp) = date('now')
                      AND strftime('%H', e.timestamp) = ?{filter_sql}
                    ORDER BY e.timestamp DESC
                    LIMIT ?
            """,
            [normalized, *filter_args, limit],
        ).fetchall()
    else:
        rows = con.execute(
            f"""
                    SELECT{_ATOM_COLUMNS}
                    FROM text_atoms a
                    JOIN context_events e ON e.id = a.event_id
                    WHERE date(e.timestamp) = date('now'){filter_sql}
                    ORDER BY e.timestamp DESC
                    LIMIT ?
            """,
            [*filter_args, limit],
        ).fetchall()
    return [_hit(r) for r in rows]


def _atoms_in_range(
    con: sqlite3.Connection, since: str, until: str, limit: int
) -> list[dict[str, Any]]:
    """``OrbitDBReader.fetchAtomsInRange`` (`:225-248`) — oldest first."""
    filter_sql, filter_args = _user_filter()
    rows = con.execute(
        f"""
                SELECT{_ATOM_COLUMNS}
                FROM text_atoms a
                JOIN context_events e ON e.id = a.event_id
                WHERE e.timestamp >= ? AND e.timestamp <= ?{filter_sql}
                ORDER BY e.timestamp ASC
                LIMIT ?
        """,
        [since, until, *filter_args, limit],
    ).fetchall()
    return [_hit(r) for r in rows]


def _latest_app_bundle_id(
    con: sqlite3.Connection, excluding: list[str]
) -> str | None:
    """``OrbitDBReader.latestAppBundleId`` (`:251-268`)."""
    rows = con.execute(
        """
                SELECT app_bundle_id
                  FROM context_events
                 WHERE app_bundle_id IS NOT NULL AND app_bundle_id != ''
                 ORDER BY timestamp DESC
                 LIMIT ?
        """,
        [LATEST_APP_SCAN],
    ).fetchall()
    skip = set(excluding)
    for row in rows:
        bundle = row["app_bundle_id"]
        if bundle and bundle not in skip:
            return bundle
    return rows[0]["app_bundle_id"] if rows else None


def _atoms_captured_today(con: sqlite3.Connection) -> int:
    """``OrbitDBReader.atomsCapturedToday`` (`:270-280`) — UTC day, deliberately."""
    filter_sql, filter_args = _user_filter()
    row = con.execute(
        f"""
                SELECT COUNT(*)
                FROM text_atoms a
                JOIN context_events e ON e.id = a.event_id
                WHERE date(e.timestamp) = date('now'){filter_sql}
        """,
        filter_args,
    ).fetchone()
    return int(row[0] or 0)


def _score_inputs(con: sqlite3.Connection) -> dict[str, float]:
    """``OrbitDBReader.computeScoreInputs`` (`:282-331`).

    Arithmetic ported verbatim, including the ``max(1, done + pending)`` guard and
    the 0.7 / 500 / 8 normalisers, so the menu-bar score does not move.
    """
    filter_sql, filter_args = _user_filter("user_id")
    task_sql, task_args = _user_filter("user_id")

    task_row = con.execute(
        f"""
                SELECT
                    SUM(CASE WHEN status IN ('approved','dispatched') THEN 1 ELSE 0 END) AS done,
                    SUM(CASE WHEN status = 'detected' THEN 1 ELSE 0 END) AS pending
                FROM task_log
                WHERE date(timestamp) = date('now'){task_sql}
        """,
        task_args,
    ).fetchone()
    done = float((task_row["done"] if task_row else 0) or 0)
    pending = float((task_row["pending"] if task_row else 0) or 0)
    task_completion = done / max(1.0, done + pending)

    focus_rows = con.execute(
        f"""
                SELECT app_bundle_id, COUNT(*) AS c
                FROM context_events
                WHERE date(timestamp) = date('now'){filter_sql}
                GROUP BY app_bundle_id
        """,
        filter_args,
    ).fetchall()
    counts = [float(r["c"]) for r in focus_rows]
    total = sum(counts)
    top_share = (max(counts) / total) if total > 0 else 0.0
    focus_depth = min(1.0, top_share / 0.7)

    atoms_row = con.execute(
        f"""
                SELECT COUNT(*)
                FROM text_atoms a
                JOIN context_events e ON e.id = a.event_id
                WHERE date(e.timestamp) = date('now'){filter_sql}
        """,
        filter_args,
    ).fetchone()
    context_richness = min(1.0, float(atoms_row[0] or 0) / 500.0)

    hours_row = con.execute(
        f"""
                SELECT COUNT(DISTINCT strftime('%H', timestamp))
                FROM context_events
                WHERE date(timestamp) = date('now')
                  AND strftime('%H', timestamp) BETWEEN '09' AND '17'{filter_sql}
        """,
        filter_args,
    ).fetchone()
    capture_consistency = min(1.0, float(hours_row[0] or 0) / 8.0)

    return {
        "task_completion": task_completion,
        "focus_depth": focus_depth,
        "context_richness": context_richness,
        "capture_consistency": capture_consistency,
    }


# --- usage snapshot helpers (OrbitDBReader.swift:352-396 / :454-622) --------- #

def _day_activity(con: sqlite3.Connection, days: int) -> list[dict[str, Any]]:
    """``fetchDayActivity`` (`:454-472`) — ``date(...,'localtime')``, ascending."""
    filter_sql, filter_args = _user_filter("user_id")
    rows = con.execute(
        f"""
            SELECT date(timestamp,'localtime') AS d, COUNT(*) AS events
              FROM context_events
             WHERE timestamp >= datetime('now', ?){filter_sql}
             GROUP BY d
             ORDER BY d ASC
        """,
        [f"-{days} days", *filter_args],
    ).fetchall()
    return [
        {"day": r["d"], "events": int(r["events"] or 0)}
        for r in rows
        if r["d"]
    ]


def _app_usage(con: sqlite3.Connection, days: int, limit: int) -> list[dict[str, Any]]:
    """``fetchAppUsage`` (`:474-505`) — excludes ``com.orbit.access``."""
    filter_sql, filter_args = _user_filter()
    rows = con.execute(
        f"""
            SELECT e.app_bundle_id AS bundle_id,
                   MAX(e.app_name)  AS app_name,
                   COUNT(DISTINCT e.id) AS events,
                   COUNT(a.id)          AS atoms
              FROM context_events e
              LEFT JOIN text_atoms a ON a.event_id = e.id
             WHERE e.timestamp >= datetime('now', ?)
               AND e.app_bundle_id IS NOT NULL AND e.app_bundle_id != ''
               AND e.app_bundle_id != 'com.orbit.access'{filter_sql}
             GROUP BY e.app_bundle_id
             ORDER BY atoms DESC
             LIMIT ?
        """,
        [f"-{days} days", *filter_args, limit],
    ).fetchall()
    return [
        {
            "bundle_id": r["bundle_id"],
            "app_name": r["app_name"] or r["bundle_id"],
            "events": int(r["events"] or 0),
            "atoms": int(r["atoms"] or 0),
        }
        for r in rows
        if r["bundle_id"]
    ]


def _capture_tier_split(con: sqlite3.Connection, days: int) -> list[dict[str, Any]]:
    """``fetchCaptureTierSplit`` (`:507-524`)."""
    filter_sql, filter_args = _user_filter()
    rows = con.execute(
        f"""
            SELECT COALESCE(e.capture_method,'unknown') AS method, COUNT(*) AS events
              FROM context_events e
             WHERE e.timestamp >= datetime('now', ?){filter_sql}
             GROUP BY method
             ORDER BY events DESC
        """,
        [f"-{days} days", *filter_args],
    ).fetchall()
    return [
        {"method": r["method"], "events": int(r["events"] or 0)}
        for r in rows
        if r["method"]
    ]


def _task_tally(con: sqlite3.Connection, days: int) -> dict[str, int]:
    """``fetchTaskTally`` (`:526-543`). SUM over zero rows is NULL, not 0."""
    filter_sql, filter_args = _user_filter("user_id")
    row = con.execute(
        f"""
            SELECT SUM(CASE WHEN status = 'detected' THEN 1 ELSE 0 END) AS detected,
                   SUM(CASE WHEN status IN ('approved','dispatched') THEN 1 ELSE 0 END) AS approved,
                   SUM(CASE WHEN status = 'skipped' THEN 1 ELSE 0 END) AS skipped
              FROM task_log
             WHERE timestamp >= datetime('now', ?){filter_sql}
        """,
        [f"-{days} days", *filter_args],
    ).fetchone()
    return {
        "detected": int((row["detected"] if row else 0) or 0),
        "approved": int((row["approved"] if row else 0) or 0),
        "skipped": int((row["skipped"] if row else 0) or 0),
    }


def _usage_totals(
    con: sqlite3.Connection, today_start: str, today_end: str
) -> dict[str, int]:
    """``fetchUsageTotals`` (`:550-584`) — five small statements.

    The two "today" counters use a **range** predicate against local-day bounds
    rendered as UTC ISO strings, not ``date(...,'localtime') = date('now',...)``:
    113 ms vs 526 ms, because the latter cannot use the index (plan 33 §0.7.2).
    """
    filter_sql, filter_args = _user_filter("user_id")
    joined_sql, joined_args = _user_filter()

    atoms = con.execute("SELECT COUNT(*) FROM text_atoms").fetchone()[0] or 0
    chars = con.execute(
        "SELECT COALESCE(SUM(length(text)), 0) FROM text_atoms"
    ).fetchone()[0] or 0
    apps = con.execute(
        f"""
            SELECT COUNT(DISTINCT app_bundle_id)
              FROM context_events
             WHERE app_bundle_id IS NOT NULL AND app_bundle_id != ''{filter_sql}
        """,
        filter_args,
    ).fetchone()[0] or 0
    atoms_today = con.execute(
        f"""
            SELECT COUNT(*)
              FROM text_atoms a
              JOIN context_events e ON e.id = a.event_id
             WHERE e.timestamp >= ? AND e.timestamp < ?{joined_sql}
        """,
        [today_start, today_end, *joined_args],
    ).fetchone()[0] or 0
    active_hours_today = con.execute(
        f"""
            SELECT COUNT(DISTINCT strftime('%H', timestamp, 'localtime'))
              FROM context_events
             WHERE timestamp >= ? AND timestamp < ?{filter_sql}
        """,
        [today_start, today_end, *filter_args],
    ).fetchone()[0] or 0

    return {
        "total_atoms": int(atoms),
        "total_chars": int(chars),
        "distinct_apps": int(apps),
        "atoms_today": int(atoms_today),
        "active_hours_today": int(active_hours_today),
    }


def _model_usage(con: sqlite3.Connection, days: int) -> list[dict[str, Any]]:
    """``fetchModelUsage`` (`:586-611`). No user filter — ``llm_calls`` has no
    ``user_id`` column (plan 33 anti-pattern 7)."""
    rows = con.execute(
        """
            SELECT COALESCE(model,'(unspecified)') AS model,
                   COALESCE(provider,'unknown')    AS provider,
                   COUNT(*)                        AS calls,
                   SUM(CASE WHEN ok = 1 THEN 1 ELSE 0 END) AS ok_calls,
                   CAST(ROUND(AVG(latency_ms)) AS INTEGER) AS avg_ms
              FROM llm_calls
             WHERE timestamp >= datetime('now', ?)
             GROUP BY model, provider
             ORDER BY calls DESC, model ASC
        """,
        [f"-{days} days"],
    ).fetchall()
    return [
        {
            "model": r["model"],
            "provider": r["provider"],
            "calls": int(r["calls"] or 0),
            "ok_calls": int(r["ok_calls"] or 0),
            "average_latency_ms": int(r["avg_ms"] or 0),
        }
        for r in rows
        if r["model"] is not None and r["provider"] is not None
    ]


def _llm_totals(con: sqlite3.Connection, days: int) -> tuple[int, int]:
    """``fetchLLMTotals`` (`:613-622`)."""
    row = con.execute(
        """
            SELECT COUNT(*) AS calls, SUM(CASE WHEN ok = 1 THEN 1 ELSE 0 END) AS ok_calls
              FROM llm_calls
             WHERE timestamp >= datetime('now', ?)
        """,
        [f"-{days} days"],
    ).fetchone()
    calls = int((row["calls"] if row else 0) or 0)
    ok_calls = int((row["ok_calls"] if row else 0) or 0)
    return calls, ok_calls


def _usage_snapshot(
    con: sqlite3.Connection,
    days: int,
    breakdown_days: int,
    app_limit: int,
    today_start: str,
    today_end: str,
) -> dict[str, Any]:
    """``OrbitDBReader.loadUsageSnapshot`` (`:409-450`) — one payload, one lock hold."""
    calls, ok_calls = _llm_totals(con, breakdown_days)
    totals = _usage_totals(con, today_start, today_end)
    return {
        "days": _day_activity(con, days),
        "apps": _app_usage(con, breakdown_days, app_limit),
        "tiers": _capture_tier_split(con, breakdown_days),
        "tasks": _task_tally(con, breakdown_days),
        "models": _model_usage(con, breakdown_days),
        "llm_calls": calls,
        "llm_ok_calls": ok_calls,
        **totals,
    }


# --- users ----------------------------------------------------------------- #

def _fetch_user(con: sqlite3.Connection, user_id: str) -> dict[str, Any] | None:
    """``UserSessionService.fetchUser(id:)`` (`UserSessionService.swift:150-157`)."""
    row = con.execute(
        """
        SELECT id, email, display_name, created_at, cloud_user_id
          FROM users
         WHERE id = ?
        """,
        [user_id],
    ).fetchone()
    if row is None:
        return None
    return {
        "id": row["id"],
        "email": row["email"],
        "display_name": row["display_name"],
        "created_at": row["created_at"],
        "cloud_user_id": row["cloud_user_id"],
    }


def _create_user(
    con: sqlite3.Connection, email: str, display_name: str, cloud_user_id: str | None
) -> tuple[int, dict[str, Any]]:
    """``UserSessionService.signUp`` DB half (`UserSessionService.swift:109-129`).

    Validation, trimming, lower-casing and the duplicate-email check are ported
    verbatim, including the user-facing message strings from
    ``UserSessionError`` (`:32-45`) so the app can surface the same text. The
    cloud sign-up (``UserAuthService.shared.signUp``) and the
    ``~/.orbit/session.json`` write stay in Swift — this route only owns the
    database rows, per D1.

    Returns ``(http_status, payload)``.
    """
    trimmed_email = email.strip().lower()
    trimmed_name = display_name.strip()
    if "@" not in trimmed_email or len(trimmed_email) < 3:
        return 400, {"error": "Enter a valid email address."}
    if len(trimmed_name) < 1:
        return 400, {"error": "Enter your name."}

    user_id = str(uuid.uuid4()).lower()
    now = _utc_now()
    try:
        existing = con.execute(
            "SELECT COUNT(*) FROM users WHERE email = ?", [trimmed_email]
        ).fetchone()[0]
        if existing:
            return 409, {"error": "An account with this email already exists on this Mac."}
        con.execute(
            """
            INSERT INTO users (id, email, display_name, created_at, cloud_user_id)
            VALUES (?, ?, ?, ?, ?)
            """,
            [user_id, trimmed_email, trimmed_name, now, cloud_user_id],
        )
        con.execute(
            """
            INSERT INTO user_sessions (user_id, last_active_at)
            VALUES (?, ?)
            ON CONFLICT(user_id) DO UPDATE SET last_active_at = excluded.last_active_at
            """,
            [user_id, now],
        )
        con.commit()
    except sqlite3.IntegrityError:
        # UNIQUE(email) — the SELECT above races with a concurrent sign-up.
        con.rollback()
        return 409, {"error": "An account with this email already exists on this Mac."}
    except sqlite3.Error as exc:
        con.rollback()
        logger.exception("user sign-up insert failed")
        return 500, {"error": str(exc)}

    return 200, {
        "ok": True,
        "user": {
            "id": user_id,
            "email": trimmed_email,
            "display_name": trimmed_name,
            "created_at": now,
            "cloud_user_id": cloud_user_id,
        },
    }


def _link_user_cloud_account(
    con: sqlite3.Connection, user_id: str, cloud_user_id: str
) -> tuple[int, dict[str, Any]]:
    """Plan 53 Phase 4: attach a relay account to an existing local ``users`` row.

    There was no ``PATCH``/``PUT`` user route (§0.4 anti-pattern 5), and sign-in cannot go
    through ``_create_user``: after Phase 1 the local user already exists — the daemon mints
    it on startup — so a second insert would fork the identity and orphan every captured
    row. This is the one column sign-in is allowed to touch.

    ``cloud_user_id`` is the **only** field written. Email is deliberately left alone: the
    local address is a synthetic ``@orbit.local`` one (§0.5A) and ``users.email`` is
    ``NOT NULL UNIQUE``, so overwriting it with the cloud address would risk an
    ``IntegrityError`` against another row on the same Mac. "Has a cloud account" is
    ``cloud_user_id IS NOT NULL``, never an email test.

    Returns ``(http_status, payload)``, matching ``_create_user``.
    """
    trimmed_user_id = user_id.strip()
    trimmed_cloud_id = cloud_user_id.strip()
    if not trimmed_user_id:
        return 400, {"error": "Enter a valid user id."}
    if not trimmed_cloud_id:
        return 400, {"error": "Enter a valid cloud user id."}

    try:
        cur = con.execute(
            "UPDATE users SET cloud_user_id = ? WHERE id = ?",
            [trimmed_cloud_id, trimmed_user_id],
        )
        if cur.rowcount == 0:
            con.rollback()
            return 404, {"error": "user not found"}
        con.commit()
    except sqlite3.Error as exc:
        con.rollback()
        logger.exception("user cloud link failed")
        return 500, {"error": str(exc)}

    user = _fetch_user(con, trimmed_user_id)
    if user is None:  # pragma: no cover - the UPDATE above proved the row exists
        return 404, {"error": "user not found"}
    return 200, {"ok": True, "user": user}


# --------------------------------------------------------------------------- #
# routers
# --------------------------------------------------------------------------- #

_GET_PATHS = {
    "/api/notes/recent",
    "/api/notes/recent/tail",
    "/api/atoms/today",
    "/api/score/inputs",
    "/api/atoms",
    "/api/atoms/by-app",
    "/api/atoms/by-hour",
    "/api/usage/snapshot",
    "/api/app/latest",
}


def handle_app_get(handler: BaseHTTPRequestHandler, server: Any, path: str) -> bool:
    """Handle GET Orbit Access data routes. Returns True if handled."""
    user_match = _USER_RE.match(path)
    if path not in _GET_PATHS and user_match is None:
        return False

    if not _check_bridge_auth(handler, server):
        _send_json(handler, 401, {"error": "unauthorized"})
        return True
    db_ref = _require_db(handler, server)
    if db_ref is None:
        return True
    con, lock = db_ref
    params = _query(handler)

    try:
        if path == "/api/notes/recent":
            after_id = _int_param(params, "after_id", 0, minimum=0, maximum=2**62)
            limit = _int_param(
                params, "limit", NOTES_DEFAULT_LIMIT, minimum=1, maximum=MAX_LIMIT
            )
            with lock:
                payload: Any = _recent_notes(con, after_id, limit)
        elif path == "/api/notes/recent/tail":
            limit = _int_param(
                params, "limit", NOTES_DEFAULT_LIMIT, minimum=1, maximum=MAX_LIMIT
            )
            with lock:
                payload = _recent_notes_tail(con, limit)
        elif path == "/api/atoms/today":
            with lock:
                payload = {"count": _atoms_captured_today(con)}
        elif path == "/api/score/inputs":
            with lock:
                payload = _score_inputs(con)
        elif path == "/api/atoms":
            since = _str_param(params, "since")
            until = _str_param(params, "until")
            if since is None or until is None:
                raise _BadParam("since and until required")
            limit = _int_param(
                params, "limit", ATOMS_RANGE_DEFAULT_LIMIT, minimum=1, maximum=MAX_LIMIT
            )
            with lock:
                payload = _atoms_in_range(con, since, until, limit)
        elif path == "/api/atoms/by-app":
            app_name = _str_param(params, "app_name")
            if app_name is None:
                raise _BadParam("app_name required")
            limit = _int_param(
                params, "limit", ATOMS_BY_DEFAULT_LIMIT, minimum=1, maximum=MAX_LIMIT
            )
            with lock:
                payload = _atoms_by_app(con, app_name, limit)
        elif path == "/api/atoms/by-hour":
            hour = _str_param(params, "hour")
            if hour is not None and not hour.isdigit():
                raise _BadParam("invalid hour")
            limit = _int_param(
                params, "limit", ATOMS_BY_DEFAULT_LIMIT, minimum=1, maximum=MAX_LIMIT
            )
            with lock:
                payload = _atoms_by_hour(con, hour, limit)
        elif path == "/api/usage/snapshot":
            days = _int_param(
                params, "days", SNAPSHOT_DEFAULT_DAYS, minimum=1, maximum=MAX_DAYS
            )
            breakdown_days = _int_param(
                params,
                "breakdown_days",
                SNAPSHOT_DEFAULT_BREAKDOWN_DAYS,
                minimum=1,
                maximum=MAX_DAYS,
            )
            app_limit = _int_param(
                params, "app_limit", SNAPSHOT_DEFAULT_APP_LIMIT, minimum=1, maximum=MAX_LIMIT
            )
            start, end = _local_day_bounds(_str_param(params, "day"))
            with lock:
                payload = _usage_snapshot(
                    con, days, breakdown_days, app_limit, start, end
                )
        elif path == "/api/app/latest":
            excluding = [
                token.strip()
                for raw in params.get("exclude", [])
                for token in raw.split(",")
                if token.strip()
            ]
            with lock:
                payload = {"app_bundle_id": _latest_app_bundle_id(con, excluding)}
        else:  # /api/user/<id>
            assert user_match is not None
            with lock:
                user = _fetch_user(con, user_match.group(1))
            if user is None:
                _send_json(handler, 404, {"error": "user not found"})
                return True
            payload = user
    except _BadParam as exc:
        _send_json(handler, 400, {"error": str(exc)})
        return True
    except Exception as exc:
        logger.exception("app route failed: %s", path)
        _send_json(handler, 503, {"error": str(exc)})
        return True

    _send_json(handler, 200, payload)
    return True


_POST_PATHS = {"/api/users", "/api/user/link"}


def handle_app_post(handler: BaseHTTPRequestHandler, server: Any, path: str) -> bool:
    """Handle POST Orbit Access data routes. Returns True if handled."""
    if path not in _POST_PATHS:
        return False

    if not _check_bridge_auth(handler, server):
        _send_json(handler, 401, {"error": "unauthorized"})
        return True
    db_ref = _require_db(handler, server)
    if db_ref is None:
        return True
    body = _read_json_body(handler)
    if body is None:
        return True

    if path == "/api/user/link":
        return _handle_user_link(handler, db_ref, body)

    email = body.get("email")
    display_name = body.get("display_name")
    if not isinstance(email, str):
        _send_json(handler, 400, {"error": "Enter a valid email address."})
        return True
    if not isinstance(display_name, str):
        _send_json(handler, 400, {"error": "Enter your name."})
        return True
    cloud_user_id = body.get("cloud_user_id")
    if not isinstance(cloud_user_id, str) or not cloud_user_id.strip():
        cloud_user_id = None
    else:
        cloud_user_id = cloud_user_id.strip()

    con, lock = db_ref
    with lock:
        status, payload = _create_user(con, email, display_name, cloud_user_id)
    _send_json(handler, status, payload)
    return True


def _handle_user_link(
    handler: BaseHTTPRequestHandler, db_ref: tuple[Any, Any], body: dict[str, Any]
) -> bool:
    """``POST /api/user/link`` — body validation, then the write under the lock.

    ``user_id`` is optional: the app knows its own session id, but the daemon reads the same
    ``~/.orbit/session.json``, so an omitted id falls back to the active user rather than
    forcing the caller to repeat it. A *present but wrong-typed* id is still a 400 — that is
    a caller bug, not an omission.
    """
    user_id = body.get("user_id")
    if user_id is None:
        user_id = get_active_user_id() or ""
    if not isinstance(user_id, str):
        _send_json(handler, 400, {"error": "Enter a valid user id."})
        return True
    cloud_user_id = body.get("cloud_user_id")
    if not isinstance(cloud_user_id, str):
        _send_json(handler, 400, {"error": "Enter a valid cloud user id."})
        return True

    con, lock = db_ref
    with lock:
        status, payload = _link_user_cloud_account(con, user_id, cloud_user_id)
    _send_json(handler, status, payload)
    return True
