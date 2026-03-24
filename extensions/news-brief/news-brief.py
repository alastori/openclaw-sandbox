#!/usr/bin/env python3
"""Daily news brief: RSS feeds -> Ollama synthesis -> Telegram delivery.

No external API keys required. Runs entirely on local Ollama.
Telegram bot token is read from .runtime/openclaw.env or TELEGRAM_BOT_TOKEN env var.
Configuration is loaded from config.json (copy config.example.json to get started).
"""
import json
import os
import re
import sys
import xml.etree.ElementTree as ET
from concurrent.futures import ThreadPoolExecutor
from datetime import datetime
from pathlib import Path
from urllib.error import URLError
from urllib.request import Request, urlopen

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------

EXTENSION_DIR = Path(__file__).resolve().parent
ROOT_DIR = EXTENSION_DIR.parent.parent
LOG_DIR = ROOT_DIR / "logs"
LOG_FILE = LOG_DIR / f"news-brief-{datetime.now():%Y-%m-%d}.txt"

# ---------------------------------------------------------------------------
# Configuration
# ---------------------------------------------------------------------------

def load_config() -> dict:
    """Load config from config.json, falling back to config.example.json."""
    config_file = EXTENSION_DIR / "config.json"
    if not config_file.exists():
        config_file = EXTENSION_DIR / "config.example.json"
    if not config_file.exists():
        raise RuntimeError(f"No config found in {EXTENSION_DIR}")
    with open(config_file) as f:
        cfg = json.load(f)
    if not cfg.get("telegram_chat_id"):
        raise RuntimeError(
            "telegram_chat_id is empty. Copy config.example.json to config.json "
            "and fill in your Telegram chat ID."
        )
    return cfg


CONFIG = load_config()

OLLAMA_URL = CONFIG.get("ollama_url", "http://localhost:11434/api/generate")
OLLAMA_MODEL = CONFIG.get("ollama_model", "qwen3-coder:30b-a3b-q8_0")
TELEGRAM_CHAT_ID = CONFIG["telegram_chat_id"]
MAX_ITEMS_PER_FEED = CONFIG.get("max_items_per_feed", 8)
SECTIONS = CONFIG.get("sections", [])


def build_system_prompt() -> str:
    """Generate the system prompt from configured sections."""
    section_names = ", ".join(s["name"].upper() for s in SECTIONS)
    return f"""\
You are a concise news brief writer. Given raw RSS headlines and descriptions \
grouped by section, write a daily news brief for Telegram delivery.

Rules:
- Sections in order: {section_names}
- Each section: 2-4 bullet points, one sentence each. High-signal only.
- FUN section (if present): exactly one light/interesting item.
- If a section has no significant news, write "Quiet today." for that section.
- End with "Sources:" and 3-5 specific article URLs copied from the [brackets] \
in the feed data. Prefer NPR, BBC, PBS links. Never use news.google.com redirect \
URLs. If no direct article link exists, omit that source.
- Factual tone, no sensationalism, no clickbait, no filler.
- Plain text only: no bold, no italic, no asterisks, no markdown formatting. \
Section headers in ALL CAPS on their own line.
- Keep total output under 3500 characters.

/no_think"""

# ---------------------------------------------------------------------------
# Logging
# ---------------------------------------------------------------------------

def log(msg: str) -> None:
    line = f"[{datetime.now().isoformat(timespec='seconds')}] {msg}"
    print(line, flush=True)
    try:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass


def log_err(msg: str) -> None:
    line = f"[{datetime.now().isoformat(timespec='seconds')}] {msg}"
    print(line, file=sys.stderr, flush=True)
    try:
        LOG_DIR.mkdir(parents=True, exist_ok=True)
        with open(LOG_FILE, "a") as f:
            f.write(line + "\n")
    except OSError:
        pass

# ---------------------------------------------------------------------------
# RSS fetching
# ---------------------------------------------------------------------------

def fetch_feed(label: str, url: str) -> list[dict]:
    """Fetch and parse an RSS/Atom feed. Returns list of {title, description, link}."""
    try:
        req = Request(url, headers={"User-Agent": "Mozilla/5.0 (news-brief/1.0)"})
        with urlopen(req, timeout=10) as resp:
            data = resp.read()
        root = ET.fromstring(data)
    except (URLError, ET.ParseError, OSError) as e:
        log_err(f"Feed failed [{label}]: {e}")
        return []

    items = []

    # RSS 2.0 format
    for item in root.findall(".//item"):
        title = item.findtext("title", "").strip()
        desc = item.findtext("description", "").strip()
        link = item.findtext("link", "").strip()
        if title:
            items.append({"title": title, "description": desc[:300], "link": link})

    # Atom format (fallback)
    if not items:
        ns = {"atom": "http://www.w3.org/2005/Atom"}
        for entry in root.findall(".//atom:entry", ns):
            title = (entry.findtext("atom:title", "", ns) or "").strip()
            summary = (entry.findtext("atom:summary", "", ns) or "").strip()
            link_el = entry.find("atom:link", ns)
            link = link_el.get("href", "") if link_el is not None else ""
            if title:
                items.append({"title": title, "description": summary[:300], "link": link})

    return items[:MAX_ITEMS_PER_FEED]


def fetch_all_sections() -> dict[str, list[dict]]:
    """Fetch all RSS feeds in parallel, grouped by section."""
    results: dict[str, list[dict]] = {}
    tasks = []

    with ThreadPoolExecutor(max_workers=8) as pool:
        for section in SECTIONS:
            for feed in section.get("feeds", []):
                future = pool.submit(fetch_feed, feed["label"], feed["url"])
                tasks.append((future, section["name"], feed["label"]))

        for future, section_name, label in tasks:
            try:
                items = future.result(timeout=15)
            except Exception as e:
                log_err(f"Feed timeout [{label}]: {e}")
                items = []
            results.setdefault(section_name, []).extend(items)

    # Log counts
    for section_name, items in results.items():
        log(f"  {section_name}: {len(items)} items")

    return results

# ---------------------------------------------------------------------------
# Ollama synthesis
# ---------------------------------------------------------------------------

def build_prompt(sections: dict[str, list[dict]]) -> str:
    """Build the user prompt from raw feed data."""
    parts = []
    for section in SECTIONS:
        name = section["name"]
        items = sections.get(name, [])
        parts.append(f"=== {name.upper()} ===")
        if not items:
            parts.append("(no feed data available)")
        else:
            for item in items:
                line = f"- {item['title']}"
                if item.get("description"):
                    desc = re.sub(r"<[^>]+>", "", item["description"]).strip()
                    if desc and desc != item["title"]:
                        line += f" — {desc}"
                if item.get("link"):
                    line += f" [{item['link']}]"
                parts.append(line)
        parts.append("")
    return "\n".join(parts)


def ollama_generate(system_prompt: str, user_prompt: str) -> str:
    """Call Ollama /api/generate and return the response text."""
    payload = json.dumps({
        "model": OLLAMA_MODEL,
        "prompt": f"{system_prompt}\n\n{user_prompt}",
        "stream": False,
        "keep_alive": "30m",
        "options": {
            "num_predict": 2000,
            "temperature": 0.3,
        },
    }).encode()

    req = Request(
        OLLAMA_URL,
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    with urlopen(req, timeout=180) as resp:
        result = json.loads(resp.read())

    text = result.get("response", "")

    # Strip <think>...</think> blocks from qwen3 models
    text = re.sub(r"<think>.*?</think>", "", text, flags=re.DOTALL).strip()

    input_tokens = result.get("prompt_eval_count", 0)
    output_tokens = result.get("eval_count", 0)
    log(f"Ollama: {input_tokens} input, {output_tokens} output tokens ({OLLAMA_MODEL})")

    return text

# ---------------------------------------------------------------------------
# Validation
# ---------------------------------------------------------------------------

def validate(text: str):
    """Validate the brief. Returns error message or None if valid."""
    if not text:
        return "empty output"
    if len(text) < 100:
        return f"too short ({len(text)} chars)"
    if re.search(r'"name"\s*:\s*"(web_search|web_fetch|exec|read|write)"', text):
        return "contains raw tool-use JSON"

    section_names = [s["name"].upper().split()[0] for s in SECTIONS]
    section_count = sum(
        1 for name in section_names
        if re.search(name, text, re.IGNORECASE)
    )
    if section_count < min(2, len(SECTIONS)):
        return f"only {section_count}/{len(SECTIONS)} sections found"

    return None

# ---------------------------------------------------------------------------
# Telegram delivery
# ---------------------------------------------------------------------------

def get_bot_token() -> str:
    """Get Telegram bot token from env var or openclaw env file."""
    token = os.environ.get("TELEGRAM_BOT_TOKEN")
    if token:
        return token

    env_file = ROOT_DIR / ".runtime" / "openclaw.env"
    if env_file.exists():
        for line in env_file.read_text().splitlines():
            if line.startswith("TELEGRAM_BOT_TOKEN="):
                return line.split("=", 1)[1].strip()

    raise RuntimeError("TELEGRAM_BOT_TOKEN not found")


def send_telegram(text: str, bot_token: str) -> int:
    """Send a message to Telegram. Returns HTTP status code."""
    if len(text) > 4000:
        text = text[:3997] + "..."

    payload = json.dumps({
        "chat_id": int(TELEGRAM_CHAT_ID),
        "text": text,
        "disable_web_page_preview": True,
    }).encode()

    req = Request(
        f"https://api.telegram.org/bot{bot_token}/sendMessage",
        data=payload,
        headers={"Content-Type": "application/json"},
        method="POST",
    )

    try:
        with urlopen(req, timeout=15) as resp:
            return resp.status
    except URLError as e:
        if hasattr(e, "code"):
            return e.code
        raise

# ---------------------------------------------------------------------------
# Main
# ---------------------------------------------------------------------------

def _alert(msg: str, bot_token: str) -> None:
    """Best-effort Telegram error notification."""
    try:
        send_telegram(f"[News Brief Failed] {msg}", bot_token)
    except Exception:
        pass


def main() -> int:
    log("Starting news brief (RSS -> Ollama)...")

    bot_token = get_bot_token()

    # Check Ollama is running
    ollama_host = OLLAMA_URL.rsplit("/api/", 1)[0]
    try:
        with urlopen(Request(f"{ollama_host}/api/tags"), timeout=5) as resp:
            resp.read()
    except Exception:
        msg = f"Ollama not reachable at {ollama_host}"
        log_err(msg)
        _alert(msg, bot_token)
        return 1

    # Warm up model
    log("Warming up Ollama model...")
    try:
        warmup = json.dumps({
            "model": OLLAMA_MODEL,
            "prompt": "",
            "keep_alive": "30m",
        }).encode()
        req = Request(OLLAMA_URL, data=warmup,
                      headers={"Content-Type": "application/json"}, method="POST")
        with urlopen(req, timeout=60) as resp:
            resp.read()
    except Exception as e:
        msg = f"Model warmup failed: {e}"
        log_err(msg)
        _alert(msg, bot_token)
        return 1

    # Fetch RSS feeds
    log("Fetching RSS feeds...")
    sections = fetch_all_sections()

    total_items = sum(len(v) for v in sections.values())
    if total_items < 5:
        msg = f"Too few feed items ({total_items}) — feeds may be down"
        log_err(msg)
        _alert(msg, bot_token)
        return 1

    # Synthesize with Ollama
    system_prompt = build_system_prompt()
    user_prompt = build_prompt(sections)
    log(f"Synthesizing brief ({len(user_prompt)} chars of feed data)...")

    try:
        brief = ollama_generate(system_prompt, user_prompt)
    except Exception as e:
        msg = f"Ollama generation failed: {e}"
        log_err(msg)
        _alert(msg, bot_token)
        return 1

    # Prepend date header
    brief = f"Daily News Brief — {datetime.now():%B %d, %Y}\n\n{brief}"

    # Log raw output
    try:
        with open(LOG_FILE, "a") as f:
            f.write("--- RAW OUTPUT ---\n")
            f.write(brief + "\n")
            f.write("--- END RAW OUTPUT ---\n")
    except OSError:
        pass

    # Validate
    error = validate(brief)
    if error:
        msg = f"Validation failed: {error}"
        log_err(msg)
        _alert(msg, bot_token)
        return 1

    log(f"Output validated ({len(brief)} chars)")

    # Deliver
    status = send_telegram(brief, bot_token)
    if status == 200:
        log(f"Delivered to Telegram (chat {TELEGRAM_CHAT_ID})")
        return 0
    else:
        msg = f"Telegram delivery failed (HTTP {status})"
        log_err(msg)
        return 1


if __name__ == "__main__":
    sys.exit(main())
