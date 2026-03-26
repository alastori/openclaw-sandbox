# Doc Watch

Monitors external documentation URLs for content changes. Fetches each URL, hashes the response body, compares against stored hashes, and reports changes to the notification buffer.

Useful for tracking prompt engineering guides, model migration docs, and API references that may update without announcement.

## How It Works

1. Fetches each monitored URL (configured in `WATCH_URLS` inside `doc-watch.py`).
2. Computes a SHA-256 hash of the response body.
3. Compares against previously stored hashes in `hashes.json`.
4. If a hash changed, buffers a medium-tier notification via `extensions/notifications/buffer.py`.
5. Updates `hashes.json` with the new hashes.

## Usage

```bash
# Normal run: check URLs, report changes, update hashes
python3 extensions/doc-watch/doc-watch.py

# Preview without updating hashes or buffering notifications
python3 extensions/doc-watch/doc-watch.py --dry-run

# Initialize hashes for the first time (no change reports)
python3 extensions/doc-watch/doc-watch.py --init
```

## Configuration

Monitored URLs are defined in the `WATCH_URLS` dictionary inside `doc-watch.py`. Edit that dict to add or remove URLs.

The hash state file (`hashes.json`) is stored in the extension directory on the host, or under `/home/node/.openclaw/doc-watch/` when running inside the Docker container (since `extensions/` is mounted read-only).

## Watched URLs (default)

| Label | URL |
|-------|-----|
| `anthropic-prompting` | Claude prompting best practices |
| `anthropic-whats-new` | Claude 4.6 what's new |
| `anthropic-migration` | Claude migration guide |
| `openai-prompt-guidance` | OpenAI prompt guidance |
| `openai-gpt5-cookbook` | GPT-5 prompting guide |
| `openai-codex-cookbook` | Codex prompting guide |
| `gemini-strategies` | Gemini prompting strategies |
| `gemini-3-guide` | Gemini 3 prompting guide |

## Troubleshooting

- **"fetch error" for a URL** -- The URL may be down, rate-limited, or returning a non-HTML response. Check it manually in a browser.
- **Frequent false-positive changes** -- Some pages include dynamic content (timestamps, ads). If a URL triggers on every run, it may not be a good candidate for hash-based watching.
- **"buffer.py exited with code 1"** -- The notifications extension is misconfigured. Check `extensions/notifications/config.json`.
- **hashes.json corrupted** -- Delete it and rerun with `--init` to rebuild from scratch.
