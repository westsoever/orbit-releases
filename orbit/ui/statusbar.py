"""
macOS menu bar status indicator for the Orbit capture daemon.
Uses NSStatusBar from pyobjc-framework-Cocoa (already installed).
Do NOT call NSApp.run() here — the daemon's NSRunLoop owns the main thread.
"""
from __future__ import annotations
from AppKit import (
    NSStatusBar,
    NSVariableStatusItemLength,
    NSMenu,
    NSMenuItem,
)

ICON_IDLE   = "○ orbit"
ICON_ACTIVE = "● orbit"
ICON_ERROR  = "× orbit"


class OrbitStatusBar:
    """Thin wrapper around NSStatusItem. Create on main thread; setTitle_ is
    thread-safe on macOS 10.14+ so worker callbacks can call set_* directly."""

    def __init__(self, quit_target=None):
        bar = NSStatusBar.systemStatusBar()
        self._item = bar.statusItemWithLength_(NSVariableStatusItemLength)
        self._item.button().setTitle_(ICON_IDLE)
        self._item.setHighlightMode_(True)

        menu = NSMenu.alloc().init()
        quit_item = NSMenuItem.alloc().initWithTitle_action_keyEquivalent_(
            "quit orbit", "terminate:", "q"
        )
        menu.addItem_(quit_item)
        self._item.setMenu_(menu)

    def set_idle(self):
        self._item.button().setTitle_(ICON_IDLE)

    def set_active(self):
        self._item.button().setTitle_(ICON_ACTIVE)

    def set_error(self):
        self._item.button().setTitle_(ICON_ERROR)
