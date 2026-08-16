"""
Focused-window OCR via Apple Vision (Tier 4).

Captures frontmost window for ``pid`` only; raster is not persisted.
Requires Screen Recording permission for the Orbit process (macOS 10.15+).

Spec: plans/completed/03-universal-capture.md Phase 3; orbit-context.md enhanced mode.
"""
from __future__ import annotations

import logging

logger = logging.getLogger(__name__)


def _window_id_for_pid(pid: int) -> int | None:
    from Quartz import CGWindowListCopyWindowInfo, kCGWindowListOptionOnScreenOnly, kCGNullWindowID

    for w in CGWindowListCopyWindowInfo(kCGWindowListOptionOnScreenOnly, kCGNullWindowID):
        if w.get("kCGWindowOwnerPID") != pid:
            continue
        if w.get("kCGWindowLayer") != 0:
            continue
        return int(w["kCGWindowNumber"])
    return None


def ocr_window_text(pid: int, *, max_lines: int = 200) -> list[str]:
    """Return OCR text lines from the app's main on-screen window."""
    if not pid or pid <= 0:
        return []

    window_id = _window_id_for_pid(pid)
    if window_id is None:
        logger.debug("ocr: no layer-0 window for pid=%s", pid)
        return []

    try:
        from Quartz import (
            CGWindowListCreateImage,
            CGRectNull,
            kCGWindowImageBoundsIgnoreFraming,
            kCGWindowListOptionIncludingWindow,
        )
        from Vision import VNImageRequestHandler, VNRecognizeTextRequest
    except ImportError:
        logger.warning("ocr: Vision/Quartz frameworks not installed")
        return []

    image = CGWindowListCreateImage(
        CGRectNull,
        kCGWindowListOptionIncludingWindow,
        window_id,
        kCGWindowImageBoundsIgnoreFraming,
    )
    if image is None:
        logger.info(
            "ocr: could not capture window pid=%s (grant Screen Recording in "
            "System Settings → Privacy & Security → Screen Recording)",
            pid,
        )
        return []

    handler = VNImageRequestHandler.alloc().initWithCGImage_options_(image, None)
    request = VNRecognizeTextRequest.alloc().init()
    ok, err = handler.performRequests_error_([request], None)
    if not ok:
        logger.debug("ocr: Vision request failed pid=%s err=%s", pid, err)
        return []

    lines: list[str] = []
    for observation in request.results() or []:
        candidates = observation.topCandidates_(1)
        if not candidates:
            continue
        text = str(candidates[0].string()).strip()
        if text:
            lines.append(text)
        if len(lines) >= max_lines:
            break
    return lines


def ocr_lines_to_atoms(lines: list[str]) -> list[dict]:
    atoms = []
    for i, line in enumerate(lines):
        atoms.append(
            {
                "role": "AXStaticText",
                "label": "ocr",
                "text": line,
                "element_path": f"/ocr/{i}",
                "element_hash": None,
            }
        )
    return atoms
