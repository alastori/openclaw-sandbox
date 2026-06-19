#!/usr/bin/env python3
"""Detect failover-cascade events in the gateway log and notify.

Closes the second detection gap from the April 2026 cascade incident:
the cron dashboard showed nightly-doc-drift as Status=ok for four days
while it was silently falling through from openai-codex (subscription)
to openai (per-token) on every run. The dashboard tracks completion,
not which model was actually used, so silent fallback degradation is
invisible there.

This script polls the in-container gateway log for two patterns:

  [model-fallback] model fallback decision: decision=candidate_failed ...
  [agent] embedded run failover decision: runId=... decision=fallback_model ...

Groups by runId, summarizes (which models failed and why), and writes
medium-tier notifications via the existing notifications/buffer.py.

Designed to be invoked by an OpenClaw cron with the local Ollama model
so it remains operational when hosted auth is broken.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
from datetime import datetime, timezone
from pathlib import Path

OPENCLAW_HOME = Path(os.environ.get("OPENCLAW_HOME", "/home/node/.openclaw"))
EXTENSIONS_DIR = Path(os.environ.get("OPENCLAW_EXTENSIONS_DIR", "/home/node/extensions"))
BUFFER_SCRIPT = EXTENSIONS_DIR / "notifications" / "buffer.py"
LOG_DIRS = [OPENCLAW_HOME / "logs", Path("/tmp/openclaw")]
STATE_DIR = OPENCLAW_HOME / "cascade-detect"
STATE_FILE = STATE_DIR / "state.json"

# 2026-04-07T18:14:35.984+00:00 [model-fallback] model fallback decision: decision=candidate_failed requested=google/gemini-2.5-flash candidate=google/gemini-2.5-flash reason=auth next=openai-codex/gpt-5.4
FALLBACK_RE = re.compile(
    r"^(?P<ts>\S+)\s+\[model-fallback\] model fallback decision:\s+"
    r"decision=(?P<decision>\S+)\s+requested=(?P<requested>\S+)\s+"
    r"candidate=(?P<candidate>\S+)\s+reason=(?P<reason>\S+)"
)

# 2026-04-07T06:01:06.024+00:00 [agent] embedded run failover decision: runId=34af0cbb-... stage=assistant decision=fallback_model reason=timeout provider=ollama/gemma4:26b-a4b-it-q8_0 profile=-
RUN_RE = re.compile(
    r"^(?P<ts>\S+)\s+\[agent\] embedded run failover decision:\s+"
    r"runId=(?P<run_id>\S+).*?reason=(?P<reason>\S+)"
)


def load_state() -> dict:
    if not STATE_FILE.exists():
        return {"last_processed_iso": None}
    try:
        return json.loads(STATE_FILE.read_text())
    except json.JSONDecodeError:
        return {"last_processed_iso": None}


def save_state(state: dict) -> None:
    STATE_DIR.mkdir(parents=True, exist_ok=True)
    STATE_FILE.write_text(json.dumps(state, indent=2) + "\n")


def candidate_log_files() -> list[Path]:
    """Current and recent gateway logs, in ascending mtime order."""
    files: list[Path] = []
    for log_dir in LOG_DIRS:
        if not log_dir.exists():
            continue
        current = log_dir / "openclaw.log"
        if current.exists():
            files.append(current)
        files.extend(sorted(log_dir.glob("openclaw-*.log"))[-2:])

    unique = {str(path): path for path in files}
    return sorted(unique.values(), key=lambda path: path.stat().st_mtime)


def parse_iso(value: str) -> datetime | None:
    try:
        return datetime.fromisoformat(value.replace("Z", "+00:00"))
    except ValueError:
        return None


def collect_events(since_iso: str | None) -> tuple[list[dict], str | None]:
    since_dt = parse_iso(since_iso) if since_iso else None
    events = []
    latest_ts = since_iso

    for log_path in candidate_log_files():
        try:
            content = log_path.read_text(errors="replace")
        except OSError:
            continue
        for line in content.splitlines():
            ts_match = re.match(r"^(\S+)", line)
            if not ts_match:
                continue
            line_dt = parse_iso(ts_match.group(1))
            if line_dt is None:
                continue
            if since_dt is not None and line_dt <= since_dt:
                continue

            fb = FALLBACK_RE.match(line)
            if fb:
                events.append({
                    "kind": "candidate_failed",
                    "ts": fb.group("ts"),
                    "requested": fb.group("requested"),
                    "candidate": fb.group("candidate"),
                    "reason": fb.group("reason"),
                })
                latest_ts = fb.group("ts") if latest_ts is None or fb.group("ts") > latest_ts else latest_ts
                continue

            run = RUN_RE.match(line)
            if run:
                events.append({
                    "kind": "run_fallback",
                    "ts": run.group("ts"),
                    "run_id": run.group("run_id"),
                    "reason": run.group("reason"),
                })
                latest_ts = run.group("ts") if latest_ts is None or run.group("ts") > latest_ts else latest_ts

    return events, latest_ts


def summarize_runs(events: list[dict]) -> list[str]:
    """Group candidate_failed events by inferred run, return one summary line per affected run.

    The candidate_failed events don't carry runId, but they appear in lockstep with
    [diagnostic] lines that do. As a simple heuristic, we use run_fallback events as
    the canonical "this run was degraded" markers and report them. The candidate_failed
    events provide the per-hop detail when grouped by request order.
    """
    run_events = [e for e in events if e["kind"] == "run_fallback"]
    if not run_events:
        return []

    # For each run, find the candidate_failed events that occurred immediately before it
    # in time and share the same `requested` model — those are the chain hops that fired.
    summaries = []
    for run in run_events:
        run_ts = run["ts"]
        # Find candidate_failed events within ~5 seconds before the run_fallback
        related = [
            e for e in events
            if e["kind"] == "candidate_failed" and e["ts"] <= run_ts and e["ts"] >= run_ts[:19]  # crude same-minute filter
        ]
        if related:
            chain = " -> ".join(f"{e['candidate']} ({e['reason']})" for e in related[-5:])
            summaries.append(f"runId={run['run_id'][:8]} reason={run['reason']} chain={chain}")
        else:
            summaries.append(f"runId={run['run_id'][:8]} reason={run['reason']}")
    return summaries


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
            "cascade-detect",
        ],
        check=True,
    )


def main() -> int:
    state = load_state()
    since_iso = state.get("last_processed_iso")
    events, latest_ts = collect_events(since_iso)

    if not events:
        # First run with no state: just record the current time and return silently.
        if since_iso is None:
            now_iso = datetime.now(timezone.utc).isoformat(timespec="seconds")
            save_state({"last_processed_iso": now_iso})
        return 0

    summaries = summarize_runs(events)
    if not summaries:
        # candidate_failed events but no run_fallback markers — log noise without an
        # actual cron-level failure. Update state but don't notify.
        if latest_ts:
            save_state({"last_processed_iso": latest_ts})
        return 0

    if len(summaries) >= 4:
        body = f"{len(summaries)} cron runs degraded since {since_iso or 'epoch'}.\n\n" + "\n".join(summaries[:8])
        if len(summaries) > 8:
            body += f"\n... and {len(summaries) - 8} more"
        buffer_notification("medium", f"{len(summaries)} cron runs degraded", body)
    else:
        for summary in summaries:
            buffer_notification("medium", "Cron run degraded", summary)

    if latest_ts:
        save_state({"last_processed_iso": latest_ts})
    return 0


if __name__ == "__main__":
    sys.exit(main())
