# orbit

**Your context becomes action. Privately, on your Mac.**

Your personal assistant, that understands who you are and how you work. Orbit turns what you are
already doing on your Mac into approved, auditable actions.

> Built for people who read the permissions dialog.

**Status: early beta.** Unsigned, and the hosted model is not switched on yet. Read
[Known issues](#known-issues) before installing.

---

## Local-first capture

Accessibility-tree text, on-device, encrypted at rest.

Orbit reads window and UI text through the macOS Accessibility API when you switch apps or windows
— not on a loop, not continuously. **Text only, no screenshots, no screen recording.** What it
captures goes into an encrypted SQLite database in `~/.orbit/`, with the key in your macOS Keychain.

Captured content never leaves your device unless you explicitly connect a cloud model.

## You approve everything

Approve the plan before it runs, and again if anything is ambiguous or irreversible.

Detected work waits on a board until you decide. An agent never executes anything you have not
explicitly approved, and every dispatch is written to a local audit log — so what ran, and why, is
answerable after the fact.

## Your context, your continent, your control

Orbit-operated backend infrastructure is EU-hosted. Nothing is uploaded by default; the local store
is yours to export or delete at any time, and password managers are excluded out of the box.

The honest exception: optional crash and usage reporting is handled by Sentry and PostHog on US
servers. It carries structural metadata only — never captured text — and you can turn it off:

```bash
orbit privacy disable-telemetry
```

The full detail is in the [Privacy Policy](docs/PRIVACY_POLICY.md).

---

## Install

```bash
curl -fsSL https://raw.githubusercontent.com/westsoever/orbit-releases/main/install.sh | bash
```

This builds Orbit from the source in this repository and installs it to `/Applications/Orbit.app`.
It needs Homebrew, the Xcode Command Line Tools (`xcode-select --install`) and about 10 GB free, and
takes **15–30 minutes** — most of it the Swift compile and the Python dependency download.

To skip the compile, download `Orbit-darwin.zip` from the
[latest release](https://github.com/westsoever/orbit-releases/releases/latest) and unzip it into
`/Applications`.

Skip the auto-launch at the end:

```bash
curl -fsSL https://raw.githubusercontent.com/westsoever/orbit-releases/main/install.sh \
  | ORBIT_NO_START=1 bash
```

> The variable goes **after** the pipe, on `bash`. Written the other way round
> (`ORBIT_NO_START=1 curl … | bash`) the assignment applies to `curl`, never reaches `bash`, and is
> silently ignored.

Build it yourself instead:

```bash
git clone https://github.com/westsoever/orbit-releases.git
cd orbit-releases
bash scripts/build-app-bundle.sh --output /Applications/Orbit.app
```

Pass an **absolute** path to `--output`.

---

## First launch

Beta builds are not signed with an Apple Developer ID, so macOS refuses to open the app the first
time:

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

## Connect a model

Orbit ships no model of its own. Choose one in **Settings → Cloud AI**:

- **Local — private, free.** `brew install ollama && ollama pull llama3.1`, then select it. Nothing
  leaves your Mac. Budget ~4 GB of download. See [running a local model](docs/local-model-ollama.md).
- **Your own key.** Paste an OpenRouter API key.

Without either, Orbit still works — chat falls back to keyword search over your own captured context
instead of answering. Hosted Cloud AI is not enabled in this build.

---

## How it works

1. **It watches.** On each app or window switch, Orbit reads the text on screen and goes back to
   sleep.
2. **It remembers.** That text is stored locally, encrypted, and ages out on the retention window
   you set.
3. **You ask.** Ask what you were working on this morning; it answers from your own context rather
   than from nothing.
4. **It proposes.** Work it thinks it spotted appears in **Detected**.
5. **You approve.** Nothing runs until you say so. The outcome is logged either way.

## Capabilities

| | |
|---|---|
| **Chat** | Ask about what you were doing. Grounded in your captured context, not a blank prompt. |
| **Search** | The same box. Before you connect a model it searches your context by keyword. |
| **Tasks** | Detected work, waiting on your approval. |
| **Timeline** | What you actually worked on, in order, reconstructed from context. |
| **Privacy & setup** | Pause, exclude apps, forget the last few minutes, export or delete everything. |

Verify the install:

```bash
orbit doctor
curl -s http://127.0.0.1:8765/health    # {"ok": true} when the daemon is running
```

---

## Known issues

- **Unsigned**, hence the Gatekeeper step above.
- **Closing the main window can leave the app unreachable** from the menu bar. Quit and relaunch.
- **Hosted Cloud AI is off.** The relay it needs is not deployed, so sign-in is hidden. Use a local
  model or your own key.
- Browsers usually expose nothing to the Accessibility API; they need the browser companion or the
  OCR fallback, which is off by default.

Report anything else at [Issues](https://github.com/westsoever/orbit-releases/issues).

---

## Legal

- [Privacy Policy](docs/PRIVACY_POLICY.md)
- [Terms of Service](docs/TERMS_OF_SERVICE.md)
- [License](LICENSE)

All three are pending formal legal review.

## About this repository

This is the public distribution of Orbit: the application source, the installer and the published
legal documents — what you need to build, install and run it, and nothing else. Internal planning
documents, design notes and development tooling are not here.
