# Orbit Privacy Policy

> **Not yet finalized by counsel.** This version was approved for publication by the product
> owner on 2026-08-13; a formal legal review is scheduled for the week of 2026-08-17 and may
> still change entity/jurisdiction details or specific clauses below. Check the "Last updated"
> date the next time you read this — this document will be updated in place if anything
> changes.
>
> **Added 2026-08-16, and not covered by that approval:** the sections "Account and profile data
> (optional)" and "Analytics & crash reporting (opt-out, on by default)", together with the
> related entries in the legal-basis, data-categories, rights, retention and
> international-transfers sections. These were written after the 2026-08-13 sign-off and have
> not yet been through legal review. They are published now so that the features they describe
> are disclosed before they are switched on, rather than after.

**Last updated:** 2026-08-16 · **Effective for:** Orbit desktop app (macOS)

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

- The app registers this installation with the Orbit Cloud AI relay, sending a random
  per-install identifier and the app version, and receives a device token in return. If you
  are not signed in to an Orbit account, that device record carries no user link. **If you
  are signed in** (see "Account and profile data" below), the registration is sent with your
  account's session token and the relay stores the device **linked to your account** — it is
  not anonymous.
- For each chat message, **context snippets** retrieved locally from your `orbit.db` plus your question are sent to the relay, which forwards them to an LLM provider to generate an answer.
- Raw capture logs, full database exports, screenshots, and file contents are **not** transmitted.
- The relay does not retain message bodies after the request completes (metadata such as token counts may be logged for abuse prevention).

Rate limits apply on the shared service (approximately 40 chat messages per device per day unless otherwise configured).

Alternatively, you may supply your own LLM API key in `~/.orbit/.env` (`OPENROUTER_API_KEY=...`), in which case prompts go directly from your Mac to your chosen provider and Orbit Cloud AI is not used.

## Account and profile data (optional)

Orbit runs fully on your Mac without an account, and nothing in the product is withheld if you
never create one. Signing in is optional: it links this Mac to Orbit's relay so that hosted
Orbit Cloud AI and a stable identity across devices work. **Signing in does not upload your
captured context** — the local capture store stays on your Mac exactly as described above.

### Creating an account

Sign-in is by a one-time code emailed to you; there is no password. If you create an account,
Orbit's relay stores:

- your **email address**, and a display name derived from the part of it before the `@`;
- the date the account was created;
- **one-time sign-in codes** — stored only as a keyed hash, never in plain text, single-use,
  and valid for a few minutes;
- **session tokens** — also stored only as a keyed hash, with an expiry date;
- the **device registration** for each Mac where you enable Orbit Cloud AI (a random
  per-install identifier, the app version, the registration date), linked to your account.

Your email address is passed to our email delivery provider for the sole purpose of sending
you the sign-in code.

### Profile questions (optional, separate consent)

After signing in, Orbit asks a short set of questions about you. **Every one of them is
optional, including all of them at once.** These are the only fields collected:

| Stored as | Question | Values offered |
|---|---|---|
| `degree` | Highest degree | High school, Vocational, Bachelor's, Master's, PhD, Self-taught |
| `position` | Position | Student, Individual contributor, Team lead, Manager, Director / VP, Founder / owner, Freelance / consultant |
| `function` | Function | Engineering, Design, Product, Research, Data / analytics, Marketing, Sales, Operations, Finance, Legal, People / HR, Support |
| `area` | Area | Software / tech, Finance, Healthcare, Education, Public sector, Media / creative, Manufacturing, Retail / e-commerce, Nonprofit, Consulting |
| `other` | Anything else | Free text you write yourself |
| `consent_at` | — | The date and time you gave consent |
| `policy_version` | — | The version of this policy your consent was given against (currently `2026-08-16`) |

Stored with them is the account they belong to. Nothing else about you is collected by this
questionnaire, and the answers are never derived from your captured context — they are only
what you type or tap yourself.

**This is profiling under the GDPR, and it runs on your consent.** The answers are sent only
if you tick a plainly-worded checkbox in the questionnaire itself. That checkbox is **not**
part of accepting this policy, not part of signing in, and not pre-ticked. If it is unticked,
the app sends nothing and the relay stores nothing — there is no "declined" record either.

**What we use them for:** understanding who uses Orbit, so we can decide what to build. They
are **not** used for advertising, not sold, not shared with third parties, and not used to
target or personalise anything inside the app.

**Changing, withdrawing, deleting.** Settings › Account → **Update answers** replaces them;
**Delete my answers** withdraws your consent and erases the stored record from the relay.
Withdrawal does not affect processing that already took place, and it does not delete your
account, your Mac's local data, or anything else.

### Retention of account and profile data

- **Profile answers:** kept until you change them, delete them, or delete your account.
- **Account record (email, display name, creation date):** kept for as long as the account
  exists.
- **Sign-in codes:** expire within minutes of being issued and are single-use.
- **Session tokens:** expire on the date recorded when they are issued (currently one year),
  and are cleared from this Mac when you sign out.
- **Account deletion:** Orbit does **not** yet have a self-service "delete my account" button.
  To delete your account and everything the relay holds for it, contact us using the details
  below and we will erase it. The profile answers, by contrast, *are* self-service deletable
  in Settings › Account.

## Analytics & crash reporting (opt-out, on by default)

Unlike the local capture store above, Orbit sends a limited set of **usage and crash
metadata** to two third-party providers — **Sentry** (crash/error reporting) and **PostHog**
(usage analytics) — to help us understand how the app is used and fix bugs. This is **on by
default**; you can turn it off at any time:

```bash
orbit privacy disable-telemetry   # opt out
orbit privacy enable-telemetry    # opt back in
```

**What is sent:** app/OS version, which features were used (e.g. capture started, a chat
message was sent, a task was approved), and crash reports (stack traces, error messages).
**What is never sent:** captured window text, chat message content, search queries, task
prompts, file paths, URLs, or any other captured content. Events are tied to a random
per-install identifier, not your name, email, or Orbit account.

**Where this data is stored:** on Sentry's and PostHog's **US-region servers** — this is the
one exception to Orbit's local-first, EU-hosted-infrastructure posture. The Orbit Cloud AI
relay and any other Orbit-operated backend infrastructure are EU-hosted; only this
analytics/crash data goes to US servers, because that is where these specific providers host
by default. This is a deliberate, disclosed trade-off made for now to help us improve the app
during early development, and one we will revisit as the product matures.

## Retention

- Default retention: **90 days** (`retention_days` in policy).
- Run `orbit privacy purge` or start with `--purge-retention` to enforce.
- You may export or delete all data at any time (see Data subject rights).
- This covers data on your Mac. Retention for the optional cloud account and profile answers
  is in "Account and profile data" above.

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
- **Optional Orbit account (email, sign-in codes, session tokens, device link): contract**
  (Art. 6(1)(b)) — you asked us to give you a hosted account, and we cannot authenticate you
  or attach your devices to it without these. Creating an account is itself optional; Orbit
  works without one.
- **Profile answers (degree, position, function, area, free text): consent**
  (Art. 6(1)(a)) — this is **non-essential profiling**. It does nothing for you and everything
  for us, so it gets its own explicit, unbundled, un-pre-ticked checkbox, separate from
  accepting this policy and separate from signing in. You may withdraw at any time in
  Settings › Account, which erases the answers; withdrawal does not affect processing that
  already happened. We record when consent was given and against which version of this policy.

## Categories of personal data and recipients

| Category | Examples | Leaves the device? |
|---|---|---|
| Device/app metadata | App name, bundle ID, window title, timestamps | No |
| Captured text (Tier 1+) | Accessibility-tree text, browser page text/URL, OCR text | No, unless Orbit Cloud AI or `orbit check` is enabled |
| File system metadata (Tier 3) | File paths, event type, mtime | No |
| LLM call audit metadata | Call site, provider, character counts, latency | No (metadata only; never prompt/response text is retained by Orbit) |
| Chat context snippets + question (Orbit Cloud AI, opt-in) | Retrieved local context, your question | Yes, to the Orbit Cloud AI relay and its LLM provider, only while the feature is enabled |
| Task prompts (`orbit check`, explicit invocation) | Derived task-detection prompt | Yes, to your configured LLM provider (e.g. Anthropic) |
| Usage/crash telemetry (on by default, opt-out) | Feature-usage events, app/OS version, crash stack traces — never captured content | Yes, to Sentry and PostHog (US-hosted), unless disabled via `orbit privacy disable-telemetry` |
| Account data (optional cloud account) | Email address, display name derived from it, account creation date, hashed single-use sign-in codes, hashed session tokens, per-install device registration linked to the account | Yes, to the Orbit relay — only if you create an account. Your email address also goes to our email delivery provider, to send the sign-in code |
| Profile answers (optional, separate consent) | Degree, position, function, area, free-text "anything else", plus the consent timestamp and policy version | Yes, to the Orbit relay — only if you tick the consent checkbox in the questionnaire |

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
- **Right to object / opt out** — disable any opt-in tier or Orbit Cloud AI at any time, and
  turn off usage/crash telemetry with `orbit privacy disable-telemetry`.
- **Right to withdraw consent (profile answers)** — Settings › Account → **Delete my
  answers** withdraws your consent and erases the answers from Orbit's relay. Withdrawing is
  as easy as giving consent was, and costs you nothing else: your account, your local data,
  and every feature keep working.
- **Account data access and erasure** — the CLI above covers data on your Mac. For the data
  the relay holds against your account (email, display name, device registrations, profile
  answers), contact us using the details below; account erasure is not yet self-service.
- **California residents:** you have the right to know, delete, correct, and opt out of the
  sale/sharing of personal information (Cal. Civ. Code §1798.100 et seq.). We do not sell or
  share personal information as those terms are defined by the CCPA/CPRA.
- **Non-discrimination:** we will not deny service or charge a different price for
  exercising any of these rights.

## International data transfers

Local capture never leaves your device by default. When Orbit Cloud AI or `orbit check` is
enabled, data is sent to the configured LLM provider's infrastructure, which may process
data outside your country of residence.

Orbit-operated backend infrastructure — the Orbit Cloud AI relay and the account/profile
relay described above — is **EU-hosted**.

Usage/crash telemetry (see "Analytics & crash reporting" above) is the exception: it is sent
to Sentry's and PostHog's US-region infrastructure by default, on an opt-out basis, and is
therefore a US transfer for EU/UK users.

## Children's privacy

Orbit is not directed to children and is not intended for use by anyone under 16. We do not
knowingly collect personal data from children.

## Changes to this policy

We will update the "Last updated" date above when this policy changes and, for material
changes affecting how previously-collected data is used, provide in-app notice before the
change takes effect.

## Contact

[EMAIL / DPO CONTACT] — pending finalization.
