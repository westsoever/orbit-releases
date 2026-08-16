from __future__ import annotations
import sqlite3

from orbit.storage.session import get_active_user_id


def resolve(con: sqlite3.Connection, uri: str, user_id: str | None = None) -> dict:
    uid = user_id if user_id is not None else get_active_user_id()
    if uri.startswith("orbit://atom/"):
        atom_id = int(uri.removeprefix("orbit://atom/"))
        if uid:
            row = con.execute(
                """SELECT a.*, e.app_bundle_id, e.app_name, e.window_title, e.timestamp, e.raw_json
                     FROM text_atoms a JOIN context_events e ON e.id = a.event_id
                    WHERE a.id = ? AND e.user_id = ?""",
                [atom_id, uid],
            ).fetchone()
        else:
            row = con.execute(
                """SELECT a.*, e.app_bundle_id, e.app_name, e.window_title, e.timestamp, e.raw_json
                     FROM text_atoms a JOIN context_events e ON e.id = a.event_id
                    WHERE a.id = ?""",
                [atom_id],
            ).fetchone()
    elif uri.startswith("orbit://event/"):
        event_id = int(uri.removeprefix("orbit://event/"))
        if uid:
            row = con.execute(
                "SELECT * FROM context_events WHERE id = ? AND user_id = ?",
                [event_id, uid],
            ).fetchone()
        else:
            row = con.execute(
                "SELECT * FROM context_events WHERE id = ?", [event_id]
            ).fetchone()
    else:
        raise ValueError(f"Unknown URI scheme: {uri!r}")
    return dict(row) if row else {}
