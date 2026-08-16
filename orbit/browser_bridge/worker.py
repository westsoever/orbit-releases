from __future__ import annotations

import datetime
import logging
import queue
from typing import Any

from orbit.storage.writer import record_event

logger = logging.getLogger(__name__)

# Skip internal browser pages — no useful context, may contain tokens in URL.
_BLOCKED_URL_PREFIXES = (
    "chrome://",
    "chrome-extension://",
    "devtools://",
    "about:",
    "edge://",
    "brave://",
)


def _blocked_url(url: str) -> bool:
    u = url.lower()
    return any(u.startswith(p) for p in _BLOCKED_URL_PREFIXES)


def _payload_to_atoms(payload: dict[str, Any]) -> list[dict[str, Any]]:
    atoms: list[dict[str, Any]] = []
    url = payload.get("url") or ""
    title = (payload.get("title") or "").strip()
    selection = (payload.get("selection") or "").strip()

    if url:
        atoms.append(
            {
                "role": "AXDocument",
                "label": "url",
                "text": url,
                "element_path": "/browser/url",
                "element_hash": None,
            }
        )
    if title:
        atoms.append(
            {
                "role": "AXStaticText",
                "label": "title",
                "text": title,
                "element_path": "/browser/title",
                "element_hash": None,
            }
        )
    if selection:
        atoms.append(
            {
                "role": "AXStaticText",
                "label": "selection",
                "text": selection[:2000],
                "element_path": "/browser/selection",
                "element_hash": None,
            }
        )
    return atoms


def run_browser_worker(
    browser_queue: queue.Queue,
    embed_queue: queue.Queue | None,
    con,
    lock,
) -> None:
    logger.info("Browser extension worker started")
    while True:
        try:
            payload = browser_queue.get(timeout=1.0)
        except queue.Empty:
            continue
        if payload is None:
            break

        url = str(payload.get("url") or "")
        if not url or _blocked_url(url):
            logger.debug("Skip browser event: blocked or empty url %r", url[:80])
            continue

        title = (payload.get("title") or "").strip()
        bundle = payload.get("bundle_id") or "browser.extension"
        app_name = payload.get("browser_name") or "Browser"
        tab_id = payload.get("tab_id")
        ts = payload.get("timestamp") or datetime.datetime.now(datetime.UTC).isoformat()

        atoms = _payload_to_atoms(payload)
        if not atoms:
            continue

        visible_parts = [title, url]
        selection = (payload.get("selection") or "").strip()
        if selection:
            visible_parts.append(selection[:200])

        ev_dict: dict[str, Any] = {
            "timestamp": ts,
            "app_bundle_id": bundle,
            "app_name": app_name,
            "window_title": title or url,
            "focused_element_role": "browser_tab",
            "focused_element_label": str(tab_id) if tab_id is not None else None,
            "visible_text": " | ".join(p for p in visible_parts if p),
            "raw_json": {
                "url": url,
                "title": title,
                "tab_id": tab_id,
                "selection_len": len(selection) if selection else 0,
            },
            "capture_method": "browser_ext",
            "capture_tier": 2,
            "page_url": url,
        }

        try:
            event_id, atom_ids = record_event(con, lock, ev_dict, atoms)
            logger.info(
                "Captured event %d from browser_ext (%s, tab=%s)",
                event_id,
                bundle,
                tab_id,
            )
        except Exception:
            logger.exception("record_event failed for browser_ext")
            continue

        if embed_queue is not None:
            for aid, atom in zip(atom_ids, atoms):
                if aid is not None:
                    embed_queue.put((event_id, aid, atom["text"]))
