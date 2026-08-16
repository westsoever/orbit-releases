"""Daily digest — structured summary of a day's work sessions."""
from __future__ import annotations

import logging
import sqlite3
import threading
from datetime import date, datetime, timedelta, timezone
from typing import Any

from orbit.check.envelope import untrusted_preamble, wrap_untrusted
from orbit.memory.sessions import (
    day_bounds,
    get_sessions,
    segment_sessions,
    sessions_to_hits,
)
from orbit.storage.links import event_uri

logger = logging.getLogger(__name__)

_DIGEST_SYSTEM = (
    "You are Orbit. Write a concise 2–4 sentence narrative of what the user "
    "worked on today, grounded only in the structured session data provided. "
    "Do not invent apps, people, or tasks that are not listed. "
    "Prefer concrete app names and themes over vague productivity claims."
    + untrusted_preamble()
)


def _local_day(day: str | None) -> str:
    if day is None or day in ("today", ""):
        return date.today().isoformat()
    return date.fromisoformat(day).isoformat()


def _task_stats(
    con: sqlite3.Connection, start: str, end: str
) -> dict[str, int]:
    row = con.execute(
        """
        SELECT
          SUM(CASE WHEN status = 'detected' THEN 1 ELSE 0 END) AS detected,
          SUM(CASE WHEN status IN ('approved', 'dispatched') THEN 1 ELSE 0 END)
            AS approved,
          SUM(CASE WHEN status = 'skipped' THEN 1 ELSE 0 END) AS skipped
          FROM task_log
         WHERE timestamp >= ? AND timestamp < ?
        """,
        (start, end),
    ).fetchone()
    return {
        "detected": int(row["detected"] or 0),
        "approved": int(row["approved"] or 0),
        "skipped": int(row["skipped"] or 0),
    }


def _files_touched(
    con: sqlite3.Connection, start: str, end: str, *, limit: int = 20
) -> list[dict[str, Any]]:
    try:
        rows = con.execute(
            """
            SELECT path, event_type, timestamp, linked_event_id
              FROM fs_events
             WHERE timestamp >= ? AND timestamp < ?
             ORDER BY timestamp DESC
             LIMIT ?
            """,
            (start, end, limit),
        ).fetchall()
    except sqlite3.Error:
        return []
    seen: set[str] = set()
    out: list[dict[str, Any]] = []
    for r in rows:
        path = r["path"]
        if path in seen:
            continue
        seen.add(path)
        item: dict[str, Any] = {
            "path": path,
            "event_type": r["event_type"],
            "timestamp": r["timestamp"],
        }
        if r["linked_event_id"]:
            item["event_uri"] = event_uri(int(r["linked_event_id"]))
        out.append(item)
    return out


def _app_breakdown(sessions: list[dict[str, Any]]) -> list[dict[str, Any]]:
    by_app: dict[str, dict[str, Any]] = {}
    for s in sessions:
        key = s.get("primary_bundle_id") or s.get("primary_app_name") or "unknown"
        entry = by_app.get(key)
        if entry is None:
            entry = {
                "app_bundle_id": s.get("primary_bundle_id"),
                "app_name": s.get("primary_app_name") or "unknown",
                "session_count": 0,
                "event_count": 0,
                "atom_count": 0,
            }
            by_app[key] = entry
        entry["session_count"] += 1
        entry["event_count"] += int(s.get("event_count") or 0)
        entry["atom_count"] += int(s.get("atom_count") or 0)
    return sorted(by_app.values(), key=lambda x: x["atom_count"], reverse=True)


def _structured_narrative(digest: dict[str, Any]) -> str:
    sessions = digest.get("sessions") or []
    if not sessions:
        return "No captures recorded for this day yet."
    apps = digest.get("apps") or []
    app_names = [a["app_name"] for a in apps[:5] if a.get("app_name")]
    parts = [
        f"{len(sessions)} work session(s)",
        f"{digest.get('total_events', 0)} capture events",
    ]
    if app_names:
        parts.append("primarily in " + ", ".join(app_names))
    files = digest.get("files") or []
    if files:
        parts.append(f"{len(files)} file(s) touched")
    tasks = digest.get("tasks") or {}
    if any(tasks.values()):
        parts.append(
            f"tasks: {tasks.get('detected', 0)} detected, "
            f"{tasks.get('approved', 0)} approved, "
            f"{tasks.get('skipped', 0)} skipped"
        )
    return "Today: " + "; ".join(parts) + "."


def _format_sessions_for_llm(sessions: list[dict[str, Any]]) -> list[tuple[str, str]]:
    blocks: list[tuple[str, str]] = []
    for i, s in enumerate(sessions, start=1):
        label = (
            f"session {i}: {s.get('started_at')} → {s.get('ended_at')} · "
            f"{s.get('primary_app_name') or 'unknown'} · "
            f"{s.get('event_count', 0)} events"
        )
        body_parts = [
            f"app={s.get('primary_app_name')}",
            f"bundle={s.get('primary_bundle_id')}",
            f"atoms={s.get('atom_count')}",
            f"switches={s.get('switch_count')}",
        ]
        if s.get("title"):
            body_parts.append(f"title={s['title']}")
        if s.get("summary"):
            body_parts.append(f"summary={s['summary']}")
        blocks.append((label, "\n".join(body_parts)))
    return blocks


def build_digest(
    con: sqlite3.Connection,
    lock: threading.Lock,
    *,
    day: str | None = None,
    use_llm: bool = True,
    db_ref: tuple[sqlite3.Connection, threading.Lock] | None = None,
) -> dict[str, Any]:
    """Build a daily digest from sessions (+ files/tasks).

    Segments sessions for the day first (idempotent). Uses ``complete()`` for a
    short narrative when ``use_llm`` is True; otherwise a structured SQL summary.
    """
    day_str = _local_day(day)
    start, end = day_bounds(day_str)

    # Ensure sessions exist for the window (and a little lookback for open gaps).
    lookback = (
        datetime.fromisoformat(start.replace("Z", "+00:00")) - timedelta(hours=1)
    ).isoformat()
    segment_sessions(con, lock, since=lookback, min_events=2)

    sessions = get_sessions(con, day=day_str, limit=100)
    with lock:
        tasks = _task_stats(con, start, end)
        files = _files_touched(con, start, end)

    apps = _app_breakdown(sessions)
    digest: dict[str, Any] = {
        "day": day_str,
        "since": start,
        "until": end,
        "sessions": sessions,
        "apps": apps,
        "files": files,
        "tasks": tasks,
        "total_events": sum(int(s.get("event_count") or 0) for s in sessions),
        "total_atoms": sum(int(s.get("atom_count") or 0) for s in sessions),
        "narrative": "",
        "source": "structured",
    }

    if not sessions:
        digest["narrative"] = "No captures recorded for this day yet."
        return digest

    if use_llm:
        try:
            from orbit.check.llm import complete

            context = wrap_untrusted(_format_sessions_for_llm(sessions))
            user_msg = (
                f"Day: {day_str}\n"
                f"Apps (by atom volume): "
                f"{', '.join(a['app_name'] for a in apps[:8]) or '(none)'}\n"
                f"Files touched: {len(files)}\n"
                f"Tasks: {tasks}\n\n"
                f"Session data:\n{context}\n\n"
                "Write the day narrative now."
            )
            narrative = complete(
                _DIGEST_SYSTEM,
                user_msg,
                call_site="daily_digest",
                db_ref=db_ref or (con, lock),
            ).strip()
            if narrative:
                digest["narrative"] = narrative
                digest["source"] = "llm"
                return digest
        except Exception:
            logger.exception("digest LLM narrative failed; using structured summary")

    digest["narrative"] = _structured_narrative(digest)
    digest["source"] = "structured"
    return digest


def render_digest_markdown(digest: dict[str, Any]) -> str:
    """Render digest dict as auditable markdown with orbit:// links where available."""
    day = digest.get("day", "")
    lines = [f"# Orbit digest — {day}", "", digest.get("narrative") or "", ""]
    sessions = digest.get("sessions") or []
    if sessions:
        lines.append("## Sessions")
        for s in sessions:
            app = s.get("primary_app_name") or "unknown"
            title = s.get("title") or app
            lines.append(
                f"- **{title}** · {s.get('started_at')} → {s.get('ended_at')} · "
                f"{s.get('event_count', 0)} events · {s.get('atom_count', 0)} atoms"
            )
            if s.get("summary"):
                lines.append(f"  {s['summary']}")
        lines.append("")
    apps = digest.get("apps") or []
    if apps:
        lines.append("## Apps")
        for a in apps:
            lines.append(
                f"- {a.get('app_name')} ({a.get('app_bundle_id') or '—'}): "
                f"{a.get('session_count')} session(s), {a.get('atom_count')} atoms"
            )
        lines.append("")
    files = digest.get("files") or []
    if files:
        lines.append("## Files touched")
        for f in files[:20]:
            uri = f.get("event_uri")
            suffix = f" · {uri}" if uri else ""
            lines.append(f"- `{f.get('path')}` ({f.get('event_type')}){suffix}")
        lines.append("")
    tasks = digest.get("tasks") or {}
    if any(tasks.values()):
        lines.append("## Tasks")
        lines.append(
            f"- detected={tasks.get('detected', 0)}, "
            f"approved={tasks.get('approved', 0)}, "
            f"skipped={tasks.get('skipped', 0)}"
        )
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def digest_context_and_hits(
    con: sqlite3.Connection,
    lock: threading.Lock,
    *,
    day: str | None = None,
    use_llm: bool = True,
    db_ref: tuple[sqlite3.Connection, threading.Lock] | None = None,
) -> tuple[str, list, dict[str, Any]]:
    """Return (context_text_for_chat, hits, digest) for the recap chat path."""
    digest = build_digest(con, lock, day=day, use_llm=use_llm, db_ref=db_ref)
    md = render_digest_markdown(digest)
    hits = sessions_to_hits(con, digest.get("sessions") or [], limit=8)
    blocks = [("daily digest", md)]
    return wrap_untrusted(blocks), hits, digest


def is_temporal_recap_query(query: str) -> bool:
    """True when the user is asking what they worked on in a time window."""
    q = query.lower().strip()
    if not q:
        return False
    recap_phrases = (
        "what did i work on",
        "what was i working on",
        "summarize what i worked",
        "summarise what i worked",
        "what have i worked on",
        "recap my day",
        "recap today",
        "daily digest",
        "day digest",
        "what did i do today",
        "what did i do this",
        "worked on today",
        "work on today",
        "today's work",
        "todays work",
        "summarize my day",
        "summarise my day",
        "summarize today",
        "summarise today",
    )
    if any(p in q for p in recap_phrases):
        return True
    # Broader: "today" / "this morning" + work/summarize verbs
    temporal = any(
        t in q
        for t in (
            "today",
            "this morning",
            "this afternoon",
            "this evening",
            "yesterday",
            "this week",
        )
    )
    intent = any(
        t in q
        for t in (
            "work",
            "worked",
            "summar",
            "recap",
            "digest",
            "activity",
            "focus",
            "do",
            "did",
            # Recap phrasings that omit an explicit work/summarize verb:
            # "what happened today", "what's going on this week",
            # "what have I been up to today", "what did I miss yesterday".
            "happen",
            "going on",
            "up to",
            "miss",
            "get done",
            "got done",
            "accomplish",
        )
    )
    return temporal and intent


def parse_chat_time_window(query: str) -> tuple[str | None, str | None]:
    """Infer since/until ISO bounds from a natural-language chat query."""
    q = query.lower()
    now = datetime.now(timezone.utc)
    if "last 24" in q or "past 24" in q or "last day" in q:
        return (now - timedelta(hours=24)).isoformat(), now.isoformat()
    if "yesterday" in q:
        y = date.today() - timedelta(days=1)
        start, end = day_bounds(y.isoformat())
        return start, end
    if "this week" in q:
        today = date.today()
        start_day = today - timedelta(days=today.weekday())
        start, _ = day_bounds(start_day.isoformat())
        return start, now.isoformat()
    if "today" in q or "this morning" in q or "this afternoon" in q:
        start, end = day_bounds(None)
        return start, end
    return None, None


def digest_day_from_query(query: str) -> str | None:
    """Return YYYY-MM-DD for day-scoped recap queries, else None."""
    q = query.lower()
    if "yesterday" in q:
        return (date.today() - timedelta(days=1)).isoformat()
    if "today" in q or "this morning" in q or "this afternoon" in q:
        return date.today().isoformat()
    if is_temporal_recap_query(query) and "week" not in q:
        return date.today().isoformat()
    return None
