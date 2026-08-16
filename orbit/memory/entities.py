"""Entity extraction — "everything about X" over the capture store.

Two-stage, cheap first:

  (a) Deterministic (no LLM): file paths from ``fs_events``, URLs/domains from
      ``context_events.page_url``, emails via regex over ``text_atoms.text``.
  (b) One LLM pass **per session** (never per atom) for people/projects/orgs,
      via ``complete()`` wrapped in the Phase 2 untrusted-data envelope. This
      stage is best-effort: a missing/unreachable provider or a malformed
      response is caught and logged, and deterministic extraction still
      returns its count. This is what "degrades gracefully with no model
      available" means for this module.

``entity_mentions`` is a fixed sibling table (schema not redesigned here) that
requires both an ``atom_id`` and an ``event_id`` per mention. Deterministic
sources that are not atom-scoped by nature (fs_events file paths,
context_events.page_url) still upsert the ``entities`` row unconditionally,
but only record an ``entity_mentions`` audit row when the source can be tied
to an actual captured atom — via ``fs_events.linked_event_id`` for files, or
directly via the owning ``context_events.id`` for URLs — anchored to that
event's earliest atom. Emails are atom-scoped already (matched directly in
``text_atoms.text``) so every email mention gets a precise anchor. The LLM
stage anchors every entity it returns for a session to that session's
earliest atom, since the model is not asked to cite a specific atom id.
"""
from __future__ import annotations

import json
import logging
import re
import sqlite3
import threading
from typing import Any, Callable
from urllib.parse import urlsplit

from orbit.check.envelope import untrusted_preamble, wrap_untrusted
from orbit.check.llm import complete
from orbit.memory.sessions import day_bounds
from orbit.storage.links import atom_uri, event_uri

logger = logging.getLogger(__name__)

_EMAIL_RE = re.compile(r"[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}")

_MAX_LLM_CONTEXT_CHARS = 12000
_MAX_ATOMS_PER_SESSION = 300

_ENTITY_SYSTEM = (
    "You extract named entities from a user's captured work context. Given a "
    "work session's captured text, list the distinct people, projects, and "
    "organizations mentioned by name. Do not include file paths, URLs, or "
    "email addresses -- those are extracted separately and deterministically.\n\n"
    "Return a JSON array of objects with exactly these fields:\n"
    '- kind: one of "person" | "project" | "org"\n'
    "- name: the entity's name as it appears in the text\n\n"
    "Return [] if nothing is clearly named. Return ONLY the JSON array, no "
    "other text or markdown fences."
) + untrusted_preamble()


# --------------------------------------------------------------------------
# Shared upsert / mention helpers
# --------------------------------------------------------------------------


def _upsert_entity(
    con: sqlite3.Connection, kind: str, name: str, normalized: str, seen_at: str
) -> int:
    """Upsert on (kind, normalized): bump mention_count and last_seen, or insert."""
    row = con.execute(
        "SELECT id FROM entities WHERE kind = ? AND normalized = ?",
        (kind, normalized),
    ).fetchone()
    if row is not None:
        entity_id = int(row["id"])
        con.execute(
            """
            UPDATE entities
               SET last_seen = MAX(last_seen, ?),
                   mention_count = mention_count + 1
             WHERE id = ?
            """,
            (seen_at, entity_id),
        )
        return entity_id
    cur = con.execute(
        """
        INSERT INTO entities (kind, name, normalized, first_seen, last_seen, mention_count)
        VALUES (?, ?, ?, ?, ?, 1)
        """,
        (kind, name, normalized, seen_at, seen_at),
    )
    return int(cur.lastrowid)


def _record_mention(
    con: sqlite3.Connection, entity_id: int, atom_id: int, event_id: int
) -> bool:
    """Insert an entity_mentions row. Returns True iff a new row was inserted."""
    cur = con.execute(
        "INSERT OR IGNORE INTO entity_mentions (entity_id, atom_id, event_id) "
        "VALUES (?, ?, ?)",
        (entity_id, atom_id, event_id),
    )
    return cur.rowcount > 0


def _earliest_atom_for_event(con: sqlite3.Connection, event_id: int) -> int | None:
    row = con.execute(
        "SELECT id FROM text_atoms WHERE event_id = ? ORDER BY id ASC LIMIT 1",
        (event_id,),
    ).fetchone()
    return int(row["id"]) if row is not None else None


# --------------------------------------------------------------------------
# Deterministic extraction (a)
# --------------------------------------------------------------------------


def _resolve_window(
    con: sqlite3.Connection, *, session_id: int | None, since: str | None
) -> tuple[str | None, str | None, list[int]]:
    """Return (start_ts, end_ts, context_event_ids) for the requested scope."""
    if session_id is not None:
        row = con.execute(
            "SELECT started_at, ended_at FROM sessions WHERE id = ?", (session_id,)
        ).fetchone()
        if row is None:
            return None, None, []
        event_ids = [
            r[0]
            for r in con.execute(
                "SELECT event_id FROM session_events WHERE session_id = ?",
                (session_id,),
            ).fetchall()
        ]
        return row["started_at"], row["ended_at"], event_ids
    if since:
        event_ids = [
            r[0]
            for r in con.execute(
                "SELECT id FROM context_events WHERE timestamp >= ?", (since,)
            ).fetchall()
        ]
        return since, None, event_ids
    event_ids = [r[0] for r in con.execute("SELECT id FROM context_events").fetchall()]
    return None, None, event_ids


def _extract_file_entities(
    con: sqlite3.Connection, start: str | None, end: str | None
) -> int:
    clauses: list[str] = []
    params: list[Any] = []
    if start:
        clauses.append("timestamp >= ?")
        params.append(start)
    if end:
        clauses.append("timestamp < ?")
        params.append(end)
    where = f"WHERE {' AND '.join(clauses)}" if clauses else ""
    rows = con.execute(
        f"SELECT path, timestamp, linked_event_id FROM fs_events {where} "
        "ORDER BY timestamp ASC",
        params,
    ).fetchall()
    inserted = 0
    for r in rows:
        path = (r["path"] or "").strip()
        if not path:
            continue
        entity_id = _upsert_entity(con, "file", path, path, r["timestamp"])
        event_id = r["linked_event_id"]
        if event_id is None:
            continue
        atom_id = _earliest_atom_for_event(con, int(event_id))
        if atom_id is None:
            continue
        if _record_mention(con, entity_id, atom_id, int(event_id)):
            inserted += 1
    return inserted


def _extract_domain(url: str) -> str | None:
    try:
        netloc = urlsplit(url).netloc
    except ValueError:
        return None
    if not netloc:
        return None
    host = netloc.rsplit("@", 1)[-1].split(":", 1)[0].lower().strip()
    if host.startswith("www."):
        host = host[4:]
    return host or None


def _extract_url_entities(con: sqlite3.Connection, event_ids: list[int]) -> int:
    if not event_ids:
        return 0
    placeholders = ",".join("?" * len(event_ids))
    rows = con.execute(
        f"""
        SELECT id, page_url, timestamp
          FROM context_events
         WHERE id IN ({placeholders}) AND page_url IS NOT NULL AND page_url != ''
        """,
        event_ids,
    ).fetchall()
    inserted = 0
    for r in rows:
        domain = _extract_domain(r["page_url"])
        if not domain:
            continue
        entity_id = _upsert_entity(con, "url", domain, domain, r["timestamp"])
        atom_id = _earliest_atom_for_event(con, int(r["id"]))
        if atom_id is None:
            continue
        if _record_mention(con, entity_id, atom_id, int(r["id"])):
            inserted += 1
    return inserted


def _extract_email_entities(con: sqlite3.Connection, event_ids: list[int]) -> int:
    if not event_ids:
        return 0
    placeholders = ",".join("?" * len(event_ids))
    rows = con.execute(
        f"""
        SELECT a.id AS atom_id, a.event_id, a.text, e.timestamp
          FROM text_atoms a
          JOIN context_events e ON e.id = a.event_id
         WHERE a.event_id IN ({placeholders})
        """,
        event_ids,
    ).fetchall()
    inserted = 0
    for r in rows:
        text = r["text"] or ""
        if not text:
            continue
        for match in dict.fromkeys(_EMAIL_RE.findall(text)):  # de-dupe, keep order
            normalized = match.lower()
            entity_id = _upsert_entity(con, "person", match, normalized, r["timestamp"])
            if _record_mention(con, entity_id, int(r["atom_id"]), int(r["event_id"])):
                inserted += 1
    return inserted


# --------------------------------------------------------------------------
# LLM extraction (b) — one call per session
# --------------------------------------------------------------------------


def _parse_llm_entities(text: str) -> list[tuple[str, str]]:
    """Fence-stripping + json.loads, matching orbit/check/detector.py's shape."""
    if text.startswith("```"):
        _fence, newline, rest = text.partition("\n")
        if newline:
            text = rest.rsplit("```", 1)[0].strip()
    try:
        data = json.loads(text)
    except json.JSONDecodeError:
        return []
    if not isinstance(data, list):
        return []
    out: list[tuple[str, str]] = []
    for item in data:
        if not isinstance(item, dict):
            continue
        kind = item.get("kind")
        name = item.get("name")
        if kind in ("person", "project", "org") and isinstance(name, str) and name.strip():
            out.append((kind, name.strip()))
    return out


def _extract_llm_entities_for_session(
    con: sqlite3.Connection, lock: threading.Lock, session_id: int
) -> int:
    with lock:
        rows = con.execute(
            """
            SELECT a.id AS atom_id, a.event_id, a.text, e.timestamp
              FROM session_events se
              JOIN text_atoms a ON a.event_id = se.event_id
              JOIN context_events e ON e.id = a.event_id
             WHERE se.session_id = ?
             ORDER BY e.timestamp ASC, a.id ASC
             LIMIT ?
            """,
            (session_id, _MAX_ATOMS_PER_SESSION),
        ).fetchall()

    if not rows:
        return 0

    anchor_atom_id = int(rows[0]["atom_id"])
    anchor_event_id = int(rows[0]["event_id"])
    seen_at = rows[0]["timestamp"]

    blocks: list[tuple[str, str]] = []
    total_chars = 0
    for r in rows:
        text = (r["text"] or "").strip()
        if not text:
            continue
        blocks.append((f"atom {r['atom_id']}", text[:1000]))
        total_chars += len(text)
        if total_chars > _MAX_LLM_CONTEXT_CHARS:
            break

    if not blocks:
        return 0

    wrapped = wrap_untrusted(blocks)
    try:
        raw = complete(_ENTITY_SYSTEM, wrapped, call_site="entity_extract")
    except Exception:
        # No provider configured, timeout, malformed response upstream, etc. --
        # deterministic extraction must not be blocked by this. Log and move on.
        logger.warning(
            "entity extraction LLM pass failed for session %s", session_id, exc_info=True
        )
        return 0

    entities = _parse_llm_entities(raw.strip())
    if not entities:
        return 0

    inserted = 0
    with lock:
        con.execute("BEGIN IMMEDIATE")
        try:
            for kind, name in entities:
                normalized = name.strip().lower()
                if not normalized:
                    continue
                entity_id = _upsert_entity(con, kind, name.strip(), normalized, seen_at)
                if _record_mention(con, entity_id, anchor_atom_id, anchor_event_id):
                    inserted += 1
            con.execute("COMMIT")
        except Exception:
            con.execute("ROLLBACK")
            raise
    return inserted


# --------------------------------------------------------------------------
# Public API
# --------------------------------------------------------------------------


def extract_entities(
    con: sqlite3.Connection,
    lock: threading.Lock,
    *,
    session_id: int | None = None,
    since: str | None = None,
) -> int:
    """Extract entities into ``entities`` / ``entity_mentions``.

    Scope:
    - ``session_id`` given: exactly that session's window.
    - ``since`` given (``session_id`` None): everything at/after ``since``.
    - neither given: the whole store.

    Runs the deterministic stage first (file paths, URLs/domains, emails --
    pure SQL + regex, no LLM), then one LLM pass per session in scope for
    people/projects/orgs. The LLM stage is best-effort per session; a failure
    there never discards the deterministic count.

    Returns the number of ``entity_mentions`` rows actually inserted (new rows
    only). Re-running over the same range is idempotent for mentions -- it
    inserts no duplicate ``(entity_id, atom_id)`` rows -- while
    ``entities.last_seen`` / ``mention_count`` still advance on every pass.
    """
    start, end, event_ids = _resolve_window(con, session_id=session_id, since=since)

    inserted = 0
    with lock:
        con.execute("BEGIN IMMEDIATE")
        try:
            inserted += _extract_file_entities(con, start, end)
            inserted += _extract_url_entities(con, event_ids)
            inserted += _extract_email_entities(con, event_ids)
            con.execute("COMMIT")
        except Exception:
            con.execute("ROLLBACK")
            raise

    if session_id is not None:
        session_ids = [session_id]
    elif since:
        session_ids = [
            r[0]
            for r in con.execute(
                "SELECT id FROM sessions WHERE started_at >= ?", (since,)
            ).fetchall()
        ]
    else:
        session_ids = [r[0] for r in con.execute("SELECT id FROM sessions").fetchall()]

    for sid in session_ids:
        inserted += _extract_llm_entities_for_session(con, lock, sid)

    return inserted


def backfill_entities(
    con: sqlite3.Connection,
    lock: threading.Lock,
    on_progress: Callable[[int, int], None] | None = None,
) -> int:
    """Populate ``entities``/``entity_mentions`` for the whole store.

    Plan 48 §4.5: nothing in the daemon or CLI ever called ``extract_entities``,
    so both tables were permanently empty and ``chat_entity`` could never fire.
    This is the missing call site, not new extraction logic -- it mirrors the
    ``backfill_embeddings`` shape (whole-store scope, optional progress
    callback) so it can be driven the same way (a one-off data backfill after
    the Phase 4.4 purge, or from a future CLI/daemon hook).

    Runs the whole-store deterministic + per-session LLM extraction in one
    ``extract_entities(con, lock)`` call (``session_id=None, since=None``).
    Returns the number of new ``entity_mentions`` rows inserted.
    """
    if on_progress is not None:
        total_sessions = con.execute("SELECT COUNT(*) FROM sessions").fetchone()[0]
        on_progress(0, total_sessions)
    inserted = extract_entities(con, lock)
    if on_progress is not None:
        on_progress(total_sessions, total_sessions)
    return inserted


def entity_timeline(
    con: sqlite3.Connection, entity_id: int, limit: int = 100
) -> list[dict[str, Any]]:
    """Every mention of one entity, newest first, each with a resolvable orbit:// link."""
    rows = con.execute(
        """
        SELECT em.atom_id, em.event_id, a.role, a.label,
               substr(a.text, 1, 240) AS snippet,
               e.app_bundle_id, e.app_name, e.window_title, e.timestamp
          FROM entity_mentions em
          JOIN text_atoms a ON a.id = em.atom_id
          JOIN context_events e ON e.id = em.event_id
         WHERE em.entity_id = ?
         ORDER BY e.timestamp DESC
         LIMIT ?
        """,
        (entity_id, limit),
    ).fetchall()
    out: list[dict[str, Any]] = []
    for r in rows:
        out.append(
            {
                "atom_id": r["atom_id"],
                "event_id": r["event_id"],
                "atom_uri": atom_uri(int(r["atom_id"])),
                "event_uri": event_uri(int(r["event_id"])),
                "role": r["role"],
                "label": r["label"],
                "snippet": r["snippet"],
                "app_bundle_id": r["app_bundle_id"],
                "app_name": r["app_name"],
                "window_title": r["window_title"],
                "timestamp": r["timestamp"],
            }
        )
    return out


def top_entities(
    con: sqlite3.Connection, *, day: str | None = None, limit: int = 20
) -> list[dict[str, Any]]:
    """Most-mentioned entities overall, or within one local calendar day."""
    if day is None:
        rows = con.execute(
            """
            SELECT id, kind, name, normalized, first_seen, last_seen, mention_count
              FROM entities
             ORDER BY mention_count DESC, last_seen DESC
             LIMIT ?
            """,
            (limit,),
        ).fetchall()
        return [dict(r) for r in rows]

    start, end = day_bounds(day)
    rows = con.execute(
        """
        SELECT en.id, en.kind, en.name, en.normalized, en.first_seen, en.last_seen,
               COUNT(DISTINCT em.atom_id) AS mention_count
          FROM entities en
          JOIN entity_mentions em ON em.entity_id = en.id
          JOIN context_events e ON e.id = em.event_id
         WHERE e.timestamp >= ? AND e.timestamp < ?
         GROUP BY en.id
         ORDER BY mention_count DESC, en.last_seen DESC
         LIMIT ?
        """,
        (start, end, limit),
    ).fetchall()
    return [dict(r) for r in rows]
