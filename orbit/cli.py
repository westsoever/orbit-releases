"""Orbit CLI — entry point for the ``orbit`` command.

Commands:

- ``orbit start`` — run the capture daemon (default DB: ``~/.orbit/orbit.db``)
- ``orbit start --detach`` — run daemon in background (PID file + log)
- ``orbit stop`` — stop a detached daemon
- ``orbit check`` — detect tasks from context and optionally dispatch one

On macOS, embeddings require a venv built with Homebrew Python (see README).
Use ``orbit start --no-embed`` when SQLite extensions are unavailable.
"""
from __future__ import annotations

import argparse
import sys


def main() -> None:
    # Re-exec via .venv when python.org Python lacks SQLite extensions.
    from orbit.runtime import maybe_reexec_for_embeddings

    maybe_reexec_for_embeddings(sys.argv)

    parser = argparse.ArgumentParser(prog="orbit", description="orbit context daemon")
    sub = parser.add_subparsers(dest="command", metavar="command")

    start_p = sub.add_parser("start", help="Start the capture daemon")
    start_p.add_argument("--db", default="~/.orbit/orbit.db", help="SQLite DB path (default: ~/.orbit/orbit.db)")
    start_p.add_argument("--no-embed", action="store_true", help="Skip embedding worker")
    start_p.add_argument(
        "--max-depth",
        type=int,
        default=None,
        help="Override AX tree depth (default: 12 native, 24 Electron, 20 Chromium)",
    )
    start_p.add_argument(
        "--browser-bridge-port",
        type=int,
        default=8765,
        help="Localhost port for browser companion extension (default: 8765)",
    )
    start_p.add_argument(
        "--no-browser-bridge",
        action="store_true",
        help="Disable browser extension HTTP ingest",
    )
    start_p.add_argument(
        "--ocr",
        action="store_true",
        help="Enable Tier 4 OCR fallback when AX capture fails",
    )
    start_p.add_argument(
        "--purge-retention",
        action="store_true",
        help="Delete capture events older than policy retention_days on startup",
    )
    start_p.add_argument(
        "--no-fsevents",
        action="store_true",
        help="Disable FSEvents workspace capture (even if tier_fsevents in policy)",
    )
    start_p.add_argument(
        "--detach",
        action="store_true",
        help="Start daemon in background (logs to ~/.orbit/daemon.log)",
    )
    start_p.add_argument(
        "--no-statusbar",
        action="store_true",
        help="Skip the Python menu bar indicator (use when orbit Access App is active)",
    )

    stop_p = sub.add_parser("stop", help="Stop a detached capture daemon")
    stop_p.add_argument(
        "--pid-file",
        default="~/.orbit/daemon.pid",
        help="PID file path (default: ~/.orbit/daemon.pid)",
    )
    stop_p.add_argument(
        "--timeout",
        type=float,
        default=10.0,
        help="Seconds to wait for graceful shutdown (default: 10)",
    )

    privacy_p = sub.add_parser("privacy", help="Export, delete, or configure capture privacy")
    privacy_sub = privacy_p.add_subparsers(dest="privacy_action", metavar="action")

    p_export = privacy_sub.add_parser("export", help="Export capture data to JSONL")
    p_export.add_argument("--db", default="~/.orbit/orbit.db")
    p_export.add_argument("--out", required=True)

    p_delete = privacy_sub.add_parser("delete", help="Delete all capture data")
    p_delete.add_argument("--db", default="~/.orbit/orbit.db")
    p_delete.add_argument("--yes", action="store_true")

    p_purge = privacy_sub.add_parser("purge", help="Delete events older than retention period")
    p_purge.add_argument("--db", default="~/.orbit/orbit.db")
    p_purge.add_argument("--days", type=int, default=None)

    p_policy = privacy_sub.add_parser("show-policy", help="Show ~/.orbit/policy.json")
    p_policy.add_argument("--policy", default="~/.orbit/policy.json")

    p_ocr = privacy_sub.add_parser("enable-ocr", help="Enable tier_ocr in policy.json")
    p_ocr.add_argument("--policy", default="~/.orbit/policy.json")

    p_fse = privacy_sub.add_parser(
        "enable-fsevents", help="Enable tier_fsevents in policy.json"
    )
    p_fse.add_argument("--policy", default="~/.orbit/policy.json")

    p_detect = privacy_sub.add_parser(
        "enable-detection",
        help="Enable proactive task detection (detect_enabled) in policy.json",
    )
    p_detect.add_argument("--policy", default="~/.orbit/policy.json")
    p_detect.add_argument(
        "--cap", type=int, default=5, help="Daily approval budget cap (detect_daily_cap)"
    )

    p_mcp = privacy_sub.add_parser(
        "enable-mcp",
        help="Enable the read-only MCP context server (mcp_enabled) in policy.json",
    )
    p_mcp.add_argument("--policy", default="~/.orbit/policy.json")
    p_mcp.add_argument(
        "--exclude",
        action="append",
        default=[],
        dest="exclude",
        help="Bundle ID to exclude from MCP tool results (repeatable)",
    )

    p_tel_off = privacy_sub.add_parser(
        "disable-telemetry",
        help="Opt out of crash reporting / usage analytics (telemetry_enabled) in policy.json",
    )
    p_tel_off.add_argument("--policy", default="~/.orbit/policy.json")

    p_tel_on = privacy_sub.add_parser(
        "enable-telemetry",
        help="Opt back into crash reporting / usage analytics (telemetry_enabled) in policy.json",
    )
    p_tel_on.add_argument("--policy", default="~/.orbit/policy.json")

    check_p = sub.add_parser("check", help="Detect tasks from context and dispatch to Claude")
    check_p.add_argument("action", nargs="?", choices=["skipped"], default=None,
                         help="'skipped' to review today's skipped tasks")
    check_p.add_argument("--context", default=None, help="Path to local context.md (fallback when --source local)")
    check_p.add_argument("--source", choices=["capture", "github", "local"], default="capture",
                         help="Context source: capture (default, orbit's own captures), github (westsoever/cos daily report), or local")
    check_p.add_argument("--since-hours", type=float, default=8.0,
                         help="Capture window in hours for --source capture (default: 8.0)")
    check_p.add_argument("--date", default=None, help="Report date YYYY-MM-DD (default: today)")
    check_p.add_argument("--db", default="~/.orbit/orbit.db", help="SQLite DB path")
    check_p.add_argument("--dry-run", action="store_true", help="Detect and print tasks; skip notification and dispatch")
    check_p.add_argument("--no-notify", action="store_true", help="Skip macOS notification")
    check_p.add_argument("--refresh", action="store_true", help="Re-run LLM detection even if today's tasks are cached")

    doctor_p = sub.add_parser(
        "doctor",
        help="Diagnose Python/SQLite setup (embeddings require loadable extensions)",
    )

    sessions_p = sub.add_parser("sessions", help="List work sessions for a day")
    sessions_p.add_argument("--day", default="today", help="YYYY-MM-DD or 'today'")
    sessions_p.add_argument("--limit", type=int, default=50)
    sessions_p.add_argument("--db", default="~/.orbit/orbit.db")

    digest_p = sub.add_parser("digest", help="Build a daily activity digest")
    digest_p.add_argument("--day", default="today", help="YYYY-MM-DD or 'today'")
    digest_p.add_argument("--markdown", action="store_true", help="Print markdown")
    digest_p.add_argument(
        "--llm",
        action="store_true",
        help="Ask the LLM for a narrative (default: structured summary)",
    )
    digest_p.add_argument("--db", default="~/.orbit/orbit.db")

    embed_p = sub.add_parser(
        "embed-backfill",
        help="Embed text_atoms captured while the daemon ran with --no-embed",
    )
    embed_p.add_argument("--db", default="~/.orbit/orbit.db")
    embed_p.add_argument("--batch-size", type=int, default=256)

    auth_p = sub.add_parser("auth", help="Manage orbit user session")
    auth_sub = auth_p.add_subparsers(dest="auth_action", metavar="action")

    auth_status_p = auth_sub.add_parser("status", help="Show active user session")
    auth_signout_p = auth_sub.add_parser("sign-out", help="Clear active session")
    auth_signin_p = auth_sub.add_parser(
        "sign-in", help="Set active session (headless/dev; sign-up is in orbit Access App)"
    )
    auth_signin_p.add_argument("--user-id", required=True)
    auth_signin_p.add_argument("--email", default="")

    args = parser.parse_args()

    if args.command == "doctor":
        from orbit.runtime import doctor_report, sqlite_supports_extensions

        print(doctor_report())
        sys.exit(0 if sqlite_supports_extensions() else 1)

    if args.command == "start":
        # Plan 53 Phase 1 — no sign-up wall, so there is no session pre-check here any
        # more. This block used to duplicate the daemon's check and `sys.exit(1)` on a
        # missing session, which would have pre-empted the daemon's recovery. Every
        # branch below ends in `orbit.capture.daemon.main` (in-process via
        # `daemon_main()`, or spawned as `orbit-daemon`), and that is the single place
        # allowed to auto-create a local identity.
        import os

        from orbit.runtime import sqlite_supports_extensions

        if not args.no_embed and not sqlite_supports_extensions():
            print(
                "WARNING: This Python build cannot load SQLite extensions; "
                "capture will run without embeddings.\n"
                f"  Interpreter: {sys.executable}\n"
                "  Fix: activate the project venv (source .venv/bin/activate) and use "
                "`python -c \"...\"` — not system `python3`.\n"
                "  Or recreate venv: /opt/homebrew/bin/python3 -m venv .venv && "
                "source .venv/bin/activate && pip install -e .\n"
                "  Capture-only: orbit start --no-embed\n",
                file=sys.stderr,
            )

        db_path = os.path.expanduser(args.db)
        os.makedirs(os.path.dirname(db_path), exist_ok=True)

        sys.argv = ["orbit-daemon", "--db", db_path]
        if args.no_embed:
            sys.argv.append("--no-embed")
        if args.max_depth is not None:
            sys.argv.extend(["--max-depth", str(args.max_depth)])
        if args.no_browser_bridge:
            sys.argv.append("--no-browser-bridge")
        if args.browser_bridge_port != 8765:
            sys.argv.extend(["--browser-bridge-port", str(args.browser_bridge_port)])
        if getattr(args, "ocr", False):
            sys.argv.append("--ocr")
        if getattr(args, "purge_retention", False):
            sys.argv.append("--purge-retention")
        if getattr(args, "no_fsevents", False):
            sys.argv.append("--no-fsevents")
        if getattr(args, "no_statusbar", False):
            sys.argv.append("--no-statusbar")

        daemon_argv = sys.argv[1:]  # orbit-daemon flags without script name

        if args.detach:
            from orbit.daemon_ctl import build_daemon_argv, spawn_detached

            port = args.browser_bridge_port
            health_url = f"http://127.0.0.1:{port}/health"
            try:
                pid, started = spawn_detached(
                    build_daemon_argv(daemon_argv),
                    health_url=health_url,
                )
            except RuntimeError as exc:
                print(str(exc), file=sys.stderr)
                sys.exit(1)
            if started:
                print(f"orbit daemon started (pid {pid})")
            else:
                print(f"orbit daemon already running (pid {pid})")
            sys.exit(0)

        from orbit.capture.daemon import main as daemon_main
        daemon_main()

    elif args.command == "stop":
        import os

        from orbit.daemon_ctl import _health_ok, stop_daemon
        from orbit.daemon_pid import read_pid

        pid_file = os.path.expanduser(args.pid_file)
        if read_pid(pid_file) is None and not _health_ok():
            print("orbit daemon is not running")
            sys.exit(0)
        if stop_daemon(pid_file=pid_file, timeout_s=args.timeout):
            print("orbit daemon stopped")
            sys.exit(0)
        print("orbit daemon did not stop in time", file=sys.stderr)
        sys.exit(1)

    elif args.command == "privacy":
        if not args.privacy_action:
            privacy_p.print_help()
            sys.exit(1)
        from orbit.privacy.store import run_privacy_command

        run_privacy_command(args)

    elif args.command == "check":
        argv = ["orbit-check"]
        if args.action:
            argv.append(args.action)
        argv += ["--source", args.source]
        argv += ["--since-hours", str(args.since_hours)]
        if args.context:
            argv += ["--context", args.context]
        if args.date:
            argv += ["--date", args.date]
        if args.db:
            argv += ["--db", args.db]
        if args.dry_run:
            argv.append("--dry-run")
        if args.no_notify:
            argv.append("--no-notify")
        if args.refresh:
            argv.append("--refresh")
        sys.argv = argv

        from orbit.check.__main__ import main as check_main
        check_main()

    elif args.command == "sessions":
        import os
        from datetime import datetime

        from orbit.memory.sessions import day_bounds, get_sessions, segment_sessions
        from orbit.storage.db import open_db_plain

        db_path = os.path.expanduser(args.db)
        con, lock = open_db_plain(db_path)
        day = "today" if args.day in (None, "today") else args.day
        start, _ = day_bounds(day)
        segment_sessions(con, lock, since=start, min_events=2)
        sessions = get_sessions(con, day=day, limit=args.limit)
        if not sessions:
            print("No sessions for that day.")
            sys.exit(0)
        for s in sessions:
            try:
                t0 = datetime.fromisoformat(s["started_at"].replace("Z", "+00:00"))
                t1 = datetime.fromisoformat(s["ended_at"].replace("Z", "+00:00"))
                mins = max(0, int((t1 - t0).total_seconds() // 60))
            except Exception:
                mins = 0
            title = s.get("title") or s.get("primary_app_name") or "session"
            print(
                f"{s['started_at']} → {s['ended_at']} ({mins}m)  "
                f"{title}  [{s.get('primary_app_name') or '—'}]  "
                f"events={s['event_count']} atoms={s['atom_count']}"
            )

    elif args.command == "digest":
        import os

        from orbit.memory.digest import build_digest, render_digest_markdown
        from orbit.storage.db import open_db_plain

        db_path = os.path.expanduser(args.db)
        con, lock = open_db_plain(db_path)
        day = None if args.day in (None, "today") else args.day
        digest = build_digest(
            con, lock, day=day, use_llm=bool(args.llm), db_ref=(con, lock)
        )
        if args.markdown:
            print(render_digest_markdown(digest), end="")
        else:
            print(digest.get("narrative") or "(empty)")
            print(f"\n({digest.get('source')}; "
                  f"{len(digest.get('sessions') or [])} sessions, "
                  f"{digest.get('total_atoms', 0)} atoms)")

    elif args.command == "embed-backfill":
        import os

        from orbit.runtime import sqlite_supports_extensions

        if not sqlite_supports_extensions():
            print(
                "This Python build cannot load SQLite extensions, so embeddings "
                "are unavailable.\n"
                "  Fix: source .venv/bin/activate (Homebrew Python 3.13 venv).",
                file=sys.stderr,
            )
            sys.exit(1)

        from orbit.embed.worker import backfill_embeddings, count_unembedded_atoms
        from orbit.storage.db import open_db

        db_path = os.path.expanduser(args.db)
        con, lock = open_db(db_path)
        # The capture daemon may be writing to this same file concurrently;
        # wait rather than fail immediately on a transient WAL lock.
        con.execute("PRAGMA busy_timeout=5000")
        total = count_unembedded_atoms(con)
        if total == 0:
            print("Nothing to backfill — every atom already has an embedding.")
            sys.exit(0)

        print(f"Backfilling {total} unembedded atoms...")

        def _progress(done: int, total: int) -> None:
            print(f"  {done}/{total}", end="\r", flush=True)

        embedded = backfill_embeddings(
            con, lock, batch_size=args.batch_size, on_progress=_progress
        )
        print(f"\nEmbedded {embedded} atoms.")

    elif args.command == "auth":
        from orbit.storage.session import clear_session, get_active_session, set_active_user

        if args.auth_action == "status":
            session = get_active_session()
            if session is None:
                print("No active orbit user session.")
                sys.exit(1)
            print(f"user_id: {session.user_id}")
            if session.email:
                print(f"email: {session.email}")
            print(f"signed_in_at: {session.signed_in_at}")
        elif args.auth_action == "sign-out":
            clear_session()
            print("Signed out.")
        elif args.auth_action == "sign-in":
            set_active_user(args.user_id, email=args.email or "")
            print(f"Signed in as {args.user_id}.")
        else:
            auth_p.print_help()
            sys.exit(1)

    else:
        parser.print_help()