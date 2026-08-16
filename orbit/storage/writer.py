import sqlite3
import threading
import json
from datetime import datetime, timezone
from typing import Any

from orbit.storage.session import require_active_user_id

# Plan 48 §4.3 dedup guard: how many prior events (walking backward from the
# new event, stopping at the first app/window change) to scan for already-seen
# (element_hash, text) atom keys before appending a duplicate row. Bounded so
# an idle window with a long unbroken run of identical captures doesn't force
# an unbounded backward scan; ORDER BY id DESC LIMIT N is a cheap rowid walk.
_DEDUP_LOOKBACK_EVENTS = 200


def _recent_unchanged_window_atom_keys(
    con: sqlite3.Connection,
    *,
    before_event_id: int,
    app_bundle_id: Any,
    window_title: Any,
) -> set[tuple[Any, str]]:
    """Atom (element_hash, text) keys already recorded for the unbroken run of
    prior events sharing this event's (app_bundle_id, window_title)."""
    same_window_event_ids: list[int] = []
    for row in con.execute(
        """SELECT id, app_bundle_id, window_title FROM context_events
           WHERE id < ? ORDER BY id DESC LIMIT ?""",
        (before_event_id, _DEDUP_LOOKBACK_EVENTS),
    ):
        if row[1] != app_bundle_id or row[2] != window_title:
            break
        same_window_event_ids.append(row[0])
    if not same_window_event_ids:
        return set()
    placeholders = ",".join("?" * len(same_window_event_ids))
    keys: set[tuple[Any, str]] = set()
    for element_hash, text in con.execute(
        f"SELECT element_hash, text FROM text_atoms WHERE event_id IN ({placeholders})",
        same_window_event_ids,
    ):
        keys.add((element_hash, text))
    return keys


def record_event(
    con: sqlite3.Connection,
    lock: threading.Lock,
    event_dict: dict[str, Any],
    atoms: list[dict[str, Any]],
) -> tuple[int, list[int | None]]:
    user_id = require_active_user_id()
    with lock:
        con.execute("BEGIN IMMEDIATE")
        cur = con.execute(
            """INSERT INTO context_events
               (user_id, timestamp, app_bundle_id, app_name, window_title,
                focused_element_role, focused_element_label, visible_text, raw_json,
                capture_method, capture_tier, page_url)
               VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?, ?)""",
            (
                user_id,
                event_dict.get("timestamp"),
                event_dict.get("app_bundle_id"),
                event_dict.get("app_name"),
                event_dict.get("window_title"),
                event_dict.get("focused_element_role"),
                event_dict.get("focused_element_label"),
                event_dict.get("visible_text"),
                json.dumps(event_dict.get("raw_json")),
                event_dict.get("capture_method", "ax"),
                event_dict.get("capture_tier", 1),
                event_dict.get("page_url"),
            ),
        )
        event_id = cur.lastrowid
        seen_keys = _recent_unchanged_window_atom_keys(
            con,
            before_event_id=event_id,
            app_bundle_id=event_dict.get("app_bundle_id"),
            window_title=event_dict.get("window_title"),
        )
        atom_ids: list[int | None] = []
        for atom in atoms:
            key = (atom.get("element_hash"), atom.get("text", ""))
            if key in seen_keys:
                # Same element_hash/text already recorded for this unchanged
                # window -- skip the duplicate row (Plan 48 §4.3).
                atom_ids.append(None)
                continue
            cur2 = con.execute(
                """INSERT INTO text_atoms (event_id, role, label, text, element_path, element_hash)
                   VALUES (?, ?, ?, ?, ?, ?)""",
                (
                    event_id,
                    atom.get("role", ""),
                    atom.get("label"),
                    atom.get("text", ""),
                    atom.get("element_path", ""),
                    atom.get("element_hash"),
                ),
            )
            atom_ids.append(cur2.lastrowid)
            seen_keys.add(key)
        con.execute(
            """INSERT INTO capture_audit
               (user_id, timestamp, capture_method, capture_tier, atom_count, app_bundle_id)
               VALUES (?, ?, ?, ?, ?, ?)""",
            (
                user_id,
                event_dict.get("timestamp") or datetime.now(timezone.utc).isoformat(),
                event_dict.get("capture_method", "ax"),
                event_dict.get("capture_tier", 1),
                len(atoms),
                event_dict.get("app_bundle_id"),
            ),
        )
        con.execute("COMMIT")
    return event_id, atom_ids

def record_embeddings(
    con: sqlite3.Connection,
    lock: threading.Lock,
    atom_ids: list[int],
    vectors: list[bytes],
) -> None:
    with lock:
        con.execute("BEGIN IMMEDIATE")
        con.executemany(
            "INSERT INTO vec_atoms(rowid, embedding) VALUES (?, ?)",
            list(zip(atom_ids, vectors)),
        )
        con.execute("COMMIT")
