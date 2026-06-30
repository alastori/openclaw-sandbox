#!/usr/bin/env python3
"""Check active workspace docs against key runtime state."""

from __future__ import annotations

import json
import subprocess
import sys
from pathlib import Path

OPENCLAW_HOME = Path("/home/node/.openclaw")
EXTENSIONS_DIR = Path("/home/node/extensions")
BUFFER_SCRIPT = EXTENSIONS_DIR / "notifications" / "buffer.py"
CONFIG_FILE = OPENCLAW_HOME / "openclaw.json"
WORKSPACE_DIR = OPENCLAW_HOME / "workspace"
REQUIRED_DOCS = ["TOOLS.md", "AGENTS.md", "IDENTITY.md", "USER.md"]
REQUIRED_EXTENSIONS = [
    "notifications/buffer.py",
    "notifications/digest.py",
    "update-check/check.py",
    "log-review/check.py",
    "doc-drift/check.py",
    "memory-synthesis/synthesize.py",
    "doc-watch/doc-watch.py",
    "security-audit/check.py",
    "auth-health/check.py",
    "cascade-detect/detect.py",
]


def buffer_notification(tier: str, title: str, body: str) -> None:
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
            "nightly-doc-drift",
        ],
        check=True,
    )


def load_config() -> dict:
    try:
        return json.loads(CONFIG_FILE.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def documented_text() -> str:
    chunks = []
    for name in REQUIRED_DOCS:
        path = WORKSPACE_DIR / name
        if path.exists():
            chunks.append(path.read_text(errors="replace"))
    return "\n".join(chunks)


def configured_models(config: dict) -> list[str]:
    model_cfg = config.get("agents", {}).get("defaults", {}).get("model", {})
    models = []
    primary = model_cfg.get("primary")
    if primary:
        models.append(primary)
    models.extend(model for model in model_cfg.get("fallbacks", []) if model not in models)
    return models


def main() -> int:
    config = load_config()
    docs = documented_text()
    gaps = []

    for name in REQUIRED_DOCS:
        if not (WORKSPACE_DIR / name).exists():
            gaps.append(f"missing workspace doc: {name}")

    for model in configured_models(config):
        if model not in docs:
            gaps.append(f"configured model not documented in active workspace: {model}")

    for rel_path in REQUIRED_EXTENSIONS:
        if not (EXTENSIONS_DIR / rel_path).exists():
            gaps.append(f"expected extension missing: {rel_path}")

    if not config:
        gaps.append("active openclaw.json could not be read")

    if gaps:
        body = "Documentation drift detected:\n" + "\n".join(f"- {gap}" for gap in gaps[:10])
        if len(gaps) > 10:
            body += f"\n- ... and {len(gaps) - 10} more"
        buffer_notification("medium", "Doc Drift", body)
    else:
        buffer_notification("low", "Doc Drift", "PASS: No gaps detected. Documentation matches key runtime state.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
