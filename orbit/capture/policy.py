"""Capture policy — GDPR tier gates (plans/completed/03-universal-capture.md Phase 3/5)."""

from __future__ import annotations

import json
from dataclasses import asdict, dataclass, field
from pathlib import Path

from orbit.capture.exclusions import EXCLUDED_BUNDLES

DEFAULT_POLICY_PATH = Path.home() / ".orbit" / "policy.json"


DEFAULT_WATCH_ROOTS = ["~/Projects"]


@dataclass
class CapturePolicy:
    tier_ax_text: bool = True
    tier_browser_ext: bool = True
    tier_ocr: bool = False
    tier_screenshot: bool = False
    tier_fsevents: bool = False
    excluded_bundles: list[str] = field(default_factory=list)
    ocr_allowlist: list[str] = field(default_factory=list)
    watch_roots: list[str] = field(default_factory=lambda: list(DEFAULT_WATCH_ROOTS))
    retention_days: int = 90
    work_hours_only: bool = False
    capture_paused: bool = False
    # Proactive detection (Plan 17 Phase 5.4). Off by default — CLAUDE.md's
    # approval-fatigue budget (2-5/day) is a prerequisite for turning this on, not
    # a polish item, so shipping it enabled would violate that constraint before
    # the gate (orbit/check/gate.py) has been calibrated on real usage. Unlike
    # tier_ax_text/tier_browser_ext/work_hours_only above, both flags below are
    # actually read — by orbit/capture/daemon.py's idle-triggered detector.
    detect_enabled: bool = False
    detect_daily_cap: int = 5
    # Read-only MCP context export (Plan 17 Phase 7). Off by default -- captured
    # context must not be exported to any MCP client (Claude Code, Cursor, ...)
    # until the user explicitly opts in via `orbit privacy enable-mcp`.
    # mcp_excluded_bundles is a second, export-time-only exclusion list on top
    # of excluded_bundles/EXCLUDED_BUNDLES (is_bundle_blocked below covers only
    # the latter two) -- orbit/mcp/server.py checks both is_bundle_blocked() and
    # mcp_excluded_bundles so the MCP export boundary honors the same contract
    # as capture time, plus this extra export-only scope.
    mcp_enabled: bool = False
    mcp_excluded_bundles: list[str] = field(default_factory=list)
    # Corpus-quality atom filter (Plan 48 Phase 4.2). §0.3 measured 51% of the
    # live corpus as sub-10-char AXStaticText chrome (punctuation, private-use
    # icon-font glyphs). These thresholds apply to AXStaticText only -- never
    # to AXTextArea/AXTextField, which are the substantive, low-volume roles
    # (1,350 of 105,475 atoms) and must not be filtered by length.
    min_static_text_chars: int = 4
    reject_punctuation_only_atoms: bool = True
    reject_private_use_glyphs: bool = True
    # Crash reporting + usage analytics (launch-blockers #10). Opt-out, on by
    # default -- a deliberate exception to Orbit's local-first default, made
    # explicitly for this feature. Structural usage/crash metadata only, never
    # captured content -- see orbit/telemetry.py's module docstring for the
    # hard rule and orbit.telemetry.init_telemetry() for what actually sends.
    telemetry_enabled: bool = True

    def is_bundle_blocked(self, bundle_id: str) -> bool:
        if bundle_id in EXCLUDED_BUNDLES:
            return True
        return bundle_id in self.excluded_bundles

    def ocr_allowed_for(self, bundle_id: str) -> bool:
        if not self.tier_ocr and not self.tier_screenshot:
            return False
        if self.is_bundle_blocked(bundle_id):
            return False
        if self.tier_screenshot and self.ocr_allowlist:
            return bundle_id in self.ocr_allowlist
        return self.tier_ocr

    def apply_runtime_controls(self, other: "CapturePolicy") -> None:
        """Refresh pause/exclusions from disk without dropping CLI tier overrides."""
        self.capture_paused = other.capture_paused
        self.excluded_bundles = list(other.excluded_bundles)


def load_policy(path: Path | None = None) -> CapturePolicy:
    path = path or DEFAULT_POLICY_PATH
    if not path.exists():
        return CapturePolicy()
    try:
        data = json.loads(path.read_text())
    except (json.JSONDecodeError, OSError):
        return CapturePolicy()
    watch = data.get("watch_roots")
    if watch is None:
        watch = list(DEFAULT_WATCH_ROOTS)
    return CapturePolicy(
        tier_ax_text=bool(data.get("tier_ax_text", True)),
        tier_browser_ext=bool(data.get("tier_browser_ext", True)),
        tier_ocr=bool(data.get("tier_ocr", False)),
        tier_screenshot=bool(data.get("tier_screenshot", False)),
        tier_fsevents=bool(data.get("tier_fsevents", False)),
        excluded_bundles=list(data.get("excluded_bundles") or []),
        ocr_allowlist=list(data.get("ocr_allowlist") or []),
        watch_roots=list(watch),
        retention_days=int(data.get("retention_days", 90)),
        work_hours_only=bool(data.get("work_hours_only", False)),
        capture_paused=bool(data.get("capture_paused", False)),
        detect_enabled=bool(data.get("detect_enabled", False)),
        detect_daily_cap=int(data.get("detect_daily_cap", 5)),
        mcp_enabled=bool(data.get("mcp_enabled", False)),
        mcp_excluded_bundles=list(data.get("mcp_excluded_bundles") or []),
        min_static_text_chars=int(data.get("min_static_text_chars", 4)),
        reject_punctuation_only_atoms=bool(data.get("reject_punctuation_only_atoms", True)),
        reject_private_use_glyphs=bool(data.get("reject_private_use_glyphs", True)),
        telemetry_enabled=bool(data.get("telemetry_enabled", True)),
    )


def save_policy(policy: CapturePolicy, path: Path | None = None) -> None:
    path = path or DEFAULT_POLICY_PATH
    path.parent.mkdir(parents=True, exist_ok=True)
    path.write_text(json.dumps(asdict(policy), indent=2) + "\n")
