"""macOS notification via osascript — zero extra deps."""
from __future__ import annotations
import subprocess


def notify(title: str, body: str) -> None:
    safe_title = title.replace('"', '\\"')
    safe_body = body.replace('"', '\\"')
    script = f'display notification "{safe_body}" with title "{safe_title}" sound name "Ping"'
    subprocess.run(["osascript", "-e", script], capture_output=True)
