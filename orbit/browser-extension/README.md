# orbit Browser Companion (Tier 2)

Sends **active tab URL and title** (plus selected text when permitted) to the local orbit daemon. No data leaves your machine except to `127.0.0.1`.

## Prerequisites

1. orbit daemon running: `orbit start --detach` (starts browser bridge on port **8765** by default). Stop with `orbit stop` or the **Stop** button in orbit access app.
2. Chromium-based browser (Chrome, Dia, Arc, Brave, Edge)

## Install (unpacked)

1. Open browser extensions page:
   - Chrome/Dia/Arc: `chrome://extensions/`
2. Enable **Developer mode**
3. **Load unpacked** → select this folder (`orbit/browser-extension/`)
4. Pin the extension if desired (optional — it runs in the background)

## Verify

```bash
curl -s http://127.0.0.1:8765/health
# {"ok":true}

# After switching tabs in the browser:
sqlite3 ~/.orbit/orbit.db "SELECT capture_method, window_title, page_url FROM context_events WHERE capture_method='browser_ext' ORDER BY id DESC LIMIT 5;"
```

## Privacy

- Does **not** capture full page HTML, cookies, or form fields
- Does **not** send data to the internet
- Requires explicit extension install (B2C consent for browser tier)

## When AX capture fails

If orbit logs `empty_tree` for your browser, also try:

- Visit `chrome://accessibility/` and enable accessibility for active tabs
- Or relaunch once: `open -a "Dia" --args --force-renderer-accessibility`

See `orbit/capture/PERMISSIONS.md` for full browser AX setup.
