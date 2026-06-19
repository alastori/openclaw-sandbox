#!/usr/bin/env python3
"""Run OpenClaw security audit and buffer only actionable findings.

OpenClaw 2026.4.5 reports `models.small_params` as critical for local
Ollama fallback models because it sees global web tools and sandbox=off.
This project mitigates that risk with a provider-scoped deny rule:

  tools.byProvider.ollama.deny = ["web_search", "web_fetch", "browser_navigate"]

The upstream audit does not currently account for provider-scoped tool denies.
This wrapper keeps the notification signal useful by filtering that known
acceptable finding only when the deny rule is actually present.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from dataclasses import dataclass
from pathlib import Path

OPENCLAW_HOME = Path(os.environ.get("OPENCLAW_HOME", "/home/node/.openclaw"))
EXTENSIONS_DIR = Path(os.environ.get("OPENCLAW_EXTENSIONS_DIR", "/home/node/extensions"))
CONFIG_FILE = OPENCLAW_HOME / "openclaw.json"
BUFFER_SCRIPT = EXTENSIONS_DIR / "notifications" / "buffer.py"
REQUIRED_OLLAMA_DENIES = {"web_search", "web_fetch", "browser_navigate"}
SEVERITIES = {"CRITICAL", "WARN", "WARNING", "INFO"}


@dataclass
class Finding:
    severity: str
    finding_id: str
    title: str
    lines: list[str]


def load_config() -> dict:
    try:
        return json.loads(CONFIG_FILE.read_text())
    except (OSError, json.JSONDecodeError):
        return {}


def ollama_web_tools_denied(config: dict) -> bool:
    deny = (
        config.get("tools", {})
        .get("byProvider", {})
        .get("ollama", {})
        .get("deny", [])
    )
    return REQUIRED_OLLAMA_DENIES.issubset(set(deny))


def run_audit() -> tuple[int, str]:
    proc = subprocess.run(
        ["openclaw", "security", "audit", "--deep"],
        text=True,
        stdout=subprocess.PIPE,
        stderr=subprocess.STDOUT,
        check=False,
    )
    return proc.returncode, proc.stdout.strip()


def parse_findings(output: str) -> list[Finding]:
    findings: list[Finding] = []
    current_severity: str | None = None
    current: Finding | None = None

    def flush() -> None:
        nonlocal current
        if current is not None:
            findings.append(current)
            current = None

    for raw_line in output.splitlines():
        line = raw_line.rstrip()
        if line in SEVERITIES:
            flush()
            current_severity = "WARN" if line == "WARNING" else line
            continue

        issue_match = re.match(r"^([a-z][a-z0-9_.-]+)\s+(.+)$", line)
        if current_severity in {"CRITICAL", "WARN"} and issue_match:
            flush()
            current = Finding(
                severity=current_severity,
                finding_id=issue_match.group(1),
                title=issue_match.group(2),
                lines=[line],
            )
            continue

        if current is not None:
            current.lines.append(line)

    flush()
    return findings


def is_known_acceptable(finding: Finding, config: dict) -> bool:
    if finding.finding_id == "models.small_params" and ollama_web_tools_denied(config):
        return True
    return False


def format_findings(findings: list[Finding], limit: int = 4) -> str:
    chunks = []
    for finding in findings[:limit]:
        chunks.append(f"{finding.severity} {finding.finding_id}: {finding.title}")
    if len(findings) > limit:
        chunks.append(f"... and {len(findings) - limit} more")
    return "\n".join(chunks)


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
            "nightly-security-audit",
        ],
        check=True,
    )


def main() -> int:
    config = load_config()
    returncode, output = run_audit()
    findings = parse_findings(output)

    if returncode != 0 and not findings:
        body = "Security audit command failed before producing parseable findings."
        if output:
            body += "\n\n" + output[:1200]
        buffer_notification("critical", "Security Audit FAILED", body)
        return returncode

    unknown = [finding for finding in findings if not is_known_acceptable(finding, config)]
    known = [finding for finding in findings if is_known_acceptable(finding, config)]

    critical = [finding for finding in unknown if finding.severity == "CRITICAL"]
    warnings = [finding for finding in unknown if finding.severity == "WARN"]

    if critical:
        body = format_findings(critical)
        if known:
            body += f"\n\nSuppressed known acceptable finding(s): {', '.join(f.finding_id for f in known)}"
        buffer_notification("critical", "Security Audit FAILED", body)
    elif warnings:
        body = format_findings(warnings)
        if known:
            body += f"\n\nSuppressed known acceptable finding(s): {', '.join(f.finding_id for f in known)}"
        buffer_notification("medium", "Security Audit warnings", body)
    else:
        if known:
            known_ids = ", ".join(sorted({finding.finding_id for finding in known}))
            body = f"Security audit completed. All findings are known and acceptable. Suppressed: {known_ids}."
        else:
            body = "Security audit completed. No actionable findings."
        buffer_notification("low", "Security Audit", body)

    return 0


if __name__ == "__main__":
    sys.exit(main())
