"""Relevance gating for detected tasks — the approval-budget prerequisite.

``CLAUDE.md``'s "2–5 high-quality approval requests per day" constraint cannot be
honored by a bare confidence threshold: nothing dedupes repeats, nothing caps the
daily count, and nothing learns from what the user actually skips. This module is
scoring and SQL only — **never an LLM call** — so the gate itself never adds cost
or latency to the thing it exists to bound.

``dedupe_against_history`` matches against ``task_log`` directly rather than through
``search_lexical``/``search_bridge`` (``orbit/search/hybrid.py``): those query
``atoms_fts``/``text_atoms``, which index captured screen text, not task titles —
there is no FTS table over ``task_log``. The "graceful degradation" property those
functions have under ``--no-embed`` (plain SQL/string ops, no ``vec0`` dependency)
is preserved here the same way: token-overlap matching in Python, no embeddings,
no new table.
"""
from __future__ import annotations

import logging
import re
import sqlite3
import threading
from datetime import datetime, timedelta, timezone
from typing import Any

from orbit.check.detector import Task
from orbit.storage.session import get_active_user_id

logger = logging.getLogger(__name__)

# Jaccard token-overlap threshold above which two task titles are treated as the
# same underlying task. 1.0 (identical titles) always clears this; the margin
# below that is for near-duplicates ("Reply to Jane's email" vs "Reply to Jane
# about the proposal").
_DUPLICATE_SIMILARITY_THRESHOLD = 0.5
# Lower bar for the skip-history penalty: two titles need only be somewhat
# related to count against a repeatedly-skipped pattern, not be near-duplicates.
_SKIP_SIMILARITY_THRESHOLD = 0.4

_STOPWORDS = {
    "a", "an", "the", "to", "for", "of", "in", "on", "and", "or", "with",
    "your", "my", "about", "from", "at", "is", "are", "be", "this", "that",
}
_WORD_RE = re.compile(r"[a-z0-9']+")


def _title_tokens(text: str) -> set[str]:
    words = _WORD_RE.findall((text or "").lower())
    return {w for w in words if w not in _STOPWORDS and len(w) > 1}


def _similarity(a: set[str], b: set[str]) -> float:
    if not a or not b:
        return 0.0
    union = len(a | b)
    if not union:
        return 0.0
    return len(a & b) / union


def _parse_ts(value: str) -> datetime:
    """Parse ISO timestamps written by capture/task_log (UTC, with or without offset)."""
    text = (value or "").strip()
    if not text:
        raise ValueError("empty timestamp")
    if text.endswith("Z"):
        text = text[:-1] + "+00:00"
    try:
        dt = datetime.fromisoformat(text)
    except ValueError:
        dt = datetime.fromisoformat(text.replace(" ", "T"))
    if dt.tzinfo is None:
        dt = dt.replace(tzinfo=timezone.utc)
    return dt


def _utc_today(day: str | None) -> str:
    return day or datetime.now(timezone.utc).date().isoformat()


def dedupe_against_history(con: sqlite3.Connection, task: Task, *, days: int = 14) -> int | None:
    """Return the ``task_log.id`` of a near-duplicate from the last ``days``, or None.

    Matches on title token-overlap against any row still relevant to the user
    (already skipped, already dispatched/approved, or still pending as
    'detected') — a repeat of any of those is noise, not a new suggestion.
    """
    since = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    uid = get_active_user_id()
    user_clause = " AND user_id = ?" if uid else ""
    params: list[Any] = [since]
    if uid:
        params.append(uid)
    rows = con.execute(
        f"""
        SELECT id, title, status
          FROM task_log
         WHERE timestamp >= ?
           AND status IN ('skipped', 'dispatched', 'approved', 'detected')
           {user_clause}
         ORDER BY timestamp DESC
        """,
        params,
    ).fetchall()
    task_tokens = _title_tokens(task.title)
    for row in rows:
        sim = _similarity(task_tokens, _title_tokens(row["title"]))
        if sim >= _DUPLICATE_SIMILARITY_THRESHOLD:
            return int(row["id"])
    return None


def _recency_factor(con: sqlite3.Connection, now_dt: datetime) -> float:
    """1.0 for context captured just now, decaying to 0.0 by 24h old.

    A task detected from a context window with no recent captures behind it is
    less trustworthy than one grounded in what just happened — this is a coarse
    proxy for "how fresh is the evidence", computed with a single SQL read.
    """
    row = con.execute("SELECT MAX(timestamp) AS ts FROM context_events").fetchone()
    if row is None or row["ts"] is None:
        return 0.0
    try:
        last = _parse_ts(row["ts"])
    except ValueError:
        return 0.0
    age_hours = max(0.0, (now_dt - last).total_seconds() / 3600.0)
    return max(0.0, 1.0 - age_hours / 24.0)


def _entity_overlap_factor(con: sqlite3.Connection, task: Task) -> float:
    """Fraction (capped at 1.0) of the user's top entities mentioned in the task text."""
    try:
        from orbit.memory.entities import top_entities

        entities = top_entities(con, day=None, limit=20)
    except Exception:
        # Missing entities tables on an older DB, or any other read failure --
        # this factor degrades to 0 rather than blocking the rest of scoring.
        logger.debug("gate: top_entities lookup failed", exc_info=True)
        return 0.0
    if not entities:
        return 0.0
    haystack = f"{task.title} {task.description} {task.suggested_prompt}".lower()
    hits = sum(
        1
        for e in entities
        if e.get("name") and len(str(e["name"])) > 2 and str(e["name"]).lower() in haystack
    )
    return min(1.0, hits / 3.0)


def _skip_penalty(con: sqlite3.Connection, task: Task, *, days: int = 30) -> float:
    """Penalty in [0, 0.6] learned from how often similar tasks were skipped recently."""
    since = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    rows = con.execute(
        "SELECT title, agent_type FROM task_log WHERE status = 'skipped' AND timestamp >= ?",
        (since,),
    ).fetchall()
    if not rows:
        return 0.0
    task_tokens = _title_tokens(task.title)
    weight = 0.0
    for row in rows:
        if row["agent_type"] and row["agent_type"] == task.agent_type:
            weight += 0.5
        if _similarity(task_tokens, _title_tokens(row["title"])) >= _SKIP_SIMILARITY_THRESHOLD:
            weight += 1.0
    return min(0.6, weight * 0.1)


def score_task(con: sqlite3.Connection, task: Task, *, now: str | None = None) -> float:
    """Combine confidence, context recency, entity overlap, and skip history into [0, 1]."""
    now_dt = _parse_ts(now) if now else datetime.now(timezone.utc)
    confidence = max(0.0, min(1.0, task.confidence))
    recency = _recency_factor(con, now_dt)
    entity_overlap = _entity_overlap_factor(con, task)
    penalty = _skip_penalty(con, task)
    score = 0.55 * confidence + 0.2 * recency + 0.15 * entity_overlap + 0.1 - penalty
    return max(0.0, min(1.0, score))


def budget_remaining(con: sqlite3.Connection, *, day: str | None = None, cap: int = 5) -> int:
    """How many more tasks may be surfaced today, counting 'detected' + 'approved' rows.

    Uses the same ``date(timestamp) = ?`` UTC-date comparison as
    ``get_skipped_today``/``get_pending_today`` (``orbit/check/log.py``), since
    ``insert_task`` writes UTC timestamps.
    """
    d = _utc_today(day)
    row = con.execute(
        "SELECT COUNT(*) AS n FROM task_log"
        " WHERE date(timestamp) = ? AND status IN ('detected', 'approved')",
        (d,),
    ).fetchone()
    used = int(row["n"]) if row is not None else 0
    return max(0, cap - used)


def filter_tasks(
    con: sqlite3.Connection, lock: threading.Lock, tasks: list[Task], *, cap: int = 5
) -> list[Task]:
    """Dedupe, score, and budget-cap detected tasks. SQL/scoring only — no LLM call.

    Every suppression is logged at INFO with its reason, so a zero-task result is
    always traceable to "budget exhausted" or "duplicate of task_log id=N", never
    a silent skip.
    """
    if not tasks:
        return []
    with lock:
        remaining = budget_remaining(con, cap=cap)
        if remaining <= 0:
            logger.info(
                "gate: daily approval budget exhausted (cap=%d); suppressing %d task(s)",
                cap, len(tasks),
            )
            return []
        scored: list[tuple[float, Task]] = []
        for task in tasks:
            dup_id = dedupe_against_history(con, task)
            if dup_id is not None:
                logger.info(
                    "gate: suppressing %r as a near-duplicate of task_log id=%d",
                    task.title, dup_id,
                )
                continue
            scored.append((score_task(con, task), task))
    scored.sort(key=lambda pair: pair[0], reverse=True)
    kept = [task for _, task in scored[:remaining]]
    dropped = len(scored) - len(kept)
    if dropped > 0:
        logger.info(
            "gate: %d slot(s) remaining in today's budget; suppressing %d lowest-scoring task(s)",
            remaining, dropped,
        )
    return kept
