"""Privacy + setup/capture-health bridge routes (additive to server.py).

Mutating routes require Bearer token (same pattern as task approve/skip).
GET status/health routes stay open.
"""
from __future__ import annotations

import json
import logging
import secrets
import sqlite3
from datetime import datetime, timedelta, timezone
from http.server import BaseHTTPRequestHandler
from pathlib import Path
from typing import Any
from urllib.parse import parse_qs, urlparse

from orbit.capture.exclusions import EXCLUDED_BUNDLES
from orbit.capture.policy import DEFAULT_POLICY_PATH, load_policy, save_policy
from orbit.privacy import (
    delete_all_capture_data,
    export_capture_data,
    purge_recent_minutes,
)

logger = logging.getLogger(__name__)

DEFAULT_EXPORT_DIR = Path.home() / ".orbit" / "exports"
DbRef = tuple[sqlite3.Connection, Any]


def _send_json(handler: BaseHTTPRequestHandler, status: int, payload: Any) -> None:
    body = json.dumps(payload).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def _read_json_body(
    handler: BaseHTTPRequestHandler, max_size: int = 65536
) -> dict[str, Any] | None:
    length = int(handler.headers.get("Content-Length", 0))
    if length < 0 or length > max_size:
        handler.send_error(400, "invalid body size")
        return None
    if length == 0:
        return {}
    try:
        payload = json.loads(handler.rfile.read(length).decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError):
        handler.send_error(400, "invalid json")
        return None
    if not isinstance(payload, dict):
        handler.send_error(400, "expected object")
        return None
    return payload


def _require_db(handler: BaseHTTPRequestHandler, server: Any) -> DbRef | None:
    db_ref: DbRef | None = getattr(server, "db_ref", None)
    if db_ref is None:
        _send_json(handler, 503, {"error": "database unavailable"})
        return None
    return db_ref


def _check_bridge_auth(handler: BaseHTTPRequestHandler, server: Any) -> bool:
    token = getattr(server, "bridge_token", None)
    if not token:
        return False
    auth = handler.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return False
    supplied = auth[7:].strip()
    return bool(supplied) and secrets.compare_digest(supplied, token)


def _capture_active(ref: Any) -> bool:
    if ref is None:
        return False
    if hasattr(ref, "is_set"):
        return bool(ref.is_set())
    return bool(ref())


def _ax_trusted() -> bool | None:
    """Return Accessibility trust state, or None if unavailable (non-macOS)."""
    try:
        from ApplicationServices import AXIsProcessTrusted

        return bool(AXIsProcessTrusted())
    except Exception:
        return None


def _llm_path_status() -> dict[str, Any]:
    """Live LLM path detection via the same probes as ``complete()``."""
    from orbit.check.llm import llm_available, local_model_ready, resolved_llm_provider

    provider = resolved_llm_provider()
    path_map = {
        "local": "ollama",
        "byok": "byok",
        "relay": "cloud",
        "none": "none",
    }
    path = path_map.get(provider, "none")
    payload = {
        "path": path,
        "cloud": provider == "relay",
        "byok": provider == "byok",
        "local": provider == "local",
        "ready": llm_available(),
    }
    if provider == "local":
        # ``ready`` above only proves Ollama answers; a configured-but-unpulled model
        # still fails at call time. Preflight it here so setup can say so.
        model_ready, hint = local_model_ready()
        payload["local_model_ready"] = model_ready
        payload["local_model_hint"] = hint
    return payload


def _privacy_status_payload() -> dict[str, Any]:
    policy = load_policy()
    return {
        "ok": True,
        "capture_paused": bool(policy.capture_paused),
        "excluded_bundles": list(policy.excluded_bundles),
        "builtin_exclusions": sorted(EXCLUDED_BUNDLES),
        "retention_days": int(policy.retention_days),
        "policy_path": str(DEFAULT_POLICY_PATH),
    }


def _set_paused(paused: bool) -> dict[str, Any]:
    policy = load_policy()
    policy.capture_paused = paused
    save_policy(policy)
    return _privacy_status_payload()


def _mutate_exclusions(
    *, add: list[str] | None = None, remove: list[str] | None = None
) -> dict[str, Any]:
    policy = load_policy()
    current = list(policy.excluded_bundles)
    for bundle in add or []:
        bundle = (bundle or "").strip()
        if bundle and bundle not in current and bundle not in EXCLUDED_BUNDLES:
            current.append(bundle)
    for bundle in remove or []:
        bundle = (bundle or "").strip()
        if bundle in current:
            current.remove(bundle)
    policy.excluded_bundles = current
    save_policy(policy)
    return _privacy_status_payload()


def _capture_health(con: sqlite3.Connection, hours: int = 24) -> dict[str, Any]:
    policy = load_policy()
    excluded = set(EXCLUDED_BUNDLES) | set(policy.excluded_bundles)
    cutoff = (datetime.now(timezone.utc) - timedelta(hours=hours)).isoformat()
    rows = con.execute(
        """
        SELECT
            e.app_bundle_id AS bundle_id,
            COALESCE(MAX(e.app_name), e.app_bundle_id) AS app_name,
            COUNT(*) AS event_count,
            SUM(
                CASE
                    WHEN e.capture_method = 'metadata_only' THEN 0
                    WHEN EXISTS (
                        SELECT 1 FROM text_atoms a WHERE a.event_id = e.id
                    ) THEN 1
                    ELSE 0
                END
            ) AS good_count,
            SUM(
                CASE
                    WHEN e.capture_method = 'metadata_only'
                      OR e.focused_element_label IN ('empty_tree', 'no_atoms', 'get_tree_error')
                    THEN 1
                    ELSE 0
                END
            ) AS empty_count
        FROM context_events e
        WHERE e.timestamp >= ?
          AND e.app_bundle_id IS NOT NULL
          AND e.app_bundle_id != ''
        GROUP BY e.app_bundle_id
        ORDER BY event_count DESC
        LIMIT 40
        """,
        (cutoff,),
    ).fetchall()

    apps: list[dict[str, Any]] = []
    for row in rows:
        bundle = row["bundle_id"] or ""
        good = int(row["good_count"] or 0)
        empty = int(row["empty_count"] or 0)
        events = int(row["event_count"] or 0)
        if bundle in excluded:
            status = "blocked"
        elif good > 0 and good >= empty:
            status = "good"
        elif empty > 0 and good == 0:
            status = "empty"
        elif good > 0:
            status = "partial"
        else:
            status = "unknown"
        apps.append(
            {
                "bundle_id": bundle,
                "app_name": row["app_name"] or bundle,
                "event_count": events,
                "good_count": good,
                "empty_count": empty,
                "status": status,
                "excluded": bundle in excluded,
            }
        )
    return {
        "ok": True,
        "hours": hours,
        "capture_paused": bool(policy.capture_paused),
        "apps": apps,
    }


def _setup_status(server: Any) -> dict[str, Any]:
    ref = getattr(server, "capture_active_ref", None)
    policy = load_policy()
    ax = _ax_trusted()
    llm = _llm_path_status()
    return {
        "ok": True,
        "accessibility_trusted": ax,
        "daemon_running": True,
        "capture_active": _capture_active(ref),
        "capture_paused": bool(policy.capture_paused),
        "llm": llm,
        "checklist": [
            {
                "id": "accessibility",
                "label": "Accessibility permission",
                "ok": ax is True,
                "detail": None
                if ax is True
                else (
                    "Grant Accessibility to Terminal/Python (or Orbit Access App)"
                    if ax is False
                    else "Unavailable on this platform"
                ),
            },
            {
                "id": "daemon",
                "label": "Capture daemon running",
                "ok": True,
                "detail": "Bridge is reachable",
            },
            {
                "id": "llm",
                "label": "LLM path (Cloud AI / Ollama / BYOK)",
                # A reachable Ollama with the wrong model pulled is not a working LLM
                # path, so the local preflight can veto ``ready``.
                "ok": bool(llm.get("ready")) and llm.get("local_model_ready") is not False,
                "detail": llm.get("local_model_hint") or llm.get("path"),
            },
            {
                "id": "capture",
                "label": "Capture not paused",
                "ok": not bool(policy.capture_paused),
                "detail": "Paused" if policy.capture_paused else "Active",
            },
        ],
    }


def handle_privacy_get(handler: BaseHTTPRequestHandler, server: Any, path: str) -> bool:
    """Handle GET privacy/setup/capture-health routes. Returns True if handled."""
    if path == "/api/privacy/status":
        _send_json(handler, 200, _privacy_status_payload())
        return True
    if path == "/api/setup/status":
        _send_json(handler, 200, _setup_status(server))
        return True
    if path == "/api/capture/health":
        db_ref = _require_db(handler, server)
        if db_ref is None:
            return True
        params = parse_qs(urlparse(handler.path).query)
        try:
            hours = int((params.get("hours") or ["24"])[0])
        except ValueError:
            handler.send_error(400, "invalid hours")
            return True
        hours = max(1, min(hours, 168))
        con, lock = db_ref
        with lock:
            payload = _capture_health(con, hours=hours)
        _send_json(handler, 200, payload)
        return True
    return False


def handle_privacy_post(handler: BaseHTTPRequestHandler, server: Any, path: str) -> bool:
    """Handle POST privacy mutating routes. Returns True if handled."""
    privacy_paths = {
        "/api/privacy/pause",
        "/api/privacy/resume",
        "/api/privacy/exclusions",
        "/api/privacy/forget",
        "/api/privacy/export",
        "/api/privacy/delete",
    }
    if path not in privacy_paths:
        return False

    if not _check_bridge_auth(handler, server):
        _send_json(handler, 401, {"error": "unauthorized"})
        return True

    if path == "/api/privacy/pause":
        _send_json(handler, 200, _set_paused(True))
        return True
    if path == "/api/privacy/resume":
        _send_json(handler, 200, _set_paused(False))
        return True

    if path == "/api/privacy/exclusions":
        payload = _read_json_body(handler)
        if payload is None:
            return True
        add = payload.get("add") or []
        remove = payload.get("remove") or []
        if not isinstance(add, list) or not isinstance(remove, list):
            handler.send_error(400, "add/remove must be arrays")
            return True
        add_s = [str(x) for x in add]
        remove_s = [str(x) for x in remove]
        _send_json(handler, 200, _mutate_exclusions(add=add_s, remove=remove_s))
        return True

    if path == "/api/privacy/forget":
        db_ref = _require_db(handler, server)
        if db_ref is None:
            return True
        payload = _read_json_body(handler)
        if payload is None:
            return True
        try:
            minutes = int(payload.get("minutes", 15))
        except (TypeError, ValueError):
            handler.send_error(400, "minutes must be int")
            return True
        if minutes <= 0 or minutes > 24 * 60:
            handler.send_error(400, "minutes out of range")
            return True
        con, lock = db_ref
        with lock:
            deleted = purge_recent_minutes(con, minutes)
            con.commit()
        _send_json(
            handler,
            200,
            {"ok": True, "deleted_events": deleted, "minutes": minutes},
        )
        return True

    if path == "/api/privacy/export":
        db_ref = _require_db(handler, server)
        if db_ref is None:
            return True
        payload = _read_json_body(handler)
        if payload is None:
            return True
        out_raw = payload.get("out")
        try:
            if out_raw:
                out_path = Path(str(out_raw)).expanduser()
                out_path.parent.mkdir(parents=True, exist_ok=True)
            else:
                DEFAULT_EXPORT_DIR.mkdir(parents=True, exist_ok=True)
                stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
                out_path = DEFAULT_EXPORT_DIR / f"orbit-export-{stamp}.jsonl"
            con, lock = db_ref
            with lock:
                count = export_capture_data(con, out_path)
        except OSError as exc:
            logger.exception("privacy export failed")
            _send_json(handler, 500, {"error": f"export failed: {exc}"})
            return True
        _send_json(
            handler,
            200,
            {"ok": True, "events": count, "path": str(out_path)},
        )
        return True

    if path == "/api/privacy/delete":
        db_ref = _require_db(handler, server)
        if db_ref is None:
            return True
        payload = _read_json_body(handler)
        if payload is None:
            return True
        if not payload.get("confirm") and not payload.get("yes"):
            _send_json(handler, 400, {"error": "confirm required"})
            return True
        con, lock = db_ref
        with lock:
            delete_all_capture_data(con)
            con.commit()
        _send_json(handler, 200, {"ok": True, "deleted": True})
        return True

    return False
