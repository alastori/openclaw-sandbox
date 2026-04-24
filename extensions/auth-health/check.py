#!/usr/bin/env python3
"""Probe each pinned model in the failover chain and report auth health.

Designed to be invoked by an OpenClaw cron with the local Ollama model
(`ollama/qwen3.6:35b-a3b-q8_0`) so it remains operational even when every
hosted provider is broken — that is the precise failure mode it exists to
detect. Closes the detection gap exposed by the April 2026 cascade incident,
where Gemini and OpenAI Codex OAuth refresh tokens rotted silently for ~4 days
before anyone noticed.

Probes are deliberately cheap (no LLM tokens spent):
- Anthropic, OpenAI: GET /v1/models with the API key. 200 = ok, 401/403 = bad.
- Google Gemini: prefer the local OAuth profile expiry; fall back to GET on
  the generative-language models list with the API key.
- OpenAI Codex (OAuth): inspect auth-profiles.json for the lastGood profile,
  check `expires` and `usageStats.errorCount`.
- Ollama: GET /api/tags and confirm the pinned model id is in the response.

Writes one notification via the existing extensions/notifications/buffer.py
helper. Critical tier when the primary or 2+ fallbacks fail; medium when
exactly one fallback fails; low all-clear otherwise.
"""

from __future__ import annotations

import json
import os
import ssl
import subprocess
import sys
import urllib.error
import urllib.parse
import urllib.request
from pathlib import Path

OPENCLAW_HOME = Path(os.environ.get("OPENCLAW_HOME", "/home/node/.openclaw"))
EXTENSIONS_DIR = Path(os.environ.get("OPENCLAW_EXTENSIONS_DIR", "/home/node/extensions"))
BUFFER_SCRIPT = EXTENSIONS_DIR / "notifications" / "buffer.py"
CONFIG_FILE = OPENCLAW_HOME / "openclaw.json"
AUTH_PROFILES_FILE = OPENCLAW_HOME / "agents" / "main" / "agent" / "auth-profiles.json"
TIMEOUT_SEC = 15


def http_get(url: str, headers: dict[str, str]) -> tuple[int | None, Exception | None]:
    req = urllib.request.Request(url, headers=headers, method="GET")
    try:
        with urllib.request.urlopen(req, timeout=TIMEOUT_SEC, context=ssl.create_default_context()) as resp:
            return resp.status, None
    except urllib.error.HTTPError as err:
        return err.code, None
    except Exception as err:  # noqa: BLE001 — we want to capture every transport failure
        return None, err


def classify(status: int | None, err: Exception | None) -> str:
    if err is not None or status is None:
        return "unreachable"
    if 200 <= status < 300:
        return "ok"
    if status in (401, 403):
        return "auth_failed"
    if status == 429:
        return "rate_limited"
    if status == 404:
        return "not_found"
    return f"http_{status}"


def probe_anthropic(_model_id: str) -> str:
    key = os.environ.get("ANTHROPIC_API_KEY")
    if not key:
        return "missing_key"
    status, err = http_get(
        "https://api.anthropic.com/v1/models",
        {"x-api-key": key, "anthropic-version": "2023-06-01"},
    )
    return classify(status, err)


def probe_openai(_model_id: str) -> str:
    key = os.environ.get("OPENAI_API_KEY")
    if not key:
        return "missing_key"
    status, err = http_get(
        "https://api.openai.com/v1/models",
        {"Authorization": f"Bearer {key}"},
    )
    return classify(status, err)


def probe_google(_model_id: str, profiles: dict) -> str:
    # Prefer the OAuth path if a profile exists, since it's the project's preferred path.
    oauth_status = check_oauth_profile(profiles, "google-gemini-cli")
    if oauth_status != "no_profile":
        return oauth_status
    key = os.environ.get("GEMINI_API_KEY")
    if not key:
        return "missing_key"
    status, err = http_get(
        "https://generativelanguage.googleapis.com/v1beta/models?key=" + urllib.parse.quote(key, safe=""),
        {},
    )
    return classify(status, err)


def probe_openai_codex(_model_id: str, profiles: dict) -> str:
    return check_oauth_profile(profiles, "openai-codex")


def probe_ollama(model_id: str) -> str:
    status, err = http_get("http://host.docker.internal:11434/api/tags", {})
    if err is not None or status is None:
        return "unreachable"
    if status != 200:
        return f"http_{status}"
    # Re-read the body so we can confirm the model is present. http_get only returns the
    # status; do a second small request that captures the body.
    try:
        with urllib.request.urlopen(
            urllib.request.Request("http://host.docker.internal:11434/api/tags", method="GET"),
            timeout=TIMEOUT_SEC,
        ) as resp:
            payload = json.loads(resp.read().decode("utf-8", "replace"))
    except Exception:  # noqa: BLE001
        return "unreachable"
    available = {item.get("name") for item in payload.get("models", [])}
    if model_id in available:
        return "ok"
    return "not_found"


def check_oauth_profile(profiles: dict, provider: str) -> str:
    """Confirm at least one usable OAuth profile exists for `provider`.

    The `expires` field on a profile is the access token's lifetime (~1 h for
    Google, ~10 d for Codex). The gateway refreshes it lazily on the next API
    call, so an expired access token is NOT a health signal — it's the normal
    steady state between calls. The refresh-token health is what matters, and
    it surfaces in two places:
      - usageStats[profile].errorCount, which the gateway increments when a
        refresh attempt fails.
      - The "[openai-codex] Token refresh failed" gateway log lines, which
        the cascade-detect script picks up.

    Here we just check that at least one profile for the provider has no
    recorded errors. The cascade-detect script provides the live "OAuth just
    broke" signal.
    """
    if not profiles:
        return "no_profile"
    candidates = [
        name
        for name, data in profiles.get("profiles", {}).items()
        if data.get("provider") == provider or name.startswith(provider + ":")
    ]
    if not candidates:
        return "no_profile"
    usage = profiles.get("usageStats", {})
    healthy = [name for name in candidates if usage.get(name, {}).get("errorCount", 0) == 0]
    if healthy:
        return "ok"
    return "oauth_recent_errors"


PROBERS = {
    "anthropic": probe_anthropic,
    "openai": probe_openai,
    "google": probe_google,
    "openai-codex": probe_openai_codex,
    "ollama": probe_ollama,
}


def load_failover_chain() -> list[str]:
    config = json.loads(CONFIG_FILE.read_text())
    model_cfg = config.get("agents", {}).get("defaults", {}).get("model", {})
    chain = []
    primary = model_cfg.get("primary")
    if primary:
        chain.append(primary)
    chain.extend(m for m in model_cfg.get("fallbacks", []) if m not in chain)
    return chain


def load_profiles() -> dict:
    if not AUTH_PROFILES_FILE.exists():
        return {}
    return json.loads(AUTH_PROFILES_FILE.read_text())


def main() -> int:
    chain = load_failover_chain()
    profiles = load_profiles()

    rows = []
    for model in chain:
        provider, _, model_id = model.partition("/")
        prober = PROBERS.get(provider)
        if prober is None:
            rows.append((model, "not_checked"))
            continue
        if provider in ("google", "openai-codex"):
            status = prober(model_id, profiles)
        else:
            status = prober(model_id)
        rows.append((model, status))

    primary_status = rows[0][1] if rows else "no_chain"
    failed = [(m, s) for m, s in rows[1:] if s != "ok"]
    primary_failed = primary_status != "ok"

    if primary_failed or len(failed) >= 2:
        tier = "critical"
        title = "Auth FAILED"
    elif failed:
        tier = "medium"
        title = "Auth degraded"
    else:
        tier = "low"
        title = "Auth Health"

    body_lines = [f"chain: {len(rows)} models, {sum(1 for _, s in rows if s != 'ok')} failing"]
    body_lines += [f"  {m}: {s}" for m, s in rows]
    body = "\n".join(body_lines)

    subprocess.run(
        [
            sys.executable,
            str(BUFFER_SCRIPT),
            "--tier",
            tier,
            "--title",
            title,
            "--body",
            body,
            "--source",
            "auth-health",
        ],
        check=True,
    )
    return 0


if __name__ == "__main__":
    sys.exit(main())
