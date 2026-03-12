# OpenClaw Sandbox

Sandboxed Docker setup for running OpenClaw with local LLMs via Ollama on macOS Apple Silicon.

Note: `CLAUDE.md` in the project root is a symlink to this file.

## Project Structure

```
Dockerfile                      Container image (node:22-bookworm-slim + openclaw CLI + python3)
docker-compose.yml              Orchestration with security constraints
setup.sh                        One-command setup script
oc                              Host-side shortcut: ./oc <cmd> = docker compose exec ... openclaw <cmd>
.env.instance.local             Local per-checkout port/project config (gitignored)
.env.instance.local.example     Example per-checkout port/project config
config/openclaw.json.example    Template config (tracked, no secrets)
config/openclaw.json            Live config (gitignored, contains secrets)
.env.secrets.example            Secret reference map for the current backend
.env.secrets.local              Local bootstrap token/config (gitignored)
models.policy.json             Pinned hosted-model policy for portable defaults
templates/openclaw.json.template Runtime config template rendered into config/openclaw.json
scripts/render-secrets-up.sh    Render secrets + start the container
scripts/check-models.sh         Probe configured models and audit policy against provider catalogs
workspace/                      Agent workspace (gitignored)
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
- There are two tracked config entry points: `config/openclaw.json.example` is the minimal local-only example; `templates/openclaw.json.template` is the richer runtime template rendered by `scripts/render-secrets-up.sh`
- Gateway port is bound to localhost only (`127.0.0.1:${OPENCLAW_PORT}`) via docker-compose, default `18789`
- `gateway.bind: lan` is set so the gateway listens on `0.0.0.0` inside the container (required for Docker port forwarding and the Control UI)
- Control UI is enabled at `http://127.0.0.1:${OPENCLAW_PORT}/` via `gateway.controlUi.enabled: true`
- `gateway.auth.rateLimit` is enabled in both tracked config entry points (`maxAttempts: 10`, `windowMs: 60000`, `lockoutMs: 300000`) because the gateway binds on `lan` inside Docker
- `docker-compose.yml` already uses `restart: unless-stopped`; for a future headless Linux deployment, persistence should be managed by enabling the Docker engine at boot via `systemd`, not by creating a separate host service for OpenClaw
- `config/openclaw.json.example` disables native `web_search`; the rendered runtime template currently enables OpenClaw web search and can still coexist with the DDG skill
- The portable runtime template is hosted-first: `anthropic/claude-sonnet-4-6` primary, `openai/gpt-5.4` fallback, local Ollama models optional
- Hosted defaults are pinned in `models.policy.json`; `bash ./scripts/check-models.sh --adopt` updates that policy only after an explicit opt-in
- If Anthropic appears to "rate limit" unexpectedly during live turns, also check billing/credits; OpenClaw can surface insufficient-credit failures as generic rate-limit-style failovers
- `agents.defaults.contextTokens` is set to 50000 to stay within the model's 65K context window (leaving ~15K headroom for system prompt and tool definitions)
- Ollama concurrency is controlled on the host with `OLLAMA_NUM_PARALLEL`; there is no OpenClaw config field like `models.providers.ollama.maxConcurrent`
- Telegram may warn at startup when `groupPolicy` is `"allowlist"` and no group allowlist is configured; this is expected for DM-only use and group messages will simply be dropped unless explicitly enabled later
- On macOS/Colima, don't run this repo from `/tmp` or `/private/tmp`; Docker can mount `config/` as effectively empty there. Use a checkout under `/Users/...`
- The default 1Password vault name is `AI-Agents`; override `OP_VAULT` if you use a different vault
- Parallel instances are supported via separate checkouts, each with its own `.env.instance.local`, `config/`, and `workspace/`
- `setup.sh` now rewrites the copied `config/openclaw.json.example` to the checkout's `OPENCLAW_PORT`, so manual bootstrap works on non-default ports too
- Validated on 2026-03-11: a second checkout on port `18790` started cleanly and the first fresh turn used `anthropic/claude-sonnet-4-6` by default
- Also validated on 2026-03-11 in the main checkout after soft-deleting the runtime `config/` contents to `~/Desktop/_TRASH/...`: rerendering from secrets rebuilt a clean session store and the first successful live turn again used `anthropic/claude-sonnet-4-6`
- The very first probe right after a rebuild can hit a transient `gateway closed (1006 abnormal closure)` if the gateway restarts once during boot; rerun after `./oc health` is clean before treating it as a real failure
- Validated on 2026-03-11 after hardening: `openclaw security audit --deep` returned `0 critical`, `0 warn`, and only one expected info finding for Telegram DM-only group handling
- Prefer `./oc ...` over raw `docker compose ...` for per-instance operations because the wrapper loads `.env.instance.local` automatically
- For Telegram pairing approval, some shell runners do not preserve `cd` between commands; use the absolute wrapper path (`~/GitHub/alastori/openclaw-sandbox/oc ...`) or `cd ... && ...` in a single shell invocation
- Parallel instances must not share the same Telegram bot token with polling enabled unless you deliberately want them competing for the same updates

## Security Notes

- `config/openclaw.json` contains bot tokens and gateway auth tokens -- never commit it
- The `config/` directory also contains credentials, session data, and device identity files
- `scripts/render-secrets-up.sh` and `setup.sh` both force `config/` and `workspace/` to mode `700`; keep those directories private on the host
- `.gitignore` uses `config/*` with a negation for `!config/openclaw.json.example` -- everything else under `config/` is excluded
- Never force-add files from `config/`
- No PII or credentials in any tracked file
- Elevated tools are disabled by default in the tracked config sources. Re-enable them only if you have a narrow provider-specific allowlist; do not restore `controlui: ["*"]`
