"""Per-app capture depth profiles (Phase 1 — plans/completed/03-universal-capture.md)."""

from __future__ import annotations

DEFAULT_DEPTH = 12
ELECTRON_DEPTH = 24

# Verified: Cursor yields 0 atoms @12, 20 @24 (session probe 2026-06-28).
ELECTRON_BUNDLE_PREFIXES = (
    "com.todesktop.",
    "com.microsoft.VSCode",
    "com.hnc.Discord",
    "com.slack.",
    "com.github.atom",
    "com.exfigstudio.",
)

CHROMIUM_BUNDLE_PREFIXES = (
    "com.google.Chrome",
    "company.thebrowser.",
    "com.brave.Browser",
    "org.mozilla.firefox",
    "com.apple.Safari",
    "com.operasoftware.Opera",
    "com.microsoft.edgemac",
    "com.vivaldi.Vivaldi",
)

CHROMIUM_DEPTH = 20
CHROMIUM_SETTLE_S = 0.5


def is_chromium_bundle(bundle_id: str) -> bool:
    return any(bundle_id.startswith(p) for p in CHROMIUM_BUNDLE_PREFIXES)


def profile_depth_for(bundle_id: str, override: int | None = None) -> int:
    if override is not None:
        return override
    if any(bundle_id.startswith(p) for p in ELECTRON_BUNDLE_PREFIXES):
        return ELECTRON_DEPTH
    if is_chromium_bundle(bundle_id):
        return CHROMIUM_DEPTH
    return DEFAULT_DEPTH


def needs_ax_enablement(bundle_id: str) -> bool:
    """Electron/Chromium apps gate renderer accessibility until enabled."""
    return any(
        bundle_id.startswith(p)
        for p in ELECTRON_BUNDLE_PREFIXES + CHROMIUM_BUNDLE_PREFIXES
    )
