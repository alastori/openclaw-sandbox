#!/usr/bin/env python3
"""Watch external documentation URLs for changes.

Fetches each URL, hashes the content, compares to stored hashes.
Reports changes to the notification buffer.

Usage:
  doc-watch.py                # Check all URLs, report changes
  doc-watch.py --dry-run      # Check without updating hashes or buffering
  doc-watch.py --init         # Initialize hashes without reporting changes
"""
import hashlib
import json
import os
import subprocess
import sys
import tempfile
from datetime import datetime
from pathlib import Path
from urllib.error import URLError
from urllib.request import Request, urlopen

EXTENSION_DIR = Path(__file__).resolve().parent
ROOT_DIR = EXTENSION_DIR.parent.parent

# Hashes file goes in a writable location (config volume inside Docker,
# extension dir on host). extensions/ is mounted read-only in the container.
_CONTAINER_STATE = Path("/home/node/.openclaw/doc-watch")
HASHES_FILE = _CONTAINER_STATE / "hashes.json" if _CONTAINER_STATE.parent.exists() else EXTENSION_DIR / "hashes.json"

MAX_RESPONSE_BYTES = 10 * 1024 * 1024  # 10 MB cap per URL

# URLs to watch — keyed by a short label
WATCH_URLS = {
    "anthropic-prompting": "https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices",
    "anthropic-whats-new": "https://platform.claude.com/docs/en/about-claude/models/whats-new-claude-4-6",
    "anthropic-migration": "https://platform.claude.com/docs/en/about-claude/models/migration-guide",
    "openai-prompt-guidance": "https://developers.openai.com/api/docs/guides/prompt-guidance",
    "openai-gpt5-cookbook": "https://cookbook.openai.com/examples/gpt-5/gpt-5_prompting_guide",
    "openai-codex-cookbook": "https://developers.openai.com/cookbook/examples/gpt-5/codex_prompting_guide",
    "gemini-strategies": "https://ai.google.dev/gemini-api/docs/prompting-strategies",
    "gemini-3-guide": "https://docs.cloud.google.com/vertex-ai/generative-ai/docs/start/gemini-3-prompting-guide",
}


def load_hashes():
    if HASHES_FILE.exists():
        try:
            with open(HASHES_FILE) as f:
                return json.load(f)
        except (json.JSONDecodeError, ValueError):
            print(f"  Warning: {HASHES_FILE} is corrupted, starting fresh")
            return {}
    return {}


def save_hashes(hashes):
    """Atomic write: temp file + rename to prevent corruption on interrupted writes."""
    HASHES_FILE.parent.mkdir(parents=True, exist_ok=True)
    fd, tmp_path = tempfile.mkstemp(dir=HASHES_FILE.parent, suffix=".json")
    try:
        with os.fdopen(fd, "w") as f:
            json.dump(hashes, f, indent=2)
            f.write("\n")
        os.replace(tmp_path, HASHES_FILE)
    except Exception:
        os.unlink(tmp_path)
        raise


def fetch_hash(url):
    """Fetch a URL and return (sha256_hex, None) or (None, error_str)."""
    try:
        req = Request(url, headers={
            "User-Agent": "Mozilla/5.0 (doc-watch/1.0)",
            "Accept": "text/html,application/xhtml+xml,*/*",
        })
        with urlopen(req, timeout=15) as resp:
            body = resp.read(MAX_RESPONSE_BYTES + 1)
            if len(body) > MAX_RESPONSE_BYTES:
                return None, f"response exceeds {MAX_RESPONSE_BYTES} bytes"
        return hashlib.sha256(body).hexdigest(), None
    except (URLError, OSError) as e:
        return None, str(e)


def buffer_notification(title, body, tier="low", source="doc-watch"):
    """Write to the notification buffer if available."""
    buffer_script = ROOT_DIR / "extensions" / "notifications" / "buffer.py"
    if not buffer_script.exists():
        print(f"  [{tier.upper()}] {title}: {body}")
        return
    env = os.environ.copy()
    # Inside Docker: /home/node/.openclaw exists; on host: use config/ path
    if not Path("/home/node/.openclaw").exists():
        env["NOTIFY_BUFFER_DIR"] = str(ROOT_DIR / "config" / "notifications")
    result = subprocess.run(
        ["python3", str(buffer_script),
         "--tier", tier, "--title", title, "--body", body, "--source", source],
        env=env,
    )
    if result.returncode != 0:
        print(f"  Warning: buffer.py exited with code {result.returncode}")


def main():
    dry_run = "--dry-run" in sys.argv
    init = "--init" in sys.argv

    stored = load_hashes()
    current = {}
    changed = []
    errors = []

    print(f"Checking {len(WATCH_URLS)} documentation URLs...")

    for label, url in WATCH_URLS.items():
        h, err = fetch_hash(url)
        if err:
            errors.append(f"{label}: {err}")
            print(f"  {label}: fetch error")
            continue

        current[label] = {"hash": h, "url": url, "checked": datetime.now().isoformat()}
        old_hash = stored.get(label, {}).get("hash")

        if old_hash is None:
            print(f"  {label}: new (first check)")
        elif old_hash != h:
            changed.append(label)
            print(f"  {label}: CHANGED")
        else:
            print(f"  {label}: unchanged")

    if dry_run:
        print(f"\nDry run: {len(changed)} changed, {len(errors)} errors. No hashes updated.")
        return 0

    if init:
        save_hashes(current)
        print(f"\nInitialized hashes for {len(current)} URLs.")
        return 0

    # Update stored hashes (preserves entries for URLs not in current WATCH_URLS)
    stored.update(current)
    save_hashes(stored)

    # Report changes
    if changed:
        labels = ", ".join(changed)
        body = f"{len(changed)} doc(s) changed: {labels}. Review defaults/prompt-guidelines.md and update if needed."
        buffer_notification(
            title="Prompt Docs Changed",
            body=body,
            tier="medium",
            source="doc-watch",
        )
        print(f"\nBuffered notification: {len(changed)} doc(s) changed.")
    else:
        print("\nNo changes detected.")

    if errors:
        print(f"Fetch errors: {len(errors)}")
        for e in errors:
            print(f"  {e}")

    return 1 if len(errors) == len(WATCH_URLS) else 0


if __name__ == "__main__":
    sys.exit(main())
