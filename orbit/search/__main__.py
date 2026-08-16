"""python -m orbit.search [--mode lexical|semantic|hybrid] "<query>" [--db PATH]"""
from __future__ import annotations
import argparse
import sys
from orbit.storage.db import open_db
from orbit.search.lexical import search_lexical
from orbit.search.semantic import search_semantic
from orbit.search.hybrid import search_hybrid

def main() -> None:
    parser = argparse.ArgumentParser(description="orbit search CLI")
    parser.add_argument("query", help="Search query")
    parser.add_argument("--mode", choices=["lexical", "semantic", "hybrid"], default="hybrid")
    parser.add_argument("--db", default="./orbit.db")
    parser.add_argument("--limit", type=int, default=10)
    parser.add_argument("--bundle", default=None, help="Filter by app bundle ID")
    args = parser.parse_args()

    con, _ = open_db(args.db)

    if args.mode == "lexical":
        hits = search_lexical(con, args.query, limit=args.limit, app_bundle_id=args.bundle)
    elif args.mode == "semantic":
        hits = search_semantic(con, args.query, limit=args.limit, app_bundle_id=args.bundle)
    else:
        hits = search_hybrid(con, args.query, limit=args.limit, app_bundle_id=args.bundle)

    if not hits:
        print("No results.")
        return

    for h in hits:
        print(f"{h.score:.4f} | {h.timestamp} | {h.app_name} | {h.snippet_html} | {h.atom_uri}")

if __name__ == "__main__":
    main()
