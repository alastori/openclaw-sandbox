#!/usr/bin/env bash
# Create default cron jobs for the OpenClaw gateway.
# Safe to run multiple times: creates missing jobs and updates existing jobs
# by name so prompt fixes are applied without deleting run history.
#
# Usage: bash scripts/setup-crons.sh [--telegram-chat-id ID] [--disable-duplicates]
# Requires a running gateway and Python 3. Updates jobs through ./oc.
# Stops on discovery errors or duplicate enabled jobs. With explicit opt-in,
# disables extra enabled copies; retains disabled jobs and their run history.
#
# If --telegram-chat-id is not provided, digest delivery setup is skipped.
# Existing digest jobs are left unchanged.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/load-local-env.sh"

CHAT_ID=""
DISABLE_DUPLICATES=false
while [[ $# -gt 0 ]]; do
  case "$1" in
    --telegram-chat-id)
      [[ $# -ge 2 && -n "$2" && "$2" != --* ]] || { echo "Missing Telegram chat ID" >&2; exit 1; }
      CHAT_ID="$2"
      shift 2
      ;;
    --disable-duplicates) DISABLE_DUPLICATES=true; shift ;;
    --*) echo "Unknown option: $1" >&2; exit 1 ;;
    *)
      [[ -z "$CHAT_ID" ]] || { echo "Unexpected argument: $1" >&2; exit 1; }
      CHAT_ID="$1"
      shift
      ;;
  esac
done

OC="$ROOT_DIR/oc"
TZ="America/New_York"

cron_json=""

refresh_jobs() {
  local listing
  if ! listing="$("$OC" cron list --all --json)"; then
    echo "Cron discovery failed; stopping setup." >&2
    return 1
  fi
  cron_json="$(python3 -c '
import json
import sys

try:
    lines = sys.stdin.read().splitlines()
    data = json.loads("\n".join(line for line in lines if not line.startswith("[state/db] skipped permission hardening for ")))
    if not isinstance(data, dict) or not isinstance(data.get("jobs"), list):
        raise ValueError("expected a jobs list")
    jobs = data["jobs"]
    if data.get("hasMore") or data.get("total", len(jobs)) != len(jobs):
        raise ValueError("incomplete job listing")
    ids = set()
    for job in jobs:
        if not isinstance(job, dict):
            raise ValueError("invalid job record")
        job_id = job.get("id")
        if not isinstance(job_id, str) or not job_id or job_id.startswith("-") or any(c.isspace() for c in job_id):
            raise ValueError("invalid job id")
        if job_id in ids or not isinstance(job.get("name"), str):
            raise ValueError("duplicate id or invalid job name")
        ids.add(job_id)
        if not isinstance(job.get("enabled", True), bool):
            raise ValueError("invalid enabled state")
    print(json.dumps(data))
except (ValueError, TypeError) as error:
    sys.exit("Cron discovery rejected: " + str(error))
' <<<"$listing")" || return 1
}

job_ids_by_name() {
  local name="$1"
  JOB_NAME="$name" python3 -c '
import json
import os
import sys

name = os.environ["JOB_NAME"]
data = json.load(sys.stdin)
jobs = [job for job in data["jobs"] if job["name"] == name]
jobs.sort(key=lambda job: (job.get("createdAtMs") if isinstance(job.get("createdAtMs"), (int, float)) else float("inf"), job["id"]))
enabled = [job for job in jobs if job.get("enabled", True)]
# Prefer an enabled copy. If all are disabled, update one without enabling it.
for job in enabled or jobs[:1]:
    print(job["id"])
' <<<"$cron_json"
}

upsert_job() {
  local name="$1"; shift
  local id
  local matching_ids
  local ids=()
  matching_ids="$(job_ids_by_name "$name")" || return 1
  while IFS= read -r id; do
    [[ -z "$id" ]] || ids+=("$id")
  done <<<"$matching_ids"
  if [[ ${#ids[@]} -gt 1 && "$DISABLE_DUPLICATES" != true ]]; then
    echo "Multiple enabled jobs named $name; stopping setup without disabling them." >&2
    return 1
  fi
  if [[ ${#ids[@]} -gt 0 ]]; then
    id="${ids[0]}"
    if ! "$OC" cron edit "$id" --name "$name" "$@" >/dev/null 2>&1; then
      echo "Failed to update $name ($id); stopping setup." >&2
      return 1
    fi
    echo "  [updated] $name"
    if [[ ${#ids[@]} -gt 1 ]]; then
      for id in "${ids[@]:1}"; do
        if ! "$OC" cron disable "$id" >/dev/null 2>&1; then
          echo "Failed to disable duplicate $name ($id); stopping setup. Earlier changes remain applied." >&2
          return 1
        fi
        echo "  [disabled duplicate] $name ($id)"
      done
      refresh_jobs
    fi
    return 0
  fi
  "$OC" cron add --name "$name" "$@" >/dev/null 2>&1
  echo "  [created] $name"
  refresh_jobs
}

echo "Setting up default cron jobs..."
refresh_jobs

# Check every managed name before the first mutation. Unrelated jobs are left alone.
managed_names=(nightly-update-check nightly-security-audit morning-log-review nightly-doc-drift weekly-memory-synthesis weekly-doc-watch nightly-auth-health cascade-detect)
if [[ -n "$CHAT_ID" ]]; then
  managed_names+=(digest-morning)
fi
for name in "${managed_names[@]}"; do
  matching_ids="$(job_ids_by_name "$name")" || exit 1
  count=0
  while IFS= read -r id; do
    [[ -z "$id" ]] || count=$((count + 1))
  done <<<"$matching_ids"
  if [[ $count -gt 1 && "$DISABLE_DUPLICATES" != true ]]; then
    echo "Multiple enabled jobs named $name; inspect them before using --disable-duplicates. No jobs changed." >&2
    exit 1
  fi
done

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
