# Connect a local Ollama model to Orbit

Use this walkthrough when you want Orbit chat to run against a model on your own Mac instead of Cloud AI or a hosted API key. Orbit's local path is **Ollama**-only in the app UI.

## Prerequisites

- macOS with [Ollama](https://ollama.com) installed
- Orbit already installed and able to capture context (see the main [README](../README.md))
- Enough RAM/VRAM for your chosen model (see [Model size](#model-size))

## 1. Install and start Ollama

```bash
# If needed: download from https://ollama.com, or:
brew install ollama
```

Start the server (the menu bar app does this automatically after install):

```bash
ollama serve
```

Leave Ollama running. Orbit does not start or stop Ollama for you.

## 2. Pull a model

```bash
ollama pull llama3.1
```

Use the same tag you'll enter in Orbit (for example `llama3.1`, `llama3.2:3b`, `mistral`). Confirm:

```bash
ollama list
```

### Model size

Pick a model that fits your machine with headroom for macOS and Orbit:

| Rough RAM | Reasonable starting point |
|-----------|---------------------------|
| 8 GB | Small 3B-class models |
| 16 GB | 7–8B class |
| 32 GB+ | 13B–70B (quantized) depending on GPU/unified memory |

## 3. Connect in Orbit

1. Open **Orbit**.
2. Ensure the capture daemon is running (sidebar **CAPTURE** → **Start**, or let the app auto-start it).
3. Open **Chat**.
4. Choose **Local model (Ollama)** (first-run card, or Settings → Cloud AI / Local model).
5. Enter the model tag exactly as in `ollama list` (default suggestion: `llama3.1`).
6. Click **Use local model** or **Save**.

That writes `~/.orbit/.env`:

```bash
ORBIT_LLM_PROVIDER=local
ORBIT_LOCAL_LLM_MODEL=llama3.1
ORBIT_LOCAL_LLM_BASE_URL=http://localhost:11434/v1
```

### Restart the daemon after env changes

When you edit `~/.orbit/.env` by hand, restart the daemon so it picks up changes:

```bash
orbit stop && orbit start --detach
```

Or use **Stop** / **Start** in the app's CAPTURE sidebar.

When you switch providers in **Orbit → Chat → AI provider** (or Settings → Cloud AI / Local model), the app saves `~/.orbit/.env` and polls the daemon until the active provider matches — no manual restart needed for in-app switches.

## 4. Verify

```bash
curl -s http://127.0.0.1:8765/api/status | python3 -m json.tool
```

You should see `"llm_available": true`, `"llm_provider": "local"`, and `"local_model"` matching your tag.

Then send a chat message in Orbit. The first reply after a cold load can take a while while Ollama loads weights into memory; later replies should be much faster once the model stays resident (next section).

## 5. Keep the model in memory (fast follow-ups)

Ollama unloads idle models by default (often after a few minutes). To keep responses snappy on an always-on Mac, use both layers below.

### A. Orbit request keep-alive (automatic)

Every local completion from Orbit sends Ollama a `keep_alive` value:

| Setting | Default | Meaning |
|---------|---------|---------|
| `ORBIT_LOCAL_LLM_KEEP_ALIVE` | `-1` | Never unload after an Orbit chat |

Optional values in `~/.orbit/.env`:

```bash
ORBIT_LOCAL_LLM_KEEP_ALIVE=-1    # keep forever (default)
ORBIT_LOCAL_LLM_KEEP_ALIVE=30m   # unload 30 minutes after last Orbit call
ORBIT_LOCAL_LLM_KEEP_ALIVE=300   # unload after 300 seconds
```

Restart the Orbit daemon after changing this value.

### B. Server-level Ollama residency

So the model stays loaded even between Orbit sessions / idle periods:

1. Keep **Ollama** running at login (menu bar app, or a LaunchAgent that runs `ollama serve`).
2. Set the server default keep-alive so unload never happens after idle:

   ```bash
   # Current login session (re-apply after reboot, or put in a LaunchAgent plist EnvironmentVariables)
   launchctl setenv OLLAMA_KEEP_ALIVE -1
   ```

   Then quit and reopen the Ollama app (or restart `ollama serve`) so it picks up the environment.
3. Optional preload after boot (loads weights before the first chat):

   ```bash
   curl -s http://localhost:11434/api/generate -d '{
     "model": "llama3.1",
     "prompt": "",
     "keep_alive": -1
   }'
   ```

4. Confirm the model is resident:

   ```bash
   ollama ps
   ```

You should see your model listed with a long / indefinite expiry when keep-alive is `-1`.

## Manual `.env` (optional)

Equivalent to the app UI:

```bash
# ~/.orbit/.env
ORBIT_LLM_PROVIDER=local
ORBIT_LOCAL_LLM_MODEL=llama3.1
ORBIT_LOCAL_LLM_BASE_URL=http://localhost:11434/v1
ORBIT_LOCAL_LLM_KEEP_ALIVE=-1
```

File mode should stay private (`chmod 600 ~/.orbit/.env`).

## Troubleshooting

| Symptom | What to check |
|---------|----------------|
| Chat says no AI / local unavailable | `ollama serve` running? `curl -s http://localhost:11434/api/tags` returns 200? |
| Model not found | `ollama list` — tag must match `ORBIT_LOCAL_LLM_MODEL` exactly; `ollama pull <tag>` |
| Still on Cloud AI | Chat toolbar → **AI provider** chip → switch to **Local model (Ollama)** and Save |
| First question slow, later ones fast | Normal cold load; use keep-alive + `ollama ps` so the model stays loaded |
| First question always slow | Model unloaded — set `OLLAMA_KEEP_ALIVE=-1` and/or `ORBIT_LOCAL_LLM_KEEP_ALIVE=-1`, preload with `/api/generate` |
| App shows daemon offline / chat disabled | Sidebar CAPTURE → Start; `curl -s http://127.0.0.1:8765/api/status` |
| Env change ignored (manual edit) | `orbit stop && orbit start --detach` (or Stop/Start in the UI) |

## Related

- [README](../README.md) — install, first launch, uninstall
- [docs/PERMISSIONS.md](PERMISSIONS.md) — macOS Accessibility setup
