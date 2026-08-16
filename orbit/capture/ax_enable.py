"""
Enable Chromium/Electron renderer accessibility trees on macOS.

Pattern from Electron accessibility tutorial:
https://electronjs.org/docs/latest/tutorial/accessibility#macos
"""
from __future__ import annotations

import logging
import time

from ApplicationServices import (
    AXUIElementCreateApplication,
    AXUIElementSetAttributeValue,
    kAXErrorSuccess,
)
from CoreFoundation import kCFRunLoopDefaultMode, CFRunLoopRunInMode

logger = logging.getLogger(__name__)

_ATTR_MANUAL = "AXManualAccessibility"
_ATTR_ENHANCED = "AXEnhancedUserInterface"

_enabled_pids: set[int] = set()


def _set_bool_attr(app, attr: str) -> bool:
    try:
        err = AXUIElementSetAttributeValue(app, attr, True)
    except Exception:
        logger.debug("AXUIElementSetAttributeValue(%s) raised", attr, exc_info=True)
        return False
    return err == kAXErrorSuccess


def _settle_run_loop(seconds: float = 0.3) -> None:
    deadline = time.monotonic() + seconds
    while time.monotonic() < deadline:
        CFRunLoopRunInMode(kCFRunLoopDefaultMode, 0.05, False)


def enable_renderer_accessibility(pid: int, *, chromium: bool = False) -> bool:
    """Opt in target app's renderer AX tree (once per pid per process lifetime)."""
    if pid in _enabled_pids:
        return True
    if not pid or pid <= 0:
        return False
    try:
        app = AXUIElementCreateApplication(int(pid))
    except Exception:
        logger.debug("AXUIElementCreateApplication failed pid=%s", pid, exc_info=True)
        return False

    ok = _set_bool_attr(app, _ATTR_MANUAL)
    if not ok:
        ok = _set_bool_attr(app, _ATTR_ENHANCED)
    if ok:
        _settle_run_loop(0.5 if chromium else 0.3)
        _enabled_pids.add(pid)
        logger.debug("Renderer accessibility enabled for pid=%s chromium=%s", pid, chromium)
    else:
        logger.debug("Could not enable renderer accessibility for pid=%s", pid)
    return ok


def ensure_renderer_accessibility(pid: int, *, bundle_id: str | None = None) -> bool:
    """Public entry: enable if not already attempted for this pid."""
    from orbit.capture.profiles import is_chromium_bundle

    chromium = bool(bundle_id and is_chromium_bundle(bundle_id))
    return enable_renderer_accessibility(pid, chromium=chromium)
