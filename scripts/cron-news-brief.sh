#!/usr/bin/env bash
# Daily news brief: RSS feeds → Ollama → Telegram.
# Thin wrapper for news-brief.py — this is what cronctl/launchd calls.
set -euo pipefail
exec python3 "$(dirname "$0")/news-brief.py" "$@"
