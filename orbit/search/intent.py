"""Formal intent classifier for chat queries.

Pure Python, deterministic (regex + SQL only) — no LLM calls, no side effects
on import. `classify_query` is the orchestrator other modules should call;
`resolve_app_name`, `extract_app_from_query`, and `resolve_entity_from_query`
are exposed individually per the API contract in
`plans/37-parallel-execution.md`.
"""

from __future__ import annotations

import re
import sqlite3
from dataclasses import dataclass
from enum import Enum


class ChatIntent(Enum):
    RECAP = "recap"  # "What did I work on today?"
    SEARCH = "search"  # "find billing notes"
    APP_SCOPED = "app_scoped"  # "What did I do in Cursor today?"
    ENTITY = "entity"  # "What did I work on with Sarah?"
    HYBRID = "hybrid"  # "What billing work did I do today?"


@dataclass
class ParsedQuery:
    intent: ChatIntent
    original: str
    app_bundle_id: str | None = None
    app_name: str | None = None
    entity_id: int | None = None
    entity_name: str | None = None
    topic: str | None = None
    day: str | None = None
    since: str | None = None
    until: str | None = None


_APP_PATTERN = re.compile(
    r"\b(?:in|on|using|with|from)\s+(?:the\s+)?"
    r"(?!(?:in|on|using|with|from|today|yesterday|this|last|earlier|now|recently)\b)"
    r"([A-Z][A-Za-z0-9\s]{0,25}?)"
    r"(?:\s+(?:today|yesterday|this|last|earlier|now|recently)|[?.!,]|$)",
    re.IGNORECASE,
)

_ENTITY_PATTERN = re.compile(
    r"\b(?:with|about|related to|regarding|for)\s+(?:the\s+)?([A-Za-z][A-Za-z0-9\s]{0,30}?)"
    r"(?:\s+(?:today|yesterday|this|last|project|work)|[?.!,]|$)",
    re.IGNORECASE,
)


# Words carrying no topic signal: interrogatives, recap verbs, temporal
# phrases, and pronouns/articles. What survives a strip of these is the topic.
_TOPIC_STOPWORDS = frozenset(
    """
    a about accomplish accomplished afternoon all am an and any anything are as at
    been being did do does doing done earlier evening everything for from get
    getting go going got had happen happened happening has have i in into is it
    its last me miss missed morning much my night now of on over past recap
    recently remind show since so summarise summarize summary tell that the their
    them then there these this those to today up us was we week weekend were what
    whats when where which while who with work worked working yesterday you your
    day days
    """.split()
)


def extract_topic(query: str) -> str | None:
    """Residual content words after stripping temporal/verb/stopword noise.

    Used only to distinguish HYBRID ("What billing work did I do today?") from
    plain RECAP ("What did I work on today?"). Deterministic, no LLM.
    """
    if not query:
        return None
    words = re.findall(r"[A-Za-z][A-Za-z0-9'-]*", query)
    residual = [w for w in words if w.lower() not in _TOPIC_STOPWORDS]
    if not residual:
        return None
    return " ".join(residual)


def resolve_app_name(con: sqlite3.Connection, name: str) -> tuple[str, str] | None:
    """Fuzzy-match a human-typed app name against known apps in context_events.

    Match priority: exact case-insensitive > unambiguous prefix > substring
    fallback. Returns (canonical_app_name, app_bundle_id) or None.
    """
    if not name or not name.strip():
        return None

    rows = con.execute(
        """
        SELECT app_name, app_bundle_id, COUNT(*) AS cnt
          FROM context_events
         WHERE app_name IS NOT NULL
         GROUP BY app_bundle_id
         ORDER BY cnt DESC
        """
    ).fetchall()

    if not rows:
        return None

    apps: list[tuple[str, str]] = [(r[0], r[1]) for r in rows]
    needle = name.strip().lower()

    # 1. Exact case-insensitive match.
    for app_name, bundle_id in apps:
        if app_name and app_name.lower() == needle:
            return (app_name, bundle_id)

    # 2. Unambiguous prefix match.
    prefix_matches = [
        (app_name, bundle_id)
        for app_name, bundle_id in apps
        if app_name and app_name.lower().startswith(needle)
    ]
    if len(prefix_matches) == 1:
        return prefix_matches[0]
    if len(prefix_matches) > 1:
        return prefix_matches[0]

    # 3. Substring fallback.
    substring_matches = [
        (app_name, bundle_id)
        for app_name, bundle_id in apps
        if app_name and needle in app_name.lower()
    ]
    if substring_matches:
        return substring_matches[0]

    return None


def extract_app_from_query(query: str) -> str | None:
    """Extract a likely app name from natural language. No DB access."""
    if not query:
        return None
    match = _APP_PATTERN.search(query)
    if not match:
        return None
    captured = match.group(1).strip()
    return captured or None


def resolve_entity_from_query(
    con: sqlite3.Connection, query: str
) -> tuple[int, str] | None:
    """Extract entity references and resolve against the entities table."""
    if not query:
        return None
    match = _ENTITY_PATTERN.search(query)
    if not match:
        return None
    captured = match.group(1).strip()
    if not captured:
        return None

    normalized = captured.lower().strip()
    row = con.execute(
        """
        SELECT id, name, kind, mention_count
          FROM entities
         WHERE normalized LIKE ?
         ORDER BY mention_count DESC
         LIMIT 1
        """,
        (f"%{normalized}%",),
    ).fetchone()

    if row is None:
        return None
    return (row[0], row[1])


def classify_query(con: sqlite3.Connection, query: str) -> ParsedQuery:
    """Deterministic intent classifier — no LLM, no side effects."""
    from orbit.memory.digest import (
        digest_day_from_query,
        is_temporal_recap_query,
        parse_chat_time_window,
    )

    temporal = is_temporal_recap_query(query)
    app_raw = extract_app_from_query(query)
    app_resolved = resolve_app_name(con, app_raw) if app_raw else None
    entity_resolved = resolve_entity_from_query(con, query)

    topic = extract_topic(query) if temporal else None
    day = digest_day_from_query(query) if temporal else None
    since, until = parse_chat_time_window(query)

    # Intent decision tree
    if entity_resolved:
        intent = ChatIntent.ENTITY
    elif temporal and app_resolved:
        intent = ChatIntent.APP_SCOPED
    elif temporal and topic:
        # Temporal *and* topic-specific — combine day frame with topic search.
        intent = ChatIntent.HYBRID
    elif temporal:
        intent = ChatIntent.RECAP
    else:
        intent = ChatIntent.SEARCH

    return ParsedQuery(
        intent=intent,
        original=query,
        app_bundle_id=app_resolved[1] if app_resolved else None,
        app_name=app_resolved[0] if app_resolved else None,
        entity_id=entity_resolved[0] if entity_resolved else None,
        entity_name=entity_resolved[1] if entity_resolved else None,
        topic=topic,
        day=day,
        since=since,
        until=until,
    )
