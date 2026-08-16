"""HTTP ingest for Orbit browser companion extension (Tier 2).

Local-only: binds 127.0.0.1 — no cloud exfiltration.
Spec: plans/completed/03-universal-capture.md Phase 2B; orbit-context.md L25.
Orbit Access API: plans/orbitaccessappdesign.md Appendix §10.
"""
from __future__ import annotations

import json
import logging
import os
import queue
import re
import secrets
import sqlite3
import subprocess
import sys
import threading
from dataclasses import asdict, dataclass, field
from datetime import datetime, timezone
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Any, Callable
from urllib.parse import parse_qs, urlparse

import orbit
from orbit.check.detector import Task
from orbit.check.envelope import untrusted_preamble, wrap_untrusted
from orbit.check.log import (
    get_all_tasks_today,
    get_pending_today,
    get_task_status,
    insert_task,
    migrate,
    update_status,
)
from orbit.search.types import Hit
from orbit.storage.session import NoActiveUserError, get_active_user_id

logger = logging.getLogger(__name__)

DEFAULT_PORT = 8765
DbRef = tuple[sqlite3.Connection, threading.Lock]
CaptureActiveRef = Callable[[], bool] | threading.Event
DispatchJob = tuple[int, str, str]
DetectJob = tuple[int, float, bool]

DETECT_MAX_SINCE_HOURS = 72.0
DETECT_DEFAULT_SINCE_HOURS = 8.0

# Plan 52 §3 ("no unbounded queues") applies here too, not just to the five queues in
# orbit/capture/daemon.py. Depth is naturally ~1: _handle_detect answers 409 while a run
# is in flight, so at most one job is queued at a time. The bound is therefore a
# guardrail against an unforeseen producer, not backpressure anyone should ever feel —
# which is also why the policy is drop_newest rather than drop_oldest: a dropped job
# would strand DetectRun.state at "running", so blocking briefly is strictly better than
# silently discarding. The queue is constructed with orbit.capture.daemon._BoundedQueue
# (see start_browser_bridge) so there is one overflow implementation, not two.
DETECT_QUEUE_MAXSIZE = 32
DETECT_PUT_TIMEOUT_S = 5.0

_CHAT_SYSTEM = """\
You are orbit, a personal context assistant. Answer the user's question using \
the provided context snippets from their recent screen activity. Be concise and \
grounded in the snippets; say when context is insufficient.\
""" + untrusted_preamble()

_DIGEST_CHAT_SYSTEM = """\
You are orbit. The user asked what they worked on (or for a day summary). \
Answer from the daily digest / session context provided. Be concise, concrete, \
and grounded; if the digest says no captures were recorded, say so clearly.\
""" + untrusted_preamble()

_ENTITY_CHAT_SYSTEM = """\
You are orbit. The user asked about a specific person, project, or entity. \
Answer from the entity timeline and search context provided. Be concise and \
grounded; cite dates and apps. Say when context is insufficient.\
""" + untrusted_preamble()

# Same output contract as detector.py's suggested_prompt field (detector.py:14-21),
# narrowed to one task the user typed by hand instead of many mined from context.
_MANUAL_TASK_SYSTEM = """\
You are a task-prompting assistant. The user manually created a task; you are \
given its title and (optionally) a description. Write a detailed, ready-to-use \
prompt that an autonomous coding/writing agent (Claude Code) can execute directly \
-- include all relevant context from the title and description so the agent can \
act without asking clarifying questions. Return ONLY the prompt text: no JSON, \
no markdown fences, no preamble or commentary.\
""" + untrusted_preamble()


def _generate_manual_task_prompt(
    title: str, description: str, db_ref: DbRef | None
) -> str:
    """Turn a hand-typed title/description into a ready-to-approve agent prompt.

    Falls back to the title verbatim whenever no LLM is configured, or when the
    configured one fails -- a manual task must never be lost (or silently
    downgraded to unusable) because AI was off or unreachable (open decision 5).
    """
    from orbit.check.llm import complete, llm_available

    if not llm_available():
        return title
    # Title/description are user input reaching a model prompt: wrap them like
    # every other external-content path so the model treats them as data, not
    # instructions (CLAUDE.md: all external content is untrusted, never instructions).
    wrapped = wrap_untrusted(
        [("Task title", title), ("Task description", description or "(none)")]
    )
    try:
        generated = complete(
            _MANUAL_TASK_SYSTEM, wrapped, call_site="manual_task_prompt", db_ref=db_ref
        )
    except Exception:
        logger.exception("manual task prompt generation failed; using title")
        return title
    generated = generated.strip()
    return generated or title


@dataclass
class DetectRun:
    """State of the most recent /api/detect run.

    Deliberately in memory only: a run does not survive a daemon restart and
    ``task_log`` is already the durable record of what was detected.
    """

    state: str = "idle"  # idle | running | done | error
    run_id: int = 0
    started_at: str | None = None
    finished_at: str | None = None
    task_ids: list[int] = field(default_factory=list)
    error: str | None = None
    # no_captures | no_user | llm | model_output | unknown
    error_kind: str | None = None


_TASK_APPROVE_RE = re.compile(r"^/api/task/(\d+)/approve$")
_TASK_SKIP_RE = re.compile(r"^/api/task/(\d+)/skip$")
_TASK_STATUS_RE = re.compile(r"^/api/task/(\d+)$")
_ENTITY_TIMELINE_RE = re.compile(r"^/api/entity/(\d+)/timeline$")


def _capture_active(ref: CaptureActiveRef | None) -> bool:
    if ref is None:
        return False
    if isinstance(ref, threading.Event):
        return ref.is_set()
    return bool(ref())


def _hit_to_dict(hit: Hit) -> dict[str, Any]:
    return asdict(hit)


def _task_to_dict(log_id: int, task: Any) -> dict[str, Any]:
    return {
        "id": log_id,
        "title": task.title,
        "description": task.description,
        "original_prompt": task.suggested_prompt,
        "agent_type": task.agent_type,
        "confidence": task.confidence,
        "status": "detected",
    }


def _read_json_body(handler: BaseHTTPRequestHandler, max_size: int = 65536) -> dict[str, Any] | None:
    length = int(handler.headers.get("Content-Length", 0))
    if length <= 0 or length > max_size:
        handler.send_error(400, "invalid body size")
        return None
    try:
        payload = json.loads(handler.rfile.read(length).decode("utf-8"))
    except (json.JSONDecodeError, UnicodeDecodeError):
        handler.send_error(400, "invalid json")
        return None
    if not isinstance(payload, dict):
        handler.send_error(400, "expected object")
        return None
    return payload


def _send_json(handler: BaseHTTPRequestHandler, status: int, payload: Any) -> None:
    body = json.dumps(payload).encode("utf-8")
    handler.send_response(status)
    handler.send_header("Content-Type", "application/json")
    handler.send_header("Content-Length", str(len(body)))
    handler.end_headers()
    handler.wfile.write(body)


def _require_db(handler: BaseHTTPRequestHandler, server: ThreadingHTTPServer) -> DbRef | None:
    db_ref: DbRef | None = getattr(server, "db_ref", None)
    if db_ref is None:
        _send_json(handler, 503, {"error": "database unavailable"})
        return None
    return db_ref


def _build_chat_context(hits: list[Hit]) -> str:
    if not hits:
        return wrap_untrusted([])
    blocks = [
        (
            f"[{i}] {hit.app_name} — {hit.window_title or 'untitled'}",
            hit.snippet_html,
        )
        for i, hit in enumerate(hits[:8], start=1)
    ]
    return wrap_untrusted(blocks)


def _check_bridge_auth(handler: BaseHTTPRequestHandler, server: ThreadingHTTPServer) -> bool:
    token = getattr(server, "bridge_token", None)
    if not token:
        return False
    auth = handler.headers.get("Authorization", "")
    if not auth.startswith("Bearer "):
        return False
    supplied = auth[7:].strip()
    return bool(supplied) and secrets.compare_digest(supplied, token)


def _run_dispatch_worker(dispatch_queue: queue.Queue, db_ref: DbRef) -> None:
    con, lock = db_ref
    while True:
        job = dispatch_queue.get()
        if job is None:
            break
        task_id, approved_prompt, title = job
        result_path: str | None = None
        result_preview: str | None = None
        try:
            from orbit.check.dispatch import dispatch

            result = dispatch(approved_prompt, title=title, db_ref=db_ref)
            exit_code = result.exit_code
            result_path = result.path
            result_preview = result.preview
        except Exception:
            logger.exception("task dispatch failed for id=%s", task_id)
            exit_code = 1
        update_status(
            con,
            lock,
            task_id,
            "dispatched",
            exit_code=exit_code,
            result_path=result_path,
            result_preview=result_preview,
        )
        dispatch_queue.task_done()


def _utc_now() -> str:
    """UTC ISO-8601 stamp — same shape as the timestamps log.py writes."""
    return datetime.now(timezone.utc).isoformat()


# This module is imported by the daemon's own startup path, so import time is start time.
_STARTED_AT = _utc_now()


def _git_build_state(package_path: str) -> tuple[str | None, bool | None]:
    """``(short SHA, working tree dirty)`` for the repo holding the loaded package.

    ``(None, None)`` when there is no repo, which is the *expected* answer in a
    release bundle: build-app-bundle.sh installs Orbit non-editable, so the deployed
    package is a plain copy.
    """
    parent = os.path.dirname(package_path)
    # `git -C` searches ancestors, so without this guard a package that merely *sits*
    # inside some unrelated checkout would confidently report that repo's SHA.
    # `exists`, not `isdir`: in a git worktree `.git` is a file, and this repo uses them.
    if not os.path.exists(os.path.join(parent, ".git")):
        return None, None
    try:
        head = subprocess.run(
            ["git", "-C", parent, "rev-parse", "--short", "HEAD"],
            capture_output=True,
            text=True,
            timeout=2.0,
            check=False,
        )
        if head.returncode != 0 or not head.stdout.strip():
            return None, None
        status = subprocess.run(
            ["git", "-C", parent, "status", "--porcelain"],
            capture_output=True,
            text=True,
            timeout=5.0,
            check=False,
        )
    except Exception:
        return None, None
    dirty = bool(status.stdout.strip()) if status.returncode == 0 else None
    return head.stdout.strip(), dirty


def _recorded_build_sha(package_path: str) -> str | None:
    """SHA that build-app-bundle.sh wrote beside the installed package.

    A released daemon has no repo to ask, so without this file it could only ever
    report the (rarely bumped) package version — useless for "which build is this?".
    """
    try:
        with open(os.path.join(package_path, "BUILD_SHA"), encoding="utf-8") as handle:
            sha = handle.read().strip()
    except OSError:
        return None
    return sha or None


def _resolve_build_info() -> dict[str, Any]:
    package_path = os.path.dirname(os.path.abspath(orbit.__file__))
    git_sha, git_dirty = _git_build_state(package_path)
    return {
        "version": orbit.__version__,
        "started_at": _STARTED_AT,
        "package_path": package_path,
        "interpreter": sys.executable,
        "git_sha": git_sha if git_sha is not None else _recorded_build_sha(package_path),
        "git_dirty": git_dirty,
    }


# Resolved at import — the same instant _STARTED_AT is taken, which is when this process
# actually loaded its Python. Deliberately *not* lazy: a daemon that outlives a `git commit`
# must keep reporting the commit whose code it is running, not whatever HEAD later became.
# Answering the first poll with a freshly-shelled-out `rev-parse` would make a stale daemon
# claim current HEAD, which is precisely the bug this payload exists to expose.
_BUILD_INFO: dict[str, Any] = _resolve_build_info()


def _model_output_message(detail: str) -> str:
    """Name the configured model, because the remedy is to change it — not to retry.

    A model that answers with prose will keep answering with prose, so a retry only
    spends budget. Naming the model turns a dead end into one setting to change.
    """
    from orbit.check.llm import _local_model, resolved_llm_provider

    if resolved_llm_provider() == "local":
        subject = f"The local model '{_local_model()}'"
        remedy = (
            "Pick a different local model in Settings — a larger instruct model "
            "follows the JSON format more reliably — or switch to Cloud AI."
        )
    else:
        # Cloud paths resolve the model inside llm.py, so there is no name to
        # quote here — but the remedy is still "change something", not "retry".
        subject = "The cloud AI model"
        remedy = "Switch provider in Settings, or use a local instruct model."
    return f"{subject} did not return tasks in the expected format ({detail}). {remedy}"


def _detect_once(
    db_ref: DbRef, since_hours: float, refresh: bool, *, cap: int = 5
) -> tuple[list[int], str | None, str | None]:
    """Run one detection pass; returns (task_ids, error, error_kind).

    Failures come back as values rather than exceptions because an empty
    capture window or a missing user session is a normal outcome the user can
    act on — the exception messages already name the fix.

    Every caller of this function — the CLI (``orbit check``) and the daemon's
    idle-triggered detector both go through the browser bridge's detect worker
    or this function directly — gets the relevance gate for free: detected
    tasks are filtered through ``filter_tasks`` (dedupe + score + daily budget)
    before ``insert_task`` ever runs. There is exactly one insertion path here,
    so there is exactly one place gating can be skipped, and it isn't skipped.
    """
    from orbit.check.context import read_context
    from orbit.check.detector import TaskDetectionParseError, detect_tasks
    from orbit.check.gate import filter_tasks
    from orbit.check.llm import format_completion_error

    con, lock = db_ref
    cached = get_pending_today(con, lock)
    if cached and not refresh:
        # Mirrors the CLI's resume path (orbit/check/__main__.py:55-59): today's
        # suggestions already exist, so don't pay for a second completion.
        return [log_id for log_id, _task in cached], None, None
    try:
        text, _label = read_context(
            source="capture", con=con, lock=lock, since_hours=since_hours
        )
    except FileNotFoundError as exc:
        return [], str(exc), "no_captures"
    try:
        tasks = detect_tasks(text, db_ref=db_ref)
    except TaskDetectionParseError as exc:
        # Before the generic handler: the provider worked, so format_completion_error
        # would fall through to str(exc) and show the user a JSON parser message.
        logger.warning("task detection returned unparseable output: %s", exc)
        return [], _model_output_message(str(exc)), "model_output"
    except Exception as exc:
        logger.exception("task detection completion failed")
        return [], format_completion_error(exc), "llm"
    tasks = filter_tasks(con, lock, tasks, cap=cap)
    if not tasks:
        logger.info("detect: relevance gate suppressed all detected task(s) for this run")
        return [], None, None
    try:
        return [insert_task(con, lock, task) for task in tasks], None, None
    except NoActiveUserError as exc:
        return [], str(exc), "no_user"


def _run_detect_worker(
    detect_queue: queue.Queue,
    db_ref: DbRef,
    run: DetectRun,
    run_lock: threading.Lock,
) -> None:
    while True:
        job = detect_queue.get()
        if job is None:
            break
        run_id, since_hours, refresh = job
        try:
            task_ids, error, error_kind = _detect_once(db_ref, since_hours, refresh)
        except Exception as exc:
            logger.exception("detection run failed for run_id=%s", run_id)
            task_ids, error, error_kind = [], str(exc), "unknown"
        # run_lock guards only these field writes — never a completion.
        with run_lock:
            run.state = "error" if error_kind else "done"
            run.task_ids = task_ids
            run.error = error
            run.error_kind = error_kind
            run.finished_at = _utc_now()
        detect_queue.task_done()


class _BridgeHandler(BaseHTTPRequestHandler):
    def log_message(self, format: str, *args) -> None:  # noqa: A003
        logger.debug("browser-bridge: " + format, *args)

    def do_POST(self) -> None:
        path = urlparse(self.path).path
        if path == "/capture":
            self._handle_capture()
            return
        if path == "/api/chat":
            self._handle_chat()
            return
        if path == "/api/shutdown":
            self._handle_shutdown()
            return
        if path == "/api/detect":
            self._handle_detect()
            return
        if path == "/api/tasks":
            self._handle_tasks_create()
            return
        match = _TASK_APPROVE_RE.match(path)
        if match:
            self._handle_task_approve(int(match.group(1)))
            return
        match = _TASK_SKIP_RE.match(path)
        if match:
            self._handle_task_skip(int(match.group(1)))
            return
        # Plan 51 Phase 3A (D1): POST /api/users — the daemon owns the encrypted
        # store, so the app's sign-up write comes over HTTP instead of GRDB.
        from orbit.browser_bridge.app_routes import handle_app_post

        if handle_app_post(self, self.server, path):
            return
        from orbit.browser_bridge.privacy_routes import handle_privacy_post

        if handle_privacy_post(self, self.server, path):
            return
        self.send_error(404)

    def do_GET(self) -> None:
        path = urlparse(self.path).path
        if path == "/health":
            _send_json(self, 200, {"ok": True})
            return
        if path == "/api/status":
            self._handle_status()
            return
        if path == "/api/tasks/pending":
            self._handle_tasks_pending()
            return
        if path == "/api/tasks/kanban":
            self._handle_tasks_kanban()
            return
        if path == "/api/detect/status":
            self._handle_detect_status()
            return
        match = _TASK_STATUS_RE.match(path)
        if match:
            self._handle_task_status(int(match.group(1)))
            return
        if path == "/api/search":
            self._handle_search()
            return
        if path == "/api/digest":
            self._handle_digest()
            return
        if path == "/api/llm/models":
            self._handle_llm_models()
            return
        if path == "/api/sessions/last":
            self._handle_sessions_last()
            return
        if path == "/api/sessions":
            self._handle_sessions()
            return
        if path == "/api/entities":
            self._handle_entities()
            return
        match = _ENTITY_TIMELINE_RE.match(path)
        if match:
            self._handle_entity_timeline(int(match.group(1)))
            return
        # Plan 51 Phase 3A (D1): notes/atoms/score/usage/user reads that the Swift
        # app used to do directly against ~/.orbit/orbit.db via GRDB.
        from orbit.browser_bridge.app_routes import handle_app_get

        if handle_app_get(self, self.server, path):
            return
        from orbit.browser_bridge.privacy_routes import handle_privacy_get

        if handle_privacy_get(self, self.server, path):
            return
        self.send_error(404)

    def _handle_capture(self) -> None:
        payload = _read_json_body(self)
        if payload is None:
            return
        url = payload.get("url")
        if not url or not isinstance(url, str):
            self.send_error(400, "url required")
            return
        self.server.event_queue.put(payload)  # type: ignore[attr-defined]
        self.send_response(204)
        self.end_headers()

    def _handle_status(self) -> None:
        from orbit.check.llm import (
            llm_available,
            local_model_ready,
            resolved_llm_provider,
            _local_model,
        )

        ref: CaptureActiveRef | None = getattr(self.server, "capture_active_ref", None)
        try:
            from orbit.capture.policy import load_policy

            paused = bool(load_policy().capture_paused)
        except Exception:
            paused = False
        llm_provider = resolved_llm_provider()
        payload: dict[str, Any] = {
            "ok": True,
            "capture_active": _capture_active(ref),
            "capture_paused": paused,
            "llm_available": llm_available(),
            "llm_provider": llm_provider,
            **_BUILD_INFO,
        }
        if llm_provider == "local":
            payload["local_model"] = _local_model()
            # Reachability + a string compare against /api/tags. This route is polled
            # every 5s by the Access App, so it must never call the model.
            ready, hint = local_model_ready()
            payload["local_model_ready"] = ready
            payload["local_model_hint"] = hint
        _send_json(self, 200, payload)

    def _handle_llm_models(self) -> None:
        # Plan 27 only needs ``models``; we always enumerate Ollama tags (even when
        # resolved provider is cloud/relay) so the Access App picker stays useful.
        from orbit.check.llm import _local_model, list_local_models, resolved_llm_provider

        llm_provider = resolved_llm_provider()
        models = list_local_models()
        _send_json(
            self,
            200,
            {
                "ok": True,
                "provider": llm_provider,
                "models": models,
                "current": _local_model(),
            },
        )

    def _handle_shutdown(self) -> None:
        shutdown_hook = getattr(self.server, "shutdown_hook", None)
        if shutdown_hook is None:
            self.send_error(503, "shutdown unavailable")
            return
        self.send_response(204)
        self.end_headers()
        shutdown_hook()

    def _handle_tasks_pending(self) -> None:
        db_ref = _require_db(self, self.server)
        if db_ref is None:
            return
        con, lock = db_ref
        tasks = [_task_to_dict(log_id, task) for log_id, task in get_pending_today(con, lock)]
        _send_json(self, 200, tasks)

    def _handle_tasks_kanban(self) -> None:
        # Open like /api/status and /api/tasks/pending: run state (title/status),
        # not captured screen text.
        db_ref = _require_db(self, self.server)
        if db_ref is None:
            return
        con, lock = db_ref
        _send_json(self, 200, get_all_tasks_today(con, lock))

    def _handle_task_status(self, task_id: int) -> None:
        if not _check_bridge_auth(self, self.server):
            _send_json(self, 401, {"error": "unauthorized"})
            return
        db_ref = _require_db(self, self.server)
        if db_ref is None:
            return
        con, lock = db_ref
        row = get_task_status(con, lock, task_id)
        if row is None:
            _send_json(self, 404, {"error": "task not found", "id": task_id})
            return
        _send_json(self, 200, {"ok": True, **row})

    def _handle_task_approve(self, task_id: int) -> None:
        if not _check_bridge_auth(self, self.server):
            _send_json(self, 401, {"error": "unauthorized"})
            return
        db_ref = _require_db(self, self.server)
        if db_ref is None:
            return
        payload = _read_json_body(self)
        if payload is None:
            return
        approved_prompt = payload.get("approved_prompt")
        if not approved_prompt or not isinstance(approved_prompt, str):
            self.send_error(400, "approved_prompt required")
            return
        con, lock = db_ref
        update_status(con, lock, task_id, "approved", approved_prompt=approved_prompt)
        dispatch_queue: queue.Queue | None = getattr(
            self.server, "dispatch_queue", None
        )
        if dispatch_queue is None:
            _send_json(
                self,
                503,
                {"error": "dispatch queue unavailable", "id": task_id},
            )
            return
        with lock:
            row = con.execute(
                "SELECT title FROM task_log WHERE id = ?",
                (task_id,),
            ).fetchone()
        title = (row["title"] if row and row["title"] else "task")
        dispatch_queue.put((task_id, approved_prompt, title))
        _send_json(
            self,
            202,
            {"ok": True, "id": task_id, "status": "approved"},
        )

    def _handle_task_skip(self, task_id: int) -> None:
        if not _check_bridge_auth(self, self.server):
            _send_json(self, 401, {"error": "unauthorized"})
            return
        db_ref = _require_db(self, self.server)
        if db_ref is None:
            return
        con, lock = db_ref
        update_status(con, lock, task_id, "skipped")
        _send_json(self, 200, {"ok": True, "id": task_id, "status": "skipped"})

    def _handle_tasks_create(self) -> None:
        # Auth'd like approve/detect: this route writes a task_log row (and, when
        # an LLM is configured, spends model budget generating a prompt) — the
        # same open-POST-that-costs-money concern as :619-620 above.
        if not _check_bridge_auth(self, self.server):
            _send_json(self, 401, {"error": "unauthorized"})
            return
        db_ref = _require_db(self, self.server)
        if db_ref is None:
            return
        payload = _read_json_body(self)
        if payload is None:
            return
        title = payload.get("title")
        if not isinstance(title, str) or not title.strip():
            self.send_error(400, "title required")
            return
        title = title.strip()
        description = payload.get("description")
        if not isinstance(description, str):
            description = ""
        con, lock = db_ref
        original_prompt = _generate_manual_task_prompt(title, description, db_ref)
        task = Task(
            title=title,
            description=description,
            suggested_prompt=original_prompt,
            # A manual task is not a probabilistic guess the way a detected one is —
            # the user already decided this is worth doing by typing it in, so it
            # carries the same "definitely relevant" weight as anything that clears
            # detect_tasks' 0.7 confidence floor: 1.0, the ceiling of that scale.
            # agent_type: the user didn't pick a lane, and Task/insert_task have no
            # "unspecified" value, so default to "admin" — the same fallback
            # get_skipped_today/get_pending_today already use for legacy NULL rows.
            agent_type="admin",
            confidence=1.0,
        )
        task_id = insert_task(con, lock, task)
        _send_json(self, 200, {"ok": True, "id": task_id})

    def _handle_detect(self) -> None:
        # Auth'd like approve: this route spends model budget and writes task_log rows.
        if not _check_bridge_auth(self, self.server):
            _send_json(self, 401, {"error": "unauthorized"})
            return
        db_ref = _require_db(self, self.server)
        if db_ref is None:
            return
        payload: dict[str, Any] = {}
        if int(self.headers.get("Content-Length", 0)) > 0:
            parsed = _read_json_body(self)
            if parsed is None:
                return
            payload = parsed
        raw_since = payload.get("since_hours", DETECT_DEFAULT_SINCE_HOURS)
        if isinstance(raw_since, bool) or not isinstance(raw_since, (int, float)):
            self.send_error(400, "invalid since_hours")
            return
        since_hours = float(raw_since)
        if not 0 < since_hours <= DETECT_MAX_SINCE_HOURS:
            self.send_error(400, "since_hours out of range")
            return
        refresh = bool(payload.get("refresh", False))
        detect_queue: queue.Queue | None = getattr(self.server, "detect_queue", None)
        run: DetectRun | None = getattr(self.server, "detect_run", None)
        run_lock: threading.Lock | None = getattr(self.server, "detect_run_lock", None)
        if detect_queue is None or run is None or run_lock is None:
            _send_json(self, 503, {"error": "detect queue unavailable"})
            return
        busy_run_id: int | None = None
        run_id = 0
        with run_lock:
            if run.state == "running":
                busy_run_id = run.run_id
            else:
                run.run_id += 1
                run.state = "running"
                run.started_at = _utc_now()
                run.finished_at = None
                run.task_ids = []
                run.error = None
                run.error_kind = None
                run_id = run.run_id
        if busy_run_id is not None:
            _send_json(
                self,
                409,
                {"error": "detection already running", "run_id": busy_run_id},
            )
            return
        # The completion happens on the worker thread; this handler must return now.
        detect_queue.put((run_id, since_hours, refresh))
        _send_json(self, 202, {"ok": True, "state": "running", "run_id": run_id})

    def _handle_detect_status(self) -> None:
        # Open like /api/status and /api/tasks/pending: run state only, never
        # captured text.
        run: DetectRun | None = getattr(self.server, "detect_run", None)
        run_lock: threading.Lock | None = getattr(self.server, "detect_run_lock", None)
        if run is None or run_lock is None:
            _send_json(self, 503, {"error": "detect unavailable"})
            return
        with run_lock:
            payload = {
                "ok": True,
                "state": run.state,
                "run_id": run.run_id,
                "started_at": run.started_at,
                "finished_at": run.finished_at,
                "task_count": len(run.task_ids),
                "task_ids": list(run.task_ids),
                "error": run.error,
                "error_kind": run.error_kind,
            }
        _send_json(self, 200, payload)

    def _handle_search(self) -> None:
        db_ref = _require_db(self, self.server)
        if db_ref is None:
            return
        params = parse_qs(urlparse(self.path).query)
        q = (params.get("q") or [""])[0].strip()
        if not q:
            self.send_error(400, "q required")
            return
        try:
            limit = int((params.get("limit") or ["20"])[0])
        except ValueError:
            self.send_error(400, "invalid limit")
            return
        app_bundle_id = (params.get("app_bundle_id") or [None])[0] or None
        since = (params.get("since") or [None])[0] or None
        until = (params.get("until") or [None])[0] or None
        con, _lock = db_ref
        user_id = get_active_user_id()
        try:
            from orbit.search.hybrid import search_bridge

            hits = [
                _hit_to_dict(h)
                for h in search_bridge(
                    con,
                    q,
                    limit=limit,
                    app_bundle_id=app_bundle_id,
                    since=since,
                    until=until,
                    user_id=user_id,
                )
            ]
        except Exception as exc:
            logger.exception("search failed")
            _send_json(self, 503, {"error": str(exc)})
            return
        _send_json(self, 200, hits)

    def _handle_digest(self) -> None:
        params = parse_qs(urlparse(self.path).query)
        day = (params.get("day") or [None])[0] or None
        markdown = (params.get("markdown") or ["0"])[0] in ("1", "true", "yes")
        use_llm = (params.get("llm") or ["0"])[0] in ("1", "true", "yes")
        # The narrative costs one completion, so llm=1 sits behind the same auth as
        # /api/task/<id>/approve — an open GET that spends model budget is the defect
        # class Plan 17 D4 named. The default stays off and plain GET /api/digest
        # stays open, which is the offline-browse contract.
        if use_llm and not _check_bridge_auth(self, self.server):
            _send_json(self, 401, {"error": "unauthorized"})
            return
        db_ref = _require_db(self, self.server)
        if db_ref is None:
            return
        con, lock = db_ref
        try:
            from orbit.memory.digest import build_digest, render_digest_markdown

            # build_digest already degrades to the structured narrative when the LLM
            # raises (digest.py:229), so no fallback belongs here.
            digest = build_digest(con, lock, day=day, use_llm=use_llm, db_ref=db_ref)
            if markdown:
                _send_json(
                    self,
                    200,
                    {"day": digest.get("day"), "markdown": render_digest_markdown(digest)},
                )
                return
            _send_json(self, 200, digest)
        except Exception as exc:
            logger.exception("digest failed")
            _send_json(self, 503, {"error": str(exc)})

    def _handle_sessions(self) -> None:
        db_ref = _require_db(self, self.server)
        if db_ref is None:
            return
        params = parse_qs(urlparse(self.path).query)
        day = (params.get("day") or ["today"])[0] or "today"
        try:
            limit = int((params.get("limit") or ["50"])[0])
        except ValueError:
            self.send_error(400, "invalid limit")
            return
        con, lock = db_ref
        try:
            from orbit.memory.sessions import day_bounds, get_sessions, segment_sessions

            start, _end = day_bounds(day)
            segment_sessions(con, lock, since=start, min_events=2)
            sessions = get_sessions(con, day=day, limit=limit)
            _send_json(self, 200, {"day": day, "sessions": sessions})
        except Exception as exc:
            logger.exception("sessions failed")
            _send_json(self, 503, {"error": str(exc)})

    def _handle_sessions_last(self) -> None:
        # Zero-approval-cost: no LLM call, just the most recently closed session
        # plus the files touched during it (Plan 17 Phase 5.5's "Resume" card).
        db_ref = _require_db(self, self.server)
        if db_ref is None:
            return
        con, lock = db_ref
        try:
            from orbit.memory.sessions import current_session

            with lock:
                session = current_session(con)
                files: list[str] = []
                if session is not None:
                    rows = con.execute(
                        """
                        SELECT DISTINCT f.path
                          FROM session_events se
                          JOIN fs_events f ON f.linked_event_id = se.event_id
                         WHERE se.session_id = ?
                         ORDER BY f.path
                         LIMIT 20
                        """,
                        (session["id"],),
                    ).fetchall()
                    files = [r["path"] for r in rows]
            _send_json(self, 200, {"session": session, "files": files})
        except Exception as exc:
            logger.exception("sessions/last failed")
            _send_json(self, 503, {"error": str(exc)})

    def _handle_entities(self) -> None:
        db_ref = _require_db(self, self.server)
        if db_ref is None:
            return
        params = parse_qs(urlparse(self.path).query)
        day = (params.get("day") or [None])[0] or None
        try:
            limit = int((params.get("limit") or ["20"])[0])
        except ValueError:
            self.send_error(400, "invalid limit")
            return
        con, _lock = db_ref
        try:
            from orbit.memory.entities import top_entities

            entities = top_entities(con, day=day, limit=limit)
            _send_json(self, 200, {"entities": entities})
        except Exception as exc:
            logger.exception("entities failed")
            _send_json(self, 503, {"error": str(exc)})

    def _handle_entity_timeline(self, entity_id: int) -> None:
        db_ref = _require_db(self, self.server)
        if db_ref is None:
            return
        params = parse_qs(urlparse(self.path).query)
        try:
            limit = int((params.get("limit") or ["100"])[0])
        except ValueError:
            self.send_error(400, "invalid limit")
            return
        con, _lock = db_ref
        try:
            from orbit.memory.entities import entity_timeline

            mentions = entity_timeline(con, entity_id, limit=limit)
            _send_json(self, 200, {"mentions": mentions})
        except Exception as exc:
            logger.exception("entity timeline failed")
            _send_json(self, 503, {"error": str(exc)})

    def _handle_chat(self) -> None:
        if not _check_bridge_auth(self, self.server):
            _send_json(self, 401, {"error": "unauthorized"})
            return
        db_ref = _require_db(self, self.server)
        if db_ref is None:
            return
        payload = _read_json_body(self)
        if payload is None:
            return
        query = payload.get("query")
        if not query or not isinstance(query, str):
            self.send_error(400, "query required")
            return
        app_bundle_id = payload.get("app_bundle_id")
        if app_bundle_id is not None and not isinstance(app_bundle_id, str):
            app_bundle_id = None
        since = payload.get("since") if isinstance(payload.get("since"), str) else None
        until = payload.get("until") if isinstance(payload.get("until"), str) else None
        # Optional per-request model override (opaque tag; local provider only).
        # Absent or unusable means "app default" — never a 400.
        model = payload.get("model") if isinstance(payload.get("model"), str) else None
        con, lock = db_ref
        user_id = get_active_user_id()

        from orbit.search.intent import classify_query, ChatIntent

        try:
            parsed = classify_query(con, query)
        except Exception:
            logger.exception("intent classification failed; falling back to search")
            parsed = None

        # Client-supplied app_bundle_id takes precedence over inferred.
        if app_bundle_id is None and parsed and parsed.app_bundle_id:
            app_bundle_id = parsed.app_bundle_id

        # Use parsed time window if the client didn't supply one.
        if since is None and until is None and parsed:
            since = parsed.since
            until = parsed.until

        intent = parsed.intent if parsed else ChatIntent.SEARCH

        if intent == ChatIntent.RECAP:
            try:
                self._chat_recap_path(con, lock, query, user_id, db_ref, model, app_bundle_id)
                return
            except Exception:
                logger.exception("recap path failed; falling back to search")

        elif intent == ChatIntent.APP_SCOPED:
            try:
                from orbit.search.hybrid import search_bridge
                from orbit.check.llm import complete

                hits = search_bridge(
                    con, query, limit=8,
                    app_bundle_id=app_bundle_id, since=since, until=until, user_id=user_id,
                )
                context = _build_chat_context(hits)
                header = f"Focus: {parsed.app_name} activity\n\n" if parsed and parsed.app_name else ""
                user_msg = f"{header}Context:\n{context}\n\nQuestion: {query}"
                answer = complete(
                    _DIGEST_CHAT_SYSTEM, user_msg,
                    call_site="chat_app_scoped", db_ref=db_ref, model=model,
                )
                self._stream_chat_sse(answer or "", hits)
                return
            except Exception:
                logger.exception("app-scoped path failed; falling back to search")

        elif intent == ChatIntent.ENTITY:
            try:
                from orbit.memory.entities import entity_timeline
                from orbit.search.hybrid import search_bridge
                from orbit.check.llm import complete

                timeline = entity_timeline(con, parsed.entity_id, limit=50)
                blocks = [
                    (
                        f"[{i}] {entry.get('app_name') or '?'} — {entry.get('window_title') or 'untitled'} "
                        f"({entry.get('timestamp') or '?'})",
                        entry.get("snippet") or "",
                    )
                    for i, entry in enumerate(timeline[:20], start=1)
                ]
                entity_context = wrap_untrusted(blocks)

                search_hits = search_bridge(
                    con, parsed.entity_name or query, limit=5,
                    since=since, until=until, user_id=user_id,
                )
                search_context = _build_chat_context(search_hits)

                user_msg = (
                    f"Entity: {parsed.entity_name}\n\n"
                    f"Timeline:\n{entity_context}\n\n"
                    f"Related search results:\n{search_context}\n\n"
                    f"Question: {query}"
                )
                answer = complete(
                    _ENTITY_CHAT_SYSTEM, user_msg,
                    call_site="chat_entity", db_ref=db_ref, model=model,
                )
                self._stream_chat_sse(answer or "", search_hits)
                return
            except Exception:
                logger.exception("entity path failed; falling back to search")

        elif intent == ChatIntent.HYBRID:
            try:
                from orbit.memory.digest import build_digest, render_digest_markdown
                from orbit.memory.sessions import sessions_to_hits
                from orbit.search.hybrid import search_bridge
                from orbit.check.llm import complete

                day = parsed.day if parsed else None
                if day:
                    digest = build_digest(con, lock, day=day, use_llm=False, db_ref=db_ref)
                    md = render_digest_markdown(digest)
                    digest_hits = sessions_to_hits(con, digest.get("sessions") or [], limit=4)
                else:
                    md = ""
                    digest_hits = []

                search_hits = search_bridge(
                    con, query, limit=5, since=since, until=until, user_id=user_id,
                )

                context = wrap_untrusted([("daily digest", md)]) if md else ""
                search_context = _build_chat_context(search_hits)
                user_msg = (
                    f"Context:\n{context}\n\n"
                    f"Topic-specific results:\n{search_context}\n\n"
                    f"Question: {query}"
                )
                answer = complete(
                    _DIGEST_CHAT_SYSTEM, user_msg,
                    call_site="chat_hybrid", db_ref=db_ref, model=model,
                )
                all_hits = digest_hits + search_hits
                self._stream_chat_sse(answer or "", all_hits[:8])
                return
            except Exception:
                logger.exception("hybrid path failed; falling back to search")

        # SEARCH intent (default), or fallback from any failed path above.
        self._chat_search_path(con, query, user_id, app_bundle_id, since, until, model, db_ref)

    def _chat_recap_path(self, con, lock, query, user_id, db_ref, model, app_bundle_id) -> None:
        """Digest-backed recap path: day digest, or multi-day window search.

        Streams via self._stream_chat_sse and returns. Raises on failure so the
        caller can fall through to the search path.
        """
        from orbit.memory.digest import digest_day_from_query, parse_chat_time_window

        day = digest_day_from_query(query)
        if day is not None:
            from orbit.memory.digest import build_digest, render_digest_markdown
            from orbit.memory.sessions import sessions_to_hits

            digest = build_digest(
                con, lock, day=day, use_llm=False, db_ref=db_ref
            )
            md = render_digest_markdown(digest)
            hits = sessions_to_hits(
                con, digest.get("sessions") or [], limit=8
            )
            context = wrap_untrusted([("daily digest", md)])
            fallback_answer = digest.get("narrative") or md
        else:
            # Multi-day window (e.g. this week): filtered search.
            win_since, win_until = parse_chat_time_window(query)
            from orbit.search.hybrid import search_bridge

            hits = search_bridge(
                con,
                query,
                limit=8,
                app_bundle_id=app_bundle_id,
                since=win_since,
                until=win_until,
                user_id=user_id,
            )
            context = _build_chat_context(hits)
            fallback_answer = None
        system = _DIGEST_CHAT_SYSTEM
        user_msg = f"Context:\n{context}\n\nQuestion: {query}"
        try:
            from orbit.check.llm import complete

            answer = complete(
                system,
                user_msg,
                call_site="chat_digest",
                db_ref=db_ref,
                model=model,
            )
        except Exception as exc:
            # Previously fell back to streaming the raw digest markdown
            # (`fallback_answer`) as if it were the model's answer — a silent
            # failure that read as "chat gives an overview instead of
            # searching" (Plan 48 §0.1 Defect A). Report the failure instead,
            # mirroring `_chat_search_path`'s use of `format_completion_error`.
            logger.exception("chat digest LLM failed")
            from orbit.check.llm import format_completion_error

            _send_json(self, 503, {"error": format_completion_error(exc)})
            return
        self._stream_chat_sse(answer or fallback_answer or "", hits)

    def _chat_search_path(self, con, query, user_id, app_bundle_id, since, until, model, db_ref) -> None:
        """Search-bridge fallback path: infer time window, search, complete, stream.

        This is also the final fallback for every other chat intent path, so its
        error responses (503 JSON) must be preserved exactly.
        """
        if since is None and until is None:
            from orbit.memory.digest import parse_chat_time_window

            since, until = parse_chat_time_window(query)

        try:
            from orbit.search.hybrid import search_bridge

            hits = search_bridge(
                con,
                query,
                limit=8,
                app_bundle_id=app_bundle_id,
                since=since,
                until=until,
                user_id=user_id,
            )
        except Exception as exc:
            logger.exception("chat search failed")
            _send_json(self, 503, {"error": str(exc)})
            return
        context = _build_chat_context(hits)
        user_msg = f"Context:\n{context}\n\nQuestion: {query}"
        try:
            from orbit.check.llm import complete

            answer = complete(
                _CHAT_SYSTEM,
                user_msg,
                call_site="chat",
                db_ref=db_ref,
                model=model,
            )
        except Exception as exc:
            logger.exception("chat completion failed")
            from orbit.check.llm import format_completion_error

            _send_json(self, 503, {"error": format_completion_error(exc)})
            return
        self._stream_chat_sse(answer or "", hits)

    def _stream_chat_sse(self, text: str, hits: list[Hit]) -> None:
        """Write the whole SSE body at once, length-framed and explicitly closed.

        Despite the name this never streamed: every caller blocks on ``complete()``
        first and hands us the finished answer, so all three events are known before
        the first byte. Buffering therefore costs nothing and lets us set a real
        ``Content-Length``, the same framing every other responder here uses
        (``_send_json``). Without it the response was delimited by *nothing* —
        no length, no ``Transfer-Encoding: chunked`` — while simultaneously
        advertising ``Connection: keep-alive``, so a client had no way to know the
        body had ended and sat waiting on an EOF that did not arrive. That is the
        "orbit is thinking…" spinner that never cleared (plan 52).

        The ``Connection: keep-alive`` header was not merely cosmetic, and this is
        the part worth remembering: ``BaseHTTPRequestHandler.send_header`` inspects
        the header you are *sending* and does ``self.close_connection = False`` for
        a keep-alive value — unconditionally, with no ``protocol_version`` check
        (CPython 3.13 ``http/server.py``). So sending it made ``handle()`` loop and
        wait for a second request on the same socket, and the EOF that was the
        body's only remaining delimiter never came. Missing length *and* suppressed
        EOF is why the client waited forever rather than merely a little too long.
        ``Connection: close`` reverses that flag; the explicit assignment above
        states the intent without depending on that side effect.

        The trailing ``data: [DONE]`` line is the terminal signal the Swift client
        actually matches (``OrbitBridgeClient.chatStream``, which breaks on a
        ``data: ``-prefixed payload equal to ``[DONE]``). The pre-existing
        ``event: done`` frame is kept as-is so nothing that reads event names
        regresses; ``[DONE]`` is purely additive, and one line here fixes every
        chat intent that funnels through this method.
        """
        events = [
            ("delta", {"text": text}),
            ("sources", {"hits": [_hit_to_dict(h) for h in hits]}),
            ("done", {}),
        ]
        body = "".join(
            f"event: {name}\ndata: {json.dumps(data)}\n\n" for name, data in events
        )
        body += "data: [DONE]\n\n"
        payload = body.encode("utf-8")
        self.close_connection = True
        self.send_response(200)
        self.send_header("Content-Type", "text/event-stream")
        self.send_header("Cache-Control", "no-cache")
        self.send_header("Content-Length", str(len(payload)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(payload)
        self.wfile.flush()


def start_browser_bridge(
    event_queue: queue.Queue,
    port: int = DEFAULT_PORT,
    db_ref: DbRef | None = None,
    capture_active_ref: CaptureActiveRef | None = None,
    shutdown_hook: Callable[[], None] | None = None,
    bridge_token: str | None = None,
    dispatch_queue: queue.Queue | None = None,
) -> tuple[ThreadingHTTPServer, threading.Thread]:
    """Start localhost HTTP server; returns (server, thread)."""
    # Imported here, not at module scope: orbit.capture.daemon pulls in PyObjC and the
    # status bar at import time, and this module is imported by tests and by the CLI on
    # paths that never start a daemon. The only caller of start_browser_bridge is the
    # daemon itself, so by the time this runs the module is loaded anyway. Reusing its
    # _BoundedQueue keeps a single overflow policy rather than a second copy here.
    from orbit.capture.daemon import DISPATCH_PUT_TIMEOUT_S, DISPATCH_QUEUE_MAXSIZE, _BoundedQueue

    if db_ref is not None:
        migrate(db_ref[0])
        from orbit.check.llm import set_llm_audit_db

        set_llm_audit_db(db_ref[0], db_ref[1])
    server = ThreadingHTTPServer(("127.0.0.1", port), _BridgeHandler)
    server.event_queue = event_queue  # type: ignore[attr-defined]
    server.db_ref = db_ref  # type: ignore[attr-defined]
    server.capture_active_ref = capture_active_ref  # type: ignore[attr-defined]
    server.shutdown_hook = shutdown_hook  # type: ignore[attr-defined]
    server.bridge_token = bridge_token  # type: ignore[attr-defined]
    if dispatch_queue is None and db_ref is not None:
        # The daemon always supplies a bounded one; this fallback (direct callers,
        # tests) used to be a seventh unbounded queue. Same bound and policy as
        # daemon.py's so behaviour doesn't depend on who constructed it.
        dispatch_queue = _BoundedQueue(
            DISPATCH_QUEUE_MAXSIZE,
            name="dispatch_queue",
            policy="drop_newest",
            put_timeout=DISPATCH_PUT_TIMEOUT_S,
            drop_hint="An APPROVED task was not dispatched — re-approve it once the dispatch worker recovers.",
        )
    server.dispatch_queue = dispatch_queue  # type: ignore[attr-defined]
    if dispatch_queue is not None and db_ref is not None:
        worker = threading.Thread(
            target=_run_dispatch_worker,
            args=(dispatch_queue, db_ref),
            daemon=True,
            name="bridge-dispatch-worker",
        )
        worker.start()
        server.dispatch_worker = worker  # type: ignore[attr-defined]
    detect_run = DetectRun()
    detect_run_lock = threading.Lock()
    server.detect_run = detect_run  # type: ignore[attr-defined]
    server.detect_run_lock = detect_run_lock  # type: ignore[attr-defined]
    detect_queue: queue.Queue | None = (
        _BoundedQueue(
            DETECT_QUEUE_MAXSIZE,
            name="detect_queue",
            policy="drop_newest",
            put_timeout=DETECT_PUT_TIMEOUT_S,
            drop_hint="A detection run was not queued; its status will stay 'running' until retried.",
        )
        if db_ref is not None
        else None
    )
    server.detect_queue = detect_queue  # type: ignore[attr-defined]
    if detect_queue is not None and db_ref is not None:
        detect_worker = threading.Thread(
            target=_run_detect_worker,
            args=(detect_queue, db_ref, detect_run, detect_run_lock),
            daemon=True,
            name="bridge-detect-worker",
        )
        detect_worker.start()
        server.detect_worker = detect_worker  # type: ignore[attr-defined]
    thread = threading.Thread(
        target=server.serve_forever,
        name="browser-bridge",
        daemon=True,
    )
    thread.start()
    logger.info("Browser bridge listening on http://127.0.0.1:%d", port)
    return server, thread


def stop_browser_bridge(server: ThreadingHTTPServer) -> None:
    dispatch_queue: queue.Queue | None = getattr(server, "dispatch_queue", None)
    if dispatch_queue is not None:
        dispatch_queue.put(None)
    detect_queue: queue.Queue | None = getattr(server, "detect_queue", None)
    if detect_queue is not None:
        detect_queue.put(None)
    server.shutdown()
