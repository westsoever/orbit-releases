"""Orbit capture daemon — listens for app-focus events and logs AX context to SQLite.

Entry points::

    orbit start [--no-embed] [--db PATH]
    python -m orbit.capture.daemon --db ./orbit.db [--no-embed]

DB selection (see ``orbit.storage.db``):

- Default: ``open_db`` with embed worker when SQLite extensions are available.
- ``--no-embed`` or missing extension support: ``open_db_plain``, capture + FTS only.

Requires macOS Accessibility permission (see ``orbit/capture/PERMISSIONS.md``).
"""
from __future__ import annotations

import argparse
import logging
import queue
import sys
import threading
import time

from PyObjCTools import AppHelper
from orbit.capture.listener import AppFocusListener
from orbit.capture.worker import run_capture_worker
from orbit.storage.db import open_db, open_db_plain, sqlite_supports_extensions
from orbit.ui.statusbar import OrbitStatusBar

logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s %(levelname)-8s %(name)s — %(message)s",
)
logger = logging.getLogger(__name__)

# Matches segment_sessions()'s default idle_gap_minutes: the same gap that closes
# a session (orbit/memory/sessions.py) is what should fire this handler, so a
# session's boundary and its trigger agree.
IDLE_DEBOUNCE_MINUTES = 12.0


# Queue bounds (Plan 52 §3). Every daemon queue used to be an unbounded
# ``queue.Queue()``: if a consumer stalls (e.g. an AX walk hanging on a
# pathological tree) the backlog grew for the whole life of the session with no
# eviction. Bounds are deliberately *per queue* — a focus-change stream and an
# embedding job stream have very different natural depths and very different
# costs when an item is lost. This is robustness hardening; it is not a fix for
# an observed crash.
FOCUS_QUEUE_MAXSIZE = 256  # focus events are ≥1.5s apart per app: 256 ≈ minutes of stall
EMBED_QUEUE_MAXSIZE = 4096  # one capture can emit hundreds of atoms; drained in batches of 32
BROWSER_QUEUE_MAXSIZE = 512  # one item per browser page/selection ingest
DISPATCH_QUEUE_MAXSIZE = 64  # human-approved tasks only (approval budget is 2–5/day)
FS_QUEUE_MAXSIZE = 4096  # FSEvents bursts hard on a checkout/build

# How long a full queue may hold a producer that is allowed to wait at all.
# Never used for run-loop producers (focus/FSEvents), which must never block.
# NOTE: this is paid PER ITEM, and the embed producers put one item per *atom* in a
# loop (`orbit/capture/worker.py:141,347`), not one item per capture. So the real cost
# of a stalled embed consumer is 0.1s × atoms-in-this-capture: a 300-atom page costs the
# `capture-worker` thread ~30s of cumulative blocking, not 0.1s. That is tolerable and
# deliberate — `capture-worker` is a dedicated thread, the run-loop producers (focus,
# FSEvents) never block on it, and the alternative (dropping without waiting) loses
# embeddings during ordinary short backlogs. It is documented here because the per-item
# framing reads as if the ceiling were 0.1s per capture, and it isn't.
EMBED_PUT_TIMEOUT_S = 0.1  # capture thread: brief backpressure, never a stall
BROWSER_PUT_TIMEOUT_S = 0.5  # HTTP handler thread, one per request
DISPATCH_PUT_TIMEOUT_S = 5.0  # losing an approved task is expensive; wait properly

_QUEUE_LOG_INTERVAL_S = 60.0  # rate limit: daemon.log already runs to megabytes


class _BoundedQueue(queue.Queue):
    """A bounded ``queue.Queue`` with an explicit overflow policy and logging.

    A bound alone would just move the failure: an unhandled ``queue.Full`` in a
    producer thread is worse than the backlog it replaces, and a blocking
    ``put`` on the capture/run-loop threads would deadlock capture outright. So
    overflow is handled *inside* ``put`` — every producer (several of which live
    in other modules and call ``put`` with default arguments) gets the policy
    for free and never sees ``queue.Full``.

    Policies:

    ``drop_oldest``
        Never blocks; evicts the head to make room. For real-time event streams
        whose producer is a macOS run-loop callback (app focus, FSEvents) —
        blocking there stalls the daemon's entire event loop — and where the
        newest event is the one worth keeping.
    ``drop_newest``
        Waits up to ``put_timeout`` seconds for room, then drops the incoming
        item. For work queues where FIFO progress matters and a short, bounded
        wait is legitimate backpressure rather than a stall.

    ``None`` is the shutdown sentinel every worker loop keys off. It is never
    dropped and never blocks — it evicts to make room if it has to.
    """

    def __init__(
        self,
        maxsize: int,
        *,
        name: str,
        policy: str = "drop_oldest",
        put_timeout: float = 0.0,
        drop_hint: str = "",
    ) -> None:
        super().__init__(maxsize=maxsize)
        self._name = name
        self._policy = policy
        self._put_timeout = put_timeout
        self._drop_hint = drop_hint
        self._high_water = max(1, int(maxsize * 0.8))
        self._dropped = 0
        self._log_lock = threading.Lock()
        self._last_log: dict[str, float] = {}

    def put(self, item, block=True, timeout=None):  # noqa: A003 - Queue's own signature
        if item is None or self._policy == "drop_oldest":
            # Shutdown sentinels always land, whatever the policy.
            self._put_evicting(item)
        else:
            # The queue's own put_timeout supersedes the caller's timeout: the
            # point of the bound is to cap how long *any* producer can be held.
            try:
                super().put(item, block=bool(block), timeout=self._put_timeout if block else None)
            except queue.Full:
                self._note_drop()
                return
        self._note_high_water()

    def _put_evicting(self, item) -> None:
        """Put without ever blocking, discarding the oldest *droppable* item if need be.

        A ``None`` already in the queue is never a valid eviction victim, and the
        invariant lives here rather than in the callers on purpose. Making it a
        property of the data structure means no ordering rule has to be
        remembered at any of the shutdown call sites — and one of them was
        already wrong: ``main()``'s ``finally`` does ``fs_queue.put(None)``
        *before* ``fs_listener.stop()``, so the FSEvents run-loop callback is
        still producing after the sentinel is enqueued. On a burst that filled
        the 4096-deep queue, the next callback evicted the head — the sentinel —
        and ``run_fs_worker`` would never have exited.

        If the head turns out to be the sentinel we let it lose its place in
        line but not its existence: it is re-queued behind the incoming item.
        Ordering does not matter for a shutdown marker (a worker stops at the
        first one it sees); surviving does. The re-queue recurses exactly one
        level deep, because the recursive call passes ``None`` and so cannot
        take this branch again.
        """
        resurrect = False
        while True:
            try:
                super().put(item, block=False)
                break
            except queue.Full:
                pass
            try:
                victim = self.get_nowait()
            except queue.Empty:
                continue  # drained concurrently — just retry the put
            try:
                self.task_done()
            except ValueError:
                pass  # only some consumers track task_done; never fatal here
            if victim is None:
                resurrect = True  # not a drop: the sentinel goes back in below
            else:
                self._note_drop()
        if resurrect and item is not None:
            self._put_evicting(None)

    def _should_log(self, key: str) -> bool:
        now = time.monotonic()
        with self._log_lock:
            if now - self._last_log.get(key, 0.0) < _QUEUE_LOG_INTERVAL_S:
                return False
            self._last_log[key] = now
            return True

    def _note_drop(self) -> None:
        with self._log_lock:  # producers are multi-threaded; keep the count honest
            self._dropped += 1
        if self._should_log("full"):
            logger.warning(
                "queue %s is full (maxsize=%d, policy=%s) — dropped %d item(s) so far; "
                "its consumer is stalled or slower than its producer.%s",
                self._name,
                self.maxsize,
                self._policy,
                self._dropped,
                f" {self._drop_hint}" if self._drop_hint else "",
            )

    def _note_high_water(self) -> None:
        depth = self.qsize()
        if depth >= self._high_water and self._should_log("high"):
            logger.warning(
                "queue %s is at %d/%d — consumer falling behind", self._name, depth, self.maxsize
            )

    @property
    def dropped_count(self) -> int:
        return self._dropped


class _IdleDebounceQueue(_BoundedQueue):
    """A focus_queue that resets an idle timer on every real item it receives.

    AppFocusListener pushes one item per app switch; run_capture_worker drains
    the same queue for capture. There is no other idle/session-boundary signal
    in this codebase (Plan 17 Phase 5.4) — wrapping ``put`` lets the daemon
    observe every focus event without a second consumer or a polling loop:
    the timer is only ever reset by a real event and only fires after a real
    gap in activity, which is the event-driven idiom, not periodic checking.

    Bounded drop-oldest: the producer is the NSWorkspace notification callback
    on the main run loop, which must never block, and a stale focus event is
    cheap to lose — capturing what the user is doing *now* is the point.
    """

    def __init__(self, on_activity, maxsize: int = FOCUS_QUEUE_MAXSIZE):
        super().__init__(
            maxsize,
            name="focus_queue",
            policy="drop_oldest",
            drop_hint="Oldest focus events are discarded; capture stays live on recent ones.",
        )
        self._on_activity = on_activity

    def put(self, item, block=True, timeout=None):  # noqa: A003 - Queue's own signature
        super().put(item, block=block, timeout=timeout)
        if item is not None:  # None is the shutdown sentinel, not activity
            self._on_activity()


def main() -> None:
    parser = argparse.ArgumentParser(description="orbit capture daemon")
    parser.add_argument("--db", default="./orbit.db", help="SQLite DB path")
    parser.add_argument("--no-embed", action="store_true", help="Skip embedding worker")
    parser.add_argument(
        "--max-depth",
        type=int,
        default=None,
        help="Override AX tree depth (default: 12 native, 24 Electron, 20 Chromium)",
    )
    parser.add_argument(
        "--browser-bridge-port",
        type=int,
        default=8765,
        help="Localhost port for browser companion extension (default: 8765)",
    )
    parser.add_argument(
        "--no-browser-bridge",
        action="store_true",
        help="Disable browser extension HTTP ingest",
    )
    parser.add_argument(
        "--ocr",
        action="store_true",
        help="Enable Tier 4 OCR fallback (also set tier_ocr in ~/.orbit/policy.json)",
    )
    parser.add_argument(
        "--no-fsevents",
        action="store_true",
        help="Disable FSEvents workspace capture (even if tier_fsevents in policy)",
    )
    parser.add_argument(
        "--no-statusbar",
        action="store_true",
        help="Skip the Python menu bar indicator",
    )
    parser.add_argument(
        "--purge-retention",
        action="store_true",
        help="On startup, delete capture events older than policy retention_days",
    )
    args = parser.parse_args()

    from orbit.ui.macos_app import hide_from_dock

    hide_from_dock()

    from orbit.storage.session import (
        NoActiveUserError,
        ensure_local_user,
        require_active_user_id,
    )

    try:
        require_active_user_id()
    except NoActiveUserError:
        # Plan 53 Phase 1 — no sign-up wall. A missing session is not fatal: mint a
        # local-only identity and carry on. The try/except stays because
        # `require_active_user_id()` must keep raising for every other caller
        # (storage/writer.py runs it on each capture write); only this startup path
        # is allowed to auto-create.
        user_id = ensure_local_user(args.db)
        logger.info("No active session; created local user %s", user_id)

    from orbit.daemon_ctl import is_daemon_running
    from orbit.daemon_pid import read_pid

    health_url = f"http://127.0.0.1:{args.browser_bridge_port}/health"
    if is_daemon_running(health_url):
        pid = read_pid()
        logger.error(
            "Another orbit daemon is already running (pid %s).",
            pid if pid is not None else "unknown",
        )
        sys.exit(1)

    from orbit.capture.policy import load_policy

    policy = load_policy()
    if args.ocr:
        policy.tier_ocr = True

    from orbit.telemetry import init_telemetry, track_event

    init_telemetry(policy)
    track_event(
        "daemon_started",
        {"no_embed": args.no_embed, "ocr": bool(args.ocr or policy.tier_ocr)},
    )

    use_embed = not args.no_embed and sqlite_supports_extensions()
    if args.no_embed:
        con, lock = open_db_plain(args.db)
        logger.info("Database opened at %s (capture-only, no embeddings)", args.db)
    elif use_embed:
        con, lock = open_db(args.db)
        logger.info(
            "Database opened at %s (embeddings enabled — use --no-embed for lower CPU/RAM)",
            args.db,
        )
    else:
        con, lock = open_db_plain(args.db)
        logger.warning(
            "SQLite extensions unavailable on %s; running capture-only (no embeddings). "
            "Use Homebrew Python for full embed support — see README.",
            sys.executable,
        )

    if args.purge_retention:
        from orbit.privacy import purge_older_than

        n = purge_older_than(con, policy.retention_days)
        if n:
            logger.info("Purged %d events older than %d days", n, policy.retention_days)

    try:
        from datetime import datetime, timedelta, timezone

        from orbit.memory.sessions import segment_sessions

        since = (datetime.now(timezone.utc) - timedelta(days=2)).isoformat()
        n_sess = segment_sessions(con, lock, since=since, min_events=2)
        if n_sess:
            logger.info("Segmented %d session(s) on startup", len(n_sess))
    except Exception:
        logger.exception("session segmentation on startup failed")

    if args.no_statusbar:
        statusbar = None
    else:
        statusbar = OrbitStatusBar()
        logger.info("Status bar initialized")

    capture_active = threading.Event()

    idle_timer_lock = threading.Lock()
    idle_timer: threading.Timer | None = None

    def _on_idle_fire() -> None:
        """The session-close signal: fires once activity has stopped for
        IDLE_DEBOUNCE_MINUTES. Always segments the just-finished window; only
        runs detection when the user opted in (``policy.detect_enabled``).

        Detection here reuses ``_detect_once`` rather than re-implementing the
        detect → gate → insert sequence (it already shares this daemon's ``con``/
        ``lock`` via the in-process browser bridge import). That function was
        gated in Phase 5.3 (``filter_tasks`` runs before any ``insert_task``), so
        calling it here gets the dedupe/score/budget gate for free — this
        handler must not apply a second round of gating on top of it.
        """
        from datetime import datetime, timedelta, timezone

        from orbit.memory.sessions import segment_sessions

        try:
            since = (
                datetime.now(timezone.utc) - timedelta(minutes=IDLE_DEBOUNCE_MINUTES * 3)
            ).isoformat()
            segment_sessions(con, lock, since=since, min_events=2)
        except Exception:
            logger.exception("idle-triggered session segmentation failed")

        if not policy.detect_enabled:
            return

        from orbit.browser_bridge.server import DETECT_DEFAULT_SINCE_HOURS, _detect_once

        try:
            task_ids, error, error_kind = _detect_once(
                (con, lock),
                DETECT_DEFAULT_SINCE_HOURS,
                False,
                cap=policy.detect_daily_cap,
            )
        except Exception:
            logger.exception("idle-triggered detection failed")
            return
        if error:
            logger.info(
                "idle-triggered detection produced no tasks: %s (%s)", error, error_kind
            )
            return
        if not task_ids:
            # Gate suppressed everything, or nothing cleared the confidence
            # threshold — either way this is a zero-task run, so no notification.
            return

        from orbit.telemetry import track_event

        track_event("task_detected", {"count": len(task_ids)})

        from orbit.check.notify import notify

        notify("orbit", f"{len(task_ids)} task(s) detected from your recent context")

    def _reset_idle_timer() -> None:
        nonlocal idle_timer
        with idle_timer_lock:
            if idle_timer is not None:
                idle_timer.cancel()
            idle_timer = threading.Timer(IDLE_DEBOUNCE_MINUTES * 60, _on_idle_fire)
            idle_timer.daemon = True
            idle_timer.start()

    focus_queue: queue.Queue = _IdleDebounceQueue(
        on_activity=_reset_idle_timer, maxsize=FOCUS_QUEUE_MAXSIZE
    )
    # embed_queue: producers are the capture worker and the browser worker, both
    # plain threads, so a short bounded wait is safe backpressure. Dropping the
    # *newest* keeps FIFO progress, and a lost atom is recoverable — it stays in
    # `text_atoms` with no `vec_atoms` row, which `backfill_embeddings` re-embeds.
    embed_queue: queue.Queue | None = (
        None
        if not use_embed
        else _BoundedQueue(
            EMBED_QUEUE_MAXSIZE,
            name="embed_queue",
            policy="drop_newest",
            put_timeout=EMBED_PUT_TIMEOUT_S,
            drop_hint="Dropped atoms stay searchable via FTS; run an embedding backfill to recover them.",
        )
    )

    listener = AppFocusListener(q=focus_queue)

    def _request_shutdown() -> None:
        from PyObjCTools import AppHelper

        AppHelper.callAfter(AppHelper.stopEventLoop)

    browser_queue: queue.Queue | None = None
    browser_server = None
    if not args.no_browser_bridge:
        from orbit.browser_bridge.auth import ensure_bridge_token
        from orbit.browser_bridge.server import start_browser_bridge
        from orbit.browser_bridge.worker import run_browser_worker

        bridge_token = ensure_bridge_token()
        from orbit.check.llm import set_llm_audit_db

        set_llm_audit_db(con, lock)
        # browser_queue: produced by per-request HTTP handler threads, consumed
        # by run_browser_worker (a DB insert). Waiting half a second in a request
        # thread is fine; past that the ingest is dropped and the extension can
        # re-send on the next navigation.
        browser_queue = _BoundedQueue(
            BROWSER_QUEUE_MAXSIZE,
            name="browser_queue",
            policy="drop_newest",
            put_timeout=BROWSER_PUT_TIMEOUT_S,
            drop_hint="Browser page ingest was discarded; re-visiting the page re-sends it.",
        )
        # dispatch_queue: carries human-approved task dispatches — the most
        # expensive item in the daemon to lose, and produced at human speed, so
        # it gets the deepest wait before giving up. A drop here means something
        # is badly wrong with the dispatch worker, hence the loud hint.
        dispatch_queue = _BoundedQueue(
            DISPATCH_QUEUE_MAXSIZE,
            name="dispatch_queue",
            policy="drop_newest",
            put_timeout=DISPATCH_PUT_TIMEOUT_S,
            drop_hint="An APPROVED task was not dispatched — re-approve it once the dispatch worker recovers.",
        )
        browser_server, _ = start_browser_bridge(
            browser_queue,
            port=args.browser_bridge_port,
            db_ref=(con, lock),
            capture_active_ref=capture_active,
            shutdown_hook=_request_shutdown,
            bridge_token=bridge_token,
            dispatch_queue=dispatch_queue,
        )
        browser_thread = threading.Thread(
            target=run_browser_worker,
            args=(browser_queue, embed_queue, con, lock),
            daemon=True,
            name="browser-worker",
        )
        browser_thread.start()

    capture_thread = threading.Thread(
        target=run_capture_worker,
        args=(focus_queue, embed_queue, con, lock),
        kwargs={
            "max_depth": args.max_depth,
            "policy": policy,
            "on_capture_start": lambda: (
                capture_active.set(),
                statusbar.set_active() if statusbar else None,
            ),
            "on_capture_done": lambda: (
                capture_active.clear(),
                statusbar.set_idle() if statusbar else None,
            ),
        },
        daemon=True,
        name="capture-worker",
    )
    capture_thread.start()

    fs_listener = None
    fs_queue: queue.Queue | None = None
    if policy.tier_fsevents and not args.no_fsevents and policy.watch_roots:
        from orbit.capture.fsevents_listener import FSEventsListener
        from orbit.capture.fs_worker import run_fs_worker

        # fs_queue: produced by the FSEvents callback, which runs on this
        # daemon's main CFRunLoop — blocking it would stall the focus listener
        # and the whole event loop. Never block; drop the oldest paths.
        fs_queue = _BoundedQueue(
            FS_QUEUE_MAXSIZE,
            name="fs_queue",
            policy="drop_oldest",
            drop_hint="Oldest filesystem events are discarded during a burst.",
        )
        fs_thread = threading.Thread(
            target=run_fs_worker,
            args=(fs_queue, con, lock),
            daemon=True,
            name="fs-worker",
        )
        fs_thread.start()
        fs_listener = FSEventsListener(fs_queue, policy.watch_roots)

    if embed_queue is not None:
        from orbit.embed.worker import run_embedding_worker

        embed_thread = threading.Thread(
            target=run_embedding_worker,
            args=(embed_queue, con, lock),
            daemon=True,
            name="embed-worker",
        )
        embed_thread.start()

    from orbit.daemon_pid import write_pid

    write_pid()
    logger.info("orbit daemon running. Switch app focus to capture context. Ctrl-C to stop.")
    try:
        AppHelper.runConsoleEventLoop(installInterrupt=True)
    finally:
        logger.info("Shutting down...")
        track_event("daemon_stopped")
        listener.stop()
        with idle_timer_lock:
            if idle_timer is not None:
                idle_timer.cancel()
        focus_queue.put(None)
        if browser_queue is not None:
            browser_queue.put(None)
        dispatch_queue_ref = getattr(browser_server, "dispatch_queue", None)
        if dispatch_queue_ref is not None:
            dispatch_queue_ref.put(None)
        # Silence the producer before enqueuing its sentinel, matching the
        # focus path above (`listener.stop()` then `focus_queue.put(None)`).
        # `_put_evicting` now guarantees the sentinel survives either way, but
        # stopping first means a shutdown burst can't evict real work for no
        # reason.
        if fs_listener is not None:
            fs_listener.stop()
        if fs_queue is not None:
            fs_queue.put(None)
        if browser_server is not None:
            from orbit.browser_bridge.server import stop_browser_bridge

            stop_browser_bridge(browser_server)
        if embed_queue is not None:
            embed_queue.put(None)
        from orbit.daemon_pid import remove_pid

        remove_pid()


if __name__ == "__main__":
    main()
