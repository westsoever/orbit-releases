# Orbit

Orbit is a personal assistant for macOS that understands who you are and how you work. Instead of
starting from a blank prompt every time, it quietly builds context from what you're actually doing
— captured locally via the Accessibility API (no screenshots by default) — and turns that context
into tasks it can do for you.

- **Before:** You asked AI — and it gave you the right answer to the question you managed to ask.
- **Now:** It's already seen what you're working on — so it knows what you actually need.

> *A mediocre model with perfect context outperforms a frontier model starting from zero every session.*

Orbit's source code is public at **https://github.com/westsoever/orbit** — the app, the installer,
and the release binaries all live there.

**This repository** hosts Orbit's published legal documents — [LICENSE](LICENSE),
[Privacy Policy](docs/PRIVACY_POLICY.md), [Terms of Service](docs/TERMS_OF_SERVICE.md) — which the
app's About panel links to, and keeps older links working. It is no longer a distribution channel.

**Status: early beta.** Read [Current state](#current-state) before installing.

---

## Install (macOS 14+)

```bash
curl -fsSL https://raw.githubusercontent.com/westsoever/orbit/main/scripts/install.sh | bash
```

Skip auto-launch after install:

```bash
curl -fsSL https://raw.githubusercontent.com/westsoever/orbit/main/scripts/install.sh | ORBIT_NO_START=1 bash
```

Install a specific version instead of the latest (latest release is `v0.1.0`):

```bash
curl -fsSL https://raw.githubusercontent.com/westsoever/orbit/main/scripts/install.sh | ORBIT_VERSION=0.1.0 bash
```

When finished you should have:

- `/Applications/Orbit.app` — open from Spotlight or Dock
- `orbit` on your PATH (symlinked to `/usr/local/bin/orbit`)

User data lives in `~/.orbit/` (database, policy, logs) and survives app upgrades.

Prefer to do it by hand? Download `Orbit-darwin.zip` from [Releases](https://github.com/westsoever/orbit/releases), unzip, and drag `Orbit.app` into `/Applications`.

### First launch

1. **Gatekeeper.** This build is not yet notarized by Apple. If macOS says the app is from an
   unidentified developer: right-click **Orbit** in `/Applications` → **Open**, or run:
   ```bash
   xattr -cr /Applications/Orbit.app
   open -a Orbit
   ```
2. **Accessibility permission.** System Settings → Privacy & Security → **Accessibility** → enable
   **Orbit**. Capture will not work without this — see [docs/PERMISSIONS.md](docs/PERMISSIONS.md).
3. **Start capture.** In the Orbit sidebar under **CAPTURE**, click **Start**.

Verify the install:

```bash
orbit doctor
curl -s http://127.0.0.1:8765/health    # {"ok": true} when the daemon is running
```

### Connect an AI model

Orbit's chat works with any of:

- **A local Ollama model** (recommended — private, free, runs on your Mac). See
  [docs/local-model-ollama.md](docs/local-model-ollama.md).
- **Your own OpenRouter API key** (`OPENROUTER_API_KEY` in `~/.orbit/.env`).
- **Hosted Cloud AI** — no setup, rate-limited.

Pick a provider the first time you open Chat, or later in Settings.

### Update or reinstall

Re-run the install command — it removes the old `/Applications/Orbit.app` first. Data in
`~/.orbit/` is kept unless you delete it yourself.

### Uninstall

```bash
orbit stop 2>/dev/null || true
rm -rf /Applications/Orbit.app /usr/local/bin/orbit
# Optional — delete all captured data:
# rm -rf ~/.orbit
```

---

## What it does

1. **Capture** — reads the active window's on-screen text via the macOS Accessibility API and
   stores it locally. No screenshots by default. This is how Orbit learns who you are and how you
   work — not from a profile you fill out, but from what you actually do.
2. **Search** — hybrid search over your own captured history.
3. **Detect** — an LLM looks at your recent captures and suggests tasks worth doing, informed by
   that context instead of a cold prompt.
4. **Approve** — you review and approve (or skip) each suggestion before anything runs.
5. **Dispatch** — approved tasks run and their output is saved locally.

## Privacy basics

- **Local-first:** capture data stays in `~/.orbit/` on your device.
- **No screenshots by default** — text via the Accessibility API only; an opt-in OCR fallback
  never stores image files.
- **Exclusion list** by app (edit `~/.orbit/policy.json` to add your own — see
  [docs/PERMISSIONS.md](docs/PERMISSIONS.md)).
- **Your data, your export:** `orbit privacy export` / `delete` / `purge` from the CLI.
- Full details: [Privacy Policy](docs/PRIVACY_POLICY.md).

## Current state

This is an early beta, not a polished consumer release yet:

- **Unsigned build** — ad-hoc signed only, not notarized. Expect the Gatekeeper prompt above on
  first launch.
- **Local storage is not yet encrypted at rest.** Treat `~/.orbit/orbit.db` like any other local
  file with your activity in it until this changes.
- **macOS 14+ (Sonoma or later)** only, Apple Silicon or Intel.
- Install is a few minutes on a good connection; first Ollama model pull is separate and can take
  longer depending on model size.

## Support

Found a bug or something confusing during install? [Open an issue](https://github.com/westsoever/orbit/issues)
on the main repository.

## Legal

- [LICENSE](LICENSE) — pending formal legal review.
- [Privacy Policy](docs/PRIVACY_POLICY.md)
- [Terms of Service](docs/TERMS_OF_SERVICE.md)
