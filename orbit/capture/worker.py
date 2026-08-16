from __future__ import annotations

import datetime
import logging
import queue
import time
from typing import Any

from orbit.capture.ax_walker import count_tree_nodes, get_app_metadata, get_tree
from orbit.capture.browser_hints import BROWSER_AX_HINT
from orbit.capture.extract import flatten_text_atoms
from orbit.capture.ocr import ocr_lines_to_atoms, ocr_window_text
from orbit.capture.policy import CapturePolicy, load_policy
from orbit.capture.profiles import CHROMIUM_SETTLE_S, is_chromium_bundle, profile_depth_for
from orbit.storage.writer import record_event

logger = logging.getLogger(__name__)

# Tier 5 rate limit: min seconds between OCR samples per bundle
_OCR_MIN_INTERVAL_S = 60.0
# Cap atoms per event to limit DB + embed work on deep Electron trees
_MAX_ATOMS_PER_EVENT = 300


def _find_window_title(tree: dict) -> str | None:
    stack = [tree]
    while stack:
        node = stack.pop()
        if not isinstance(node, dict):
            continue
        if node.get("role") == "AXWindow":
            return node.get("name") or node.get("title")
        stack.extend(node.get("children") or [])
    return None


def _record_metadata_event(
    con,
    lock,
    *,
    bundle: str,
    app_name: str,
    pid: int | None,
    window_title: str | None,
    reason: str,
) -> None:
    visible = window_title or app_name or bundle
    ev_dict: dict[str, Any] = {
        "timestamp": datetime.datetime.now(datetime.UTC).isoformat(),
        "app_bundle_id": bundle,
        "app_name": app_name,
        "window_title": window_title,
        "focused_element_role": None,
        "focused_element_label": reason,
        "visible_text": visible,
        "raw_json": None,
        "capture_method": "metadata_only",
        "capture_tier": 0,
    }
    event_id, _ = record_event(con, lock, ev_dict, [])
    logger.info(
        "Captured event %d for %s (metadata_only, reason=%s, pid=%s)",
        event_id,
        bundle,
        reason,
        pid,
    )


def _tree_storage_summary(node_count: int, depth: int) -> dict[str, Any]:
    """Lightweight raw_json — full AX tree lives only in text_atoms."""
    return {"node_count": node_count, "depth": depth, "tree_stored": False}


def _try_ocr_capture(
    con,
    lock,
    *,
    bundle: str,
    app_name: str,
    pid: int | None,
    window_title: str | None,
    reason: str,
    policy: CapturePolicy,
    ocr_last: dict[str, float],
    embed_queue: queue.Queue | None,
) -> bool:
    """Tier 4/5 OCR fallback. Returns True if OCR event was stored."""
    if not policy.ocr_allowed_for(bundle):
        return False

    now = time.monotonic()
    last = ocr_last.get(bundle, 0.0)
    if now - last < _OCR_MIN_INTERVAL_S:
        logger.debug("ocr rate-limited for %s", bundle)
        return False

    tier = 4
    if policy.tier_screenshot and policy.ocr_allowlist and bundle in policy.ocr_allowlist:
        tier = 5
    elif not policy.tier_ocr:
        return False

    ocr_last[bundle] = now

    lines = ocr_window_text(pid or 0)
    if not lines:
        return False

    atoms = ocr_lines_to_atoms(lines)
    visible = " | ".join(lines[:5])
    ev_dict: dict[str, Any] = {
        "timestamp": datetime.datetime.now(datetime.UTC).isoformat(),
        "app_bundle_id": bundle,
        "app_name": app_name,
        "window_title": window_title,
        "focused_element_role": "ocr",
        "focused_element_label": reason,
        "visible_text": visible,
        "raw_json": {"ocr_lines": len(lines), "trigger": reason},
        "capture_method": "ocr",
        "capture_tier": tier,
    }
    try:
        event_id, atom_ids = record_event(con, lock, ev_dict, atoms)
        logger.info(
            "Captured event %d for %s (ocr tier=%s, %d lines, trigger=%s)",
            event_id,
            bundle,
            tier,
            len(lines),
            reason,
        )
    except Exception:
        logger.exception("record_event failed for ocr %s", bundle)
        return False

    if embed_queue is not None:
        for aid, atom in zip(atom_ids, atoms):
            if aid is not None:
                embed_queue.put((event_id, aid, atom["text"]))
    return True


def _handle_ax_failure(
    con,
    lock,
    *,
    bundle: str,
    app_name: str,
    pid: int | None,
    window_title: str | None,
    reason: str,
    policy: CapturePolicy,
    ocr_last: dict[str, float],
    embed_queue: queue.Queue | None,
) -> None:
    if _try_ocr_capture(
        con,
        lock,
        bundle=bundle,
        app_name=app_name,
        pid=pid,
        window_title=window_title,
        reason=reason,
        policy=policy,
        ocr_last=ocr_last,
        embed_queue=embed_queue,
    ):
        return
    _record_metadata_event(
        con,
        lock,
        bundle=bundle,
        app_name=app_name,
        pid=pid,
        window_title=window_title,
        reason=reason,
    )


def run_capture_worker(
    focus_queue: queue.Queue,
    embed_queue: queue.Queue | None,
    con,
    lock,
    max_depth: int | None = None,
    policy: CapturePolicy | None = None,
    on_capture_start=None,
    on_capture_done=None,
) -> None:
    policy = policy or load_policy()
    ocr_last: dict[str, float] = {}
    logger.info(
        "Capture worker started (ocr=%s, screenshot_tier=%s)",
        policy.tier_ocr,
        policy.tier_screenshot,
    )
    while True:
        try:
            event = focus_queue.get(timeout=1.0)
        except queue.Empty:
            # Keep pause/exclusion toggles live while idle.
            policy.apply_runtime_controls(load_policy())
            continue
        if event is None:
            break

        policy.apply_runtime_controls(load_policy())
        if policy.capture_paused:
            logger.debug("Skip capture: paused")
            continue

        bundle = event["bundle_id"]
        app_name = event["app_name"]
        pid = event.get("pid")

        if policy.is_bundle_blocked(bundle):
            logger.info("Skip %s (%s): excluded", bundle, app_name)
            continue

        depth = profile_depth_for(bundle, override=max_depth)

        try:
            if on_capture_start:
                on_capture_start()
            if is_chromium_bundle(bundle):
                time.sleep(CHROMIUM_SETTLE_S)
            tree = get_tree(pid, max_depth=depth, bundle_id=bundle)
            if on_capture_done:
                on_capture_done()
        except Exception:
            logger.exception("get_tree failed for %s", bundle)
            meta = get_app_metadata(pid)
            _handle_ax_failure(
                con,
                lock,
                bundle=bundle,
                app_name=app_name,
                pid=pid,
                window_title=meta.get("window_title"),
                reason="get_tree_error",
                policy=policy,
                ocr_last=ocr_last,
                embed_queue=embed_queue,
            )
            continue

        node_count = count_tree_nodes(tree)
        if not tree:
            meta = get_app_metadata(pid)
            logger.info(
                "Skip %s (%s): empty_tree pid=%s depth=%s window=%r",
                bundle,
                app_name,
                pid,
                depth,
                meta.get("window_title"),
            )
            if is_chromium_bundle(bundle):
                logger.warning(BROWSER_AX_HINT)
            _handle_ax_failure(
                con,
                lock,
                bundle=bundle,
                app_name=app_name,
                pid=pid,
                window_title=meta.get("window_title"),
                reason="empty_tree",
                policy=policy,
                ocr_last=ocr_last,
                embed_queue=embed_queue,
            )
            continue

        atoms = flatten_text_atoms(tree, policy=policy)
        if len(atoms) > _MAX_ATOMS_PER_EVENT:
            logger.info(
                "Truncating %s atoms to %d for %s",
                len(atoms),
                _MAX_ATOMS_PER_EVENT,
                bundle,
            )
            atoms = atoms[:_MAX_ATOMS_PER_EVENT]
        if not atoms:
            window_title = _find_window_title(tree) or get_app_metadata(pid).get("window_title")
            logger.info(
                "Skip %s (%s): zero_atoms pid=%s depth=%s nodes=%s window=%r",
                bundle,
                app_name,
                pid,
                depth,
                node_count,
                window_title,
            )
            _handle_ax_failure(
                con,
                lock,
                bundle=bundle,
                app_name=app_name,
                pid=pid,
                window_title=window_title,
                reason="zero_atoms",
                policy=policy,
                ocr_last=ocr_last,
                embed_queue=embed_queue,
            )
            continue

        window_title = _find_window_title(tree)
        if not window_title:
            window_title = get_app_metadata(pid).get("window_title")

        visible_texts = [a["text"] for a in atoms[:5]]
        capture_method = "ax_enhanced" if depth > 12 else "ax"

        ev_dict: dict[str, Any] = {
            "timestamp": datetime.datetime.now(datetime.UTC).isoformat(),
            "app_bundle_id": bundle,
            "app_name": app_name,
            "window_title": window_title,
            "focused_element_role": atoms[0]["role"] if atoms else None,
            "focused_element_label": atoms[0]["label"] if atoms else None,
            "visible_text": " | ".join(visible_texts),
            "raw_json": _tree_storage_summary(node_count, depth),
            "capture_method": capture_method,
            "capture_tier": 1,
        }

        try:
            event_id, atom_ids = record_event(con, lock, ev_dict, atoms)
            logger.info(
                "Captured event %d for %s (%d atoms, depth=%s, method=%s)",
                event_id,
                bundle,
                len(atoms),
                depth,
                capture_method,
            )
        except Exception:
            logger.exception("record_event failed for %s", bundle)
            continue

        if embed_queue is not None:
            for aid, atom in zip(atom_ids, atoms):
                if aid is not None:
                    embed_queue.put((event_id, aid, atom["text"]))
