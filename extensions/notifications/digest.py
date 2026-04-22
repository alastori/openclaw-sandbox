#!/usr/bin/env python3
"""Read the notification buffer for a tier, format a digest, deliver to Telegram, and clear.

Usage:
  digest.py --tier low         # Deliver all buffered low-priority notifications
  digest.py --tier medium      # Deliver all buffered medium-priority notifications
  digest.py --tier critical    # Deliver all buffered critical notifications
  digest.py --all              # Deliver all tiers in one combined message
  digest.py --dry-run --all    # Preview without sending or clearing
"""
import argparse
import json
import os
import sys
from datetime import datetime
from pathlib import Path
from urllib.error import URLError
from urllib.request import Request, urlopen

EXTENSION_DIR = Path(__file__).resolve().parent
ROOT_DIR = EXTENSION_DIR.parent.parent

# Host side: ROOT_DIR/config/logs; container side: /home/node/.openclaw/logs.
# Both point at the same dir on disk via the config/ volume mount.
_openclaw_home = Path.home() / ".openclaw"
AUDIT_LOG = (_openclaw_home if _openclaw_home.exists() else ROOT_DIR / "config") / "logs" / "digest.jsonl"


def log_delivery(record: dict) -> None:
    """Append one JSON line with delivery outcome. Never raises."""
    try:
        AUDIT_LOG.parent.mkdir(parents=True, exist_ok=True)
        record = {"ts": datetime.now().isoformat(timespec="seconds"), **record}
        with open(AUDIT_LOG, "a") as fh:
            fh.write(json.dumps(record) + "\n")
    except Exception:
        pass

TIER_LABELS = {
    "critical": "CRITICAL",
    "medium": "MEDIUM",
    "low": "LOW",
}

TIER_ORDER = ["critical", "medium", "low"]


def load_config() -> dict:
    config_file = EXTENSION_DIR / "config.json"
    if not config_file.exists():
        config_file = EXTENSION_DIR / "config.example.json"
    with open(config_file) as f:
        cfg = json.load(f)
    if not cfg.get("telegram_chat_id"):
        raise RuntimeError(
            "telegram_chat_id is empty. Copy config.example.json to config.json "
            "and fill in your Telegram chat ID."
        )
    return cfg


def get_bot_token() -> str:
    token = os.environ.get("TELEGRAM_BOT_TOKEN")
    if token:
        return token
    # Host-side: .runtime/openclaw.env
    env_file = ROOT_DIR / ".runtime" / "openclaw.env"
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            if line.startswith("TELEGRAM_BOT_TOKEN="):
                return line.split("=", 1)[1].strip()
    # Container-side: openclaw.json
    for config_path in [
        Path.home() / ".openclaw" / "openclaw.json",
        ROOT_DIR / "config" / "openclaw.json",
    ]:
        if config_path.exists():
            try:
                with open(config_path) as f:
                    cfg = json.load(f)
                token = cfg.get("channels", {}).get("telegram", {}).get("botToken")
                if token and not token.startswith("op://"):
                    return token
            except (json.JSONDecodeError, OSError):
                pass
    raise RuntimeError("TELEGRAM_BOT_TOKEN not found")


def read_buffer(buffer_dir: Path, tier: str) -> list[dict]:
    """Read and sort all entries in a tier buffer."""
    tier_dir = buffer_dir / tier
    if not tier_dir.exists():
        return []
    entries = []
    for f in sorted(tier_dir.glob("*.json")):
        try:
            with open(f) as fh:
                entry = json.load(fh)
                entry["_path"] = f
                entries.append(entry)
        except (json.JSONDecodeError, OSError):
            continue
    return entries


def clear_buffer(entries: list[dict]) -> int:
    """Delete buffered files. Returns count deleted."""
    count = 0
    for entry in entries:
        path = entry.get("_path")
        if path and Path(path).exists():
            Path(path).unlink()
            count += 1
    return count


def format_digest(entries_by_tier):
    """Format a combined digest message. Returns None if empty."""
    total = sum(len(v) for v in entries_by_tier.values())
    if total == 0:
        return None

    now = datetime.now()
    lines = [f"Notification Digest — {now:%B %d, %Y %H:%M}"]
    lines.append(f"{total} notification(s)\n")

    for tier in TIER_ORDER:
        entries = entries_by_tier.get(tier, [])
        if not entries:
            continue
        lines.append(f"--- {TIER_LABELS[tier]} ({len(entries)}) ---\n")
        for entry in entries:
            ts = entry.get("timestamp", "?")
            title = entry.get("title", "Untitled")
            body = entry.get("body", "").strip()
            source = entry.get("source", "")
            header = f"[{ts}] {title}"
            if source and source != "unknown":
                header += f" ({source})"
            lines.append(header)
            if body:
                # Indent body and truncate long bodies
                if len(body) > 500:
                    body = body[:497] + "..."
                lines.append(body)
            lines.append("")

    return "\n".join(lines).strip()


def send_telegram(text: str, chat_id: str, bot_token: str, topic_id=None) -> int:
    if len(text) > 4000:
        text = text[:3997] + "..."
    msg = {
        "chat_id": int(chat_id),
        "text": text,
        "disable_web_page_preview": True,
    }
    if topic_id:
        msg["message_thread_id"] = int(topic_id)
    payload = json.dumps(msg).encode()
    req = Request(
        f"https://api.telegram.org/bot{bot_token}/sendMessage",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )
    try:
        with urlopen(req, timeout=15) as resp:
            return resp.status
    except URLError as e:
        if hasattr(e, "code"):
            return e.code
        raise


def main():
    parser = argparse.ArgumentParser(description="Deliver notification digests")
    parser.add_argument("--tier", choices=TIER_ORDER, help="Deliver a single tier")
    parser.add_argument("--all", action="store_true", help="Deliver all tiers combined")
    parser.add_argument("--dry-run", action="store_true", help="Preview without sending")
    args = parser.parse_args()

    if not args.tier and not args.all:
        parser.error("Specify --tier or --all")

    config = load_config()
    buffer_dir = Path(os.environ.get("NOTIFY_BUFFER_DIR", config["buffer_dir"]))

    tiers = TIER_ORDER if args.all else [args.tier]
    entries_by_tier = {}
    for tier in tiers:
        entries_by_tier[tier] = read_buffer(buffer_dir, tier)

    message = format_digest(entries_by_tier)
    if not message:
        print("No pending notifications.")
        return 0

    if args.dry_run:
        print("--- DRY RUN ---")
        print(message)
        print(f"--- Would clear {sum(len(v) for v in entries_by_tier.values())} entries ---")
        return 0

    bot_token = get_bot_token()
    chat_id = config["telegram_chat_id"]
    topics = config.get("topics", {})
    tier_configs = config.get("tiers", {})

    # Group entries by target topic for separate delivery
    by_topic = {}
    for tier in tiers:
        entries = entries_by_tier.get(tier, [])
        if not entries:
            continue
        topic_name = tier_configs.get(tier, {}).get("topic")
        topic_id = topics.get(topic_name) if topic_name else None
        by_topic.setdefault(topic_id, {})[tier] = entries

    if not by_topic:
        print("No pending notifications.")
        return 0

    all_entries = [e for entries in entries_by_tier.values() for e in entries]
    success = True

    for topic_id, tier_entries in by_topic.items():
        msg = format_digest(tier_entries)
        if not msg:
            continue
        entry_count = sum(len(v) for v in tier_entries.values())
        try:
            status = send_telegram(msg, chat_id, bot_token, topic_id=topic_id)
        except Exception as e:
            log_delivery({"event": "send_exception", "topic_id": topic_id, "entries": entry_count, "error": str(e)[:200]})
            print(f"Telegram delivery failed ({e}, topic={topic_id}). Buffer NOT cleared.")
            success = False
            continue
        log_delivery({"event": "send", "topic_id": topic_id, "entries": entry_count, "http_status": status, "ok": status == 200})
        if status != 200:
            print(f"Telegram delivery failed (HTTP {status}, topic={topic_id}). Buffer NOT cleared.")
            success = False

    if success:
        cleared = clear_buffer(all_entries)
        log_delivery({"event": "cleared", "entries": len(all_entries), "files": cleared})
        print(f"Delivered digest ({len(all_entries)} entries), cleared {cleared} files.")
        return 0
    else:
        return 1


if __name__ == "__main__":
    sys.exit(main())
