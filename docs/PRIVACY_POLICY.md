# Orbit Privacy Policy

> **Not yet finalized by counsel.** This version was approved for publication by the product
> owner on 2026-08-13; a formal legal review is scheduled for the week of 2026-08-17 and may
> still change entity/jurisdiction details or specific clauses below. Check the "Last updated"
> date the next time you read this — this document will be updated in place if anything
> changes.

**Last updated:** 2026-08-13 · **Effective for:** Orbit desktop app (macOS)

## Who this policy covers

This policy describes Orbit's data practices for individual users who install and run the
Orbit application on their own Mac ("**you**"). If you are deploying Orbit across an
organization to monitor other people's devices, additional obligations apply (notice to
those individuals, a data protection impact assessment, and likely a data processing
agreement); this consumer-facing policy does not cover that deployment on its own.

**Data controller:** [LEGAL ENTITY NAME], [ADDRESS] — pending finalization.
**Contact / Data Protection contact:** [EMAIL] — pending finalization.

## Overview

Orbit is a **local-first** macOS context capture system. By default it stores structured text and metadata on your device only. This policy describes what each capture tier collects, how long data is kept, and your controls.

## Capture tiers

| Tier | Name | Default | Data collected |
|------|------|---------|----------------|
| 0 | Metadata only | Fallback | App name, bundle ID, window title, timestamp |
| 1 | Accessibility text | **On** | Structured text atoms from macOS Accessibility API |
| 2 | Browser companion | Opt-in | URL, page title, selected text via local browser extension |
| 3 | File workspace | Opt-in | File paths, event type, mtime via FSEvents — **not file contents** |
| 4 | OCR | Opt-in | On-device text recognition from focused window; raster discarded |
| 5 | Sampled screenshot | Opt-in | Interval-capped capture; prefer OCR derivative only |

Orbit does **not** log keystrokes globally, continuous webcam, or always-on full-screen video by default.

## Local storage

- Capture data is stored in SQLite at `~/.orbit/orbit.db` (configurable).
- Policy settings live at `~/.orbit/policy.json`.
- Embeddings (when enabled) are stored locally via sqlite-vec.
- LLM audit metadata (call site, provider, character counts, latency — never prompt or response text) is stored in the `llm_calls` table.
- No raw capture payload is sent to Orbit cloud services by the capture daemon.

## Orbit Cloud AI (opt-in)

Orbit Access can optionally use **Orbit Cloud AI** for chat answers. This is **disabled by default** and requires an explicit in-app enable action.

When enabled:

- The app registers an anonymous device token with the Orbit Cloud AI relay.
- For each chat message, **context snippets** retrieved locally from your `orbit.db` plus your question are sent to the relay, which forwards them to an LLM provider to generate an answer.
- Raw capture logs, full database exports, screenshots, and file contents are **not** transmitted.
- The relay does not retain message bodies after the request completes (metadata such as token counts may be logged for abuse prevention).

Rate limits apply on the shared service (approximately 40 chat messages per device per day unless otherwise configured).

Alternatively, you may supply your own LLM API key in `~/.orbit/.env` (`OPENROUTER_API_KEY=...`), in which case prompts go directly from your Mac to your chosen provider and Orbit Cloud AI is not used.

## Retention

- Default retention: **90 days** (`retention_days` in policy).
- Run `orbit privacy purge` or start with `--purge-retention` to enforce.
- You may export or delete all data at any time (see Data subject rights).

## Third-party LLM dispatch (`orbit check`)

The optional `orbit check` command may send **derived task prompts** to a configured LLM provider (e.g. Claude) for task detection. This is separate from the always-on capture store:

- Capture daemon: local-only by default.
- `orbit check`: explicit user invocation; review `--dry-run` before enabling automation.

## Exclusions

Apps on the no-capture list (banking, password managers, etc.) are never captured. Users can add bundle IDs via policy.

## Data subject rights

Use the Orbit privacy CLI (GDPR Arts. 15–17):

```bash
orbit privacy export --out ~/orbit-export.jsonl   # Access / portability
orbit privacy delete --yes                        # Erasure
orbit privacy purge --days 90                     # Storage limitation
orbit privacy show-policy                         # Transparency
orbit privacy enable-ocr                          # Granular consent (Tier 4)
orbit privacy enable-fsevents                     # Granular consent (Tier 3)
```

To exercise any of the above by request instead of via CLI (e.g. you no longer have access
to the machine that ran Orbit), contact us using the details below.

## Legal basis for processing (GDPR Art. 6)

- **Core local capture (Tiers 0–1, on by default):** legitimate interest in providing the
  product's core function — you installed Orbit specifically to have your on-screen context
  captured for later retrieval and task detection. You can disable capture or uninstall at
  any time.
- **Opt-in tiers (2–5) and Orbit Cloud AI:** consent, obtained through an explicit in-app
  enable action. You may withdraw consent at any time via the privacy CLI or in-app settings;
  withdrawal does not affect processing that already happened.
- **`orbit check` LLM dispatch:** consent, via explicit invocation of the command and, where
  applicable, a `--dry-run` review step before enabling automation.

## Categories of personal data and recipients

| Category | Examples | Leaves the device? |
|---|---|---|
| Device/app metadata | App name, bundle ID, window title, timestamps | No |
| Captured text (Tier 1+) | Accessibility-tree text, browser page text/URL, OCR text | No, unless Orbit Cloud AI or `orbit check` is enabled |
| File system metadata (Tier 3) | File paths, event type, mtime | No |
| LLM call audit metadata | Call site, provider, character counts, latency | No (metadata only; never prompt/response text is retained by Orbit) |
| Chat context snippets + question (Orbit Cloud AI, opt-in) | Retrieved local context, your question | Yes, to the Orbit Cloud AI relay and its LLM provider, only while the feature is enabled |
| Task prompts (`orbit check`, explicit invocation) | Derived task-detection prompt | Yes, to your configured LLM provider (e.g. Anthropic) |

We do not sell personal data. We do not use captured data for advertising. We do not share
data with third parties except the processors above, strictly to provide the feature you
enabled.

## Security

Local capture data is encrypted at rest (SQLCipher; key stored in the macOS Keychain via
`keyring`, not in a plaintext file).

## Your rights: EU/UK (GDPR) and California (CCPA/CPRA)

In addition to the CLI-driven access, portability, erasure, and transparency rights above:

- **Right to rectification** — correct inaccurate captured data via `orbit privacy delete`
  plus re-capture, or contact us for entries you cannot self-service.
- **Right to object / opt out** — disable any opt-in tier or Orbit Cloud AI at any time.
- **California residents:** you have the right to know, delete, correct, and opt out of the
  sale/sharing of personal information (Cal. Civ. Code §1798.100 et seq.). We do not sell or
  share personal information as those terms are defined by the CCPA/CPRA.
- **Non-discrimination:** we will not deny service or charge a different price for
  exercising any of these rights.

## International data transfers

Local capture never leaves your device by default. When Orbit Cloud AI or `orbit check` is
enabled, data is sent to the configured LLM provider's infrastructure, which may process
data outside your country of residence.

## Children's privacy

Orbit is not directed to children and is not intended for use by anyone under 16. We do not
knowingly collect personal data from children.

## Changes to this policy

We will update the "Last updated" date above when this policy changes and, for material
changes affecting how previously-collected data is used, provide in-app notice before the
change takes effect.

## Contact

[EMAIL / DPO CONTACT] — pending finalization.
