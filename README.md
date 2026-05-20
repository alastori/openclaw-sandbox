# OpenClaw Sandbox

Run [OpenClaw](https://github.com/openclaw/openclaw) locally in a sandboxed Docker container on macOS Apple Silicon, powered by local models via [Ollama](https://ollama.com).

Note: `CLAUDE.md` in the project root is a symlink to `AGENTS.md`.

## Table of Contents

- [Quick Start](#quick-start)
- [Prerequisites](#prerequisites)
- [Architecture](#architecture)
- [Common Commands](#common-commands)
- [Configuration](#configuration)
  - [Config Variants](#config-variants)
  - [Enforced Defaults](#enforced-defaults)
  - [Workspace Templates](#workspace-templates)
  - [Extensions](#extensions)
  - [Docker Build Args](#docker-build-args)
- [1Password Service Account Flow](#1password-service-account-flow)
  - [Parallel Instances](#parallel-instances)
  - [Fresh Clone Recovery](#fresh-clone-recovery)
  - [Periodic Model Audit](#periodic-model-audit)
- [Integrations](#integrations)
  - [Connect a Telegram bot](#connect-a-telegram-bot)
  - [Enable web access](#enable-web-access)
  - [Add a ChatGPT fallback](#add-a-chatgpt-fallback)
  - [Change the model](#change-the-model)
  - [Ollama Concurrency](#ollama-concurrency)
- [Recommended Models](#recommended-models)
- [Security](#security)
- [Maintenance](#maintenance)
- [Troubleshooting](#troubleshooting)

**Two setup paths:**
- **Quick Start** (local only) -- Uses `templates/openclaw.json.minimal` with local Ollama models. No API keys needed.
- **Full setup** (hosted models + Telegram) -- Uses 1Password to render secrets into `templates/openclaw.json.template`. See [1Password Service Account Flow](#1password-service-account-flow).

## Quick Start

```bash
# 1. Start Ollama and pull a model
brew services start ollama
ollama pull qwen3.6:35b-a3b-q8_0  # or see Recommended Models below

# 2. Clone and set up
git clone https://github.com/alastori/openclaw-sandbox.git
cd openclaw-sandbox

# 3. Run setup
./setup.sh
```

The setup script verifies prerequisites, tests networking, builds the Docker image, initializes config, and starts the gateway. Once running, open the web UI:

```
./oc dashboard    # prints the URL with auth token
```

Or go directly to `http://127.0.0.1:$OPENCLAW_PORT/` and paste your gateway token from `config/openclaw.json` (`18789` by default).

## Prerequisites

- macOS with Apple Silicon (M1/M2/M3/M4)
- [Docker](https://docs.docker.com/desktop/mac/install/) or [Colima](https://github.com/abiosoft/colima)
- [Ollama](https://ollama.com) (`brew install ollama`)
- 32 GB+ unified memory (64 GB+ recommended for larger models)

## Architecture

```
macOS Host
├── Ollama (native, Metal GPU acceleration)
│   ├── OpenAI-compatible API on :11434
│   └── qwen3.6:35b-a3b-q8_0 (or any model)
│
└── Docker Container (sandboxed)
    └── OpenClaw Gateway
        ├── Reaches Ollama via host.docker.internal
        ├── Config:    ./config/  -> /home/node/.openclaw
        └── Workspace: ./workspace/ -> /home/node/workspace
```

The LLM runs natively on the host for full Metal GPU acceleration. The Docker container runs the OpenClaw gateway with Node.js 22, Python 3, cron, and Gemini CLI available for agent tasks, capped at 2 GB RAM and 2 CPU cores.

## Common Commands

The `./oc` wrapper script is a checkout-scoped shortcut for `docker compose exec openclaw-gateway openclaw`:

```bash
./oc health                       # Health check
./oc models list                  # List configured models
./oc skills list                  # List available skills
./oc sessions                     # List active sessions
```

Docker Compose commands:

```bash
docker compose --env-file .runtime/openclaw.env up -d   # Start (with API keys)
docker compose down               # Stop
docker compose restart            # Restart after config changes
docker compose logs -f            # Watch logs
```

**Important:** If secrets were rendered via `scripts/render-secrets-up.sh`, always pass `--env-file .runtime/openclaw.env` to `docker compose up`. Without it, the container starts with empty API keys and all hosted providers will fail. The `./oc` wrapper loads `.env.instance.local` automatically but does **not** load `.runtime/openclaw.env`.

If this checkout uses `.env.instance.local`, load it before raw `docker compose` commands:

```bash
set -a
source .env.instance.local
set +a
docker compose ps
```

## Configuration

The setup script creates `config/openclaw.json` from the included example template. You can also copy it manually:

```bash
cp templates/openclaw.json.minimal config/openclaw.json
```

After any config change, restart the gateway with `docker compose restart`.

### Config Variants

The repo has two tracked configuration entry points:

- `templates/openclaw.json.minimal` -- minimal local-only example for manual setup
- `templates/openclaw.json.template` -- richer runtime template rendered by `./scripts/render-secrets-up.sh`

Use the rendered template as the reference for the current day-to-day setup. It includes the generic secret-rendering flow, Telegram token placeholders, and model auth strategy.

### Enforced Defaults

The `defaults/` directory contains JSON overlays that are deep-merged into the rendered config at deploy time. User-explicit values always win; defaults only fill in missing keys.

- `defaults/security.json` -- elevated tools off, loop detection, rate limits, bash/debug commands disabled
- `defaults/logging.json` -- file logging path, API key redaction patterns
- `defaults/governance.json` -- context tokens, compaction mode
- `defaults/models.policy.json` -- pinned primary/fallback model choices
- `defaults/secrets-backend.json` -- pluggable credential backend definitions (1Password, Vault, AWS SM, Keychain, env)
- `defaults/prompt-guidelines.md` -- model-neutral prompt style guide for Claude, GPT, and Gemini

The model policy is defined in `defaults/models.policy.json` -- subscription models first (Gemini CLI OAuth, Codex OAuth), then API-billed fallbacks, local Ollama as last resort.

### Workspace Templates

The `workspace-templates/` directory contains seed files (`SOUL.md`, `USER.md`, `IDENTITY.md`, etc.) that are copied to `workspace/` on the first deploy. Users can customize them before running setup. They define the agent's personality, memory structure, and behavioral guidelines.

### Extensions

Extensions live in `extensions/`. Each has its own README with configuration and usage details.

- **notifications** -- Notification buffer + digest system with Telegram topic routing.
- **news-brief** -- RSS feeds summarized by Ollama, delivered via Telegram.
- **backup** -- Git auto-commit + push tracked changes.
- **doc-watch** -- Monitors external documentation URLs for changes.

To set up an extension:

```bash
cp extensions/<name>/config.example.json extensions/<name>/config.json
# Edit config.json with your settings
```

### Docker Build Args

The `Dockerfile` accepts build arguments to customize the image:

| Arg | Default | Description |
|-----|---------|-------------|
| `OPENCLAW_VERSION` | `latest` | Pin to a specific OpenClaw release |
| `INSTALL_GEMINI_CLI` | `true` | Set to `false` to skip Gemini CLI installation |

Example:

```bash
OPENCLAW_VERSION=2026.3.23-2 docker compose build
```

**Model auth strategy:** Gemini uses the bundled `google` plugin with `google-gemini-cli` OAuth (free tier); OpenAI prefers Codex OAuth (subscription) with API key as fallback; Anthropic uses API key only (subscription OAuth is banned for third-party tools since Jan 2026). After rebuilding, run the interactive OAuth flows:

```bash
docker compose exec -it openclaw-gateway openclaw models auth login --provider openai-codex
docker compose exec -it openclaw-gateway openclaw models auth login --provider google-gemini-cli
```

Pinned hosted defaults live in `defaults/models.policy.json`, and `bash ./scripts/render-secrets-up.sh` applies that policy to the rendered config before starting the container.

## 1Password Service Account Flow

Use this when you want non-interactive startup without the 1Password desktop approval prompts.

1. In 1Password, create a shared vault for OpenClaw secrets. The repo defaults now assume the vault is named `AI-Agents`.
2. Create an item named `OpenClaw Sandbox` with fields:
   - `anthropic_api_key`
   - `gemini_api_key`
   - `openai_api_key`
   - `gateway_token`
   - `telegram_bot_token`
3. Run the bootstrap script to create a read-only service account token and write `.env.secrets.local`:

```bash
bash ./scripts/bootstrap-secrets-local.sh
```

If your names differ from the defaults, override them:

```bash
OP_VAULT='My Vault' OP_ITEM='My Item' bash ./scripts/bootstrap-secrets-local.sh
```

4. Run:

```bash
bash ./scripts/render-secrets-up.sh
```

What this does:

- uses `op inject` to render `config/openclaw.json` from `templates/openclaw.json.template`
- resolves provider API keys into `.runtime/openclaw.env`
- backs up any existing `config/openclaw.json` to `config/openclaw.json.bak.YYYYMMDD-HHMMSS`
- starts the container with `docker compose --env-file .runtime/openclaw.env up -d`

Today the renderer is backed by 1Password service-account references (`op://...`), but the filenames are backend-neutral so the renderer can be replaced later without renaming the workflow.

Files involved:

**Bootstrap & secrets:**
- `.env.instance.local.example` -- example per-checkout port/project settings
- `.env.secrets.example` -- tracked secret-reference map
- `.env.secrets.local.example` -- example local bootstrap file
- `.env.secrets.local` -- untracked local bootstrap token
- `scripts/bootstrap-secrets-local.sh` -- creates the service account token and local bootstrap file

**Config overlays & policy:**
- `defaults/models.policy.json` -- pinned hosted-model policy for portable primary/fallback choices
- `defaults/security.json`, `logging.json`, `governance.json` -- enforced config overlays
- `scripts/apply-model-policy.py` -- applies the pinned model policy to the rendered config
- `scripts/apply-defaults.py` -- deep-merges defaults into the rendered config

**Deploy pipeline:**
- `scripts/init-workspace.sh` -- copies `workspace-templates/` into `workspace/` on first run
- `templates/openclaw.json.template` -- tracked config template with 1Password secret references
- `.runtime/openclaw.env` -- generated runtime env file, untracked
- `scripts/resolve-secrets.py` -- pluggable secret resolver, used by `render-secrets-up.sh` when `config/secrets-mapping.yaml` exists
- `templates/secrets-mapping.yaml.template` -- tracked secret mapping seed; copy to `config/secrets-mapping.yaml`

The bootstrap script writes shell-safe values into `.env.secrets.local`. This matters for names with spaces, such as `OP_ITEM=OpenClaw Sandbox`.
Use `bash ./scripts/...` to run the helper scripts unless you've explicitly marked them executable in your local checkout.
On macOS/Colima, don't deploy from `/tmp` or `/private/tmp`: Docker bind-mounts for the repo's `config/` directory can appear empty inside the container there. Use a clone under `/Users/...` instead.

### Parallel Instances

Run one checkout per user or persona. Each checkout should have:

- its own `config/` and `workspace/`
- a unique `COMPOSE_PROJECT_NAME`
- a unique `OPENCLAW_PORT`

Example:

```bash
cp .env.instance.local.example .env.instance.local
```

Then edit `.env.instance.local`:

```bash
COMPOSE_PROJECT_NAME=openclaw-wife
OPENCLAW_PORT=18790
```

- This repo does not support multiple independent users from a single checkout because `config/` and `workspace/` are shared within one repo directory.
- `./setup.sh` also respects `OPENCLAW_PORT` for checkouts that start from `templates/openclaw.json.minimal`, not just the secrets-rendered path.
- For routine per-instance operations, prefer `./oc ...` over raw `docker compose ...`; the wrapper loads `.env.instance.local` automatically.
- If two parallel instances share the same Telegram bot token, only one should poll Telegram at a time. For smoke tests or temporary side-by-side instances, disable Telegram in the secondary instance or give it a different bot token.

### Fresh Clone Recovery

```bash
git clone https://github.com/alastori/openclaw-sandbox.git
cd openclaw-sandbox
bash ./scripts/bootstrap-secrets-local.sh
bash ./scripts/render-secrets-up.sh
./oc health
```

If you already have a valid `.env.secrets.local` from another checkout, you can copy that file into the new clone instead of re-running the bootstrap step.

To force a truly fresh local state, remove the runtime `config/` contents and re-run `bash ./scripts/render-secrets-up.sh`. The first probe immediately after container start can fail with a transient gateway websocket close if the gateway restarts once during boot; rerun the probe after `./oc health` is clean.

### Periodic Model Audit

Use this when keys rotate, providers change, or you move the repo to another host:

```bash
bash ./scripts/check-models.sh
```

The script reads the rendered config plus `.runtime/openclaw.env`, probes the configured models directly against their providers, and reports `required` versus `optional` models. It also compares `models.policy.json` against the current provider catalogs and reports whether newer compatible hosted models are available.
Use `bash ./scripts/check-models.sh --adopt` to opt in to newer provider models. That only updates `models.policy.json` when the newer model is confirmed by both the provider catalog and the local OpenClaw catalog; rerun `bash ./scripts/render-secrets-up.sh` afterward to apply the new pins.
OAuth/profile-backed providers such as `github-copilot` currently report as `not_checked` because they are not driven by direct API-key requests from this script.

### Credential Management

The repo supports two credential resolution paths:

- **New (pluggable resolver):** `scripts/resolve-secrets.py` reads `config/secrets-mapping.yaml` and resolves references against the configured backend. `render-secrets-up.sh` calls it automatically when the mapping file exists.
- **Legacy (`op inject`):** If no mapping file is present, `render-secrets-up.sh` falls back to direct `op inject` against the template, as before.

Supported backends: **1Password**, **HashiCorp Vault**, **AWS Secrets Manager**, **macOS Keychain**, **environment variables**. Backend definitions live in `defaults/secrets-backend.json`.

To set up the pluggable resolver:

```bash
cp templates/secrets-mapping.yaml.template config/secrets-mapping.yaml
# Edit config/secrets-mapping.yaml: choose a backend and fill in secret references
python3 scripts/resolve-secrets.py --validate   # dry-run check
bash scripts/render-secrets-up.sh               # deploy as usual
```

Environment variable fallback is always available: any key listed in `.env.secrets.example` can be set directly in the shell, and the resolver will prefer it over the mapping file entry.

## Integrations

### Connect a Telegram bot

<details>
<summary>Step-by-step setup</summary>

1. Create a bot via [@BotFather](https://t.me/BotFather) on Telegram.
2. Enable the plugin and add the channel:

```bash
docker compose run --rm openclaw-gateway openclaw plugins enable telegram
docker compose run --rm openclaw-gateway openclaw channels add \
  --channel telegram --token YOUR_BOT_TOKEN --name YOUR_BOT_NAME
docker compose restart
```

3. Message your bot. It will reply with a pairing code. Approve it:

```bash
docker compose exec -T openclaw-gateway openclaw pairing approve telegram YOUR_CODE
```

If your shell runner does not preserve `cd` between commands, run the `cd` and approval in the same command:

```bash
cd /path/to/openclaw-sandbox && ./oc pairing approve telegram YOUR_CODE
```

A DM-only setup may still log a startup warning if `groupPolicy` is set to `"allowlist"` without any group allowlist entries. That is expected and harmless if you do not plan to use the bot in group chats.
Do not run two instances with the same Telegram bot token enabled unless you explicitly want them competing for updates.

</details>

### Telegram topics (recommended)

<details>
<summary>Organize conversations with topic threads</summary>

Instead of one flat DM, create a Telegram group with **Topics** enabled. Each topic gets its own OpenClaw session and context window -- better memory, no topic cross-contamination, and cleaner notifications.

**Setup:**

1. In Telegram, create a new Group. Add only yourself and your bot.
2. Go to Group Settings > Topics > Enable.
3. Create topics. Suggested defaults:

| Topic | Purpose |
|-------|---------|
| General | Main conversation with the agent |
| Ops | Nightly cron digests, routine reports |
| Alerts | Critical-only notifications |

4. Get the group chat ID and topic IDs. Send a message in each topic, then check:

```bash
./oc directory self telegram
```

Or use the Telegram Bot API:

```bash
curl -s "https://api.telegram.org/bot<TOKEN>/getUpdates" | python3 -m json.tool
```

Look for `message.chat.id` (group ID, negative number) and `message.message_thread_id` (topic ID).

5. **Disable privacy mode** so the bot sees all messages (not just @mentions):
   - In Telegram, message `@BotFather` → `/setprivacy` → select your bot → `Disable`
   - **Remove and re-add the bot** to the group (Telegram only applies the change on re-join)

6. Add the group ID to `.env.instance.local`:

```bash
TELEGRAM_GROUP_ID=<GROUP_CHAT_ID>
```

Then re-render: `bash scripts/render-secrets-up.sh`

The template sets `groupPolicy: "allowlist"` with an empty `groups`/`groupAllowFrom` so a fresh deploy will not respond in any group until one is explicitly added. `scripts/setup-telegram-topics.sh` (or manual edit) appends your group chat ID to `groupAllowFrom`. If you want the bot to respond without @mentions in an allowed group, set `requireMention: false` in that group's entry under `groups`.

7. Update `extensions/notifications/config.json` with topic IDs:

```json
{
  "telegram_chat_id": "<GROUP_CHAT_ID>",
  "topics": {
    "ops": <OPS_TOPIC_ID>,
    "alerts": <ALERTS_TOPIC_ID>
  },
  "tiers": {
    "critical": { "delivery": "immediate", "topic": "alerts" },
    "medium":   { "delivery": "digest", "topic": "ops" },
    "low":      { "delivery": "digest", "topic": "ops" }
  }
}
```

Critical notifications go to `Alerts`, routine digests go to `Ops`, and your main conversation stays in `General`.

**Why this matters:** Without topics, every cron output, news brief, and alert lands in the same chat as your conversations. With topics, you only check `Alerts` for urgent items and `Ops` when you feel like it.

</details>

### Enable web access

Web fetching (`web_fetch`) is enabled by default. There are currently two tracked variants:

- `templates/openclaw.json.minimal` disables native `web_search`
- `templates/openclaw.json.template` enables native `web_search`

The DuckDuckGo skill can still coexist with native web search and remains useful when you want explicit DDG-style results.

<details>
<summary>Manual config</summary>

```json
{
  "tools": {
    "web": {
      "search": { "enabled": false },
      "fetch": { "enabled": true, "maxChars": 30000 }
    }
  }
}
```

Restart the gateway and send `/reset` to the bot to pick up the new tools.

</details>

The DuckDuckGo search skill should be installed during setup. If it's missing:

<details>
<summary>Install DuckDuckGo skill</summary>

```bash
docker compose exec -T openclaw-gateway npx clawhub install ddg-web-search --no-input
docker compose exec -T openclaw-gateway mkdir -p /home/node/.openclaw/workspace/skills
docker compose exec -T openclaw-gateway cp -r /home/node/skills/ddg-web-search \
  /home/node/.openclaw/workspace/skills/
docker compose restart
```

Note: `/home/node/.openclaw/workspace/` inside the container maps to `./config/workspace/` on the host (not `./workspace/`), because `./config/` is mounted at `/home/node/.openclaw`.

</details>

### Add a ChatGPT fallback

<details>
<summary>Use your existing ChatGPT subscription via GitHub Copilot</summary>

```bash
docker compose run --rm openclaw-gateway openclaw plugins enable copilot-proxy
docker compose restart
docker compose exec -it openclaw-gateway openclaw models auth login-github-copilot
docker compose exec openclaw-gateway openclaw models fallbacks add github-copilot/gpt-4o
```

> **Note:** Failover triggers on auth, rate-limit, and timeout errors only.
> Connection errors (e.g. Ollama is stopped) do not trigger fallback.
> This is a [known upstream issue](https://github.com/openclaw/openclaw/issues/20931) with a fix pending.

</details>

### Change the model

Edit `config/openclaw.json`, update the model ID under `models.providers.ollama.models` and `agents.defaults.model.primary`, then restart.

> **Note:** If you use the 1Password/secrets flow (`scripts/render-secrets-up.sh`), edit `templates/openclaw.json.template` or `defaults/models.policy.json` instead, since `config/openclaw.json` is regenerated on each deploy and your manual changes will be overwritten.

> **Tip:** Also set `agents.defaults.contextTokens` to match your model's context window (minus ~15K headroom for system prompt and tool definitions). For example, a 65K context model should use `"contextTokens": 50000`.

### Ollama Concurrency

OpenClaw does not expose an Ollama provider concurrency setting in config. Concurrency is controlled by the Ollama server on the host:

```bash
OLLAMA_NUM_PARALLEL=1
```

For a single-user setup this default is usually fine. If you increase it, do it in the Ollama host service configuration, not in `openclaw.json`.

## Recommended Models

Tested on Apple Silicon with 64+ GB unified memory:

| Model | Approx. RAM (Q8) | Speed | Best For |
|-------|-------------------|-------|----------|
| `qwen3.6:35b-a3b-q8_0` | ~35 GB | ~40-70 tok/s | Agentic tool calling, general (MoE, 3B active) |
| `nemotron-3-super:120b-a12b-q4_K_M` | ~60 GB | ~15-25 tok/s | Complex agentic reasoning (120B hybrid Mamba-Transformer MoE, 12B active) |
| `glm4.7:flash` | ~9 GB | ~80+ tok/s | Fast agent loops |
| `qwen3:32b` | ~34 GB | ~15-25 tok/s | General purpose |
| `mistral-small3.1` | ~25 GB | ~25-40 tok/s | Multimodal, fast |

## Security

The Docker container enforces:

- **Non-root user** (`node`, uid 1000)
- **`no-new-privileges`** security option
- **Resource limits** -- 2 GB memory, 2 CPU cores
- **Volume isolation** -- `./workspace/` (agent working directory) and `./config/` (OpenClaw home) are mounted; `/tmp` is a size-limited tmpfs
- **No host filesystem access** -- no home directory, documents, or credentials
- **Localhost-only port binding** -- gateway accessible only from the host
- **Gateway auth rate limiting** -- `gateway.auth.rateLimit` defaults to `10` attempts per `60s`, with a `5m` lockout
- **Private state directories** -- `setup.sh` and `scripts/render-secrets-up.sh` force `config/` and `workspace/` to mode `700`
- **Elevated tools disabled by default** -- shell/write escalation is off unless you explicitly opt back in with a narrow allowlist
- **ClawSec skill suite** -- baked into the Docker image; provides drift detection for SOUL.md/IDENTITY.md, skill integrity checks (SHA256), and CVE advisory feed
- **Prompt injection defense** -- behavioral rules in `workspace-templates/SOUL.md` instruct the agent to treat all external content as untrusted, flag injection patterns, and never execute instructions from fetched content
- **Outbound PII redaction** -- behavioral rules require the agent to scan outbound messages for API keys, phone numbers, emails, SSNs, and credit cards before sending
- **Log redaction patterns** -- `defaults/logging.json` includes regex patterns for Anthropic, OpenAI, Google, GitHub, Slack tokens, SSNs, and credit card numbers

### Nightly Crons

Default crons are created by `bash scripts/setup-crons.sh --telegram-chat-id <ID>`. View the schedule with `./oc cron list`. Manage with `./oc cron run <id>`, `./oc cron disable <id>`.

## Maintenance

Routine checks to keep the gateway, crons, and model chain healthy.

### Quick health

```bash
./oc health                      # gateway reachability + basic probe
./oc cron list                   # every cron, last status, next run
./oc doctor                      # diagnostic report (no changes)
```

### Apply recommended repairs

```bash
./oc doctor --fix                # archive orphan transcripts, normalize legacy cron storage, etc.
./oc doctor --fix --deep         # same, plus scan for extra gateway installs on the host
```

`--fix` is the non-destructive repair path: archived files are renamed to `*.deleted.<timestamp>`, not removed. Use `--force` only to overwrite custom service config.

### Periodic audits

```bash
bash ./scripts/check-models.sh               # probe the pinned model chain; see Periodic Model Audit
./oc security audit --deep                   # security review; known-acceptable findings live in workspace/learnings.md
cat config/logs/digest.jsonl | tail -20      # confirm recent Telegram digest deliveries
```

### When to run what

| Trigger | Run |
|---|---|
| Every few days | `./oc doctor` |
| After provider / key rotation | `bash ./scripts/check-models.sh` |
| After upgrading OpenClaw | `./oc doctor --fix`, then `./oc health` |
| Cron silently reports `ok` but doesn't do the work | Check `config/cron/runs/<jobId>.jsonl` |
| No morning digest arrived | `tail config/logs/digest.jsonl`; then `./oc cron run <digest-id>` to retry |

## Troubleshooting

<details>
<summary>Agent says it can't access the internet</summary>

Enable `tools.web.fetch` and `tools.web.search` in `config/openclaw.json` (see [Enable web access](#enable-web-access)), restart, and send `/reset` to the bot.
</details>

<details>
<summary>Context overflow errors</summary>

The model's context window may be too small. Create a Modelfile to increase it:

```
FROM qwen3.6:35b-a3b-q8_0
PARAMETER num_ctx 65536
```

```bash
ollama create qwen3.6-64k -f Modelfile
```

Update `config/openclaw.json` to use the new model name and restart.
</details>

<details>
<summary>Agent not responding</summary>

```bash
./oc health                                     # Check health
docker compose logs --tail 20                   # Check for errors
docker compose restart                          # Restart
```
</details>

<details>
<summary>Model context or concurrency confusion</summary>

Two common mistakes:

- Don't set `contextTokens` to the model's full advertised context. Leave headroom for the system prompt, tools, and workspace context; `50000` is the practical setting for a 65K model here.
- Don't look for `models.providers.ollama.maxConcurrent` in OpenClaw config. Parallelism is an Ollama host setting via `OLLAMA_NUM_PARALLEL`.
</details>

<details>
<summary>Colima networking issues</summary>

If the container can't reach Ollama, verify `host.docker.internal` resolves:

```bash
docker run --rm --add-host=host.docker.internal:host-gateway alpine \
  sh -c "wget -qO- http://host.docker.internal:11434/v1/models"
```
</details>

<details>
<summary>Built-in cron jobs not executing</summary>

Verify your OpenClaw version supports built-in cron with `./oc cron status`.
</details>

<details>
<summary>Anthropic rate-limit diagnostic</summary>

If a live turn reports an Anthropic "rate limit" failover unexpectedly, check Anthropic billing/credits too. In practice, insufficient Anthropic credits can surface through OpenClaw as a generic rate-limit-style failover message even when the provider is returning a different error class.
</details>

## License

[MIT](LICENSE)
