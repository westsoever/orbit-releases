"""Local bridge auth token — protects mutating task routes on localhost."""
from __future__ import annotations

import secrets
from pathlib import Path

TOKEN_PATH = Path("~/.orbit/bridge.token").expanduser()


def write_bridge_token(token: str) -> None:
    TOKEN_PATH.parent.mkdir(parents=True, exist_ok=True)
    TOKEN_PATH.write_text(token, encoding="utf-8")
    TOKEN_PATH.chmod(0o600)


def load_bridge_token() -> str | None:
    if not TOKEN_PATH.exists():
        return None
    token = TOKEN_PATH.read_text(encoding="utf-8").strip()
    return token or None


def generate_bridge_token() -> str:
    token = secrets.token_urlsafe(32)
    write_bridge_token(token)
    return token


def ensure_bridge_token() -> str:
    existing = load_bridge_token()
    if existing:
        return existing
    return generate_bridge_token()
