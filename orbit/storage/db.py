"""SQLite connection helpers for the Orbit context store.

Two open paths:

- ``open_db`` — loads the sqlite-vec extension and creates the ``vec_atoms`` virtual
  table. Requires a Python build with loadable SQLite extensions (Homebrew Python on
  macOS; not the python.org installer). See https://alexgarcia.xyz/sqlite-vec/python.html
- ``open_db_plain`` — schema without vec0; used for capture-only mode (``--no-embed``)
  or when extensions are unavailable.

Use ``sqlite_supports_extensions()`` to probe capability before calling ``open_db``.

Both paths connect through ``sqlcipher3`` rather than stdlib ``sqlite3`` so the
database file is encrypted at rest (see ``orbit/storage/crypto.py`` for the key).
An existing plaintext database from before this was added is migrated in place
the first time it's opened — see ``_migrate_plaintext_to_encrypted``.
"""
import os
import sqlite3
import sys
import threading
import sqlite_vec
from datetime import datetime, timezone
from pathlib import Path
from sqlcipher3 import dbapi2 as sqlcipher

from orbit.runtime import sqlite_supports_extensions
from orbit.storage.crypto import get_or_create_db_key, quote_pragma_string
from orbit.storage.session import LEGACY_USER_ID, legacy_user_email

_SCHEMA = Path(__file__).parent / "schema.sql"


def _extension_error() -> RuntimeError:
    return RuntimeError(
        "This Python build cannot load SQLite extensions (required for sqlite-vec embeddings).\n"
        "Fix: activate the project venv and verify with its `python`, not system `python3`:\n"
        "  source .venv/bin/activate\n"
        "  python -c \"import sqlite3; sqlite3.connect(':memory:').enable_load_extension(True)\"\n"
        "If the venv is missing or broken, recreate it:\n"
        "  brew install python@3.13\n"
        "  /opt/homebrew/bin/python3.13 -m venv .venv && source .venv/bin/activate && pip install -e .\n"
        "Or run capture-only:\n"
        "  orbit start --no-embed\n"
        f"Current interpreter: {sys.executable}\n"
        "See: https://alexgarcia.xyz/sqlite-vec/python.html"
    )

def _table_names(con: sqlite3.Connection) -> set[str]:
    return {
        r[0]
        for r in con.execute(
            "SELECT name FROM sqlite_master WHERE type='table'"
        ).fetchall()
    }


def _ensure_legacy_user(con: sqlite3.Connection) -> None:
    row = con.execute(
        "SELECT id FROM users WHERE id = ?", (LEGACY_USER_ID,)
    ).fetchone()
    if row is not None:
        return
    now = datetime.now(timezone.utc).isoformat()
    con.execute(
        """
        INSERT INTO users (id, email, display_name, created_at, cloud_user_id)
        VALUES (?, ?, ?, ?, NULL)
        """,
        (LEGACY_USER_ID, legacy_user_email(), "Legacy User", now),
    )


def _migrate_user_schema(con: sqlite3.Connection) -> None:
    tables = _table_names(con)
    if "users" not in tables:
        con.executescript(
            """
            CREATE TABLE users (
              id TEXT PRIMARY KEY,
              email TEXT NOT NULL UNIQUE,
              display_name TEXT NOT NULL,
              created_at TEXT NOT NULL,
              cloud_user_id TEXT
            );
            CREATE TABLE user_sessions (
              user_id TEXT PRIMARY KEY REFERENCES users(id) ON DELETE CASCADE,
              last_active_at TEXT NOT NULL
            );
            """
        )
    _ensure_legacy_user(con)

    user_tables = (
        ("context_events", "idx_events_user_ts"),
        ("fs_events", "idx_fs_events_user_ts"),
        ("capture_audit", "idx_capture_audit_user_ts"),
        ("task_log", "idx_task_log_user_ts"),
    )
    for table, index_name in user_tables:
        if table not in _table_names(con):
            continue
        cols = {row[1] for row in con.execute(f"PRAGMA table_info({table})")}
        if "user_id" not in cols:
            con.execute(
                f"ALTER TABLE {table} ADD COLUMN user_id TEXT REFERENCES users(id)"
            )
            con.execute(
                f"UPDATE {table} SET user_id = ? WHERE user_id IS NULL",
                (LEGACY_USER_ID,),
            )
            con.execute(
                f"CREATE INDEX IF NOT EXISTS {index_name} ON {table}(user_id, timestamp)"
            )


def _migrate_schema(con: sqlite3.Connection) -> None:
    cols = {row[1] for row in con.execute("PRAGMA table_info(context_events)")}
    if "capture_method" not in cols:
        con.execute(
            "ALTER TABLE context_events ADD COLUMN capture_method TEXT DEFAULT 'ax'"
        )
    if "capture_tier" not in cols:
        con.execute(
            "ALTER TABLE context_events ADD COLUMN capture_tier INTEGER DEFAULT 1"
        )
    if "page_url" not in cols:
        con.execute("ALTER TABLE context_events ADD COLUMN page_url TEXT")

    tables = _table_names(con)
    if "fs_events" not in tables:
        con.executescript(
            """
            CREATE TABLE fs_events (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              timestamp TEXT NOT NULL,
              path TEXT NOT NULL,
              event_type TEXT NOT NULL,
              mtime REAL,
              linked_event_id INTEGER REFERENCES context_events(id) ON DELETE SET NULL,
              capture_tier INTEGER DEFAULT 3
            );
            CREATE INDEX idx_fs_events_ts ON fs_events(timestamp);
            CREATE INDEX idx_fs_events_linked ON fs_events(linked_event_id);
            """
        )
    if "capture_audit" not in tables:
        con.executescript(
            """
            CREATE TABLE capture_audit (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              timestamp TEXT NOT NULL,
              capture_method TEXT NOT NULL,
              capture_tier INTEGER NOT NULL,
              atom_count INTEGER NOT NULL,
              app_bundle_id TEXT
            );
            CREATE INDEX idx_capture_audit_ts ON capture_audit(timestamp);
            """
        )
    if "llm_calls" not in tables:
        con.executescript(
            """
            CREATE TABLE llm_calls (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              timestamp TEXT NOT NULL,
              call_site TEXT NOT NULL,
              provider TEXT NOT NULL,
              model TEXT,
              prompt_chars INTEGER NOT NULL,
              response_chars INTEGER,
              latency_ms INTEGER,
              ok INTEGER NOT NULL,
              error TEXT
            );
            CREATE INDEX idx_llm_calls_ts ON llm_calls(timestamp);
            """
        )

    if "task_log" in tables:
        task_cols = {row[1] for row in con.execute("PRAGMA table_info(task_log)")}
        if "result_path" not in task_cols:
            con.execute("ALTER TABLE task_log ADD COLUMN result_path TEXT")
        if "result_preview" not in task_cols:
            con.execute("ALTER TABLE task_log ADD COLUMN result_preview TEXT")
        if "confidence" not in task_cols:
            con.execute("ALTER TABLE task_log ADD COLUMN confidence REAL")
    if "sessions" not in tables:
        con.executescript(
            """
            CREATE TABLE sessions (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              started_at TEXT NOT NULL,
              ended_at TEXT NOT NULL,
              primary_bundle_id TEXT,
              primary_app_name TEXT,
              event_count INTEGER NOT NULL,
              atom_count INTEGER NOT NULL,
              switch_count INTEGER NOT NULL,
              title TEXT,
              summary TEXT
            );
            CREATE INDEX idx_sessions_started ON sessions(started_at);
            CREATE UNIQUE INDEX idx_sessions_started_unique ON sessions(started_at);
            """
        )
    else:
        # Existing installs may lack the uniqueness guard used for idempotent upserts.
        indexes = {
            r[0]
            for r in con.execute(
                "SELECT name FROM sqlite_master WHERE type='index'"
            ).fetchall()
        }
        if "idx_sessions_started_unique" not in indexes:
            con.execute(
                "CREATE UNIQUE INDEX IF NOT EXISTS idx_sessions_started_unique "
                "ON sessions(started_at)"
            )
    if "session_events" not in tables:
        con.executescript(
            """
            CREATE TABLE session_events (
              session_id INTEGER NOT NULL REFERENCES sessions(id) ON DELETE CASCADE,
              event_id INTEGER NOT NULL REFERENCES context_events(id) ON DELETE CASCADE,
              PRIMARY KEY (session_id, event_id)
            );
            """
        )
    if "entities" not in tables:
        con.executescript(
            """
            CREATE TABLE entities (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              kind TEXT NOT NULL,
              name TEXT NOT NULL,
              normalized TEXT NOT NULL,
              first_seen TEXT NOT NULL,
              last_seen TEXT NOT NULL,
              mention_count INTEGER NOT NULL DEFAULT 0,
              UNIQUE(kind, normalized)
            );
            """
        )
    if "entity_mentions" not in tables:
        con.executescript(
            """
            CREATE TABLE entity_mentions (
              entity_id INTEGER NOT NULL REFERENCES entities(id) ON DELETE CASCADE,
              atom_id INTEGER NOT NULL REFERENCES text_atoms(id) ON DELETE CASCADE,
              event_id INTEGER NOT NULL REFERENCES context_events(id) ON DELETE CASCADE,
              PRIMARY KEY (entity_id, atom_id)
            );
            CREATE INDEX idx_entity_mentions_event ON entity_mentions(event_id);
            """
        )
    if "mcp_calls" not in tables:
        con.executescript(
            """
            CREATE TABLE mcp_calls (
              id INTEGER PRIMARY KEY AUTOINCREMENT,
              user_id TEXT NOT NULL REFERENCES users(id),
              tool_name TEXT NOT NULL,
              timestamp TEXT NOT NULL,
              result_count INTEGER NOT NULL
            );
            CREATE INDEX idx_mcp_calls_ts ON mcp_calls(timestamp);
            """
        )

    _migrate_user_schema(con)


def _apply_schema(con: sqlite3.Connection, skip_vec: bool = False) -> None:
    sql = _SCHEMA.read_text()
    if skip_vec:
        # Filter whole statements that reference vec0/vec_atoms
        statements = [s.strip() for s in sql.split(";") if s.strip()]
        sql = ";\n".join(
            s for s in statements
            if "vec0" not in s and "vec_atoms" not in s
        ) + ";"
    con.executescript(sql)
    _migrate_schema(con)


def _is_plaintext(path: str) -> bool:
    """True if the file at ``path`` is a readable, unencrypted SQLite database.

    A nonexistent path (brand new install) is not plaintext — there's nothing
    to migrate, ``open_db``/``open_db_plain`` just create a fresh encrypted file.
    """
    if not os.path.exists(path):
        return False
    try:
        con = sqlite3.connect(f"file:{path}?mode=ro", uri=True)
        try:
            con.execute("SELECT count(*) FROM sqlite_master")
        finally:
            con.close()
        return True
    except sqlite3.DatabaseError:
        return False


def _migrate_plaintext_to_encrypted(path: str, key: str) -> None:
    """Convert an existing plaintext database to SQLCipher-encrypted, in place.

    Uses SQLCipher's documented ``sqlcipher_export()`` path: attach a freshly
    keyed database alongside the plaintext one, copy everything into it, verify
    every table's row count matches before trusting the copy, then swap it in.
    No plaintext backup is left on disk — either the migration is verified and
    the original is replaced, or it's aborted and the original is untouched.
    """
    tmp_path = path + ".encrypting-tmp"
    if os.path.exists(tmp_path):
        os.remove(tmp_path)

    plain = sqlcipher.connect(path, isolation_level=None)
    try:
        plain.execute("ATTACH DATABASE ? AS encrypted KEY ?", (tmp_path, key))
        plain.execute("SELECT sqlcipher_export('encrypted')")
        plain.execute("DETACH DATABASE encrypted")
    finally:
        plain.close()

    # sqlcipher3, not stdlib sqlite3: SQLCipher reads a genuinely plaintext file
    # fine with no PRAGMA key (it auto-detects unencrypted pages), and this keeps
    # src/dst on the SAME native SQLite build. Loading the sqlite-vec extension
    # onto a stdlib sqlite3 connection and a sqlcipher3 connection in the same
    # process corrupts a global API pointer inside vec0 (confirmed by direct
    # repro: identical code segfaults with stdlib sqlite3.connect() for src,
    # works fine with sqlcipher.connect()) — loading it twice onto two
    # connections from the *same* library is safe, mixed libraries are not.
    src = sqlcipher.connect(path)
    dst = sqlcipher.connect(tmp_path, isolation_level=None)
    try:
        dst.execute(f"PRAGMA key = {quote_pragma_string(key)};")
        # A pre-existing plaintext DB may already have vec_atoms (a sqlite-vec
        # virtual table) from before encryption was added. Row-count verification
        # below queries every table in sqlite_master, including that one, so both
        # connections need the extension loaded first — same pattern as open_db().
        if sqlite_supports_extensions():
            for con in (src, dst):
                con.enable_load_extension(True)
                sqlite_vec.load(con)
                con.enable_load_extension(False)
        tables = [
            r[0]
            for r in src.execute(
                "SELECT name FROM sqlite_master WHERE type='table' "
                "AND name NOT LIKE 'sqlite_%'"
            ).fetchall()
        ]
        for table in tables:
            src_count = src.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()[0]
            dst_count = dst.execute(f'SELECT COUNT(*) FROM "{table}"').fetchone()[0]
            if src_count != dst_count:
                os.remove(tmp_path)
                raise RuntimeError(
                    f"Encryption migration verification failed for table {table!r}: "
                    f"{src_count} rows in the plaintext database, {dst_count} in the "
                    "encrypted copy. Aborting migration; the original plaintext file "
                    "was left untouched."
                )
    finally:
        src.close()
        dst.close()

    os.replace(tmp_path, path)


def _connect_encrypted(path: str, key: str) -> sqlcipher.Connection:
    if _is_plaintext(path):
        _migrate_plaintext_to_encrypted(path, key)
    con = sqlcipher.connect(path, check_same_thread=False, isolation_level=None)
    con.execute(f"PRAGMA key = {quote_pragma_string(key)};")
    return con


def open_db_plain(path: str) -> tuple[sqlcipher.Connection, threading.Lock]:
    """Open the context DB without sqlite-vec (FTS + relational tables only)."""
    con = _connect_encrypted(path, get_or_create_db_key())
    con.row_factory = sqlcipher.Row
    con.execute("PRAGMA journal_mode=WAL;")
    con.execute("PRAGMA synchronous=NORMAL;")
    con.execute("PRAGMA foreign_keys=ON;")
    _apply_schema(con, skip_vec=True)
    return con, threading.Lock()


def open_db(path: str) -> tuple[sqlcipher.Connection, threading.Lock]:
    """Open the context DB with sqlite-vec loaded and ``vec_atoms`` created."""
    if not sqlite_supports_extensions():
        raise _extension_error()
    con = _connect_encrypted(path, get_or_create_db_key())
    con.row_factory = sqlcipher.Row
    con.enable_load_extension(True)
    sqlite_vec.load(con)
    con.enable_load_extension(False)
    con.execute("PRAGMA journal_mode=WAL;")
    con.execute("PRAGMA synchronous=NORMAL;")
    con.execute("PRAGMA foreign_keys=ON;")
    _apply_schema(con)
    lock = threading.Lock()
    return con, lock
