"""Privacy utilities — export, delete, retention (GDPR Art. 15/17)."""

from __future__ import annotations

import json
from datetime import datetime, timedelta, timezone
from pathlib import Path
from sqlcipher3 import dbapi2 as sqlite3

# Connections passed into this module come from orbit.storage.db, which opens
# them via sqlcipher3 (see orbit/storage/crypto.py) — imported here under the
# `sqlite3` name so the `except sqlite3.Error` clauses below actually match
# the exception classes those connections raise. sqlcipher3's are a separate
# class hierarchy from stdlib sqlite3's, not a subclass, so importing stdlib
# `sqlite3` here would silently stop catching real errors.

from orbit.storage.session import get_active_user_id

__all__ = [
    "export_capture_data",
    "delete_all_capture_data",
    "purge_older_than",
    "purge_recent_minutes",
]


def _user_clause(user_id: str | None) -> tuple[str, list]:
    if user_id:
        return " WHERE user_id = ?", [user_id]
    return "", []


def export_capture_data(
    con: sqlite3.Connection, out_path: Path, user_id: str | None = None
) -> int:
    """Export context_events + text_atoms (+ sessions) as JSONL. Returns row count."""
    uid = user_id if user_id is not None else get_active_user_id()
    where, params = _user_clause(uid)
    count = 0
    with out_path.open("w", encoding="utf-8") as f:
        for row in con.execute(
            f"SELECT * FROM context_events{where} ORDER BY id", params
        ):
            event = dict(row)
            eid = event["id"]
            atoms = [
                dict(a)
                for a in con.execute(
                    "SELECT * FROM text_atoms WHERE event_id = ? ORDER BY id", (eid,)
                )
            ]
            f.write(json.dumps({"event": event, "atoms": atoms}, default=str) + "\n")
            count += 1
        try:
            for row in con.execute("SELECT * FROM sessions ORDER BY id"):
                sess = dict(row)
                sid = sess["id"]
                event_ids = [
                    r[0]
                    for r in con.execute(
                        "SELECT event_id FROM session_events WHERE session_id = ?",
                        (sid,),
                    )
                ]
                # When scoped to a user, only export sessions that touch that user's events.
                if uid and event_ids:
                    placeholders = ",".join("?" * len(event_ids))
                    owned = con.execute(
                        f"SELECT 1 FROM context_events WHERE id IN ({placeholders}) AND user_id = ? LIMIT 1",
                        [*event_ids, uid],
                    ).fetchone()
                    if owned is None:
                        continue
                elif uid:
                    continue
                f.write(
                    json.dumps(
                        {"session": sess, "event_ids": event_ids},
                        default=str,
                    )
                    + "\n"
                )
                count += 1
        except sqlite3.Error:
            pass
        try:
            for row in con.execute("SELECT * FROM entities ORDER BY id"):
                entity = dict(row)
                entity_id = entity["id"]
                mentions = [
                    dict(m)
                    for m in con.execute(
                        "SELECT * FROM entity_mentions WHERE entity_id = ? ORDER BY atom_id",
                        (entity_id,),
                    )
                ]
                # When scoped to a user, only export entities that touch that user's events.
                if uid and mentions:
                    atom_ids = [m["atom_id"] for m in mentions]
                    placeholders = ",".join("?" * len(atom_ids))
                    owned = con.execute(
                        f"SELECT 1 FROM text_atoms a JOIN context_events e "
                        f"ON e.id = a.event_id WHERE a.id IN ({placeholders}) "
                        f"AND e.user_id = ? LIMIT 1",
                        [*atom_ids, uid],
                    ).fetchone()
                    if owned is None:
                        continue
                elif uid:
                    continue
                f.write(
                    json.dumps({"entity": entity, "mentions": mentions}, default=str)
                    + "\n"
                )
                count += 1
        except sqlite3.Error:
            pass
    return count


def delete_all_capture_data(con: sqlite3.Connection, user_id: str | None = None) -> None:
    uid = user_id if user_id is not None else get_active_user_id()
    if uid:
        event_ids = [
            r[0]
            for r in con.execute(
                "SELECT id FROM context_events WHERE user_id = ?", (uid,)
            ).fetchall()
        ]
        if event_ids:
            _delete_events_by_ids(con, event_ids)
        try:
            con.execute("DELETE FROM fs_events WHERE user_id = ?", (uid,))
        except sqlite3.Error:
            pass
        try:
            con.execute("DELETE FROM capture_audit WHERE user_id = ?", (uid,))
        except sqlite3.Error:
            pass
        return

    try:
        con.execute("DELETE FROM entity_mentions")
    except sqlite3.Error:
        pass
    try:
        con.execute("DELETE FROM entities")
    except sqlite3.Error:
        pass
    try:
        con.execute("DELETE FROM session_events")
    except sqlite3.Error:
        pass
    try:
        con.execute("DELETE FROM sessions")
    except sqlite3.Error:
        pass
    con.execute("DELETE FROM text_atoms")
    try:
        con.execute("DELETE FROM fs_events")
    except sqlite3.Error:
        pass
    con.execute("DELETE FROM context_events")
    try:
        con.execute("DELETE FROM vec_atoms")
    except sqlite3.Error:
        pass
    try:
        con.execute("DELETE FROM capture_audit")
    except sqlite3.Error:
        pass
    con.execute("DELETE FROM atoms_fts")


def _delete_events_by_ids(con: sqlite3.Connection, ids: list[int]) -> int:
    """Delete context_events (and related rows) by id. Returns deleted event count."""
    if not ids:
        return 0
    placeholders = ",".join("?" * len(ids))
    atom_ids = [
        r[0]
        for r in con.execute(
            f"SELECT id FROM text_atoms WHERE event_id IN ({placeholders})", ids
        ).fetchall()
    ]
    if atom_ids:
        atom_ph = ",".join("?" * len(atom_ids))
        try:
            con.execute(
                f"DELETE FROM vec_atoms WHERE rowid IN ({atom_ph})", atom_ids
            )
        except sqlite3.Error:
            pass
        try:
            con.execute(
                f"DELETE FROM entity_mentions WHERE atom_id IN ({atom_ph})", atom_ids
            )
        except sqlite3.Error:
            pass
    try:
        con.execute(
            f"DELETE FROM session_events WHERE event_id IN ({placeholders})", ids
        )
    except sqlite3.Error:
        pass
    con.execute(f"DELETE FROM text_atoms WHERE event_id IN ({placeholders})", ids)
    con.execute(f"DELETE FROM context_events WHERE id IN ({placeholders})", ids)
    try:
        con.execute(
            """
            DELETE FROM sessions
             WHERE id NOT IN (SELECT DISTINCT session_id FROM session_events)
            """
        )
    except sqlite3.Error:
        pass
    try:
        con.execute(
            """
            DELETE FROM entities
             WHERE id NOT IN (SELECT DISTINCT entity_id FROM entity_mentions)
            """
        )
    except sqlite3.Error:
        pass
    return len(ids)


def purge_older_than(
    con: sqlite3.Connection, days: int, user_id: str | None = None
) -> int:
    """Delete events older than ``days``. Returns deleted event count."""
    cutoff = (datetime.now(timezone.utc) - timedelta(days=days)).isoformat()
    uid = user_id if user_id is not None else get_active_user_id()
    if uid:
        ids = [
            r[0]
            for r in con.execute(
                "SELECT id FROM context_events WHERE user_id = ? AND timestamp < ?",
                (uid, cutoff),
            ).fetchall()
        ]
    else:
        ids = [
            r[0]
            for r in con.execute(
                "SELECT id FROM context_events WHERE timestamp < ?", (cutoff,)
            ).fetchall()
        ]
    n = _delete_events_by_ids(con, ids)
    try:
        if uid:
            con.execute(
                "DELETE FROM fs_events WHERE user_id = ? AND timestamp < ?",
                (uid, cutoff),
            )
            con.execute(
                "DELETE FROM capture_audit WHERE user_id = ? AND timestamp < ?",
                (uid, cutoff),
            )
        else:
            con.execute("DELETE FROM fs_events WHERE timestamp < ?", (cutoff,))
            con.execute("DELETE FROM capture_audit WHERE timestamp < ?", (cutoff,))
    except sqlite3.Error:
        pass
    return n


def purge_recent_minutes(
    con: sqlite3.Connection, minutes: int, user_id: str | None = None
) -> int:
    """Delete events from the last ``minutes``. Returns deleted event count."""
    if minutes <= 0:
        return 0
    cutoff = (datetime.now(timezone.utc) - timedelta(minutes=minutes)).isoformat()
    uid = user_id if user_id is not None else get_active_user_id()
    if uid:
        ids = [
            r[0]
            for r in con.execute(
                "SELECT id FROM context_events WHERE user_id = ? AND timestamp >= ?",
                (uid, cutoff),
            ).fetchall()
        ]
    else:
        ids = [
            r[0]
            for r in con.execute(
                "SELECT id FROM context_events WHERE timestamp >= ?", (cutoff,)
            ).fetchall()
        ]
    n = _delete_events_by_ids(con, ids)
    try:
        if uid:
            con.execute(
                "DELETE FROM fs_events WHERE user_id = ? AND timestamp >= ?",
                (uid, cutoff),
            )
            con.execute(
                "DELETE FROM capture_audit WHERE user_id = ? AND timestamp >= ?",
                (uid, cutoff),
            )
        else:
            con.execute("DELETE FROM fs_events WHERE timestamp >= ?", (cutoff,))
            con.execute("DELETE FROM capture_audit WHERE timestamp >= ?", (cutoff,))
    except sqlite3.Error:
        pass
    return n
