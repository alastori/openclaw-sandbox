#!/usr/bin/env bash
# Create default cron jobs for the OpenClaw gateway.
# Safe to run multiple times: creates missing jobs and updates existing jobs
# by name so prompt fixes are applied without deleting run history.
#
# Usage: bash scripts/setup-crons.sh [--telegram-chat-id ID]
#
# If --telegram-chat-id is not provided, digest delivery setup is skipped.
# Existing digest jobs are left unchanged.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/load-local-env.sh"

CHAT_ID="${1:-}"
if [[ "$CHAT_ID" == "--telegram-chat-id" ]]; then
  CHAT_ID="${2:-}"
fi

OC="$ROOT_DIR/oc"
TZ="America/New_York"

cron_json=""

refresh_jobs() {
  cron_json="$("$OC" cron list --all --json 2>/dev/null || printf '{"jobs":[]}')"
}

job_id_by_name() {
  local name="$1"
  JOB_NAME="$name" python3 -c '
import json
import os
import sys

name = os.environ["JOB_NAME"]
try:
    data = json.load(sys.stdin)
except json.JSONDecodeError:
    data = {"jobs": []}

for job in data.get("jobs", []):
    if job.get("name") == name:
        print(job.get("id", ""))
        break
' <<<"$cron_json"
}

upsert_job() {
  local name="$1"; shift
  local id
  id="$(job_id_by_name "$name")"
  if [[ -n "$id" ]]; then
    "$OC" cron edit "$id" --name "$name" "$@" >/dev/null 2>&1
    echo "  [updated] $name"
    return 0
  fi
  "$OC" cron add --name "$name" "$@" >/dev/null 2>&1
  echo "  [created] $name"
  refresh_jobs
}

echo "Setting up default cron jobs..."
refresh_jobs

# --- Nightly ops (buffer to notification system) ---
#
# Script-only checks use command payloads instead of agentTurn payloads. That
# keeps deterministic checks from being retried because an LLM failed after the
# script already buffered its notification.

upsert_job "nightly-update-check" \
  --cron "0 2 * * *" --tz "$TZ" \
  --no-deliver \
  --timeout-seconds 180 --output-max-bytes 4096 \
  --command-argv '["python3","/home/node/extensions/update-check/check.py"]'

upsert_job "nightly-security-audit" \
  --cron "30 2 * * *" --tz "$TZ" \
  --no-deliver \
  --timeout-seconds 180 --output-max-bytes 4096 \
  --command-argv '["python3","/home/node/extensions/security-audit/check.py"]'

upsert_job "morning-log-review" \
  --cron "0 7 * * *" --tz "$TZ" \
  --no-deliver \
  --timeout-seconds 120 --output-max-bytes 4096 \
  --command-argv '["python3","/home/node/extensions/log-review/check.py"]'

upsert_job "nightly-doc-drift" \
  --cron "0 3 * * *" --tz "$TZ" \
  --no-deliver \
  --timeout-seconds 120 --output-max-bytes 4096 \
  --command-argv '["python3","/home/node/extensions/doc-drift/check.py"]'

upsert_job "weekly-memory-synthesis" \
  --cron "40 3 * * 0" --tz "$TZ" \
  --no-deliver \
  --timeout-seconds 120 --output-max-bytes 4096 \
  --command-argv '["python3","/home/node/extensions/memory-synthesis/synthesize.py"]'

upsert_job "weekly-doc-watch" \
  --cron "0 4 * * 1" --tz "$TZ" \
  --no-deliver \
  --timeout-seconds 240 --output-max-bytes 4096 \
  --command-argv '["python3","/home/node/extensions/doc-watch/doc-watch.py"]'

# --- Monitoring ---
# These two crons watch the rest of the system. They run as command payloads so
# they keep firing during the exact failure mode they exist to detect: a hosted
# provider auth or rate-limit outage that breaks every other agent cron. The
# April 2026 cascade incident (commit `9ef8bac`, 4-day silent outage) is the
# precedent.
#
# Verified 2026-06-25 on OpenClaw 2026.6.9:
#   cascade-detect command payload completed in 82 ms and reset its error state.

upsert_job "nightly-auth-health" \
  --cron "0 6 * * *" --tz "$TZ" \
  --no-deliver \
  --timeout-seconds 180 --output-max-bytes 4096 \
  --command-argv '["python3","/home/node/extensions/auth-health/check.py"]'

upsert_job "cascade-detect" \
  --cron "*/30 * * * *" --tz "$TZ" \
  --no-deliver \
  --timeout-seconds 180 --output-max-bytes 4096 \
  --command-argv '["python3","/home/node/extensions/cascade-detect/detect.py"]'

# --- Digest delivery ---

if [[ -n "$CHAT_ID" ]]; then
  upsert_job "digest-morning" \
    --cron "15 7 * * *" --tz "$TZ" \
    --no-deliver \
    --timeout-seconds 60 --output-max-bytes 4096 \
    --command-argv '["python3","/home/node/extensions/notifications/digest.py","--all"]'
else
  echo ""
  echo "  [info] Skipped digest-morning (no --telegram-chat-id provided)."
  echo "  To add later: ./oc cron add --name digest-morning --cron '15 7 * * *' --tz $TZ ..."
fi

echo ""
echo "Done. View with: ./oc cron list"
