# macOS Accessibility Permissions

To allow the capture daemon to read the accessibility tree:

System Settings → Privacy & Security → Accessibility → toggle on your Terminal app (or the Python interpreter process).

You may need to add the terminal manually via the "+" button if it does not appear in the list.

After granting permission, restart the terminal session and re-run:

```bash
source .venv/bin/activate
orbit start --detach --no-embed   # background; orbit access app can also start/stop the daemon
orbit stop                        # when finished
```

Foreground mode (terminal attached): `orbit start` — stop with Ctrl-C or menu bar **quit orbit**.

## Python / SQLite (separate from Accessibility)

Embeddings require loadable SQLite extensions. After creating the venv (see README), verify:

```bash
python -c "import sqlite3; sqlite3.connect(':memory:').enable_load_extension(True)"
```

Use `python` from the activated venv, not system `python3`. If verification fails, run `orbit start --no-embed` for capture-only mode.

## Chromium browsers (Chrome, Dia, Arc, Brave, Edge)

Many browsers hide page content from the Accessibility API until enabled.

### Option A — Enable in the browser (AX Tier 1)

While the browser is running:

1. Open `chrome://accessibility/` (or your browser’s equivalent)
2. Enable accessibility for **active tabs** / web contents

Or relaunch once with the renderer flag:

```bash
open -a "Google Chrome" --args --force-renderer-accessibility
open -a "Dia" --args --force-renderer-accessibility
```

Then verify:

```bash
python scripts/probe_app.py --bundle company.thebrowser.dia
```

### Option B — orbit Browser Companion (Tier 2, recommended for AX-blind browsers)

Captures **URL + page title + selection** via a local browser extension (no cloud).

1. Start daemon: `orbit start --detach` (bridge on `http://127.0.0.1:8765`)
2. Load unpacked extension from `orbit/browser-extension/` — see that folder’s README
3. Switch tabs; check capture:

```bash
sqlite3 ~/.orbit/orbit.db \
  "SELECT capture_method, window_title, page_url FROM context_events WHERE capture_method='browser_ext' ORDER BY id DESC LIMIT 5;"
```

If orbit logs `empty_tree` for a browser, you will also see a warning with these options.

## Enhanced capture — OCR (Tier 4, opt-in)

OCR captures **focused window text only** via Apple Vision. No screenshot files are stored.

1. Enable in policy:
   ```bash
   orbit privacy enable-ocr
   # or: orbit start --ocr
   ```
2. Grant **Screen Recording** to Terminal/Python:
   System Settings → Privacy & Security → Screen Recording
3. When AX capture fails (`empty_tree`, `zero_atoms`), orbit runs OCR automatically.

Policy file: `~/.orbit/policy.json` (`tier_ocr`, `retention_days`, `excluded_bundles`).

## Privacy commands (GDPR)

```bash
orbit privacy show-policy
orbit privacy enable-fsevents    # Tier 3: workspace file paths (opt-in)
orbit privacy enable-ocr       # Tier 4: OCR fallback (opt-in)
orbit privacy export --out ~/orbit-export.jsonl
orbit privacy purge --days 90
orbit privacy delete --yes
```

## Workspace file events (Tier 3, opt-in)

Captures **file paths and mtimes only** — never file contents.

1. Enable in policy:
   ```bash
   orbit privacy enable-fsevents
   ```
2. Edit `~/.orbit/policy.json` to set `watch_roots` (default: `["~/Projects"]`). Paths must exist.
3. Start daemon: `orbit start --detach` (disable with `--no-fsevents`)

File events are stored in `fs_events` and linked to the nearest app-focus event within ±30 seconds.

Verify:

```bash
python scripts/test_fsevents.py
sqlite3 ~/.orbit/orbit.db "SELECT path, event_type, linked_event_id FROM fs_events ORDER BY id DESC LIMIT 5;"
```

Compliance templates: `docs/gdpr/PRIVACY_POLICY.md`
