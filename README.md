# orbit

Always-on agentic assistant for macOS. It captures your working context through the Accessibility
API — text only, no screenshots — keeps it on your Mac, and answers questions from it.

- **Before:** You asked AI — and it gave you the right answer to the question you managed to ask.
- **Now:** It has already seen what you're working on — so it knows what you actually need.

> *A mediocre model with perfect context outperforms a frontier model starting from zero every session.*

**Status: early beta.** Read [Known issues](#known-issues) before installing.

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/westsoever/orbit-releases/main/install.sh | bash
```

This builds Orbit from the source in this repository and installs it to `/Applications/Orbit.app`.
First install takes **15–30 minutes** — most of it is the Swift compile and the Python dependency
download. It needs Homebrew, the Xcode Command Line Tools (`xcode-select --install`), and about
10 GB free.

Skip the auto-launch at the end:

```bash
curl -fsSL https://raw.githubusercontent.com/westsoever/orbit-releases/main/install.sh \
  | ORBIT_NO_START=1 bash
```

> The variable goes **after** the pipe, on `bash`. Written the other way round
> (`ORBIT_NO_START=1 curl … | bash`) the assignment applies to `curl`, never reaches `bash`, and is
> silently ignored.

When it finishes you have `/Applications/Orbit.app` and `orbit` on your `PATH`. Your data lives in
`~/.orbit/` and survives upgrades.

### Build it yourself instead

```bash
git clone https://github.com/westsoever/orbit-releases.git
cd orbit-releases
bash scripts/build-app-bundle.sh --output /Applications/Orbit.app
```

Pass an **absolute** path to `--output`.

---

## First launch — read this or the app won't open

Beta builds are **not signed with an Apple Developer ID**, so macOS refuses to open the app the
first time:

```bash
xattr -cr /Applications/Orbit.app
open -a Orbit
```

If macOS still blocks it, open **System Settings → Privacy & Security**, find the message naming
Orbit, and click **Open Anyway**.

> On macOS 15 (Sequoia) and later, right-clicking the app and choosing **Open** no longer bypasses
> Gatekeeper — Apple removed that shortcut.

Then grant **System Settings → Privacy & Security → Accessibility**. Capture does nothing without
it ([details](docs/PERMISSIONS.md)).

---

## You need a model

Orbit ships no model of its own. Pick one in **Settings → Cloud AI**:

- **Local — private and free.** `brew install ollama && ollama pull llama3.1`, then select it.
  Nothing leaves your Mac. Budget ~4 GB of download.
- **Your own key.** Paste an OpenRouter API key.

Without either, Orbit still works: chat falls back to keyword search over your captured context
instead of answering. Hosted Cloud AI is not enabled in this build.

See [running a local model](docs/local-model-ollama.md) for the longer version.

---

## What it does

| | |
|---|---|
| **Captures** | Window and UI text via the Accessibility API, event-driven — on app and window switches, not on a loop. No screenshots, no screen recording. |
| **Stores** | A local encrypted SQLite database in `~/.orbit/`. The key lives in your macOS Keychain. |
| **Answers** | Ask what you were working on; it answers from your own captured context. |
| **Proposes** | Detected work waits on a board. An agent never runs anything you have not approved. |
| **Excludes** | Password managers are excluded by default; add any app, or pause capture entirely. |

Everything stays on your Mac unless you explicitly enable a cloud model.

---

## Verify the install

```bash
orbit doctor
curl -s http://127.0.0.1:8765/health    # {"ok": true} when the daemon is running
```

Useful commands:

```bash
orbit start --detach --no-embed   # start capture in the background
orbit stop                        # stop it
orbit privacy --help              # pause, exclude apps, forget recent, export, delete everything
```

---

## Known issues

- **Unsigned**, hence the Gatekeeper step above.
- **Closing the main window can leave the app unreachable** from the menu bar. Quit and relaunch.
- **Hosted Cloud AI is off** — use a local model or your own key.
- Browsers usually expose nothing to the Accessibility API; they need the browser companion or the
  OCR fallback, which is off by default.

Report anything else at [Issues](https://github.com/westsoever/orbit-releases/issues).

---

## Privacy

Text only. Captured content stays in a local encrypted database and is not uploaded. Analytics and
crash reporting are opt-out and carry structural metadata only — never captured text; turn them off
in Settings → Capture, or with `orbit privacy disable-telemetry`.

- [Privacy Policy](docs/PRIVACY_POLICY.md)
- [Terms of Service](docs/TERMS_OF_SERVICE.md)
- [License](LICENSE)

Both the policy and the terms are **pending formal legal review**.

---

## About this repository

This is the public distribution of Orbit: the application source, the installer, and the published
legal documents — what you need to build, install and run it, and nothing else. Internal planning
documents, design notes and development tooling are not here.
