"""Assemble a context window from Orbit's own captures.

Pure SQL + string assembly — no LLM call, no embeddings. The output is the text
blob ``detect_tasks()`` consumes when ``orbit check --source capture`` runs, so
task detection reads real captured context instead of a third-party file.

Assembly rules:

- Query ``context_events`` joined to ``text_atoms`` for the window, newest first
  (same join/column shape as :mod:`orbit.search.lexical`).
- Group by ``app_bundle_id`` + ``window_title``; within a group keep the longest
  ``_MAX_ATOMS_PER_GROUP`` atoms (mirrors the per-event truncation policy at
  ``orbit/capture/worker.py:269``).
- Append ``fs_events`` rows in the window as a "Files touched" block — path and
  ``event_type`` only.
- Prefix each block with its ``orbit://event/<id>`` link so every claim derived
  from it stays resolvable.
- Hard-stop at ``max_chars``, oldest block dropped first.
"""
from __future__ import annotations

import sqlite3
import threading
from datetime import datetime, timedelta, timezone

from orbit.storage.links import event_uri

# Longest N atoms kept per (app_bundle_id, window_title) group.
_MAX_ATOMS_PER_GROUP = 25
# Per-atom clamp; long documents should not crowd out other apps.
_MAX_ATOM_CHARS = 400
# Atoms shorter than this are decorative (single glyphs, separators).
_MIN_ATOM_CHARS = 3
# Safety valve on the raw row scan.
_MAX_ROWS = 20000
# Rows in the "Files touched" block.
_MAX_FS_ROWS = 40
# Fraction of max_chars reserved for the "Files touched" block.
_FS_BUDGET_RATIO = 0.2

_HEADER = "# Orbit capture window"


def _window_start(since_hours: float) -> str:
    """UTC ISO-8601 lower bound, matching what the capture workers write."""
    return (datetime.now(timezone.utc) - timedelta(hours=since_hours)).isoformat()


def _clean(text: str | None) -> str:
    if not text:
        return ""
    collapsed = " ".join(text.split())
    if len(collapsed) > _MAX_ATOM_CHARS:
        collapsed = collapsed[:_MAX_ATOM_CHARS].rstrip() + "…"
    return collapsed


def _render_group(group: dict) -> str:
    app = group["app_name"] or group["bundle"] or "unknown app"
    title = group["window_title"] or "(no window title)"
    lines = [
        f"## {app} — {title}",
        f"{group['latest_ts']} · {group['bundle'] or 'unknown.bundle'} · "
        f"{len(group['event_ids'])} capture(s) · {event_uri(group['latest_event_id'])}",
    ]
    if group["page_url"]:
        lines.append(f"url: {group['page_url']}")

    kept = sorted(group["atoms"], key=lambda a: len(a[1]), reverse=True)
    kept = kept[:_MAX_ATOMS_PER_GROUP]
    kept.sort(key=lambda a: a[0])  # restore capture order
    for _, text, label in kept:
        # `label` is an element-kind hint ("text", "text field", "shell").
        # The generic "text" carries no signal — don't spend budget on it.
        if label and label != text and label.lower() != "text":
            lines.append(f"- [{label}] {text}")
        else:
            lines.append(f"- {text}")
    return "\n".join(lines)


def _render_fs_block(rows: list[sqlite3.Row]) -> str:
    if not rows:
        return ""
    lines = ["## Files touched"]
    seen: set[tuple[str, str]] = set()
    for row in rows:
        key = (row["event_type"], row["path"])
        if key in seen:
            continue
        seen.add(key)
        lines.append(f"- {row['event_type']}: {row['path']}")
    return "\n".join(lines)


def build_context_window(
    con: sqlite3.Connection,
    lock: threading.Lock,
    *,
    user_id: str,
    since_hours: float = 8.0,
    max_chars: int = 12000,
) -> tuple[str, list[int]]:
    """Return (assembled_text, source context_events.id values).

    ``user_id`` is required, not optional-and-defaulting-to-everyone: this
    feeds an LLM prompt with "the user's own recent activity", and without
    the filter it silently spans every user's captures ever stored in the
    same database. Callers resolve it via ``orbit.storage.session`` before
    calling in (see ``orbit/check/context.py::read_capture``).

    Deterministic and side-effect free. Returns ``("", [])`` when the window
    holds no captured text.
    """
    start = _window_start(since_hours)

    with lock:
        rows = con.execute(
            """
            SELECT a.id  AS atom_id,
                   a.event_id,
                   a.role, a.label, a.text,
                   e.app_bundle_id, e.app_name, e.window_title, e.timestamp,
                   e.page_url
              FROM text_atoms a
              JOIN context_events e ON e.id = a.event_id
             WHERE e.timestamp >= :start
               AND e.user_id = :user_id
             ORDER BY e.timestamp DESC, a.id ASC
             LIMIT :limit
            """,
            {"start": start, "user_id": user_id, "limit": _MAX_ROWS},
        ).fetchall()
        fs_rows = con.execute(
            """
            SELECT timestamp, path, event_type
              FROM fs_events
             WHERE timestamp >= :start
               AND user_id = :user_id
             ORDER BY timestamp DESC
             LIMIT :limit
            """,
            {"start": start, "user_id": user_id, "limit": _MAX_FS_ROWS},
        ).fetchall()

    # ── group by app + window title, newest group first ──────────────
    groups: dict[tuple[str | None, str | None], dict] = {}
    order: list[tuple[str | None, str | None]] = []
    for row in rows:
        text = _clean(row["text"])
        if len(text) < _MIN_ATOM_CHARS:
            continue
        key = (row["app_bundle_id"], row["window_title"])
        group = groups.get(key)
        if group is None:
            group = {
                "bundle": row["app_bundle_id"],
                "app_name": row["app_name"],
                "window_title": row["window_title"],
                "latest_ts": row["timestamp"],
                "latest_event_id": row["event_id"],
                "page_url": row["page_url"],
                "event_ids": [],
                "seen_events": set(),
                "seen_text": set(),
                "atoms": [],
            }
            groups[key] = group
            order.append(key)
        if row["event_id"] not in group["seen_events"]:
            group["seen_events"].add(row["event_id"])
            group["event_ids"].append(row["event_id"])
        if text in group["seen_text"]:
            continue
        group["seen_text"].add(text)
        group["atoms"].append((row["atom_id"], text, _clean(row["label"])))

    fs_block = _render_fs_block(fs_rows)
    fs_budget = min(len(fs_block), int(max_chars * _FS_BUDGET_RATIO)) if fs_block else 0

    blocks: list[str] = []
    event_ids: list[int] = []
    used = len(_HEADER) + 1
    for key in order:
        group = groups[key]
        if not group["atoms"]:
            continue
        block = _render_group(group)
        cost = len(block) + 2
        if used + cost + fs_budget > max_chars:
            break  # remaining groups are older — oldest-dropped-first
        blocks.append(block)
        event_ids.extend(group["event_ids"])
        used += cost

    if not blocks and not fs_block:
        return "", []

    if fs_block and used + len(fs_block) + 2 <= max_chars:
        blocks.append(fs_block)

    text = _HEADER + "\n\n" + "\n\n".join(blocks) + "\n"
    return text, event_ids
