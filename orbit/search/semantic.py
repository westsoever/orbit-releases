from __future__ import annotations
import sqlite3
import sqlite_vec
from sentence_transformers import SentenceTransformer
from orbit.search.types import Hit

_MODEL: SentenceTransformer | None = None

def _get_model() -> SentenceTransformer:
    global _MODEL
    if _MODEL is None:
        try:
            _MODEL = SentenceTransformer("sentence-transformers/all-MiniLM-L6-v2", local_files_only=True)
        except Exception:
            _MODEL = SentenceTransformer("sentence-transformers/all-MiniLM-L6-v2")
    return _MODEL

def search_semantic(
    con: sqlite3.Connection,
    query: str,
    limit: int = 20,
    app_bundle_id: str | None = None,
    since: str | None = None,
    until: str | None = None,
) -> list[Hit]:
    model = _get_model()
    qvec = sqlite_vec.serialize_float32(
        model.encode([query], normalize_embeddings=True)[0].tolist()
    )
    rows = con.execute(
        """
        WITH knn AS (
          SELECT rowid, distance
            FROM vec_atoms
           WHERE embedding MATCH ?
           ORDER BY distance
           LIMIT ?
        )
        SELECT a.id AS atom_id, a.event_id, a.role, a.label,
               e.app_bundle_id, e.app_name, e.window_title, e.timestamp,
               substr(a.text, 1, 240) AS snippet_html,
               knn.distance AS score
          FROM knn
          JOIN text_atoms a    ON a.id = knn.rowid
          JOIN context_events e ON e.id = a.event_id
         WHERE (? IS NULL OR e.app_bundle_id = ?)
           AND (? IS NULL OR e.timestamp >= ?)
           AND (? IS NULL OR e.timestamp < ?)
         ORDER BY score
        """,
        [
            qvec,
            limit * 4,
            app_bundle_id,
            app_bundle_id,
            since,
            since,
            until,
            until,
        ],
    ).fetchall()
    return [Hit.from_row(r) for r in rows[:limit]]
