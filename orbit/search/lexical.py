from __future__ import annotations
import re
import sqlite3
from orbit.search.intent import _TOPIC_STOPWORDS
from orbit.search.types import Hit

_FTS_TOKEN = re.compile(r"[^\W_]+", re.UNICODE)


def fts_match_query(query: str) -> str:
    """Turn free text into a syntactically valid FTS5 MATCH expression.

    FTS5 treats `?`, `-`, `*`, `:`, `"` and bare AND/OR/NOT/NEAR as query
    syntax, so a raw natural-language question ("What did I do in Cursor
    today?") raises `sqlite3.OperationalError: fts5: syntax error`. Each token
    is extracted and quoted as a phrase.

    Quoting every token and joining with FTS5's implicit AND (the previous
    behaviour) required *every* word of a natural-language question to appear
    verbatim in a single atom, so a six-word question returned zero hits
    unless all six words matched. Stopwords (reusing the shared list in
    `orbit.search.intent`, the same list `extract_topic` strips) carry no
    retrieval signal and are dropped; the remaining content tokens are
    OR'd together so a match on any one of them (e.g. "pricing") is enough.
    """
    tokens = _FTS_TOKEN.findall(query or "")
    if not tokens:
        return '""'
    if len(tokens) == 1:
        # A single search term is never noise, even when that exact word
        # doubles as a topic-extraction stopword (e.g. "working" — a real
        # literal search-box query, not a natural-language sentence).
        return f'"{tokens[0]}"'
    content_tokens = [t for t in tokens if t.lower() not in _TOPIC_STOPWORDS]
    if not content_tokens:
        return '""'
    return " OR ".join(f'"{t}"' for t in content_tokens)


def search_lexical(
    con: sqlite3.Connection,
    query: str,
    limit: int = 20,
    app_bundle_id: str | None = None,
    since: str | None = None,
    until: str | None = None,
    user_id: str | None = None,
) -> list[Hit]:
    user_clause = " AND e.user_id = :user_id" if user_id else ""
    rows = con.execute(
        f"""
        SELECT a.id  AS atom_id,
               a.event_id,
               a.role, a.label,
               e.app_bundle_id, e.app_name, e.window_title, e.timestamp,
               snippet(atoms_fts, 0, '<mark>', '</mark>', '…', 12) AS snippet_html,
               bm25(atoms_fts) AS score
          FROM atoms_fts
          JOIN text_atoms a    ON a.id = atoms_fts.rowid
          JOIN context_events e ON e.id = a.event_id
         WHERE atoms_fts MATCH :q
           AND (:bundle IS NULL OR e.app_bundle_id = :bundle)
           AND (:since IS NULL OR e.timestamp >= :since)
           AND (:until IS NULL OR e.timestamp < :until)
           {user_clause}
         ORDER BY score
         LIMIT :limit
        """,
        {
            "q": fts_match_query(query),
            "bundle": app_bundle_id,
            "since": since,
            "until": until,
            "limit": limit,
            "user_id": user_id,
        },
    ).fetchall()
    return [Hit.from_row(r) for r in rows]
