"""Crash reporting and usage analytics (launch-blockers #10).

Two cloud-hosted providers, both US-region by default:

- Sentry — crash/error reporting.
- PostHog — usage-event analytics ("what do users use the app for").

This is opt-out, on by default — a deliberate product decision (see
``docs/launch-blockers.md`` #10), not the local-first default the rest of
Orbit uses. Disable with ``orbit privacy disable-telemetry`` or by setting
``telemetry_enabled: false`` in ``~/.orbit/policy.json``.

Hard rule, not a suggestion: nothing sent here may ever contain captured
window text, URLs, search queries, chat messages, task prompts, file paths,
or any other captured content — only structural usage/crash metadata (which
action fired, counts, durations, app/OS version). ``_scrub_event`` and
``include_local_variables=False`` below are defense in depth against a
captured string ending up in an exception's local variables or arguments,
on top of every ``track_event`` call site being responsible for only ever
passing structural properties in the first place.

No-ops completely, with zero network activity, unless BOTH the policy flag
is on AND the provider's credentials (``ORBIT_SENTRY_DSN`` /
``ORBIT_POSTHOG_API_KEY``) are configured in ``~/.orbit/.env`` — an unconfigured
dev machine or CI run never sends anything.
"""
from __future__ import annotations

import logging
import os
import uuid
from pathlib import Path

logger = logging.getLogger(__name__)

_CONFIG = Path("~/.orbit/.env").expanduser()
_ANONYMOUS_ID_PATH = Path("~/.orbit/telemetry_id").expanduser()

DEFAULT_POSTHOG_HOST = "https://us.i.posthog.com"

_enabled = False
_posthog_ready = False


def _read_env(name: str) -> str | None:
    value = os.environ.get(name)
    if value:
        return value
    if not _CONFIG.exists():
        return None
    try:
        for line in _CONFIG.read_text(encoding="utf-8").splitlines():
            line = line.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, _, val = line.partition("=")
            if key.strip() == name:
                return val.strip().strip('"').strip("'") or None
    except OSError:
        return None
    return None


def _anonymous_id() -> str:
    """A random per-install ID — never the user's email or database user_id."""
    if _ANONYMOUS_ID_PATH.exists():
        existing = _ANONYMOUS_ID_PATH.read_text(encoding="utf-8").strip()
        if existing:
            return existing
    new_id = str(uuid.uuid4())
    _ANONYMOUS_ID_PATH.parent.mkdir(parents=True, exist_ok=True)
    _ANONYMOUS_ID_PATH.write_text(new_id, encoding="utf-8")
    return new_id


_SCRUB_KEYS = {"text", "window_title", "query", "message", "prompt", "url", "path", "content"}


def _scrub_event(event: dict, _hint: dict) -> dict | None:
    """Sentry ``before_send`` hook — defense in depth, not the primary guard.

    Drops any request/extra/context field whose key looks like it could carry
    captured content, in case it ever got attached despite
    ``include_local_variables=False``. Does not attempt to scrub inside
    exception messages themselves — those come from Orbit's own code, which
    must not format captured text into an exception message in the first
    place; this hook only catches structured side-channels (extra/contexts).
    """
    for section in ("extra", "contexts"):
        data = event.get(section)
        if isinstance(data, dict):
            for key in list(data.keys()):
                if key.lower() in _SCRUB_KEYS:
                    del data[key]
    return event


def init_telemetry(policy) -> None:
    """Call once at daemon startup, after ``load_policy()``.

    Safe to call multiple times or with telemetry disabled/unconfigured —
    every path below is a no-op unless both opted in and configured.
    """
    global _enabled, _posthog_ready

    if not getattr(policy, "telemetry_enabled", True):
        logger.info("Telemetry disabled by policy (telemetry_enabled=false).")
        return

    sentry_dsn = _read_env("ORBIT_SENTRY_DSN")
    if sentry_dsn:
        try:
            import sentry_sdk

            sentry_sdk.init(
                dsn=sentry_dsn,
                # No performance tracing / profiling — this is crash reporting
                # only, and tracing would burn quota for no product benefit.
                traces_sample_rate=0.0,
                profiles_sample_rate=0.0,
                # Local variables in a traceback frame are exactly where a
                # captured window-text string could otherwise leak.
                include_local_variables=False,
                send_default_pii=False,
                before_send=_scrub_event,
            )
            logger.info("Sentry crash reporting initialized.")
        except Exception:
            logger.exception("Failed to initialize Sentry; continuing without it.")
    else:
        logger.info("ORBIT_SENTRY_DSN not set; crash reporting disabled.")

    posthog_key = _read_env("ORBIT_POSTHOG_API_KEY")
    if posthog_key:
        try:
            import posthog as posthog_module

            posthog_module.api_key = posthog_key
            posthog_module.host = _read_env("ORBIT_POSTHOG_HOST") or DEFAULT_POSTHOG_HOST
            _posthog_ready = True
            logger.info("PostHog usage analytics initialized.")
        except Exception:
            logger.exception("Failed to initialize PostHog; continuing without it.")
    else:
        logger.info("ORBIT_POSTHOG_API_KEY not set; usage analytics disabled.")

    _enabled = True


def track_event(name: str, properties: dict | None = None) -> None:
    """Fire a structural usage event. See module docstring for what may NOT
    be passed in ``properties`` — no captured content, ever."""
    if not _enabled or not _posthog_ready:
        return
    try:
        import posthog as posthog_module

        posthog_module.capture(
            distinct_id=_anonymous_id(), event=name, properties=properties or {}
        )
    except Exception:
        logger.exception("Failed to send telemetry event %r; dropping it.", name)
