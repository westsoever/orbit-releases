from __future__ import annotations

import queue
import logging
import sqlite3
import threading
import time
from typing import Callable
import sqlite_vec
from sentence_transformers import SentenceTransformer
from orbit.storage.writer import record_embeddings

logger = logging.getLogger(__name__)

_MODEL: SentenceTransformer | None = None
_MODEL_LOCK = threading.Lock()

def _get_model() -> SentenceTransformer:
    global _MODEL
    if _MODEL is None:
        with _MODEL_LOCK:
            if _MODEL is None:
                try:
                    _MODEL = SentenceTransformer("sentence-transformers/all-MiniLM-L6-v2", local_files_only=True)
                except Exception:
                    _MODEL = SentenceTransformer("sentence-transformers/all-MiniLM-L6-v2")
                logger.info("Embedding model loaded on device: %s", _MODEL.device)
    return _MODEL

def run_embedding_worker(
    embed_queue: queue.Queue,
    con,
    lock,
    flush_ms: float = 200,
    batch_max: int = 32,
) -> None:
    logger.info("Embedding worker started")
    while True:
        batch = []
        deadline = time.monotonic() + flush_ms / 1000.0
        try:
            item = embed_queue.get(timeout=flush_ms / 1000.0)
            if item is None:
                break
            batch.append(item)
            while len(batch) < batch_max:
                remaining = deadline - time.monotonic()
                if remaining <= 0:
                    break
                try:
                    item = embed_queue.get(timeout=remaining)
                    if item is None:
                        embed_queue.put(None)
                        break
                    batch.append(item)
                except queue.Empty:
                    break
        except queue.Empty:
            continue

        if not batch:
            continue

        try:
            texts = [t for (_, _, t) in batch]
            model = _get_model()
            vectors = model.encode(texts, normalize_embeddings=True)
            payload = [sqlite_vec.serialize_float32(v.tolist()) for v in vectors]
            atom_ids = [aid for (_, aid, _) in batch]
            record_embeddings(con, lock, atom_ids, payload)
            logger.debug("Embedded %d atoms", len(batch))
        except Exception:
            logger.exception("Embedding batch failed")


def count_unembedded_atoms(con: sqlite3.Connection) -> int:
    """Atoms in `text_atoms` with no matching row in `vec_atoms`.

    Non-zero whenever the daemon has ever run with `--no-embed`: nothing
    re-queues atoms captured while the embedding worker was off, so they stay
    invisible to semantic search until backfilled.
    """
    row = con.execute(
        "SELECT COUNT(*) FROM text_atoms a"
        " WHERE NOT EXISTS (SELECT 1 FROM vec_atoms v WHERE v.rowid = a.id)"
    ).fetchone()
    return row[0]


def backfill_embeddings(
    con: sqlite3.Connection,
    lock: threading.Lock,
    batch_size: int = 256,
    on_progress: Callable[[int, int], None] | None = None,
) -> int:
    """Embed every atom missing a `vec_atoms` row. Returns the number embedded.

    Safe to interrupt and re-run — each batch commits via `record_embeddings`
    before the next SELECT, so a Ctrl-C loses at most one in-flight batch.
    """
    total = count_unembedded_atoms(con)
    if total == 0:
        return 0

    model = _get_model()
    done = 0
    while True:
        rows = con.execute(
            "SELECT a.id, a.text FROM text_atoms a"
            " WHERE NOT EXISTS (SELECT 1 FROM vec_atoms v WHERE v.rowid = a.id)"
            " AND a.text IS NOT NULL AND a.text != ''"
            " ORDER BY a.id LIMIT ?",
            (batch_size,),
        ).fetchall()
        if not rows:
            break

        atom_ids = [r[0] for r in rows]
        texts = [r[1] for r in rows]
        vectors = model.encode(texts, normalize_embeddings=True)
        payload = [sqlite_vec.serialize_float32(v.tolist()) for v in vectors]
        record_embeddings(con, lock, atom_ids, payload)
        done += len(rows)
        if on_progress is not None:
            on_progress(done, total)

    # Atoms with NULL/empty text can never be embedded; skip them so the loop
    # above terminates instead of re-selecting the same rows forever.
    skipped = con.execute(
        "SELECT COUNT(*) FROM text_atoms a"
        " WHERE NOT EXISTS (SELECT 1 FROM vec_atoms v WHERE v.rowid = a.id)"
    ).fetchone()[0]
    if skipped:
        logger.info("Backfill skipped %d atoms with empty text", skipped)

    return done
