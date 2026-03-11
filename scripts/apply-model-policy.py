#!/usr/bin/env python3

import json
import os
import sys
from copy import deepcopy
from typing import Optional


def load_json(path: str):
    with open(path, "r", encoding="utf-8") as handle:
        return json.load(handle)


def ensure_entry(models: dict, old_key: Optional[str], new_key: str, alias: str):
    entry = {}
    if new_key in models and isinstance(models[new_key], dict):
        entry = deepcopy(models[new_key])
    elif old_key and old_key in models and isinstance(models[old_key], dict):
        entry = deepcopy(models[old_key])
    entry["alias"] = alias
    models[new_key] = entry


def main() -> int:
    if len(sys.argv) != 3:
        print("usage: apply-model-policy.py CONFIG_FILE POLICY_FILE", file=sys.stderr)
        return 1

    config_path, policy_path = sys.argv[1], sys.argv[2]
    config = load_json(config_path)
    policy = load_json(policy_path)

    defaults = config.setdefault("agents", {}).setdefault("defaults", {})
    model_defaults = defaults.setdefault("model", {})
    models = defaults.setdefault("models", {})

    previous_primary = model_defaults.get("primary")
    previous_fallbacks = list(model_defaults.get("fallbacks", []))

    primary_policy = policy["defaults"]["primary"]
    fallback_policies = policy["defaults"].get("fallbacks", [])

    primary_key = primary_policy["pinned"]
    fallback_keys = [entry["pinned"] for entry in fallback_policies]

    model_defaults["primary"] = primary_key
    model_defaults["fallbacks"] = fallback_keys

    ensure_entry(models, previous_primary, primary_key, primary_policy["alias"])

    for index, fallback_key in enumerate(fallback_keys):
        previous_key = previous_fallbacks[index] if index < len(previous_fallbacks) else None
        ensure_entry(models, previous_key, fallback_key, fallback_policies[index]["alias"])

    gateway = config.setdefault("gateway", {})
    control_ui = gateway.setdefault("controlUi", {})
    port = int(os.environ.get("OPENCLAW_PORT", "18789"))
    gateway["port"] = port
    control_ui["allowedOrigins"] = [
        f"http://localhost:{port}",
        f"http://127.0.0.1:{port}",
    ]

    with open(config_path, "w", encoding="utf-8") as handle:
        json.dump(config, handle, indent=2)
        handle.write("\n")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
