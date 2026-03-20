#!/usr/bin/env bash
# Host-side workaround for the broken built-in cron executor.
# Runs the daily news brief via ./oc agent (dedicated news-brief agent)
# and delivers to Telegram with output validation.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

LOGDIR="$ROOT_DIR/logs"
mkdir -p "$LOGDIR"
LOGFILE="$LOGDIR/news-brief-$(date +%Y-%m-%d).txt"

log() { echo "[$(date -Iseconds)] $*" | tee -a "$LOGFILE"; }
log_err() { echo "[$(date -Iseconds)] $*" | tee -a "$LOGFILE" >&2; }

# Fail fast if Docker runtime or gateway container is not available
# (Colima availability is managed by the colima-keepalive cronctl job)
colima status &>/dev/null || { log_err "Colima not running — aborting"; exit 1; }
docker compose ps --status running --format '{{.Name}}' 2>/dev/null | grep -q gateway || {
  log_err "Gateway container not running — aborting"; exit 1
}

# Extract bot token from env file (can't source directly — unquoted spaces)
if [[ -f .runtime/openclaw.env ]]; then
  TELEGRAM_BOT_TOKEN=$(grep '^TELEGRAM_BOT_TOKEN=' .runtime/openclaw.env | cut -d= -f2-)
fi

: "${TELEGRAM_BOT_TOKEN:?missing TELEGRAM_BOT_TOKEN in .runtime/openclaw.env}"
CHAT_ID="6453473977"

# Send a message to Telegram (used for both delivery and error alerts)
send_telegram() {
  local text="$1"
  local payload
  payload=$(python3 -c "
import json, sys
text = sys.stdin.read().strip()
if len(text) > 4000:
    text = text[:3997] + '...'
print(json.dumps({
    'chat_id': int('$CHAT_ID'),
    'text': text,
    'disable_web_page_preview': True
}))
" <<< "$text")

  curl -sf -o /dev/null -w '%{http_code}' \
    -X POST "https://api.telegram.org/bot${TELEGRAM_BOT_TOKEN}/sendMessage" \
    -H 'Content-Type: application/json' \
    -d "$payload"
}

# Abort and notify on failure
abort() {
  local reason="$1"
  log_err "$reason"
  send_telegram "[News Brief Failed] $reason" >/dev/null 2>&1 || true
  exit 1
}

PROMPT='Prepare a short daily news brief for the user. Order sections exactly as follows: (1) United States, (2) Florida Northeast with emphasis on Jacksonville metro and St. Augustine, (3) Brazil, (4) World, (5) Science, (6) Fun. Keep it concise, useful, and easy to skim. Use web search when needed, prioritize high-signal developments from the last day, avoid sensationalism, and clearly say when a section is quiet. Include a few relevant links at the end, ideally 3 to 5 total, pointing to the most useful or authoritative sources from the briefing. For the Fun section, include one light and interesting item such as a curiosity, ephemeris, quirky fact, uplifting oddity, or very short human-interest story. Deliver the brief as a single cohesive message.'

log "Starting news brief..."

# Run the dedicated news-brief agent (Claude primary, GPT-5.4 fallback, no Ollama)
CONTENT=$(./oc agent --agent news-brief --message "$PROMPT" --timeout 300 2>/dev/null) || {
  abort "Agent command failed (non-zero exit)"
}

# Log raw output for debugging
echo "--- RAW OUTPUT ---" >> "$LOGFILE"
echo "$CONTENT" >> "$LOGFILE"
echo "--- END RAW OUTPUT ---" >> "$LOGFILE"

# Validate output: reject tool-use leaks, empty, or suspiciously short content
if [[ -z "$CONTENT" ]]; then
  abort "Agent returned empty content"
fi

if [[ ${#CONTENT} -lt 100 ]]; then
  abort "Agent output too short (${#CONTENT} chars) — likely incomplete"
fi

if echo "$CONTENT" | grep -qE '"name"\s*:\s*"(web_search|web_fetch|exec|read|write|edit)"'; then
  abort "Agent output contains raw tool-use JSON — tool execution loop did not complete"
fi

# Check for at least 2 expected section headers
SECTION_COUNT=0
for section in "UNITED STATES" "FLORIDA" "BRAZIL" "WORLD" "SCIENCE" "FUN"; do
  if echo "$CONTENT" | grep -qi "$section"; then
    SECTION_COUNT=$((SECTION_COUNT + 1))
  fi
done
if [[ $SECTION_COUNT -lt 2 ]]; then
  abort "Agent output missing expected sections ($SECTION_COUNT/6 found) — likely malformed"
fi

log "Output validated ($SECTION_COUNT/6 sections, ${#CONTENT} chars)"

# Send to Telegram
HTTP_CODE=$(send_telegram "$CONTENT")

if [[ "$HTTP_CODE" == "200" ]]; then
  log "Delivered to Telegram (chat $CHAT_ID)"
else
  abort "Telegram delivery failed (HTTP $HTTP_CODE)"
fi
