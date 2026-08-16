"""Load Orbit Cloud AI relay credentials written by Orbit Access."""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

_CLOUD_JSON = Path("~/.orbit/cloud.json").expanduser()


@dataclass(frozen=True)
class CloudConfig:
    device_token: str
    relay_base_url: str


def load_cloud_config() -> CloudConfig | None:
    if not _CLOUD_JSON.exists():
        return None
    try:
        raw = json.loads(_CLOUD_JSON.read_text(encoding="utf-8"))
    except (json.JSONDecodeError, OSError):
        return None
    if not isinstance(raw, dict):
        return None
    token = raw.get("device_token")
    base_url = raw.get("relay_base_url")
    if not token or not base_url or not isinstance(token, str) or not isinstance(base_url, str):
        return None
    token = token.strip()
    base_url = base_url.strip()
    if not token or not base_url:
        return None
    return CloudConfig(device_token=token, relay_base_url=base_url)
