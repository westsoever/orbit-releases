"""Orbit MCP context server package (Plan 17 Phase 7).

Read-only export of Orbit's memory (search, sessions, digest, entities) to any
MCP client the user runs (Claude Code, Cursor, etc). This is *not* the
Orchestrator -> tools execution bridge mandated at CLAUDE.md:63 -- that remains
out of scope until a real agent loop exists. No write tools live here.
"""
