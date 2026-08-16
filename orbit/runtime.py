"""Runtime helpers — pick a Python that can load SQLite extensions (sqlite-vec)."""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path


def sqlite_supports_extensions() -> bool:
    import sqlite3

    return hasattr(sqlite3.connect(":memory:"), "enable_load_extension")


def _probe_python(python: Path) -> bool:
    if not python.is_file():
        return False
    try:
        r = subprocess.run(
            [
                str(python),
                "-c",
                "import sqlite3; "
                "raise SystemExit(0 if hasattr(sqlite3.connect(':memory:'), "
                "'enable_load_extension') else 1)",
            ],
            capture_output=True,
            timeout=10,
        )
        return r.returncode == 0
    except (OSError, subprocess.TimeoutExpired):
        return False


def _repo_roots() -> list[Path]:
    roots: list[Path] = []
    here = Path(__file__).resolve().parent.parent
    roots.append(here)

    cwd = Path.cwd()
    if cwd not in roots:
        roots.append(cwd)

    for start in (cwd, here):
        cur = start
        for _ in range(8):
            if (cur / "pyproject.toml").is_file() and cur not in roots:
                roots.append(cur)
            if cur.parent == cur:
                break
            cur = cur.parent
    return roots


def find_project_venv_orbit() -> Path | None:
    """Return ``.venv/bin/orbit`` when that interpreter supports SQLite extensions."""
    for root in _repo_roots():
        orbit_bin = root / ".venv" / "bin" / "orbit"
        venv_py = root / ".venv" / "bin" / "python"
        if orbit_bin.is_file() and _probe_python(venv_py):
            return orbit_bin.resolve()
    return None


def maybe_reexec_for_embeddings(argv: list[str]) -> None:
    """Re-launch via project ``.venv/bin/orbit`` when the current Python cannot embed.

    Skipped when ``--no-embed`` is set or ``ORBIT_NO_REEXEC=1``.
    """
    if os.environ.get("ORBIT_NO_REEXEC") == "1":
        return
    if "--no-embed" in argv:
        return
    if sqlite_supports_extensions():
        return

    venv_orbit = find_project_venv_orbit()
    if venv_orbit is None:
        return

    # Already running under the capable venv interpreter.
    try:
        venv_py = (venv_orbit.parent / "python").resolve()
        if Path(sys.executable).resolve() == venv_py:
            return
    except OSError:
        pass

    os.environ["ORBIT_NO_REEXEC"] = "1"
    os.execv(str(venv_orbit), [str(venv_orbit), *argv[1:]])


def doctor_report() -> str:
    """Human-readable diagnosis for SQLite / interpreter issues."""
    import shutil

    try:
        import orbit as _orbit

        import_path = str(Path(_orbit.__file__).resolve())
    except Exception as exc:  # pragma: no cover - defensive; this is itself the diagnostic
        import_path = f"FAILED to import ({exc})"

    lines = [
        f"orbit executable: {shutil.which('orbit') or '(not on PATH)'}",
        f"sys.executable:   {sys.executable}",
        f"import orbit resolves to: {import_path}",
        f"sqlite extensions: {'yes' if sqlite_supports_extensions() else 'NO'}",
    ]

    venv_orbit = find_project_venv_orbit()
    if venv_orbit:
        lines.append(f"project venv:     {venv_orbit} (capable)")
    else:
        lines.append("project venv:     not found or lacks extension support")

    if not sqlite_supports_extensions():
        lines.extend(
            [
                "",
                "Fix (recommended):",
                "  cd /path/to/orbit",
                "  source .venv/bin/activate",
                "  pip install -e .",
                "  orbit start",
                "",
                "Or recreate venv with Homebrew Python:",
                "  brew install python@3.13",
                "  /opt/homebrew/bin/python3.13 -m venv .venv",
                "  source .venv/bin/activate && pip install -e .",
                "",
                "Capture-only (no embeddings): orbit start --no-embed",
            ]
        )
    return "\n".join(lines)
