from __future__ import annotations

from typing import TYPE_CHECKING

if TYPE_CHECKING:
    from orbit.capture.policy import CapturePolicy

CAPTURE_ROLES = {"AXTextField", "AXTextArea", "AXStaticText", "AXDocument", "AXWebArea"}

# Roles exempt from the low-value AXStaticText filter (Plan 48 §4.2 / CLAUDE.md
# anti-pattern guard: never filter AXTextArea/AXTextField by length -- they are
# the substantive, low-volume roles).
_LENGTH_EXEMPT_ROLES = {"AXTextField", "AXTextArea", "AXDocument", "AXWebArea"}

# Unicode Private Use Area ranges -- icon-font glyphs (e.g. SF Symbols-style
# codepoints) that render as empty/blank but are captured as "text". Measured
# in the live corpus at 686 occurrences of a single PUA glyph (§0.3).
_PUA_RANGES = ((0xE000, 0xF8FF), (0xF0000, 0xFFFFD), (0x100000, 0x10FFFD))


def _is_private_use_char(ch: str) -> bool:
    cp = ord(ch)
    return any(lo <= cp <= hi for lo, hi in _PUA_RANGES)


def _is_low_value_static_text(text: str, policy: "CapturePolicy | None") -> bool:
    """True if a stripped AXStaticText value carries no semantic value.

    Only ever called for AXStaticText -- see _LENGTH_EXEMPT_ROLES.
    """
    from orbit.capture.policy import CapturePolicy as _CapturePolicy

    policy = policy or _CapturePolicy()
    stripped = text.strip()
    if not stripped:
        return True
    if policy.reject_private_use_glyphs and all(_is_private_use_char(c) for c in stripped):
        return True
    if policy.reject_punctuation_only_atoms and not any(c.isalnum() for c in stripped):
        return True
    if len(stripped) < policy.min_static_text_chars:
        return True
    return False


def flatten_text_atoms(
    tree, _path: str = "", policy: "CapturePolicy | None" = None
) -> list[dict]:
    if isinstance(tree, dict):
        nodes = [tree]
    elif isinstance(tree, list):
        nodes = tree
    else:
        return []
    results = []
    for i, node in enumerate(nodes):
        if not isinstance(node, dict):
            continue
        path = f"{_path}/{i}"
        role = node.get("role", "")
        val = node.get("value")
        name = node.get("name")
        text = (val if isinstance(val, str) else name if isinstance(name, str) else "").strip()
        if role in CAPTURE_ROLES and text:
            low_value = role not in _LENGTH_EXEMPT_ROLES and _is_low_value_static_text(
                text, policy
            )
            if not low_value:
                results.append({
                    "role": role,
                    "label": node.get("description") or node.get("role_description"),
                    "text": text,
                    "element_path": path,
                    "element_hash": node.get("id"),
                })
        children = node.get("children") or []
        results.extend(flatten_text_atoms(children, path, policy))
    return results
