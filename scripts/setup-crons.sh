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
MODEL_LIGHT="google/gemini-2.5-flash"         # Lightweight checks (update, security audit, digest) — subscription
MODEL_HEAVY="openai-codex/gpt-5.4"            # Reasoning-heavy tasks (doc drift, memory synthesis) — subscription
MODEL_MONITOR="ollama/qwen3.6:35b-a3b-q8_0"   # Monitoring crons — local so they survive hosted outages
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
  --message "Review overnight logs. Sources in priority order: (1) /home/node/.openclaw/cron/runs/*.jsonl, grep for '\"status\":\"error\"' in files modified in the last 12h, this is the authoritative signal for cron failures; (2) /home/node/.openclaw/logs/openclaw.log, tail the last 2000 lines and grep -iE 'error|fail|timeout'; (3) /home/node/.openclaw/logs/config-audit.jsonl for unexpected config changes. Read workspace/learnings.md first and skip anything listed there. For genuinely new issues, append a dated lesson to workspace/learnings.md, then buffer a summary: python3 /home/node/extensions/notifications/buffer.py --tier low --title 'Log Review' --body '<your summary of NEW issues only>' --source morning-log-review. Use --tier medium for serious new issues. If nothing new, buffer a brief all-clear at tier low."

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

create_if_missing "weekly-doc-watch" \
  --cron "0 4 * * 1" --tz "$TZ" \
  --model "$MODEL_LIGHT" --thinking off --timeout-seconds 240 \
  --no-deliver \
  --message "Run this command exactly: python3 /home/node/extensions/doc-watch/doc-watch.py. It checks if prompting guidelines from Anthropic, OpenAI, and Google have been updated. The script handles notification buffering on its own. Just run it and report the output."

# --- Monitoring ---
# These two crons watch the rest of the system. They run on a local Ollama
# model (`$MODEL_MONITOR`) so they keep firing during the exact failure mode
# they exist to detect: a hosted-provider auth or rate-limit outage that
# breaks every other cron. The April 2026 cascade incident (commit `9ef8bac`,
# 4-day silent outage) is the precedent.
#
# Verified 2026-04-24 on OpenClaw 2026.4.5 + ollama/qwen3.6:35b-a3b-q8_0:
#   nightly-auth-health ran in ~40s, produced the expected notification file.
#   cascade-detect only works with `--tools exec`; without that restriction
#   qwen3.6 tries to edit the script (rootfs is read-only, loops to timeout).
# Earlier Ollama+OpenClaw combos had a hardcoded ~60s streaming timeout and a
# qwen3-coder tool-call format bug; neither reproduces in the current stack.

create_if_missing "nightly-auth-health" \
  --cron "0 6 * * *" --tz "$TZ" \
  --model "$MODEL_MONITOR" --thinking off --timeout-seconds 180 \
  --no-deliver \
  --message "Run this command exactly: python3 /home/node/extensions/auth-health/check.py. The script handles notification buffering on its own. Just run it."

create_if_missing "cascade-detect" \
  --cron "*/30 * * * *" --tz "$TZ" \
  --model "$MODEL_MONITOR" --thinking off --timeout-seconds 180 \
  --tools exec \
  --no-deliver \
  --message "Run this command exactly: python3 /home/node/extensions/cascade-detect/detect.py. The script handles notification buffering on its own. Just run it."

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
