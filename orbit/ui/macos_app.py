"""macOS application policy helpers for background Orbit processes."""
from __future__ import annotations


def hide_from_dock() -> None:
    """Prevent a PyObjC process from appearing in the Dock.

    The capture daemon uses AppKit (NSWorkspace, AX APIs, optional NSStatusItem)
    but is not a user-facing app — Orbit Access owns the UI.
    """
    from AppKit import NSApplication, NSApplicationActivationPolicyAccessory

    app = NSApplication.sharedApplication()
    app.setActivationPolicy_(NSApplicationActivationPolicyAccessory)
