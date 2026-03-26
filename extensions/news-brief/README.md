# News Brief

Daily news brief pipeline: fetches RSS feeds in parallel, synthesizes a summary using a local Ollama model, validates the output, and delivers it to Telegram.

No external API keys required beyond the Telegram bot token. Runs entirely on local Ollama.

## How It Works

1. Fetches configured RSS/Atom feeds (parallel, 8 workers).
2. Groups headlines by section (e.g., US, World, Science, Fun).
3. Sends raw feed data to Ollama with a system prompt that enforces concise, factual style.
4. Validates the output (section coverage, minimum length, no tool-use JSON leaks).
5. Delivers the brief to Telegram. On failure, sends an error alert.

## Configuration

```bash
cp extensions/news-brief/config.example.json extensions/news-brief/config.json
```

Edit `config.json`:

- Set `telegram_chat_id` to your Telegram chat or group ID.
- Optionally customize `ollama_model`, `ollama_url`, `max_items_per_feed`, and `sections`.

## Usage

Run manually:

```bash
python3 extensions/news-brief/news-brief.py
```

Run via cron wrapper (for launchd or cronctl):

```bash
bash extensions/news-brief/cron-news-brief.sh
```

## Config Reference

| Key | Type | Default | Description |
|-----|------|---------|-------------|
| `telegram_chat_id` | string | (required) | Telegram chat or group ID |
| `ollama_url` | string | `http://localhost:11434/api/generate` | Ollama API endpoint |
| `ollama_model` | string | `qwen3-coder:30b-a3b-q8_0` | Model for synthesis |
| `max_items_per_feed` | int | `8` | Max items fetched per RSS feed |
| `sections` | array | (see example) | Section definitions with name and feeds |
| `sections[].name` | string | -- | Section name (e.g., "United States") |
| `sections[].feeds` | array | -- | RSS feeds: `{ "label": "...", "url": "..." }` |

## Troubleshooting

- **"telegram_chat_id is empty"** -- Copy `config.example.json` to `config.json` and fill in the chat ID.
- **"Ollama not reachable"** -- Start Ollama on the host (`brew services start ollama`).
- **"Model warmup failed"** -- Pull the model first: `ollama pull <model>`.
- **"Too few feed items"** -- RSS feeds may be down or returning empty results. Check feed URLs manually.
- **"Validation failed: only N sections found"** -- The model output missed expected section headers. May happen with smaller models; try a larger one.
- **Logs** are written to `logs/news-brief-YYYY-MM-DD.txt` in the repo root.
