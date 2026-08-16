"""LLM abstraction — swap provider by changing this file only.

Resolution order for ``complete()``:
1. Local Ollama — ``ORBIT_LLM_PROVIDER=local``, or ``auto`` when Ollama responds
2. BYOK — ``OPENROUTER_API_KEY`` in env or ``~/.orbit/.env``
3. Orbit Cloud relay — ``~/.orbit/cloud.json`` (device token + relay URL)
4. Raise with setup instructions

``complete()`` also accepts an optional per-request ``model`` override. It is
honoured only on the local path (an Ollama model tag). The relay path always
uses its own fixed server-side alias (``_RELAY_MODEL``) and ignores the
override. The BYOK path uses its own overridable slug (default
``anthropic/claude-sonnet-4.5``, override via ``ORBIT_BYOK_MODEL``) and also
ignores the per-request override — only the *default* BYOK slug is
configurable, not per call.

Local model: base_url ``http://localhost:11434/v1`` (Ollama), api_key ``ollama``.
Keep-alive: ``ORBIT_LOCAL_LLM_KEEP_ALIVE`` (default ``-1``) is sent as Ollama
``keep_alive`` on every local completion so the model stays resident.
"""
from __future__ import annotations

import os
import sqlite3
import threading
import time
from datetime import datetime, timezone
from pathlib import Path

from orbit.check.cloud_config import CloudConfig, load_cloud_config

_CONFIG = Path("~/.orbit/.env").expanduser()
_RELAY_MODEL = "owl-alpha"
_BYOK_MODEL_DEFAULT = "anthropic/claude-sonnet-4.5"
_BASE_URL = "https://openrouter.ai/api/v1"
_MODEL_TAG_MAX_LEN = 200

DbRef = tuple[sqlite3.Connection, threading.Lock]
_audit_db_ref: DbRef | None = None


def set_llm_audit_db(con: sqlite3.Connection, lock: threading.Lock) -> None:
    """Register the shared DB for llm_calls audit rows (one connection only)."""
    global _audit_db_ref
    _audit_db_ref = (con, lock)


def _resolve_db_ref(db_ref: DbRef | None) -> DbRef | None:
    return db_ref or _audit_db_ref


def _log_llm_call(
    db_ref: DbRef | None,
    *,
    call_site: str,
    provider: str,
    model: str | None,
    prompt_chars: int,
    response_chars: int | None,
    latency_ms: int,
    ok: bool,
    error: str | None,
) -> None:
    ref = _resolve_db_ref(db_ref)
    if ref is None:
        return
    con, lock = ref
    ts = datetime.now(timezone.utc).isoformat()
    with lock:
        con.execute(
            """
            INSERT INTO llm_calls (
              timestamp, call_site, provider, model,
              prompt_chars, response_chars, latency_ms, ok, error
            ) VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)
            """,
            (
                ts,
                call_site,
                provider,
                model,
                prompt_chars,
                response_chars,
                latency_ms,
                1 if ok else 0,
                error,
            ),
        )


def _get_setting(name: str) -> str | None:
    """Read a setting from the environment, falling back to ``~/.orbit/.env``."""
    value = os.environ.get(name)
    if value:
        return value
    if _CONFIG.exists():
        prefix = f"{name}="
        for line in _CONFIG.read_text().splitlines():
            if line.startswith(prefix):
                parsed = line.split("=", 1)[1].strip()
                if parsed:
                    return parsed
    return None


def _try_load_api_key() -> str | None:
    return _get_setting("OPENROUTER_API_KEY")


def _resolve_provider() -> str:
    """Resolve the configured LLM provider: auto/local/cloud/byok (default auto)."""
    return (_get_setting("ORBIT_LLM_PROVIDER") or "auto").lower()


def _local_base_url() -> str:
    return _get_setting("ORBIT_LOCAL_LLM_BASE_URL") or "http://localhost:11434/v1"


def _local_model() -> str:
    return _get_setting("ORBIT_LOCAL_LLM_MODEL") or "llama3.1"


def _byok_model() -> str:
    """BYOK (OpenRouter) model slug. Overridable via ORBIT_BYOK_MODEL, unlike the
    relay path's fixed ``_RELAY_MODEL``, because BYOK sends the slug straight to
    OpenRouter and a key's reachable models vary per account."""
    return _get_setting("ORBIT_BYOK_MODEL") or _BYOK_MODEL_DEFAULT


def normalise_model_override(model: str | None) -> str | None:
    """Sanitise a caller-supplied model tag; return None when unusable.

    The tag is treated as an **opaque** identifier: it is only ever placed in the
    ``model`` field of an OpenAI-compatible JSON body. It is never interpolated
    into a shell command, a filesystem path, or SQL. Anything blank, oversized,
    or containing whitespace/control characters is rejected as "use the default"
    rather than raising — an unusable override must never break a chat request.
    """
    if not isinstance(model, str):
        return None
    tag = model.strip()
    if not tag or len(tag) > _MODEL_TAG_MAX_LEN:
        return None
    if any(ch.isspace() or ord(ch) < 0x20 or ord(ch) == 0x7F for ch in tag):
        return None
    return tag


def _local_keep_alive() -> int | str:
    """Ollama keep_alive: -1 (default), seconds as int, or duration like ``30m``."""
    raw = (_get_setting("ORBIT_LOCAL_LLM_KEEP_ALIVE") or "-1").strip()
    if not raw:
        return -1
    try:
        return int(raw)
    except ValueError:
        return raw


def _llm_timeout_s() -> float:
    """Wall-clock ceiling for one completion. ORBIT_LLM_TIMEOUT_S, default 90.

    90s is above a cold local-model load but well under the point where a caller
    assumes Orbit hung. The openai SDK default is 600s, which is indistinguishable
    from a hang on demo day.
    """
    raw = (_get_setting("ORBIT_LLM_TIMEOUT_S") or "").strip()
    if not raw:
        return 90.0
    try:
        parsed = float(raw)
    except ValueError:
        return 90.0
    return parsed if parsed > 0 else 90.0


def llm_available() -> bool:
    """True when ``complete()`` would succeed without calling a model."""
    provider_mode = _resolve_provider()
    if provider_mode == "cloud":
        return bool(_try_load_api_key() or load_cloud_config())
    if provider_mode == "byok":
        return bool(_try_load_api_key())
    if provider_mode == "local":
        return _local_available(_local_base_url())
    if provider_mode == "auto" and _local_available(_local_base_url()):
        return True
    if _try_load_api_key():
        return True
    if load_cloud_config():
        return True
    return False


def resolved_llm_provider() -> str:
    """Effective provider: local, byok, relay, or none."""
    provider_mode = _resolve_provider()
    if provider_mode == "cloud":
        if _try_load_api_key():
            return "byok"
        if load_cloud_config():
            return "relay"
        return "none"
    if provider_mode == "local" or (
        provider_mode == "auto" and _local_available(_local_base_url())
    ):
        return "local"
    if provider_mode != "local":
        if _try_load_api_key():
            return "byok"
        if load_cloud_config():
            return "relay"
    return "none"


def _missing_key_message() -> str:
    return (
        "No AI credentials configured.\n"
        "Enable orbit Cloud AI in orbit Access, or add OPENROUTER_API_KEY to "
        f"{_CONFIG}, "
        "or run a local model with Ollama (set ORBIT_LLM_PROVIDER=local, run "
        "`ollama serve`, `ollama pull llama3.1`)."
    )


def _complete_openrouter(system: str, user: str, api_key: str) -> str:
    import openai

    # max_retries=0: the SDK default of 2 retries would triple the wall clock past
    # the timeout the caller was promised. One bounded attempt, one clear error.
    client = openai.OpenAI(
        api_key=api_key,
        base_url=_BASE_URL,
        timeout=_llm_timeout_s(),
        max_retries=0,
    )
    response = client.chat.completions.create(
        model=_byok_model(),
        max_tokens=1024,
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
    )
    content = response.choices[0].message.content
    return content if content is not None else ""


def _fetch_local_tags(base_url: str) -> dict | None:
    # Ollama exposes an OpenAI-compatible API at /v1 and a /api/tags health route.
    # See https://github.com/ollama/ollama/blob/main/docs/openai.md
    # Single GET shared by _local_available, list_local_models, and
    # local_model_ready so a readiness check costs one round trip, not two.
    try:
        import httpx

        tags_url = base_url.replace("/v1", "") + "/api/tags"
        response = httpx.get(tags_url, timeout=2.0)
        if response.status_code != 200:
            return None
        data = response.json()
        return data if isinstance(data, dict) else None
    except Exception:
        return None


def _tag_names(tags: dict) -> list[str]:
    models = tags.get("models", [])
    names = [
        str(entry["name"])
        for entry in models
        if isinstance(entry, dict) and entry.get("name")
    ]
    return sorted(names)


def _local_available(base_url: str) -> bool:
    return _fetch_local_tags(base_url) is not None


def list_local_models() -> list[str]:
    """Return installed Ollama model tags, or [] if Ollama is unreachable."""
    tags = _fetch_local_tags(_local_base_url())
    return _tag_names(tags) if tags is not None else []


def local_model_ready() -> tuple[bool, str | None]:
    """(True, None) when the configured local model is installed.
    (False, reason) when Ollama is unreachable or the model is not pulled.

    Matching rule: exact tag, or a bare configured name against ``<name>:latest``.
    Nothing looser. Verified against Ollama 2026-07-27: with only ``mistral:7b``
    pulled, a request for bare ``mistral`` returns ``model 'mistral' not found`` —
    Ollama expands a bare name to ``:latest`` rather than picking any installed tag.
    Treating ``mistral`` as satisfied by ``mistral:7b`` would therefore reproduce the
    exact bug this preflight exists to catch: available here, failing at call time.
    """
    base_url = _local_base_url()
    tags = _fetch_local_tags(base_url)
    if tags is None:
        return False, (
            f"Ollama is not responding at {base_url}. Start it with `ollama serve`."
        )
    model = _local_model()
    installed = _tag_names(tags)
    wanted = {model, model if ":" in model else f"{model}:latest"}
    if wanted & set(installed):
        return True, None
    if installed:
        return False, (
            f"Local model '{model}' is not installed. Run `ollama pull {model}`, or "
            f"pick an installed model ({', '.join(installed)}) in Settings."
        )
    return False, (
        f"No Ollama models are installed. Run `ollama pull {model}`."
    )


def _complete_local(system: str, user: str, base_url: str, model: str) -> str:
    import openai

    # See _complete_openrouter for why retries are disabled.
    client = openai.OpenAI(
        api_key="ollama",
        base_url=base_url,
        timeout=_llm_timeout_s(),
        max_retries=0,
    )
    response = client.chat.completions.create(
        model=model,
        max_tokens=1024,
        messages=[
            {"role": "system", "content": system},
            {"role": "user", "content": user},
        ],
        extra_body={"keep_alive": _local_keep_alive()},
    )
    content = response.choices[0].message.content
    return content if content is not None else ""


def complete_via_relay(system: str, user: str, cfg: CloudConfig) -> str:
    import httpx

    url = f"{cfg.relay_base_url.rstrip('/')}/v1/chat/completions"
    response = httpx.post(
        url,
        headers={"Authorization": f"Bearer {cfg.device_token}"},
        json={"system": system, "user": user, "model": _RELAY_MODEL},
        timeout=_llm_timeout_s(),
    )
    response.raise_for_status()
    data = response.json()
    content = data.get("content")
    return str(content) if content is not None else ""


def _timeout_message() -> str:
    """Name the budget and the provider so the message is actionable, not just 'timed out'."""
    budget = int(_llm_timeout_s())
    provider = resolved_llm_provider()
    if provider == "local":
        return (
            f"The local model ({_local_model()}) did not respond within {budget}s. "
            "Try a smaller model, or switch to Cloud AI in Settings."
        )
    return (
        f"The AI provider did not respond within {budget}s. Try again, or switch "
        "provider in Settings."
    )


def _is_timeout(exc: Exception) -> bool:
    """True for httpx read/connect timeouts and the SDK's APITimeoutError wrapper."""
    try:
        import httpx

        if isinstance(exc, httpx.TimeoutException):
            return True
    except ImportError:
        pass
    # openai converts httpx.TimeoutException into APITimeoutError (a subclass of
    # APIConnectionError, so it does NOT surface as httpx.TimeoutException) at
    # openai/_base_client.py:1055. Imported lazily and by name to keep the SDK
    # dependency optional, as the other paths in this module do.
    try:
        import openai

        if isinstance(exc, openai.APITimeoutError):
            return True
    except ImportError:
        pass
    return False


def _error_body_text(exc: Exception) -> str:
    """Best-effort text of an error body, tolerating either the openai SDK's
    parsed/raw ``body`` attribute or a raw httpx response's ``.text``."""
    body = getattr(exc, "body", None)
    if body is not None:
        return str(body)
    response = getattr(exc, "response", None)
    if response is not None:
        try:
            return response.text
        except Exception:
            pass
    return str(exc)


def _no_endpoints_message() -> str:
    return (
        f"OpenRouter rejected model '{_byok_model()}'. Set ORBIT_BYOK_MODEL in "
        "~/.orbit/.env to a slug your key can reach."
    )


def _quota_exhausted_message() -> str:
    """Shown when the shared Cloud AI allowance runs out.

    Names both escape hatches, because the included allowance is deliberately
    small and hitting it is an expected event rather than an error: a personal
    OpenRouter key, or a local Ollama model that has no quota at all. Points at
    Settings rather than ``~/.orbit/.env`` — both routes have real UI
    (``CloudAISettingsView`` for the key, ``LocalModelPickerSection`` for the
    model), and a message that sends a non-technical user to edit a dotfile
    when a panel exists is a worse instruction even though it also works.
    """
    return (
        "You've used up today's included Cloud AI. It resets tomorrow.\n"
        "To keep going now, open Settings › Cloud AI and either add your own "
        "OpenRouter API key, or switch to a local model that runs on this Mac "
        "with no limit."
    )


def format_completion_error(exc: Exception) -> str:
    if _is_timeout(exc):
        return _timeout_message()

    # OpenRouter (BYOK) rejects an unrecognised model slug with a 404 whose body
    # contains "No endpoints found for <slug>". The openai SDK wraps this as
    # NotFoundError -- an APIStatusError, NOT an httpx.HTTPStatusError -- the same
    # two-exception-shape situation _is_timeout already handles for timeouts, so
    # check both shapes here too.
    try:
        import openai

        if isinstance(exc, openai.NotFoundError) and "No endpoints found" in _error_body_text(exc):
            return _no_endpoints_message()
    except ImportError:
        pass

    try:
        import httpx
    except ImportError:
        return str(exc)

    if isinstance(exc, httpx.HTTPStatusError):
        status = exc.response.status_code
        if status == 404 and "No endpoints found" in _error_body_text(exc):
            return _no_endpoints_message()
        if status == 429:
            return _quota_exhausted_message()
        if status == 401:
            return "Cloud AI session expired. Re-enable orbit Cloud AI in orbit Access."
        if status == 503:
            try:
                body = exc.response.json()
                if isinstance(body, dict):
                    error = body.get("error")
                    nested = body.get("detail")
                    if not isinstance(error, str):
                        error = nested.get("error") if isinstance(nested, dict) else None
                    if error == "relay_disabled":
                        return "Cloud AI temporarily unavailable."
            except Exception:
                pass
        try:
            body = exc.response.json()
            if isinstance(body, dict):
                error = body.get("error")
                if not isinstance(error, str) or not error:
                    nested = body.get("detail")
                    error = nested.get("error") if isinstance(nested, dict) else None
                if isinstance(error, str) and error:
                    mapped = {
                        "relay_disabled": "Cloud AI temporarily unavailable.",
                        "upstream_unavailable": "The AI provider is temporarily unavailable. Try again in a few minutes.",
                        "rate_limit_exceeded": _quota_exhausted_message(),
                        "registration_limit_exceeded": _quota_exhausted_message(),
                    }
                    if error in mapped:
                        return mapped[error]
                    return error
        except Exception:
            pass
    return str(exc)


def complete(
    system: str,
    user: str,
    *,
    call_site: str = "unknown",
    db_ref: DbRef | None = None,
    model: str | None = None,
) -> str:
    """Run one completion through the resolved provider.

    ``model`` is an optional per-request override. It applies **only** when the
    resolved provider is ``local`` (it names an Ollama model tag). The relay
    path uses its fixed server-side ``_RELAY_MODEL`` and the BYOK path uses its
    own overridable ``_byok_model()`` slug, so a per-request override on either
    is meaningless and is silently ignored rather than raising. The
    ``llm_calls`` audit row always records the model that was *actually* used
    (the transport-specific value), never a per-request override.
    """
    requested_model = normalise_model_override(model)
    prompt_chars = len(system) + len(user)
    started = time.monotonic()
    provider = "unknown"
    used_model: str | None = None
    try:
        provider_mode = _resolve_provider()
        if provider_mode == "cloud":
            if key := _try_load_api_key():
                provider = "byok"
                used_model = _byok_model()
                result = _complete_openrouter(system, user, key)
            elif cfg := load_cloud_config():
                provider = "relay"
                used_model = _RELAY_MODEL
                result = complete_via_relay(system, user, cfg)
            else:
                raise RuntimeError(_missing_key_message())
        elif provider_mode == "local" or (
            provider_mode == "auto" and _local_available(_local_base_url())
        ):
            provider = "local"
            used_model = requested_model or _local_model()
            result = _complete_local(system, user, _local_base_url(), used_model)
        elif provider_mode != "local":
            if key := _try_load_api_key():
                provider = "byok"
                used_model = _byok_model()
                result = _complete_openrouter(system, user, key)
            elif cfg := load_cloud_config():
                provider = "relay"
                used_model = _RELAY_MODEL
                result = complete_via_relay(system, user, cfg)
            else:
                raise RuntimeError(_missing_key_message())
        else:
            raise RuntimeError(_missing_key_message())
        latency_ms = int((time.monotonic() - started) * 1000)
        _log_llm_call(
            db_ref,
            call_site=call_site,
            provider=provider,
            model=used_model,
            prompt_chars=prompt_chars,
            response_chars=len(result),
            latency_ms=latency_ms,
            ok=True,
            error=None,
        )
        return result
    except Exception as exc:
        latency_ms = int((time.monotonic() - started) * 1000)
        _log_llm_call(
            db_ref,
            call_site=call_site,
            provider=provider,
            model=used_model,
            prompt_chars=prompt_chars,
            response_chars=None,
            latency_ms=latency_ms,
            ok=False,
            error=str(exc),
        )
        raise


def _load_api_key() -> str:
    """Backward-compatible strict loader for dispatch and other callers."""
    key = _try_load_api_key()
    if key:
        return key
    raise RuntimeError(
        "OPENROUTER_API_KEY not set.\n"
        f"Add it to {_CONFIG} or export it as an environment variable."
    )
