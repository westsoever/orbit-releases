"""Encryption key management for the Orbit context store.

The database (~/.orbit/orbit.db) is encrypted at rest via SQLCipher (see
``orbit/storage/db.py``). The passphrase is a random value generated once and
stored in the macOS Keychain via the ``keyring`` package — never written into
``~/.orbit/policy.json`` or any other plaintext config file alongside the
database it protects.

Losing the Keychain item (Keychain reset, migrating to a new Mac without a
Keychain backup, etc.) means the encrypted database can no longer be opened —
there is no vendor-side key escrow, the same trade-off Signal Desktop makes
for its own SQLCipher-encrypted store. The one mitigation is the recovery
file written the first time a key is generated; see ``_write_recovery_file``.
"""
from __future__ import annotations

import os
import secrets
from pathlib import Path

SERVICE_NAME = "Orbit Context Store"
ACCOUNT_NAME = "orbit-db-key"

_RECOVERY_FILE = Path("~/.orbit/RECOVERY-KEY.txt").expanduser()

_RECOVERY_FILE_TEMPLATE = """\
Orbit database recovery key
============================

This is the only copy of the passphrase protecting your local Orbit database
(~/.orbit/orbit.db). It is also stored in your macOS Keychain under the
service name "{service}" — Orbit reads it from there automatically and does
not need this file for normal use.

Keep this file somewhere safe if you want a way to recover your data should
the Keychain entry ever be lost (Keychain reset, migrating to a new Mac
without a Keychain backup, etc.). There is no other way to recover this key
if both copies are lost — the database would be permanently unreadable.

Key: {key}
"""


def _write_recovery_file(key: str) -> None:
    _RECOVERY_FILE.parent.mkdir(parents=True, exist_ok=True)
    _RECOVERY_FILE.write_text(
        _RECOVERY_FILE_TEMPLATE.format(service=SERVICE_NAME, key=key),
        encoding="utf-8",
    )
    os.chmod(_RECOVERY_FILE, 0o600)


def get_or_create_db_key() -> str:
    """Return the passphrase used to encrypt ~/.orbit/orbit.db.

    Resolution order:

    1. ``ORBIT_DB_KEY`` env var — test/CI escape hatch so automated test runs
       never touch a real machine's Keychain. Do not set this for a real
       install; anyone who can read the process environment can read the key.
    2. macOS Keychain via ``keyring`` — the normal path for a real install.
    3. A freshly generated key, stored to the Keychain and written once to a
       local recovery file (see module docstring) since this is the only
       moment the plaintext key is ever available to write down.
    """
    override = os.environ.get("ORBIT_DB_KEY")
    if override:
        return override

    import keyring

    existing = keyring.get_password(SERVICE_NAME, ACCOUNT_NAME)
    if existing:
        return existing

    new_key = secrets.token_urlsafe(32)
    keyring.set_password(SERVICE_NAME, ACCOUNT_NAME, new_key)
    _write_recovery_file(new_key)
    return new_key


def quote_pragma_string(value: str) -> str:
    """Single-quote a value for use directly in a PRAGMA statement.

    PRAGMA statements do not accept bound parameters (``PRAGMA key = ?``
    raises a syntax error), so the key has to be interpolated into the SQL
    text. Escaping embedded single quotes keeps this safe even though the
    keys this module generates (``secrets.token_urlsafe``) never contain one.
    """
    return "'" + value.replace("'", "''") + "'"
