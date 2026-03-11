#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/load-local-env.sh"

CONFIG_FILE="${CONFIG_FILE:-config/openclaw.json}"
RUNTIME_ENV_FILE="${RUNTIME_ENV_FILE:-.runtime/openclaw.env}"
MODEL_POLICY_FILE="${MODEL_POLICY_FILE:-models.policy.json}"
TIMEOUT_SEC="${TIMEOUT_SEC:-20}"
ADOPT=0

for arg in "$@"; do
  case "$arg" in
    --adopt)
      ADOPT=1
      ;;
    *)
      echo "usage: bash ./scripts/check-models.sh [--adopt]" >&2
      exit 1
      ;;
  esac
done

if [[ ! -f "$CONFIG_FILE" ]]; then
  echo "error: $CONFIG_FILE not found; run bash ./scripts/render-secrets-up.sh first" >&2
  exit 1
fi

if [[ ! -f "$RUNTIME_ENV_FILE" ]]; then
  echo "error: $RUNTIME_ENV_FILE not found; run bash ./scripts/render-secrets-up.sh first" >&2
  exit 1
fi

if [[ ! -f "$MODEL_POLICY_FILE" ]]; then
  echo "error: $MODEL_POLICY_FILE not found" >&2
  exit 1
fi

python3 - "$CONFIG_FILE" "$RUNTIME_ENV_FILE" "$MODEL_POLICY_FILE" "$TIMEOUT_SEC" "$ADOPT" <<'PY'
import json
import os
import re
import shutil
import ssl
import subprocess
import sys
import time
import urllib.error
import urllib.parse
import urllib.request
from copy import deepcopy


def load_json(path: str):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def save_json(path: str, data):
    with open(path, "w", encoding="utf-8") as handle:
        json.dump(data, handle, indent=2)
        handle.write("\n")


def load_env_file(path: str) -> dict[str, str]:
    env = {}
    with open(path, "r", encoding="utf-8") as handle:
        for raw in handle:
            line = raw.strip()
            if not line or line.startswith("#") or "=" not in line:
                continue
            key, value = line.split("=", 1)
            env[key] = value
    return env


def http_json(url: str, headers: dict[str, str], timeout: int):
    req = urllib.request.Request(url, headers=headers, method="GET")
    start = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ssl.create_default_context()) as resp:
            body = resp.read().decode("utf-8", "replace")
            return resp.status, json.loads(body), time.time() - start, None
    except urllib.error.HTTPError as err:
        body = err.read().decode("utf-8", "replace")
        payload = None
        try:
            payload = json.loads(body)
        except json.JSONDecodeError:
            payload = {"raw": body}
        return err.code, payload, time.time() - start, None
    except Exception as err:
        return None, None, time.time() - start, err


def post_json(url: str, payload: dict, headers: dict[str, str], timeout: int):
    req = urllib.request.Request(
        url,
        data=json.dumps(payload).encode("utf-8"),
        headers={"Content-Type": "application/json", **headers},
        method="POST",
    )
    start = time.time()
    try:
        with urllib.request.urlopen(req, timeout=timeout, context=ssl.create_default_context()) as resp:
            body = resp.read().decode("utf-8", "replace")
            return resp.status, body, time.time() - start, None
    except urllib.error.HTTPError as err:
        body = err.read().decode("utf-8", "replace")
        return err.code, body, time.time() - start, None
    except Exception as err:
        return None, "", time.time() - start, err


def classify_probe(status_code, body: str, err) -> str:
    if err is not None or status_code is None:
        return "provider_unreachable"
    if 200 <= status_code < 300:
        return "ok"
    body_l = body.lower()
    if status_code in (401, 403):
        return "auth_failed"
    if status_code == 404 or ("model" in body_l and "not found" in body_l):
        return "model_not_found"
    if status_code == 429:
        return "rate_limited"
    return f"http_{status_code}"


def catalog_probe(provider: str, model: str, env: dict[str, str], timeout: int):
    status, models, elapsed = fetch_provider_models(provider, env, timeout)
    if status != "ok":
        return status, elapsed
    if model not in models:
        return "model_not_found", elapsed
    return "ok", elapsed


def probe_anthropic(model: str, env: dict[str, str], timeout: int):
    return catalog_probe("anthropic", model, env, timeout)


def probe_openai(model: str, env: dict[str, str], timeout: int):
    return catalog_probe("openai", model, env, timeout)


def probe_google(model: str, env: dict[str, str], timeout: int):
    key = env.get("GEMINI_API_KEY")
    if not key:
        return "missing_key", None
    url = (
        "https://generativelanguage.googleapis.com/v1beta/models/"
        + urllib.parse.quote(model, safe="")
        + ":generateContent?key="
        + urllib.parse.quote(key, safe="")
    )
    status, body, elapsed, err = post_json(
        url,
        {"contents": [{"parts": [{"text": "ping"}]}]},
        {},
        timeout,
    )
    return classify_probe(status, body, err), elapsed


def probe_ollama(model: str, config: dict, timeout: int):
    provider = config.get("models", {}).get("providers", {}).get("ollama", {})
    base_url = provider.get("baseUrl")
    if not base_url:
        return "missing_base_url", None
    if "host.docker.internal" in base_url:
        base_url = base_url.replace("host.docker.internal", "127.0.0.1")
    status, body, elapsed, err = post_json(
        base_url.rstrip("/") + "/chat/completions",
        {
            "model": model,
            "messages": [{"role": "user", "content": "ping"}],
            "max_tokens": 8,
        },
        {"Authorization": f"Bearer {provider.get('apiKey', 'ollama')}"},
        timeout,
    )
    return classify_probe(status, body, err), elapsed


PROBERS = {
    "anthropic": probe_anthropic,
    "openai": probe_openai,
    "google": probe_google,
    "ollama": probe_ollama,
}


def fetch_provider_models(provider: str, env: dict[str, str], timeout: int):
    if provider == "anthropic":
        key = env.get("ANTHROPIC_API_KEY")
        if not key:
            return "missing_key", [], None
        status, payload, elapsed, err = http_json(
            "https://api.anthropic.com/v1/models",
            {
                "x-api-key": key,
                "anthropic-version": "2023-06-01",
            },
            timeout,
        )
    elif provider == "openai":
        key = env.get("OPENAI_API_KEY")
        if not key:
            return "missing_key", [], None
        status, payload, elapsed, err = http_json(
            "https://api.openai.com/v1/models",
            {"Authorization": f"Bearer {key}"},
            timeout,
        )
    else:
        return "unsupported_provider", [], None

    if err is not None or status is None:
        return "provider_unreachable", [], None
    if status in (401, 403):
        return "auth_failed", [], None
    if status == 429:
        return "rate_limited", [], None
    if not 200 <= status < 300:
        return f"http_{status}", [], None

    data = payload.get("data", []) if isinstance(payload, dict) else []
    ids = []
    for item in data:
        model_id = item.get("id")
        if model_id:
            ids.append(model_id)
    return "ok", ids, elapsed


def fetch_openclaw_models(provider: str):
    if shutil.which("docker") is None:
        return "docker_missing", []
    try:
        proc = subprocess.run(
            [
                "docker",
                "compose",
                "exec",
                "-T",
                "openclaw-gateway",
                "openclaw",
                "models",
                "list",
                "--all",
                "--provider",
                provider,
                "--json",
            ],
            check=True,
            text=True,
            capture_output=True,
        )
    except Exception:
        return "unavailable", []

    payload = json.loads(proc.stdout)
    ids = []
    prefix = provider + "/"
    for item in payload.get("models", []):
        key = item.get("key")
        if key and key.startswith(prefix):
            ids.append(key[len(prefix):])
    return "ok", ids


def version_tuple(model_id: str, pattern: re.Pattern[str]):
    match = pattern.fullmatch(model_id)
    if not match:
        return None
    groups = []
    for group in match.groups():
        if group is None:
            groups.append(0)
        else:
            groups.append(int(group))
    return tuple(groups)


def latest_matching(models: list[str], family_regex: str):
    pattern = re.compile(family_regex)
    best_id = None
    best_version = None
    for model_id in models:
        parsed = version_tuple(model_id, pattern)
        if parsed is None:
            continue
        if best_version is None or parsed > best_version:
            best_id = model_id
            best_version = parsed
    return best_id


def model_alias(provider: str, model_id: str):
    if provider == "anthropic":
        for prefix, label in (
            ("claude-sonnet-", "Sonnet "),
            ("claude-opus-", "Opus "),
            ("claude-haiku-", "Haiku "),
        ):
            if model_id.startswith(prefix):
                return label + model_id[len(prefix):].replace("-", ".")
    if provider == "openai" and model_id.startswith("gpt-"):
        return model_id.upper()
    return model_id


config_path, runtime_env_path, policy_path, timeout_raw, adopt_raw = sys.argv[1:]
config = load_json(config_path)
policy = load_json(policy_path)
env = {**os.environ, **load_env_file(runtime_env_path)}
timeout = int(timeout_raw)
adopt = adopt_raw == "1"

defaults = config.get("agents", {}).get("defaults", {})
model_cfg = defaults.get("model", {})
primary = model_cfg.get("primary")
fallbacks = model_cfg.get("fallbacks", [])
registered = list(defaults.get("models", {}).keys())

required_models = []
if primary:
    required_models.append(primary)
required_models.extend(model for model in fallbacks if model not in required_models)

optional_models = [model for model in registered if model not in required_models]

probe_results = []
failed_required = False
for role, model_list in (("required", required_models), ("optional", optional_models)):
    for model in model_list:
        provider, _, model_id = model.partition("/")
        probe = PROBERS.get(provider)
        if probe is None:
            probe_results.append((role, model, "not_checked", None))
            continue
        if provider == "ollama":
            status, elapsed = probe(model_id, config, timeout)
        else:
            status, elapsed = probe(model_id, env, timeout)
        if role == "required" and status != "ok":
            failed_required = True
        probe_results.append((role, model, status, elapsed))

print("Configured models")
if probe_results:
    width = max(len(model) for _, model, _, _ in probe_results)
    for role, model, status, elapsed in probe_results:
        elapsed_s = "-" if elapsed is None else f"{elapsed:.1f}s"
        print(f"{role:<8} {model:<{width}}  {status:<18} {elapsed_s}")
else:
    print("none")

policy_entries = [("primary", policy["defaults"]["primary"])]
for index, entry in enumerate(policy["defaults"].get("fallbacks", []), start=1):
    policy_entries.append((f"fallback{index}", entry))

provider_cache = {}
openclaw_cache = {}
policy_updates = []

print("")
print("Policy audit")
label_width = max(len(label) for label, _ in policy_entries)

for label, entry in policy_entries:
    provider = entry["provider"]
    pinned = entry["pinned"]
    provider_model_id = pinned.split("/", 1)[1]
    family_regex = entry["familyRegex"]

    if provider not in provider_cache:
        provider_cache[provider] = fetch_provider_models(provider, env, timeout)
    catalog_status, provider_models, _ = provider_cache[provider]

    if provider not in openclaw_cache:
        openclaw_cache[provider] = fetch_openclaw_models(provider)
    openclaw_status, openclaw_models = openclaw_cache[provider]

    latest_provider = latest_matching(provider_models, family_regex) if catalog_status == "ok" else None
    latest_source = "provider_api"
    if latest_provider is None and openclaw_status == "ok":
        latest_provider = latest_matching(openclaw_models, family_regex)
        latest_source = "openclaw_catalog"

    if latest_provider is None:
        audit_status = catalog_status
    elif latest_provider == provider_model_id:
        audit_status = "up_to_date"
    else:
        audit_status = "newer_available"

    openclaw_support = "-"
    if latest_provider is not None:
        if openclaw_status == "ok":
            openclaw_support = "yes" if latest_provider in openclaw_models else "no"
        else:
            openclaw_support = openclaw_status

    latest_display = "-" if latest_provider is None else f"{provider}/{latest_provider}"
    print(
        f"{label:<{label_width}}  {pinned:<32}  {audit_status:<16} latest={latest_display:<32} source={latest_source:<16} openclaw={openclaw_support}"
    )

    if adopt and audit_status == "newer_available":
        if latest_source != "provider_api":
            print(f"skip    {label:<{label_width}}  latest model was not confirmed by the provider catalog")
            continue
        if openclaw_support != "yes":
            print(f"skip    {label:<{label_width}}  latest model is not confirmed in OpenClaw")
            continue
        updated = deepcopy(entry)
        updated["pinned"] = provider + "/" + latest_provider
        updated["alias"] = model_alias(provider, latest_provider)
        policy_updates.append((label, updated))

if adopt and policy_updates:
    updated_policy = deepcopy(policy)
    for label, updated in policy_updates:
        if label == "primary":
            updated_policy["defaults"]["primary"] = updated
        else:
            index = int(label.replace("fallback", "")) - 1
            updated_policy["defaults"]["fallbacks"][index] = updated
    save_json(policy_path, updated_policy)
    print("")
    print(f"Updated {policy_path}")
    print("Next: bash ./scripts/render-secrets-up.sh")
elif adopt:
    print("")
    print("No policy updates were applied.")

if failed_required:
    sys.exit(1)
PY
