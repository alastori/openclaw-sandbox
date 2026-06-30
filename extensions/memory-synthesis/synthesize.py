#!/usr/bin/env python3
"""Synthesize existing daily memory notes into MEMORY.md.

This is intentionally deterministic. The weekly cron should not fail just
because some daily memory files were never created, and it should not need a
model call to keep the long-term memory file current.
"""

from __future__ import annotations

import argparse
import hashlib
import json
import os
import re
import subprocess
import sys
from datetime import date, datetime, timedelta, timezone
from pathlib import Path

EXTENSION_DIR = Path(__file__).resolve().parent
ROOT_DIR = EXTENSION_DIR.parent.parent
DEFAULT_OPENCLAW_HOME = Path("/home/node/.openclaw") if Path("/home/node/.openclaw").exists() else ROOT_DIR / "config"
OPENCLAW_HOME = Path(os.environ.get("OPENCLAW_HOME", DEFAULT_OPENCLAW_HOME))
EXTENSIONS_DIR = Path(os.environ.get("OPENCLAW_EXTENSIONS_DIR", "/home/node/extensions" if Path("/home/node/extensions").exists() else ROOT_DIR / "extensions"))
BUFFER_SCRIPT = EXTENSIONS_DIR / "notifications" / "buffer.py"
WORKSPACE_DIR = OPENCLAW_HOME / "workspace"
MEMORY_DIR = WORKSPACE_DIR / "memory"
MEMORY_FILE = WORKSPACE_DIR / "MEMORY.md"
STATE_DIR = OPENCLAW_HOME / "memory-synthesis"
STATE_FILE = STATE_DIR / "state.json"
MARKER_PREFIX = "<!-- weekly-memory-synthesis:"


def parse_args() -> argparse.Namespace:
    parser = argparse.ArgumentParser(description="Update MEMORY.md from existing daily memory files")
    parser.add_argument("--days", type=int, default=8, help="Number of calendar days to scan, inclusive of today")
    parser.add_argument("--dry-run", action="store_true", help="Print the generated section without writing or buffering")
    return parser.parse_args()


def parse_date_from_name(path: Path) -> date | None:
    try:
        return datetime.strptime(path.stem, "%Y-%m-%d").date()
    except ValueError:
        return None


def daily_files(days: int) -> list[Path]:
    today = datetime.now(timezone.utc).date()
    start = today - timedelta(days=max(days - 1, 0))
    files = []
    if not MEMORY_DIR.exists():
        return files
    for path in sorted(MEMORY_DIR.glob("*.md")):
        file_date = parse_date_from_name(path)
        if file_date is None:
            continue
        if start <= file_date <= today:
            files.append(path)
    return files


def meaningful_lines(text: str, limit: int = 8) -> list[str]:
    lines = []
    current_heading = ""
    for raw_line in text.splitlines():
        line = raw_line.strip()
        if not line:
            continue
        if line.startswith("# "):
            continue
        if line.startswith("## "):
            current_heading = line.lstrip("#").strip()
            continue
        if line.startswith("- "):
            item = line[2:].strip()
        else:
            item = line
        if not item or item.startswith("<!--"):
            continue
        item = re.sub(r"\s+", " ", item)
        if current_heading and not item.lower().startswith(current_heading.lower()):
            item = f"{current_heading}: {item}"
        lines.append(item)
        if len(lines) >= limit:
            break
    return lines


def digest_sources(files: list[Path]) -> str:
    digest = hashlib.sha256()
    for path in files:
        digest.update(path.name.encode())
        digest.update(b"\0")
        digest.update(path.read_bytes())
        digest.update(b"\0")
    return digest.hexdigest()[:16]


def load_state() -> dict:
    if not STATE_FILE.exists():
        return {}
    try:
        return json.loads(STATE_FILE.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def save_state(state: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, indent=2) + "\n")


def build_section(files: list[Path], source_hash: str) -> str:
    today = datetime.now(timezone.utc).date().isoformat()
    source_dates = ", ".join(path.stem for path in files)
    lines = [
        f"## Weekly Synthesis - {today}",
        f"{MARKER_PREFIX}{today}:{source_hash} -->",
        f"Source daily files: {source_dates}",
        "",
    ]
    for path in files:
        items = meaningful_lines(path.read_text(errors="replace"))
        if not items:
            continue
        lines.append(f"### {path.stem}")
        lines.extend(f"- {item}" for item in items)
        lines.append("")
    return "\n".join(lines).rstrip() + "\n"


def append_section(section: str) -> None:
    MEMORY_FILE.parent.mkdir(parents=True, exist_ok=True)
    existing = MEMORY_FILE.read_text(errors="replace") if MEMORY_FILE.exists() else "# MEMORY.md\n"
    MEMORY_FILE.write_text(existing.rstrip() + "\n\n" + section)


def buffer_notification(tier: str, title: str, body: str) -> None:
    if not BUFFER_SCRIPT.exists():
        print(f"[{tier}] {title}: {body}")
        return
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
            "weekly-memory-synthesis",
        ],
        check=True,
    )


def main() -> int:
    args = parse_args()
    files = daily_files(args.days)
    if not files:
        body = f"No daily memory files found in the last {args.days} days. MEMORY.md unchanged."
        if args.dry_run:
            print(body)
        else:
            buffer_notification("low", "Memory Synthesis", body)
        return 0

    source_hash = digest_sources(files)
    existing = MEMORY_FILE.read_text(errors="replace") if MEMORY_FILE.exists() else ""
    if source_hash in existing:
        body = f"Weekly memory synthesis already current for {len(files)} source file(s)."
        if args.dry_run:
            print(body)
        else:
            buffer_notification("low", "Memory Synthesis", body)
        save_state({"last_source_hash": source_hash, "last_source_files": [path.name for path in files]})
        return 0

    section = build_section(files, source_hash)
    if args.dry_run:
        print(section)
        return 0

    append_section(section)
    save_state({"last_source_hash": source_hash, "last_source_files": [path.name for path in files]})
    body = f"Updated MEMORY.md from {len(files)} existing daily memory file(s): {', '.join(path.stem for path in files)}."
    buffer_notification("low", "Memory Synthesis", body)
    return 0


if __name__ == "__main__":
    sys.exit(main())
