"""Active Orbit user session — reads/writes ~/.orbit/session.json."""
from __future__ import annotations

import json
import os
import uuid
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

LEGACY_USER_ID = "legacy-local"
_SESSION_JSON = Path("~/.orbit/session.json").expanduser()
_DEFAULT_DB_PATH = "~/.orbit/orbit.db"


class NoActiveUserError(RuntimeError):
    """Raised when capture or writes require a signed-in user."""


@dataclass(frozen=True)
class UserSession:
    user_id: str
    email: str
    signed_in_at: str


def _ensure_orbit_dir() -> None:
    _SESSION_JSON.parent.mkdir(parents=True, exist_ok=True)


def get_active_session() -> UserSession | None:
    if not _SESSION_JSON.exists():
        return None
    try:
        raw = json.loads(_SESSION_JSON.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None
    if not isinstance(raw, dict):
        return None
    user_id = raw.get("user_id")
    if not user_id or not isinstance(user_id, str) or not user_id.strip():
        return None
    email = raw.get("email")
    signed_in_at = raw.get("signed_in_at")
    return UserSession(
        user_id=user_id.strip(),
        email=email.strip() if isinstance(email, str) else "",
        signed_in_at=signed_in_at if isinstance(signed_in_at, str) else "",
    )


def get_active_user_id() -> str | None:
    session = get_active_session()
    return session.user_id if session else None


def require_active_user_id() -> str:
    user_id = get_active_user_id()
    if not user_id:
        raise NoActiveUserError(
            "No active orbit user session. Complete sign-up in orbit access app "
            "or run: orbit auth sign-in --user-id <id> --email <email>"
        )
    return user_id


def set_active_user(user_id: str, email: str = "") -> None:
    _ensure_orbit_dir()
    payload = {
        "user_id": user_id,
        "email": email,
        "signed_in_at": datetime.now(timezone.utc).isoformat(),
    }
    _SESSION_JSON.write_text(json.dumps(payload, indent=2) + "\n", encoding="utf-8")
    os.chmod(_SESSION_JSON, 0o600)


def clear_session() -> None:
    if _SESSION_JSON.exists():
        _SESSION_JSON.unlink()


def legacy_user_email() -> str:
    username = os.environ.get("USER") or os.environ.get("USERNAME") or "local"
    return f"{username}@orbit.local"


def local_user_email(user_id: str) -> str:
    """Synthetic, non-routable address for a silently created local-only user.

    Same ``{$USER}@orbit.local`` shape as :func:`legacy_user_email`, but
    plus-addressed with a slice of the user id. That disambiguation is not
    cosmetic: ``users.email`` is ``NOT NULL UNIQUE`` (``storage/schema.sql``) and
    ``_ensure_legacy_user`` (``storage/db.py``) writes the *bare*
    ``legacy_user_email()`` address onto the ``legacy-local`` row on **every**
    database open, so that address is always taken by the time we get here.

    ``.local`` is reserved by RFC 6762 and never routable, so a local-only
    identity can never be accidentally mailed — plan 53 §0.5A. "Has a cloud
    account" is ``cloud_user_id IS NOT NULL``, never an email test.
    """
    base = legacy_user_email()
    name, _, domain = base.partition("@")
    return f"{name}+{user_id[:8]}@{domain}"


def ensure_local_user(db_path: str = _DEFAULT_DB_PATH) -> str:
    """Mint a local-only identity when there is no active session. Idempotent.

    Plan 53 Phase 1: Orbit opens straight into the product, so a missing session
    is not an error to die on — it is an identity to create. Returns the active
    user id either way.

    Auto-creation lives **only** on the daemon-startup path (here, plus the
    ``orbit start`` wrapper that execs into it). :func:`require_active_user_id`
    must keep raising ``NoActiveUserError``, because ``storage/writer.py`` calls
    it on every capture write — auto-creating there would silently mint a user on
    any bug that clears the session.
    """
    existing = get_active_user_id()
    if existing:
        return existing

    user_id = str(uuid.uuid4())
    email = local_user_email(user_id)
    now = datetime.now(timezone.utc).isoformat()

    # Imported lazily: orbit.storage.db imports this module at its top level.
    from orbit.storage.db import open_db_plain

    path = os.path.expanduser(db_path)
    parent = os.path.dirname(path)
    if parent:
        os.makedirs(parent, exist_ok=True)

    con, _lock = open_db_plain(path)
    try:
        # SELECT-then-INSERT, mirroring `_ensure_legacy_user` (storage/db.py).
        row = con.execute("SELECT id FROM users WHERE id = ?", (user_id,)).fetchone()
        if row is None:
            con.execute(
                """
                INSERT INTO users (id, email, display_name, created_at, cloud_user_id)
                VALUES (?, ?, ?, ?, NULL)
                """,
                (user_id, email, "Local User", now),
            )
        con.execute(
            "INSERT OR REPLACE INTO user_sessions (user_id, last_active_at) "
            "VALUES (?, ?)",
            (user_id, now),
        )
        con.commit()
    finally:
        con.close()

    set_active_user(user_id, email=email)
    return user_id
