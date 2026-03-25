#!/usr/bin/env python3
"""Write a notification to the buffer.

Usage:
  buffer.py --tier low --title "Update Check" --body "OpenClaw is up to date."
  buffer.py --tier critical --title "System Down" --body "Gateway unreachable."

Critical tier triggers immediate delivery after buffering.
"""
import argparse
import json
import os
import subprocess
import sys
from datetime import datetime
from pathlib import Path

EXTENSION_DIR = Path(__file__).resolve().parent
ROOT_DIR = EXTENSION_DIR.parent.parent


def load_config() -> dict:
    config_file = EXTENSION_DIR / "config.json"
    if not config_file.exists():
        config_file = EXTENSION_DIR / "config.example.json"
    with open(config_file) as f:
        return json.load(f)


def main():
    parser = argparse.ArgumentParser(description="Buffer a notification")
    parser.add_argument("--tier", required=True, choices=["critical", "medium", "low"])
    parser.add_argument("--title", required=True)
    parser.add_argument("--body", required=True)
    parser.add_argument("--source", default="unknown", help="Source job/cron name")
    args = parser.parse_args()

    config = load_config()
    buffer_dir = Path(os.environ.get("NOTIFY_BUFFER_DIR", config["buffer_dir"])) / args.tier
    buffer_dir.mkdir(parents=True, exist_ok=True)

    ts = datetime.now()
    entry = {
        "timestamp": ts.isoformat(timespec="seconds"),
        "title": args.title,
        "body": args.body,
        "source": args.source,
        "tier": args.tier,
    }

    filename = f"{ts:%Y%m%d-%H%M%S}-{args.source}.json"
    out_path = buffer_dir / filename
    with open(out_path, "w") as f:
        json.dump(entry, f, indent=2)
        f.write("\n")

    print(f"Buffered [{args.tier}] {args.title} -> {out_path}")

    # Critical tier: deliver immediately
    if args.tier == "critical":
        digest_script = EXTENSION_DIR / "digest.py"
        subprocess.run(
            [sys.executable, str(digest_script), "--tier", "critical"],
            cwd=str(ROOT_DIR),
        )

    return 0


if __name__ == "__main__":
    sys.exit(main())
