"""Dispatch an approved prompt — runs one completion, saves output as .md file."""
from __future__ import annotations

import re
from dataclasses import dataclass
from datetime import datetime, timezone
from pathlib import Path

OUTPUT_DIR = Path("~/.orbit/output").expanduser()
PREVIEW_MAX_CHARS = 1500

from .envelope import untrusted_preamble, wrap_untrusted
from .llm import DbRef

_SYSTEM = (
    "You are an autonomous agent executing a task on behalf of the user. "
    "Complete the task fully and thoroughly. Provide the complete output — "
    "do not summarise or abbreviate. If the task produces a document, write "
    "the full document."
) + untrusted_preamble()


@dataclass(frozen=True)
class DispatchResult:
    """Outcome of a dispatch run — exit code plus bounded artifact metadata."""

    exit_code: int
    path: str | None = None
    preview: str | None = None


def _slugify(title: str) -> str:
    slug = title.lower().strip()
    slug = re.sub(r"[^\w\s-]", "", slug)
    slug = re.sub(r"[\s_]+", "-", slug)
    return slug[:60]


def _preview(text: str, limit: int = PREVIEW_MAX_CHARS) -> str:
    text = text.strip()
    if len(text) <= limit:
        return text
    return text[: limit - 1].rstrip() + "…"


def dispatch(prompt: str, title: str = "task", *, db_ref: DbRef | None = None) -> DispatchResult:
    """Run one completion for an approved prompt and save it under OUTPUT_DIR.

    Uses ``complete()`` — the single mandated LLM swap point — so dispatch works
    on every provider path (local Ollama, BYOK OpenRouter, cloud relay). This
    is non-streaming by design; ``complete()`` has no streaming sibling yet.

    Returns path + short preview for the Access App result panel; full text
    remains in the markdown file.
    """
    from .llm import complete, format_completion_error

    ts = datetime.now(timezone.utc).strftime("%Y-%m-%d-%H%M%S")
    slug = _slugify(title)
    OUTPUT_DIR.mkdir(parents=True, exist_ok=True)
    out_path = OUTPUT_DIR / f"{ts}-{slug}.md"
    # One run can now approve several tasks; identical titles must not overwrite.
    n = 1
    while out_path.exists():
        n += 1
        out_path = OUTPUT_DIR / f"{ts}-{slug}-{n}.md"

    print("\nRunning task...\n" + "─" * 58)

    wrapped = wrap_untrusted([("Approved task prompt", prompt)])
    try:
        content = complete(
            _SYSTEM, wrapped, call_site="dispatch", db_ref=db_ref
        )
    except Exception as e:
        print(f"\nerror during dispatch: {format_completion_error(e)}")
        return DispatchResult(exit_code=1)

    print(content)
    print("─" * 58)
    out_path.write_text(f"# {title}\n\n{content}\n", encoding="utf-8")
    print(f"\nSaved → {out_path}")
    return DispatchResult(
        exit_code=0,
        path=str(out_path),
        preview=_preview(content),
    )
