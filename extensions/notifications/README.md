# Notifications

Buffered notification system with tier-based routing and Telegram digest delivery. Cron jobs and extensions write notifications to a buffer; a digest job collects them and delivers a combined message to Telegram, routed by topic.

## How It Works

1. **buffer.py** writes a JSON file to a tier directory (`critical/`, `medium/`, `low/`).
2. Critical-tier notifications trigger immediate delivery after buffering.
3. **digest.py** reads buffered entries, formats a combined digest, sends it to Telegram, and clears the buffer.
4. When Telegram topics are configured, each tier routes to its assigned topic (e.g., critical -> Alerts, routine -> Ops).

## Configuration

Copy the example config and fill in your values:

```bash
cp extensions/notifications/config.example.json extensions/notifications/config.json
```

Edit `config.json`:

```json
{
  "telegram_chat_id": "<YOUR_CHAT_ID>",
  "topics": {
    "ops": <OPS_TOPIC_ID>,
    "alerts": <ALERTS_TOPIC_ID>
  },
  "tiers": {
    "critical": { "delivery": "immediate", "topic": "alerts" },
    "medium":   { "delivery": "digest", "interval_minutes": 60, "topic": "ops" },
    "low":      { "delivery": "digest", "interval_minutes": 180, "topic": "ops" }
  },
  "buffer_dir": "/home/node/.openclaw/notifications"
}
```

## Usage

Buffer a notification:

```bash
python3 extensions/notifications/buffer.py \
  --tier low --title "Update Check" --body "OpenClaw is up to date." --source nightly-update
```

Deliver a digest:

```bash
python3 extensions/notifications/digest.py --all        # all tiers combined
python3 extensions/notifications/digest.py --tier critical
python3 extensions/notifications/digest.py --dry-run --all   # preview only
```

## Config Reference

| Key | Type | Description |
|-----|------|-------------|
| `telegram_chat_id` | string | Telegram chat or group ID (required) |
| `topics.ops` | int/null | Telegram topic ID for routine digests |
| `topics.alerts` | int/null | Telegram topic ID for critical notifications |
| `tiers.<name>.delivery` | string | `"immediate"` or `"digest"` |
| `tiers.<name>.interval_minutes` | int | Minimum interval between digest deliveries |
| `tiers.<name>.topic` | string | Which topic key to route to |
| `buffer_dir` | string | Path to the notification buffer directory |

## Troubleshooting

- **"telegram_chat_id is empty"** -- Copy `config.example.json` to `config.json` and fill in the chat ID.
- **Bot token not found** -- Set `TELEGRAM_BOT_TOKEN` env var, or ensure `.runtime/openclaw.env` or `config/openclaw.json` contains a valid token.
- **Digest says "No pending notifications"** -- Buffer directory is empty; nothing to deliver.
