"""Detect actionable tasks from a context string via LLM."""
from __future__ import annotations
import json
from dataclasses import dataclass

from .envelope import untrusted_preamble, wrap_untrusted
from .llm import DbRef, complete

_SYSTEM = """\
You are a task-detection assistant. Given a user's context file, identify 1–3 \
concrete, actionable tasks they should work on.

Return a JSON array of objects with exactly these fields:
- title: short task label (max 60 chars)
- description: what needs doing, 1–2 sentences
- suggested_prompt: a detailed, ready-to-use prompt that Claude Code can execute \
directly — include all relevant context so the agent can act without asking questions
- agent_type: one of writing | research | code | admin
- confidence: float 0.0–1.0 reflecting how clearly the context calls for this task

Only include tasks with confidence >= 0.7. Return [] if nothing is clear enough.
Return ONLY the JSON array, no other text or markdown fences.\
""" + untrusted_preamble()

_CONFIDENCE_THRESHOLD = 0.7


@dataclass
class Task:
    title: str
    description: str
    suggested_prompt: str
    agent_type: str
    confidence: float


class TaskDetectionParseError(ValueError):
    """The model answered, but not with the requested JSON array of tasks.

    Kept distinct from a provider failure because the remedy is different: nothing
    is wrong with the connection or the credentials — the chosen model just cannot
    follow the output contract, so the fix is to change the model. Callers that
    surface errors to a user must be able to say that instead of leaking a raw
    ``json.JSONDecodeError`` message like "Expecting value: line 1 column 1".

    The detail never quotes the model's output: a prose reply can echo captured
    context, and error strings travel further than the context window does.
    """


def _parse_tasks(text: str) -> list[Task]:
    try:
        data = json.loads(text)
    except json.JSONDecodeError as exc:
        raise TaskDetectionParseError("it was not JSON") from exc
    if not isinstance(data, list):
        raise TaskDetectionParseError("it was JSON, but not an array")
    tasks: list[Task] = []
    for item in data:
        if not isinstance(item, dict):
            raise TaskDetectionParseError("the array held something other than task objects")
        try:
            tasks.append(
                Task(
                    title=item["title"],
                    description=item["description"],
                    suggested_prompt=item["suggested_prompt"],
                    agent_type=item.get("agent_type", "admin"),
                    confidence=float(item.get("confidence", 0.0)),
                )
            )
        except KeyError as exc:
            raise TaskDetectionParseError(f"a task was missing the {exc} field") from exc
        except (TypeError, ValueError) as exc:
            raise TaskDetectionParseError("a task's confidence was not a number") from exc
    return [t for t in tasks if t.confidence >= _CONFIDENCE_THRESHOLD]


def detect_tasks(context_text: str, *, db_ref: DbRef | None = None) -> list[Task]:
    wrapped = wrap_untrusted([("Captured context window", context_text)])
    raw = complete(_SYSTEM, wrapped, call_site="detect", db_ref=db_ref)
    text = raw.strip()
    if text.startswith("```"):
        # Unchanged fence strip. A fence with no newline after it falls through
        # untouched and is reported as unparseable rather than raising IndexError.
        _fence, newline, rest = text.partition("\n")
        if newline:
            text = rest.rsplit("```", 1)[0].strip()
    return _parse_tasks(text)
