# OpenClaw Sandbox

Run [OpenClaw](https://github.com/openclaw/openclaw) locally in a sandboxed Docker container on macOS Apple Silicon, powered by local models via [Ollama](https://ollama.com).

## Quick Start

```bash
# 1. Start Ollama and pull a model
brew services start ollama
ollama pull qwen3-coder:30b-a3b-q8_0  # or see Recommended Models below

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
│   └── qwen3-coder:30b-a3b-q8_0 (or any model)
│
└── Docker Container (sandboxed)
    └── OpenClaw Gateway
        ├── Reaches Ollama via host.docker.internal
        ├── Config:    ./config/  -> /home/node/.openclaw
        └── Workspace: ./workspace/ -> /home/node/workspace
```

The LLM runs natively on the host for full Metal GPU acceleration. The Docker container runs the OpenClaw gateway with Node.js 22 and Python 3 available for agent tasks, capped at 2 GB RAM and 2 CPU cores.

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
docker compose up -d              # Start
docker compose down               # Stop
docker compose restart            # Restart after config changes
docker compose logs -f            # Watch logs
```

If this checkout uses `.env.instance.local`, load it before raw `docker compose` commands:

```bash
set -a
source .env.instance.local
set +a
docker compose ps
```

For future headless-server deployments: this repo already sets `restart: unless-stopped` in [docker-compose.yml](docker-compose.yml), so the container is meant to come back automatically when the Docker engine comes back. On a Linux server, the missing persistence layer is usually Docker itself at boot, managed by `systemd` (`docker.service` / `containerd.service`), not a separate systemd unit for OpenClaw. If you later deploy this on a headless box, the practical checklist is: enable Docker at boot, keep using `docker compose up -d`, preserve `config/`, `workspace/`, and `.env.secrets.local`, and only expose the port beyond loopback deliberately behind your preferred network boundary.

## Configuration

The setup script creates `config/openclaw.json` from the included example template. You can also copy it manually:

```bash
cp config/openclaw.json.example config/openclaw.json
```

After any config change, restart the gateway with `docker compose restart`.

### Config Variants

The repo has two tracked configuration entry points:

- `config/openclaw.json.example` — minimal local-only example for manual setup
- `templates/openclaw.json.template` — richer runtime template rendered by `./scripts/render-secrets-up.sh`

Use the rendered template as the reference for the current day-to-day setup. It includes the generic secret-rendering flow, Telegram token placeholders, and GitHub Copilot fallback wiring.
The current portable default policy is hosted-first: `anthropic/claude-sonnet-4-6` as primary, `openai/gpt-5.4` as automatic fallback, with local Ollama models kept as optional manual choices.
Pinned hosted defaults live in `models.policy.json`, and `bash ./scripts/render-secrets-up.sh` applies that policy to the rendered config before starting the container.

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
The renderer also backs up the previous `config/openclaw.json` and renders via temp directories so `op inject` does not prompt on overwrite.

Files involved:

- `.env.instance.local.example` — example per-checkout port/project settings
- `.env.secrets.example` — tracked secret-reference map
- `.env.secrets.local.example` — example local bootstrap file
- `.env.secrets.local` — untracked local bootstrap token
- `scripts/bootstrap-secrets-local.sh` — creates the service account token and local bootstrap file
- `models.policy.json` — pinned hosted-model policy for portable primary/fallback choices
- `scripts/apply-model-policy.py` — applies the pinned model policy to the rendered config
- `templates/openclaw.json.template` — tracked config template with 1Password secret references
- `.runtime/openclaw.env` — generated runtime env file, untracked

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

This repo does not support multiple independent users from a single checkout because `config/` and `workspace/` are shared within one repo directory.
`./setup.sh` now also respects `OPENCLAW_PORT` for checkouts that start from `config/openclaw.json.example`, not just the secrets-rendered path.
Validated on 2026-03-11 with a second checkout on port `18790`: the first turn in a brand-new container used the default provider `anthropic/claude-sonnet-4-6`.
For routine per-instance operations, prefer `./oc ...` over raw `docker compose ...`; the wrapper loads `.env.instance.local` automatically.
If two parallel instances share the same Telegram bot token, only one should poll Telegram at a time. For smoke tests or temporary side-by-side instances, disable Telegram in the secondary instance or give it a different bot token.

### Fresh Clone Recovery

Validated on 2026-03-11 from a clean clone under `/Users/...`.

```bash
git clone https://github.com/alastori/openclaw-sandbox.git ~/GitHub/alastori/openclaw-sandbox-fresh
cd ~/GitHub/alastori/openclaw-sandbox-fresh
bash ./scripts/bootstrap-secrets-local.sh
bash ./scripts/render-secrets-up.sh
./oc health
```

If you already have a valid `.env.secrets.local` from another checkout, you can copy that file into the new clone instead of re-running the bootstrap step.

Validated on 2026-03-11 from the main checkout after a config reset:
- soft-deleting the runtime `config/` contents to `~/Desktop/_TRASH/...` and re-running `bash ./scripts/render-secrets-up.sh` is a safe way to force a truly fresh local state
- the first probe immediately after container start can fail with a transient gateway websocket close if the gateway restarts once during boot; rerun the probe after `./oc health` is clean
- after that rebuild, the first successful live turn in the main checkout again used the default provider `anthropic/claude-sonnet-4-6`

### Periodic Model Audit

Use this when keys rotate, providers change, or you move the repo to another host:

```bash
bash ./scripts/check-models.sh
```

The script reads the rendered config plus `.runtime/openclaw.env`, probes the configured models directly against their providers, and reports `required` versus `optional` models. It also compares `models.policy.json` against the current provider catalogs and reports whether newer compatible hosted models are available.
Use `bash ./scripts/check-models.sh --adopt` to opt in to newer provider models. That only updates `models.policy.json` when the newer model is confirmed by both the provider catalog and the local OpenClaw catalog; rerun `bash ./scripts/render-secrets-up.sh` afterward to apply the new pins.
OAuth/profile-backed providers such as `github-copilot` currently report as `not_checked` because they are not driven by direct API-key requests from this script.
If a live turn reports an Anthropic "rate limit" failover unexpectedly, check Anthropic billing/credits too. In practice, insufficient Anthropic credits can surface through OpenClaw as a generic rate-limit-style failover message even when the provider is returning a different error class.

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

If your shell runner does not preserve `cd` between commands, use the absolute wrapper path instead:

```bash
~/GitHub/alastori/openclaw-sandbox/oc pairing approve telegram YOUR_CODE
```

or run the `cd` and approval in the same command:

```bash
cd ~/GitHub/alastori/openclaw-sandbox && docker compose exec -T openclaw-gateway openclaw pairing approve telegram YOUR_CODE
```

A DM-only setup may still log a startup warning if `groupPolicy` is set to `"allowlist"` without any group allowlist entries. That is expected and harmless if you do not plan to use the bot in group chats.
Do not run two instances with the same Telegram bot token enabled unless you explicitly want them competing for updates.

</details>

### Enable web access

Web fetching (`web_fetch`) is enabled by default. There are currently two tracked variants:

- `config/openclaw.json.example` disables native `web_search`
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

> **Tip:** Also set `agents.defaults.contextTokens` to match your model's context window (minus ~15K headroom for system prompt and tool definitions). For example, a 65K context model should use `"contextTokens": 50000`.

### Ollama Concurrency

OpenClaw does not expose an Ollama provider concurrency setting in config. Concurrency is controlled by the Ollama server on the host:

```bash
OLLAMA_NUM_PARALLEL=1
```

For a single-user setup this default is usually fine. If you increase it, do it in the Ollama host service configuration, not in `openclaw.json`.

## Recommended Models

Tested on Mac Studio with 96 GB unified memory:

| Model | Approx. RAM (Q8) | Speed | Best For |
|-------|-------------------|-------|----------|
| `qwen3-coder:30b-a3b-q8_0` | ~32 GB | ~40-70 tok/s | Agentic tool calling, coding |
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

Validated on 2026-03-11: `openclaw security audit --deep` returned `0 critical`, `0 warn`, and only one expected info finding for Telegram DM-only group handling.

## Troubleshooting

<details>
<summary>Agent says it can't access the internet</summary>

Enable `tools.web.fetch` and `tools.web.search` in `config/openclaw.json` (see [Enable web access](#enable-web-access)), restart, and send `/reset` to the bot.
</details>

<details>
<summary>Context overflow errors</summary>

The model's context window may be too small. Create a Modelfile to increase it:

```
FROM qwen3-coder:30b-a3b-q8_0
PARAMETER num_ctx 65536
```

```bash
ollama create qwen3-coder-64k -f Modelfile
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

## License

[MIT](LICENSE)
