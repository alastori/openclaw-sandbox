#!/usr/bin/env python3
"""Deterministic overnight log review for cron and gateway health."""

from __future__ import annotations

import json
import re
import subprocess
import sys
from collections import Counter
from datetime import datetime, timedelta, timezone
from pathlib import Path

OPENCLAW_HOME = Path("/home/node/.openclaw")
EXTENSIONS_DIR = Path("/home/node/extensions")
BUFFER_SCRIPT = EXTENSIONS_DIR / "notifications" / "buffer.py"
LOG_FILE = OPENCLAW_HOME / "logs" / "openclaw.log"
CONFIG_AUDIT_FILE = OPENCLAW_HOME / "logs" / "config-audit.jsonl"
WINDOW_HOURS = 12

KNOWN_LOG_PATTERNS = (
    "Your credit balance is too low to access the Anthropic API",
    "You exceeded your current quota",
    "insufficient_quota",
    "low context window:",
    "skipped permission hardening for /home/node/.openclaw/state/openclaw.sqlite",
)


def parse_ts(value: str | None) -> datetime | None:
    if not value:
        return None
    try:
        parsed = datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None
    if parsed.tzinfo is None:
        return parsed.replace(tzinfo=timezone.utc)
    return parsed.astimezone(timezone.utc)


def shorten(value: object, limit: int = 220) -> str:
    text = str(value).replace("\n", " ").strip()
    text = re.sub(r"\s+", " ", text)
    if len(text) > limit:
        return text[: limit - 3] + "..."
    return text


def is_known_log_noise(message: str) -> bool:
    return any(pattern in message for pattern in KNOWN_LOG_PATTERNS)


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
            "morning-log-review",
        ],
        check=True,
    )


def cron_status_issues() -> list[str]:
    try:
        proc = subprocess.run(
            ["openclaw", "cron", "list", "--all", "--json"],
            stdout=subprocess.PIPE,
            stderr=subprocess.STDOUT,
            text=True,
            timeout=30,
            check=False,
        )
    except subprocess.SubprocessError as exc:
        return [f"cron status unavailable: {shorten(exc)}"]

    if proc.returncode != 0:
        return [f"cron status failed: {shorten(proc.stdout)}"]

    json_start = proc.stdout.find("{")
    if json_start == -1:
        return [f"cron status returned invalid JSON: {shorten(proc.stdout)}"]

    try:
        payload = json.loads(proc.stdout[json_start:])
    except json.JSONDecodeError:
        return [f"cron status returned invalid JSON: {shorten(proc.stdout)}"]

    issues = []
    for job in payload.get("jobs", []):
        state = job.get("state", {})
        if not job.get("enabled", True):
            continue
        if state.get("lastStatus") != "error" and job.get("status") != "error":
            continue
        name = job.get("name", job.get("id", "unknown"))
        count = state.get("consecutiveErrors", 0)
        error = state.get("lastDiagnosticSummary") or state.get("lastError") or "unknown error"
        issues.append(f"{name}: {count} consecutive error(s), {shorten(error)}")
    return issues


def log_issues(since: datetime) -> list[str]:
    if not LOG_FILE.exists():
        return []

    counts: Counter[str] = Counter()
    try:
        with LOG_FILE.open(errors="replace") as fh:
            for line in fh:
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                meta = record.get("_meta", {})
                ts = parse_ts(meta.get("date") or record.get("time"))
                if ts is None or ts < since:
                    continue
                level = meta.get("logLevelName", "")
                message = str(record.get("message") or record.get("1") or "")
                if not message:
                    continue
                if is_known_log_noise(message):
                    continue
                if level == "ERROR" or re.search(r"\b(error|fail|timeout)\b", message, re.I):
                    counts[shorten(message)] += 1
    except OSError as exc:
        return [f"openclaw.log unreadable: {shorten(exc)}"]

    return [f"{count}x {message}" for message, count in counts.most_common(6)]


def config_audit_issues(since: datetime) -> list[str]:
    if not CONFIG_AUDIT_FILE.exists():
        return []

    issues = []
    try:
        with CONFIG_AUDIT_FILE.open(errors="replace") as fh:
            for line in fh:
                try:
                    record = json.loads(line)
                except json.JSONDecodeError:
                    continue
                ts = parse_ts(record.get("ts"))
                if ts is None or ts < since:
                    continue
                suspicious = record.get("suspicious") or []
                if suspicious:
                    issues.append(f"config audit suspicious: {shorten(suspicious)}")
                elif record.get("event") == "config.write":
                    issues.append(f"config write: {shorten(record.get('argv', []))}")
    except OSError as exc:
        return [f"config-audit.jsonl unreadable: {shorten(exc)}"]
    return issues[:4]


def main() -> int:
    since = datetime.now(timezone.utc) - timedelta(hours=WINDOW_HOURS)
    issues = []
    issues.extend(cron_status_issues())
    issues.extend(log_issues(since))
    issues.extend(config_audit_issues(since))

    if issues:
        body = f"{len(issues)} issue(s) in the last {WINDOW_HOURS}h:\n" + "\n".join(f"- {item}" for item in issues[:10])
        if len(issues) > 10:
            body += f"\n- ... and {len(issues) - 10} more"
        buffer_notification("medium", "Log Review found issues", body)
    else:
        buffer_notification("low", "Log Review", "All clear. No new cron errors, gateway errors, or config-audit issues detected.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
