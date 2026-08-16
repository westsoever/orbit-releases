"""Terminal approval loop — present detected tasks, collect approve/edit/skip."""
from __future__ import annotations

from .detector import Task

_WIDTH = 58


def _hr() -> None:
    print("═" * _WIDTH)


def _wrap(text: str, indent: int = 2) -> None:
    prefix = " " * indent
    words = text.split()
    line = prefix
    for word in words:
        if len(line) + len(word) + 1 > _WIDTH - 2:
            print(line)
            line = prefix + word
        else:
            line += (" " if line != prefix else "") + word
    if line.strip():
        print(line)


def _print_task(index: int, total: int, task: Task, prompt: str) -> None:
    _hr()
    print(f"  orbit  [{index}/{total}]  {task.agent_type.upper()}")
    _hr()
    _wrap(task.title)
    print()
    _wrap(task.description)
    print()
    print("  PROMPT:")
    _wrap(prompt)
    print()


def run_approval(
    tasks: list[Task],
    on_skip=None,
) -> list[tuple[Task, str]]:
    """Present every task and collect decisions. Returns all (task, prompt) approvals.

    The loop continues after each approval, so one run can approve several
    tasks. Quitting (or EOF/Ctrl-C) stops asking but keeps the approvals
    already given — they were explicit commitments.

    on_skip(task) is called immediately when the user presses 's'.
    """
    approved: list[tuple[Task, str]] = []
    total = len(tasks)
    for i, task in enumerate(tasks, 1):
        prompt = task.suggested_prompt
        while True:
            _print_task(i, total, task, prompt)
            print("  (a)pprove  (e)dit  (s)kip  (q)uit")
            _hr()
            try:
                choice = input("  > ").strip().lower()
            except (EOFError, KeyboardInterrupt):
                print()
                return approved

            if choice in ("a", "approve", ""):
                approved.append((task, prompt))
                break
            elif choice in ("e", "edit"):
                try:
                    new = input("  New prompt: ").strip()
                except (EOFError, KeyboardInterrupt):
                    print()
                    return approved
                if new:
                    prompt = new
            elif choice in ("s", "skip"):
                if on_skip:
                    on_skip(task)
                break
            elif choice in ("q", "quit"):
                return approved
    return approved
