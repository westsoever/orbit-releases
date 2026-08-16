from __future__ import annotations
import sqlite_vec
from sentence_transformers import SentenceTransformer
from sqlcipher3 import dbapi2 as sqlite3
from orbit.search.types import Hit

# Connections here come from orbit.storage.db (sqlcipher3-backed, see
# orbit/storage/crypto.py) — imported under the `sqlite3` name so the
# `except sqlite3.OperationalError` below matches what those connections
# actually raise (sqlcipher3's exception classes aren't a subclass of
# stdlib sqlite3's).

_MODEL: SentenceTransformer | None = None

def _get_model() -> SentenceTransformer:
    global _MODEL
    if _MODEL is None:
        try:
            _MODEL = SentenceTransformer("sentence-transformers/all-MiniLM-L6-v2", local_files_only=True)
        except Exception:
            _MODEL = SentenceTransformer("sentence-transformers/all-MiniLM-L6-v2")
    return _MODEL

def _has_vec_atoms(con: sqlite3.Connection) -> bool:
    """True only if this connection can actually query vec_atoms.

    The table's sqlite_master row persists once created, even on a
    connection opened via open_db_plain() (--no-embed) that never loaded
    the vec0 extension. Checking schema presence alone is not enough —
    querying the virtual table without the extension loaded raises
    OperationalError: no such module: vec0.
    """
    try:
        con.execute("SELECT 1 FROM vec_atoms LIMIT 1")
    except sqlite3.OperationalError:
        return False
    return True


def search_bridge(
    con: sqlite3.Connection,
    query: str,
    limit: int = 20,
    app_bundle_id: str | None = None,
    since: str | None = None,
    until: str | None = None,
    user_id: str | None = None,
) -> list[Hit]:
    """Hybrid search when embeddings exist; lexical FTS otherwise (--no-embed)."""
    if _has_vec_atoms(con):
        return search_hybrid(
            con,
            query,
            limit=limit,
            app_bundle_id=app_bundle_id,
            since=since,
            until=until,
            user_id=user_id,
        )
    from orbit.search.lexical import search_lexical

    return search_lexical(
        con,
        query,
        limit=limit,
        app_bundle_id=app_bundle_id,
        since=since,
        until=until,
        user_id=user_id,
    )


def search_hybrid(
    con: sqlite3.Connection,
    query: str,
    limit: int = 20,
    app_bundle_id: str | None = None,
    since: str | None = None,
    until: str | None = None,
    user_id: str | None = None,
    k_each: int = 60,
    rrf_k: int = 60,
) -> list[Hit]:
    """Hybrid search using Reciprocal Rank Fusion of lexical and semantic results.

    sqlite-vec's vec0 virtual table cursors cannot be safely reused inside
    multi-reference CTEs, so we run the two searches as separate queries and
    fuse rankings in Python.
    """
    model = _get_model()
    qvec = sqlite_vec.serialize_float32(
        model.encode([query], normalize_embeddings=True)[0].tolist()
    )

    # Over-fetch when time/app filters may discard candidates at fetch time.
    fetch_n = limit * 5 if (since or until or app_bundle_id or user_id) else limit

    # --- 1. Semantic (vec) candidates ------------------------------------------
    vec_rows = con.execute(
        """
        SELECT rowid AS atom_id, distance
          FROM vec_atoms
         WHERE embedding MATCH ?
           AND k = ?
         ORDER BY distance
        """,
        [qvec, k_each],
    ).fetchall()

    # --- 2. Lexical (FTS) candidates -------------------------------------------
    from orbit.search.lexical import fts_match_query

    fts_rows = con.execute(
        f"""
        SELECT rowid AS atom_id, bm25(atoms_fts) AS score
          FROM atoms_fts
         WHERE atoms_fts MATCH ?
         ORDER BY score
         LIMIT {int(k_each)}
        """,
        [fts_match_query(query)],
    ).fetchall()

    # --- 3. RRF fusion in Python -----------------------------------------------
    rrf_scores: dict[int, float] = {}
    for rank, row in enumerate(vec_rows, start=1):
        aid = row["atom_id"]
        rrf_scores[aid] = rrf_scores.get(aid, 0.0) + 1.0 / (rrf_k + rank)
    for rank, row in enumerate(fts_rows, start=1):
        aid = row["atom_id"]
        rrf_scores[aid] = rrf_scores.get(aid, 0.0) + 1.0 / (rrf_k + rank)

    if not rrf_scores:
        return []

    ranked_ids = sorted(rrf_scores, key=lambda x: rrf_scores[x], reverse=True)[:fetch_n]

    # --- 4. Fetch full rows for the top-k atom IDs ----------------------------
    placeholders = ",".join("?" * len(ranked_ids))
    user_clause = " AND e.user_id = ?" if user_id else ""
    user_params: list = [user_id] if user_id else []
    rows = con.execute(
        f"""
        SELECT a.id AS atom_id, a.event_id, a.role, a.label,
               e.app_bundle_id, e.app_name, e.window_title, e.timestamp,
               a.text AS full_text
          FROM text_atoms a
          JOIN context_events e ON e.id = a.event_id
         WHERE a.id IN ({placeholders})
           AND (? IS NULL OR e.app_bundle_id = ?)
           AND (? IS NULL OR e.timestamp >= ?)
           AND (? IS NULL OR e.timestamp < ?)
           {user_clause}
        """,
        [
            *ranked_ids,
            app_bundle_id,
            app_bundle_id,
            since,
            since,
            until,
            until,
            *user_params,
        ],
    ).fetchall()

    # Map to dict for quick lookup, then order by RRF rank
    row_map = {r["atom_id"]: r for r in rows}
    result = []
    seen_texts: set[str] = set()
    for aid in ranked_ids:
        if aid not in row_map:
            continue
        r = row_map[aid]
        full_text = r["full_text"] or ""
        # Corpus has heavy near-duplication (repeated UI labels); collapse
        # near-duplicate text before truncating so the top-N window isn't
        # wasted on repeats of the same string. Normalise on whitespace and
        # case so trivially-different repeats ("Billing" / "billing ") also
        # collapse.
        dedup_key = " ".join(full_text.split()).casefold()
        if dedup_key and dedup_key in seen_texts:
            continue
        if dedup_key:
            seen_texts.add(dedup_key)
        # Snippet cap raised from 240 to 500: §0.3 measured 353 atoms over
        # 500 chars, and those are the substantive ones the 240-char cap was
        # truncating away; short atoms are unaffected.
        snippet_html = full_text[:500]
        # Build a synthetic row dict so Hit.from_row() works
        hit = Hit(
            atom_id=r["atom_id"],
            event_id=r["event_id"],
            atom_uri=f"orbit://atom/{r['atom_id']}",
            event_uri=f"orbit://event/{r['event_id']}",
            app_bundle_id=r["app_bundle_id"],
            app_name=r["app_name"],
            window_title=r["window_title"],
            timestamp=r["timestamp"],
            role=r["role"],
            label=r["label"],
            snippet_html=snippet_html,
            score=rrf_scores[aid],
        )
        result.append(hit)
        if len(result) >= limit:
            break
    return result
