"""orbit privacy — export / delete / retention for capture store."""
from __future__ import annotations

import argparse
import os
import sys

from orbit.privacy.store import run_privacy_command


def main() -> None:
    parser = argparse.ArgumentParser(prog="orbit privacy", description="GDPR data subject tools")
    sub = parser.add_subparsers(dest="action", required=True)

    export_p = sub.add_parser("export", help="Export capture data to JSONL")
    export_p.add_argument("--db", default="~/.orbit/orbit.db")
    export_p.add_argument("--out", required=True, help="Output JSONL path")

    delete_p = sub.add_parser("delete", help="Delete all capture data")
    delete_p.add_argument("--db", default="~/.orbit/orbit.db")
    delete_p.add_argument("--yes", action="store_true", help="Confirm deletion")

    purge_p = sub.add_parser("purge", help="Delete events older than retention period")
    purge_p.add_argument("--db", default="~/.orbit/orbit.db")
    purge_p.add_argument("--days", type=int, default=None, help="Override retention days")

    show_p = sub.add_parser("show-policy", help="Print capture policy")
    show_p.add_argument("--policy", default="~/.orbit/policy.json")

    enable_ocr_p = sub.add_parser("enable-ocr", help="Enable Tier 4 OCR in policy.json")
    enable_ocr_p.add_argument("--policy", default="~/.orbit/policy.json")

    args = parser.parse_args()
    run_privacy_command(args)


if __name__ == "__main__":
    main()
