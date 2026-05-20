#!/usr/bin/env bash
# Set up Telegram group topics for organized notifications.
#
# Prerequisites (manual, one-time):
#   1. Create a Telegram group
#   2. Add your bot to the group as Admin (with "Manage Topics" permission)
#   3. Enable Topics in group settings
#   4. Send any message in the group so the bot can discover the chat ID
#
# Usage:
#   bash scripts/setup-telegram-topics.sh --allow-from <id[,id...]>
#   bash scripts/setup-telegram-topics.sh --chat-id -100123456789 --allow-from 1234567
#   TELEGRAM_ALLOW_FROM=1234567 bash scripts/setup-telegram-topics.sh   # via .env
#
# What this script does:
#   1. Reads the bot token from .runtime/openclaw.env or config/openclaw.json
#   2. Discovers the group chat ID from recent bot updates (or uses --chat-id)
#   3. Creates "Ops" and "Alerts" topics via the Telegram Bot API
#   4. Updates extensions/notifications/config.json with topic IDs
#   5. Adds the group chat ID to channels.telegram.groups, switches
#      groupPolicy to "allowlist", and writes --allow-from /
#      TELEGRAM_ALLOW_FROM into channels.telegram.groupAllowFrom. The
#      script refuses to enable group access without senders.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck source=load-local-env.sh
source "$ROOT_DIR/scripts/load-local-env.sh"

CHAT_ID=""
ALLOW_FROM=""
while [[ $# -gt 0 ]]; do
  case "$1" in
    --chat-id) CHAT_ID="$2"; shift 2 ;;
    --allow-from) ALLOW_FROM="$2"; shift 2 ;;
    *) echo "Unknown option: $1" >&2; exit 1 ;;
  esac
done

# Both flags are optional on the CLI; fall back to TELEGRAM_GROUP_ID /
# TELEGRAM_ALLOW_FROM from the environment (sourced by
# scripts/load-local-env.sh from .env.instance.local) so operators don't
# have to repeat them on every run.
if [[ -z "$CHAT_ID" && -n "${TELEGRAM_GROUP_ID:-}" ]]; then
  CHAT_ID="$TELEGRAM_GROUP_ID"
fi
if [[ -z "$ALLOW_FROM" && -n "${TELEGRAM_ALLOW_FROM:-}" ]]; then
  ALLOW_FROM="$TELEGRAM_ALLOW_FROM"
fi

# Normalize ALLOW_FROM to a space-free comma-separated list, then collapse
# stray separators (",,", trailing/leading commas). Persisting "123, 456"
# verbatim to .env.instance.local would break the next `source` (the
# shell would treat 456 as a command under set -e); and a value that is
# only separators (e.g. ",") must not survive the non-empty check below
# because the JSON patcher would later parse it to zero senders and
# silently land in the unsafe allowlist + empty groupAllowFrom state.
ALLOW_FROM="$(printf '%s' "$ALLOW_FROM" | tr -d '[:space:]' \
  | awk -F, '{
      out=""; sep="";
      for (i=1; i<=NF; i++) if ($i != "") { out = out sep $i; sep = "," }
      print out
    }')"

# Activating a group while channels.telegram.groupAllowFrom is empty
# leaves slash/native commands callable by any member of that group in
# OpenClaw's current Telegram command auth path (empty effective allow
# list is treated as allowed). Refuse to enable group access without
# explicit senders.
if [[ -z "$ALLOW_FROM" ]]; then
  cat >&2 <<'EOF'
error: refusing to enable group access with an empty groupAllowFrom.
       With groupPolicy: "allowlist" and no approved senders,
       slash/native commands would be exposed to every member of the
       configured group.
       Pass the operator's Telegram user ID(s) (comma-separated) via
       --allow-from <id[,id...]>, or set TELEGRAM_ALLOW_FROM in
       .env.instance.local before re-running.
EOF
  exit 1
fi

# --- Resolve bot token ---
get_bot_token() {
  # Try .runtime/openclaw.env
  if [[ -f "$ROOT_DIR/.runtime/openclaw.env" ]]; then
    local token
    token=$(grep '^TELEGRAM_BOT_TOKEN=' "$ROOT_DIR/.runtime/openclaw.env" | cut -d= -f2-)
    if [[ -n "$token" ]]; then echo "$token"; return; fi
  fi
  # Try config/openclaw.json
  if [[ -f "$ROOT_DIR/config/openclaw.json" ]]; then
    local token
    token=$(python3 -c "
import json
with open('$ROOT_DIR/config/openclaw.json') as f:
    c = json.load(f)
t = c.get('channels',{}).get('telegram',{}).get('botToken','')
if t and not t.startswith('op://'):
    print(t)
" 2>/dev/null)
    if [[ -n "$token" ]]; then echo "$token"; return; fi
  fi
  echo "error: could not find bot token" >&2
  return 1
}

BOT_TOKEN=$(get_bot_token)
API="https://api.telegram.org/bot${BOT_TOKEN}"

# --- Discover group chat ID ---
if [[ -z "$CHAT_ID" ]]; then
  echo "Looking for group chats in recent bot updates..."
  GROUPS=$(curl -sf "$API/getUpdates?limit=100" | python3 -c "
import json, sys
data = json.load(sys.stdin)
seen = {}
for r in data.get('result', []):
    msg = r.get('message') or r.get('my_chat_member', {}).get('chat')
    if not msg:
        continue
    chat = msg.get('chat', msg) if 'chat' in msg else msg
    if chat.get('type') in ('group', 'supergroup'):
        cid = str(chat['id'])
        title = chat.get('title', 'Unknown')
        if cid not in seen:
            seen[cid] = title
            print(f'{cid}\t{title}')
" 2>/dev/null)

  if [[ -z "$GROUPS" ]]; then
    echo ""
    echo "No group chats found. Make sure you:"
    echo "  1. Created a Telegram group and added the bot as Admin"
    echo "  2. Enabled Topics in the group settings"
    echo "  3. Sent a message in the group"
    echo ""
    echo "Then run this script again, or pass --chat-id manually."
    exit 1
  fi

  echo ""
  echo "Found groups:"
  echo "$GROUPS" | while IFS=$'\t' read -r id title; do
    echo "  $id  $title"
  done
  echo ""

  GROUP_COUNT=$(echo "$GROUPS" | wc -l | tr -d ' ')
  if [[ "$GROUP_COUNT" -eq 1 ]]; then
    CHAT_ID=$(echo "$GROUPS" | cut -f1)
    GROUP_TITLE=$(echo "$GROUPS" | cut -f2)
    echo "Using: $CHAT_ID ($GROUP_TITLE)"
  else
    echo "Multiple groups found. Please re-run with --chat-id <id>"
    exit 1
  fi
fi

echo ""
echo "Creating topics in chat $CHAT_ID..."

# --- Create topics ---
create_topic() {
  local name="$1"
  local color="${2:-7322096}"  # Default: blue-ish
  local result
  result=$(curl -sf "$API/createForumTopic" \
    -H "Content-Type: application/json" \
    -d "{\"chat_id\": $CHAT_ID, \"name\": \"$name\", \"icon_color\": $color}" 2>&1)

  local topic_id
  topic_id=$(echo "$result" | python3 -c "
import json, sys
data = json.load(sys.stdin)
if data.get('ok'):
    print(data['result']['message_thread_id'])
else:
    print('ERROR:' + data.get('description', 'unknown error'))
" 2>/dev/null)

  if [[ "$topic_id" == ERROR:* ]]; then
    echo "  Failed to create '$name': ${topic_id#ERROR:}" >&2
    return 1
  fi

  echo "  Created '$name' (topic_id: $topic_id)" >&2
  echo "$topic_id"
}

OPS_TOPIC=$(create_topic "Ops" 16766590)          # amber
ALERTS_TOPIC=$(create_topic "Alerts" 16749490)    # red
CODING_TOPIC=$(create_topic "Coding" 13338331)    # green
RESEARCH_TOPIC=$(create_topic "Research" 9367192)  # blue

if [[ -z "$OPS_TOPIC" || -z "$ALERTS_TOPIC" ]]; then
  echo ""
  echo "Topic creation failed. The bot needs Admin rights with 'Manage Topics' permission."
  exit 1
fi

# Coding and Research are optional — don't fail if they already exist
CODING_TOPIC="${CODING_TOPIC:-}"
RESEARCH_TOPIC="${RESEARCH_TOPIC:-}"

# --- Update notification config ---
echo ""
echo "Updating extensions/notifications/config.json..."

NOTIFY_CONFIG="$ROOT_DIR/extensions/notifications/config.json"
if [[ ! -f "$NOTIFY_CONFIG" ]]; then
  cp "$ROOT_DIR/extensions/notifications/config.example.json" "$NOTIFY_CONFIG"
fi

python3 -c "
import json
with open('$NOTIFY_CONFIG') as f:
    cfg = json.load(f)
cfg['telegram_chat_id'] = '$CHAT_ID'
cfg['topics'] = {'ops': $OPS_TOPIC, 'alerts': $ALERTS_TOPIC}
with open('$NOTIFY_CONFIG', 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
print('  Updated: chat_id=$CHAT_ID, ops=$OPS_TOPIC, alerts=$ALERTS_TOPIC')
"

# --- Update OpenClaw config groups (chat-id allowlist) ---
# Per upstream docs/channels/telegram.md: channels.telegram.groups is the
# group/chat allowlist (which chats the bot will respond in), while
# channels.telegram.groupAllowFrom is the sender allowlist (which user IDs
# are allowed to message). The chat ID belongs in `groups`, not
# `groupAllowFrom`.
echo ""
echo "Updating config/openclaw.json telegram.groups..."

OC_CONFIG="$ROOT_DIR/config/openclaw.json"
if [[ -f "$OC_CONFIG" ]]; then
  python3 -c "
import json
with open('$OC_CONFIG') as f:
    cfg = json.load(f)
tg = cfg.setdefault('channels', {}).setdefault('telegram', {})

changed = False

# Migrate legacy 'open'/'disabled' policy + any wildcard to the allowlist
# defaults from templates/openclaw.json.template. Without this migration the
# explicit chat ID added below is shadowed by the wildcard and 'open' senders.
if tg.get('groupPolicy') != 'allowlist':
    tg['groupPolicy'] = 'allowlist'
    changed = True
groups = tg.setdefault('groups', {})
if '*' in groups:
    del groups['*']
    changed = True

chat_id = '$CHAT_ID'
if chat_id not in groups:
    groups[chat_id] = {'requireMention': False}
    changed = True
    print(f'  Added {chat_id} to channels.telegram.groups')
else:
    print(f'  {chat_id} already in channels.telegram.groups')

# Sender allowlist: merge any pre-existing entries with the operator-supplied
# IDs from --allow-from / TELEGRAM_ALLOW_FROM so we never leave the bot in the
# unsafe 'allowlist + empty groupAllowFrom' state (which exposes slash/native
# commands per upstream Telegram command auth).
existing = tg.get('groupAllowFrom') or []
new_ids = [s.strip() for s in '$ALLOW_FROM'.split(',') if s.strip()]
merged = list(dict.fromkeys(list(existing) + new_ids))
if merged != list(existing):
    tg['groupAllowFrom'] = merged
    changed = True
    print(f'  Set channels.telegram.groupAllowFrom = {merged}')

if changed:
    with open('$OC_CONFIG', 'w') as f:
        json.dump(cfg, f, indent=2)
        f.write('\n')
    print('  channels.telegram.groupPolicy=allowlist, wildcard removed if present')
"
fi

# --- Persist TELEGRAM_GROUP_ID in .env.instance.local so re-renders preserve it ---
INSTANCE_ENV="$ROOT_DIR/.env.instance.local"
persist_kv() {
  local key="$1" value="$2"
  if grep -qE "^${key}=" "$INSTANCE_ENV"; then
    sed -i.bak "s|^${key}=.*|${key}=${value}|" "$INSTANCE_ENV"
    rm -f "$INSTANCE_ENV.bak"
    echo "  Updated ${key} in .env.instance.local"
  else
    printf '\n%s=%s\n' "$key" "$value" >> "$INSTANCE_ENV"
    echo "  Appended ${key} to .env.instance.local"
  fi
}

if [[ -f "$INSTANCE_ENV" ]]; then
  persist_kv "TELEGRAM_GROUP_ID" "$CHAT_ID"
  persist_kv "TELEGRAM_ALLOW_FROM" "$ALLOW_FROM"
else
  echo "  Note: .env.instance.local not found; set TELEGRAM_GROUP_ID=$CHAT_ID and TELEGRAM_ALLOW_FROM=$ALLOW_FROM there so re-renders preserve the group."
fi

echo ""
echo "Done! Topics are set up:"
echo ""
echo "  Notification routing:"
echo "    Ops:      topic_id=$OPS_TOPIC (routine digests)"
echo "    Alerts:   topic_id=$ALERTS_TOPIC (critical, immediate)"
echo ""
echo "  Conversation topics:"
echo "    General:  (default topic, already exists)"
[[ -n "$CODING_TOPIC" ]] && echo "    Coding:   topic_id=$CODING_TOPIC — use /model sonnet for coding tasks"
[[ -n "$RESEARCH_TOPIC" ]] && echo "    Research: topic_id=$RESEARCH_TOPIC — use /model gpt-5.4 for deep research"
echo ""
echo "Restart the gateway to pick up the group allowlist change:"
echo "  docker compose restart"
echo ""
echo "Tip: In each topic, send /model <alias> to set the preferred model:"
echo "  General:  /model gemini  (fast, everyday chat — subscription)"
echo "  Coding:   /model gpt-5.4 (strong for code — Codex subscription)"
echo "  Research: /model gpt-5.4 (strong reasoning — Codex subscription)"
