#!/usr/bin/env python3
"""Deep-merge defaults/*.json into a rendered openclaw.json.

User-explicit values win; defaults only fill in missing keys.
Skips $comment fields.

Usage: python3 scripts/apply-defaults.py <config.json> <defaults-dir/>
"""
import json
import sys
from pathlib import Path


def deep_merge(base: dict, overlay: dict) -> dict:
    """Merge overlay into base. Base values win for non-dict leaves."""
    for key, value in overlay.items():
        if key == "$comment":
            continue
        if key in base and isinstance(base[key], dict) and isinstance(value, dict):
            deep_merge(base[key], value)
        elif key not in base:
            base[key] = value
    return base


def main():
    if len(sys.argv) < 3:
        print(f"Usage: {sys.argv[0]} <config.json> <defaults-dir/>", file=sys.stderr)
        sys.exit(1)

    config_path = Path(sys.argv[1])
    defaults_dir = Path(sys.argv[2])

    with open(config_path) as f:
        config = json.load(f)

    applied = []
    for defaults_file in sorted(defaults_dir.glob("*.json")):
        if defaults_file.name == "models.policy.json":
            continue  # handled by apply-model-policy.py
        with open(defaults_file) as f:
            defaults = json.load(f)
        deep_merge(config, defaults)
        applied.append(defaults_file.name)

    with open(config_path, "w") as f:
        json.dump(config, f, indent=2)
        f.write("\n")

    if applied:
        print(f"Applied defaults: {', '.join(applied)}")


if __name__ == "__main__":
    main()
