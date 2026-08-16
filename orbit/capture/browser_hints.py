"""Chromium browser AX onboarding hints (Phase 2A)."""

from __future__ import annotations

BROWSER_AX_HINT = (
    "Browser AX tree empty. Enable one of:\n"
    "  1) Visit chrome://accessibility/ → enable for active tabs\n"
    "  2) Relaunch: open -a \"YourBrowser\" --args --force-renderer-accessibility\n"
    "  3) Install Orbit browser companion: orbit/browser-extension/ (see README)"
)
