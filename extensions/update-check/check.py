#!/usr/bin/env python3
"""Check OpenClaw update status and buffer a compact notification."""

from __future__ import annotations

import subprocess
import sys
from pathlib import Path

OPENCLAW_HOME = Path("/home/node/.openclaw")
EXTENSIONS_DIR = Path("/home/node/extensions")
BUFFER_SCRIPT = EXTENSIONS_DIR / "notifications" / "buffer.py"


def compact(text: str, limit: int = 900) -> str:
    lines = [line.strip() for line in text.splitlines() if line.strip()]
    body = "\n".join(lines[:12]) or "openclaw update status produced no output."
    if len(body) > limit:
        return body[: limit - 3] + "..."
    return body


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
            "nightly-update-check",
        ],
        check=True,
    )


def main() -> int:
    proc = subprocess.run(
        ["openclaw", "update", "status"],
        cwd=str(OPENCLAW_HOME),
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        text=True,
        timeout=120,
        check=False,
    )
    body = compact(proc.stdout)
    if proc.returncode == 0:
        buffer_notification("low", "Update Check", body)
        return 0

    buffer_notification("medium", "Update Check failed", body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
