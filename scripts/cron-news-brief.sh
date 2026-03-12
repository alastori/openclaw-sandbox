#!/usr/bin/env bash
# Host-side workaround for the broken built-in cron executor.
# Runs the daily news brief via ./oc agent and delivers to Telegram.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# Extract bot token from env file (can't source directly — unquoted spaces)
if [[ -f .runtime/openclaw.env ]]; then
  TELEGRAM_BOT_TOKEN=$(grep '^TELEGRAM_BOT_TOKEN=' .runtime/openclaw.env | cut -d= -f2-)
fi

: "${TELEGRAM_BOT_TOKEN:?missing TELEGRAM_BOT_TOKEN in .runtime/openclaw.env}"
CHAT_ID="6453473977"

PROMPT='Prepare a short daily news brief for the user. Order sections exactly as follows: (1) United States, (2) Florida Northeast with emphasis on Jacksonville metro and St. Augustine, (3) Brazil, (4) World, (5) Science, (6) Fun. Keep it concise, useful, and easy to skim. Use web search when needed, prioritize high-signal developments from the last day, avoid sensationalism, and clearly say when a section is quiet. Include a few relevant links at the end, ideally 3 to 5 total, pointing to the most useful or authoritative sources from the briefing. For the Fun section, include one light and interesting item such as a curiosity, ephemeris, quirky fact, uplifting oddity, or very short human-interest story. Deliver the brief as a single cohesive message.'

echo "[$(date -Iseconds)] Starting news brief..."

# Run the agent (uses gateway with Ollama fallback)
CONTENT=$(./oc agent --agent main --message "$PROMPT" 2>/dev/null) || {
  echo "[$(date -Iseconds)] Agent failed" >&2
  exit 1
}

if [[ -z "$CONTENT" ]]; then
  echo "[$(date -Iseconds)] Agent returned empty content" >&2
  exit 1
fi

# Build JSON payload via python (handles all escaping safely)
PAYLOAD=$(python3 -c "
import json, sys
text = sys.stdin.read().strip()
# Telegram messages have a 4096 char limit
if len(text) > 4000:
    text = text[:3997] + '...'
print(json.dumps({
    'chat_id': int('$CHAT_ID'),
    'text': text,
    'disable_web_page_preview': True
}))
" <<< "$CONTENT")

# Send to Telegram
HTTP_CODE=$(curl -sf -o /dev/null -w '%{http_code}' \
  -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
  -H 'Content-Type: application/json' \
  -d "$PAYLOAD")

if [[ "$HTTP_CODE" == "200" ]]; then
  echo "[$(date -Iseconds)] Delivered to Telegram (chat $CHAT_ID)"
else
  echo "[$(date -Iseconds)] Telegram delivery failed (HTTP $HTTP_CODE)" >&2
  exit 1
fi
