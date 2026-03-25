#!/usr/bin/env bash
# Create default cron jobs for the OpenClaw gateway.
# Safe to run multiple times — skips jobs that already exist (by name).
#
# Usage: bash scripts/setup-crons.sh [--telegram-chat-id ID]
#
# If --telegram-chat-id is not provided, digest delivery is disabled
# (jobs still buffer notifications, but no Telegram messages are sent).
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
MODEL_LIGHT="google/gemini-2.5-flash"   # Lightweight checks (update, security audit, digest) — subscription
MODEL_HEAVY="openai-codex/gpt-5.4"      # Reasoning-heavy tasks (doc drift, memory synthesis) — subscription
TZ="America/New_York"

existing=$("$OC" cron list 2>/dev/null | tail -n +2 || true)

create_if_missing() {
  local name="$1"; shift
  if echo "$existing" | grep -q "$name"; then
    echo "  [skip] $name (already exists)"
    return 0
  fi
  "$OC" cron add --name "$name" "$@" >/dev/null 2>&1
  echo "  [created] $name"
}

echo "Setting up default cron jobs..."

# --- Nightly ops (buffer to notification system) ---

create_if_missing "nightly-update-check" \
  --cron "0 2 * * *" --tz "$TZ" \
  --model "$MODEL_LIGHT" --thinking off --timeout-seconds 180 \
  --no-deliver \
  --message "Check if there is a newer version of OpenClaw available. Run: openclaw update status. Then write your findings to the notification buffer by running: python3 /home/node/extensions/notifications/buffer.py --tier low --title 'Update Check' --body '<your one-line summary>' --source nightly-update-check"

create_if_missing "nightly-security-audit" \
  --cron "30 2 * * *" --tz "$TZ" \
  --model "$MODEL_LIGHT" --thinking off --timeout-seconds 180 \
  --no-deliver \
  --message "Run a security audit: openclaw security audit --deep. Before reporting, read workspace/learnings.md for known acceptable findings (ClawSec shell patterns, 0.0.0.0 binding, Ollama sandbox warnings). Exclude those from your report. For genuinely new findings, write to the notification buffer: python3 /home/node/extensions/notifications/buffer.py --tier low --title 'Security Audit' --body '<your summary of NEW findings only>' --source nightly-security-audit. Use --tier critical only for genuinely new critical issues. If everything is known/acceptable, buffer a brief all-clear at tier low."

create_if_missing "morning-log-review" \
  --cron "0 7 * * *" --tz "$TZ" \
  --model "$MODEL_LIGHT" --thinking off --timeout-seconds 300 \
  --no-deliver \
  --message "Review the gateway logs from the last 12 hours. First read workspace/learnings.md for known acceptable findings — do not re-report those. Look for genuinely new errors, warnings, failed cron runs, model failures. For each new issue, if you can identify the root cause, append a lesson to workspace/learnings.md with the date and what went wrong. Then write your summary to the notification buffer: python3 /home/node/extensions/notifications/buffer.py --tier low --title 'Log Review' --body '<your summary of NEW issues only>' --source morning-log-review. Use --tier medium for serious new issues. If nothing new, buffer a brief all-clear at tier low."

create_if_missing "nightly-doc-drift" \
  --cron "0 3 * * *" --tz "$TZ" \
  --model "$MODEL_HEAVY" --thinking off --timeout-seconds 300 \
  --no-deliver \
  --message "Compare the workspace documentation files (TOOLS.md, AGENTS.md, IDENTITY.md, USER.md) against the actual system state. Check: Are configured models documented? Are any skills or tools mentioned that no longer exist? Are there undocumented features? Write a summary to the notification buffer: python3 /home/node/extensions/notifications/buffer.py --tier low --title 'Doc Drift' --body '<your findings>' --source nightly-doc-drift. Only report if you found actual gaps."

create_if_missing "weekly-memory-synthesis" \
  --cron "40 3 * * 0" --tz "$TZ" \
  --model "$MODEL_HEAVY" --thinking off --timeout-seconds 600 \
  --no-deliver \
  --message "Review all daily memory files from the past week (memory/YYYY-MM-DD.md). Identify significant events, lessons, decisions, user preferences, and recurring themes worth keeping long-term. Update MEMORY.md with distilled insights — add new entries and remove anything stale or outdated. Also review learnings.md and remove any lessons that are no longer relevant. Write a summary to the notification buffer: python3 /home/node/extensions/notifications/buffer.py --tier low --title 'Memory Synthesis' --body '<brief summary of what was added/removed>' --source weekly-memory-synthesis"

# --- Digest delivery ---

if [[ -n "$CHAT_ID" ]]; then
  create_if_missing "digest-morning" \
    --cron "15 7 * * *" --tz "$TZ" \
    --model "$MODEL_LIGHT" --thinking off --timeout-seconds 60 \
    --no-deliver \
    --message "Execute this command exactly: python3 /home/node/extensions/notifications/digest.py --all. The script handles Telegram delivery on its own. Just run it."
else
  echo ""
  echo "  [info] Skipped digest-morning (no --telegram-chat-id provided)."
  echo "  To add later: ./oc cron add --name digest-morning --cron '15 7 * * *' --tz $TZ ..."
fi

echo ""
echo "Done. View with: ./oc cron list"
