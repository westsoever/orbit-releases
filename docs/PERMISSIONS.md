# macOS Permissions

Orbit reads the on-screen accessibility tree of your active app to capture context. It needs one
system permission to do that.

## Accessibility (required)

System Settings → Privacy & Security → **Accessibility** → toggle on **Orbit**.

If Orbit doesn't appear in the list, open Orbit once first, then check again — or add it manually
with the **+** button (`/Applications/Orbit.app`).

After granting permission, quit and reopen Orbit (or restart capture from the sidebar).

## Screen Recording (optional — only for OCR fallback)

Orbit's default capture is text-only via the Accessibility API — no screenshots. An optional,
off-by-default OCR fallback (for apps where Accessibility returns no text) needs **Screen
Recording** permission and can be turned on in Settings. It recognizes on-screen text only; no
image files are stored.

## Chromium browsers (Chrome, Arc, Brave, Edge, Dia)

Some Chromium-based browsers hide page content from the Accessibility API until enabled.

**Option A — enable in the browser:**

1. Open `chrome://accessibility/` (or your browser's equivalent)
2. Enable accessibility for active tabs / web contents

**Option B — Orbit's browser companion:** captures URL, page title, and selected text via a local
browser extension (no cloud). See in-app setup under Settings → Browser Companion.

## Verify capture is working

Open Orbit, click **Start** under CAPTURE in the sidebar, then switch between a couple of apps.
The history/search panel should show new entries within a couple of seconds.
