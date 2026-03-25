# OpenClaw Sandbox

Sandboxed Docker setup for running OpenClaw with local LLMs via Ollama on macOS Apple Silicon.

Note: `CLAUDE.md` in the project root is a symlink to this file.

## Project Structure

```
Dockerfile                          Container image (node:22 + openclaw + gemini-cli + clawsec + python3 + cron)
docker-compose.yml                  Orchestration with security constraints
setup.sh                            One-command setup script
oc                                  Host-side shortcut: ./oc <cmd> = docker compose exec ... openclaw <cmd>
.env.instance.local.example         Example per-checkout port/project config
.env.secrets.example                Secret reference map for the current backend

templates/
  openclaw.json.template            Runtime config template (op:// refs + ${TELEGRAM_BOT_NAME})
  openclaw.json.minimal             Minimal local-only config (no secrets, no Telegram)

defaults/                           Enforced config overlays (merged at deploy time)
  models.policy.json                Pinned hosted-model primary/fallback choices
  security.json                     Elevated tools off, loop detection, rate limits
  logging.json                      File logging, API key redaction patterns
  governance.json                   Context tokens, compaction mode

workspace-templates/                Tracked seed files copied to config/workspace/ on first deploy
  SOUL.md, USER.md, IDENTITY.md, AGENTS.md, BOOTSTRAP.md, HEARTBEAT.md, TOOLS.md

extensions/                         Optional add-ons (not loaded by default)
  news-brief/                       RSS → Ollama → Telegram daily brief
    config.example.json             Template: feeds, chat ID, model
    news-brief.py                   Main script
    cron-news-brief.sh              Thin wrapper for launchd/cronctl

scripts/
  render-secrets-up.sh              Pipeline: op inject → model policy → defaults → workspace init → deploy
  apply-defaults.py                 Deep-merge defaults/*.json into rendered config
  apply-model-policy.py             Apply pinned model policy
  init-workspace.sh                 Copy workspace-templates/ into config/workspace/ (first run only)
  bootstrap-secrets-local.sh        Create 1Password service account token
  check-models.sh                   Probe configured models and audit policy
  load-local-env.sh                 Source .env.instance.local and .env.secrets.local into the shell

config/                             gitignored — runtime state (sessions, credentials, live config)
workspace/                          gitignored — agent working directory
```

## Volume Mounts

| Host Path | Container Path | Purpose |
|-----------|---------------|---------|
| `./config/` | `/home/node/.openclaw` | OpenClaw home (config, credentials, sessions) |
| `./workspace/` | `/home/node/workspace` | Agent working directory |

## Key Details

- Ollama runs natively on the host (port 11434), not inside Docker
- Container reaches Ollama via `host.docker.internal` (requires `extra_hosts: host-gateway` for Colima)
- Container is limited to 2 GB memory and 2 CPU cores; the model runs on the host
- Config format is JSON at `config/openclaw.json`
- There are two tracked config entry points: `templates/openclaw.json.minimal` is the minimal local-only example; `templates/openclaw.json.template` is the richer runtime template rendered by `scripts/render-secrets-up.sh`
- Gateway port is bound to localhost only (`127.0.0.1:${OPENCLAW_PORT}`) via docker-compose, default `18789`
- `gateway.bind: lan` is set so the gateway listens on `0.0.0.0` inside the container (required for Docker port forwarding and the Control UI)
- Control UI is enabled at `http://127.0.0.1:${OPENCLAW_PORT}/` via `gateway.controlUi.enabled: true`
- `gateway.auth.rateLimit` is enforced via `defaults/security.json` (`maxAttempts: 10`, `windowMs: 60000`, `lockoutMs: 300000`) because the gateway binds on `lan` inside Docker
- `docker-compose.yml` already uses `restart: unless-stopped`; for a future headless Linux deployment, persistence should be managed by enabling the Docker engine at boot via `systemd`, not by creating a separate host service for OpenClaw
- `templates/openclaw.json.minimal` disables native `web_search`; the rendered runtime template currently enables OpenClaw web search and can still coexist with the DDG skill
- The portable runtime template is hosted-first: `google/gemini-2.5-flash` primary, `openai-codex/gpt-5.4` (subscription) → `openai/gpt-5.4` (API) → local Ollama fallback
- **Model auth strategy:** Gemini uses bundled `google` plugin with `google-gemini-cli` OAuth (free tier); OpenAI prefers Codex OAuth (subscription) with API key as fallback; Anthropic uses API key only (subscription OAuth is banned for third-party tools since Jan 2026)
- Hosted defaults are pinned in `defaults/models.policy.json`; `bash ./scripts/check-models.sh --adopt` updates that policy only after an explicit opt-in
- After rebuilding, run `./oc models auth login --provider openai-codex` (interactive TTY) to set up OpenAI Codex OAuth
- After rebuilding, run `./oc models auth login --provider google-gemini-cli` (interactive TTY) to set up Google Gemini OAuth
- If Anthropic appears to "rate limit" unexpectedly during live turns, also check billing/credits; OpenClaw can surface insufficient-credit failures as generic rate-limit-style failovers
- `agents.defaults.contextTokens` is set to 50000 to stay within the model's 65K context window (leaving ~15K headroom for system prompt and tool definitions)
- Ollama concurrency is controlled on the host with `OLLAMA_NUM_PARALLEL`; there is no OpenClaw config field like `models.providers.ollama.maxConcurrent`
- Telegram may warn at startup when `groupPolicy` is `"allowlist"` and no group allowlist is configured; this is expected for DM-only use and group messages will simply be dropped unless explicitly enabled later
- On macOS/Colima, don't run this repo from `/tmp` or `/private/tmp`; Docker can mount `config/` as effectively empty there. Use a checkout under `/Users/...`
- The default 1Password vault name is `AI-Agents`; override `OP_VAULT` if you use a different vault
- Parallel instances are supported via separate checkouts, each with its own `.env.instance.local`, `config/`, and `workspace/`
- `setup.sh` now rewrites the copied `templates/openclaw.json.minimal` to the checkout's `OPENCLAW_PORT`, so manual bootstrap works on non-default ports too
- The very first probe right after a rebuild can hit a transient `gateway closed (1006 abnormal closure)` if the gateway restarts once during boot; rerun after `./oc health` is clean before treating it as a real failure
- Prefer `./oc ...` over raw `docker compose ...` for per-instance operations because the wrapper loads `.env.instance.local` automatically
- For Telegram pairing approval, some shell runners do not preserve `cd` between commands; use `cd /path/to/openclaw-sandbox && ./oc ...` in a single shell invocation
- Parallel instances must not share the same Telegram bot token with polling enabled unless you deliberately want them competing for the same updates
- **Always use `docker compose --env-file .runtime/openclaw.env up -d`** (or `bash ./scripts/render-secrets-up.sh`) instead of bare `docker compose up -d`; the env file carries the API keys and without it the container starts with empty credentials
- `ollama/qwen2.5-coder:32b-instruct-q8_0` is the last-resort fallback (after `openai-codex` and `openai` API); reached via `host.docker.internal:11434` and works when all hosted providers are down
- OpenClaw's built-in cron scheduler is enabled and running as of 2026.3.23 (was broken in 2026.3.8–2026.3.11). The daily news brief lives in `extensions/news-brief/` and can be run via host-side cronctl or migrated to built-in OpenClaw cron
- **ClawSec** security skill suite is baked into the Docker image (drift detection, integrity checks, CVE advisory feed). Discovered via `skills.load.extraDirs: ["/home/node/skills"]`
- **Built-in nightly crons** (stored in `config/cron/jobs.json`, persisted via volume mount):
  - `nightly-update-check` — 2:00 AM ET, checks for OpenClaw updates, reports to Telegram
  - `nightly-security-audit` — 2:30 AM ET, runs `security audit --deep`, reports findings
  - `morning-log-review` — 7:00 AM ET, reviews overnight logs for errors, proposes fixes
  - All use `google/gemini-2.5-flash` with 180s timeout and isolated sessions

## Security Notes

- `config/openclaw.json` contains bot tokens and gateway auth tokens -- never commit it
- The `config/` directory also contains credentials, session data, and device identity files
- `scripts/render-secrets-up.sh` and `setup.sh` both force `config/` and `workspace/` to mode `700`; keep those directories private on the host
- `.gitignore` uses `config/*` to exclude everything under `config/`; all tracked config lives in `templates/` and `defaults/`
- Never force-add files from `config/`
- No PII or credentials in any tracked file
- Elevated tools are disabled by default in the tracked config sources. Re-enable them only if you have a narrow provider-specific allowlist; do not restore `controlui: ["*"]`
