# OpenClaw Sandbox

Sandboxed Docker setup for running OpenClaw with local LLMs via Ollama on macOS Apple Silicon.

## Project Structure

```
Dockerfile                          Container image (node:22 + openclaw + gemini-cli + clawsec + python3)
docker-compose.yml                  Orchestration with security constraints
setup.sh                            One-command setup script
oc                                  Host-side shortcut: ./oc <cmd> = docker compose exec ... openclaw <cmd>
.env.instance.local.example         Example per-checkout port/project config
.env.secrets.example                Secret reference map for the current backend
.env.secrets.local.example          Example local bootstrap file (SA token, vault, item)

templates/
  openclaw.json.template            Runtime config template (op:// refs + ${TELEGRAM_BOT_NAME})
  openclaw.json.minimal             Minimal local-only config (no secrets, no Telegram)
  secrets-mapping.yaml.template     Per-user secret reference map (copy to config/secrets-mapping.yaml)

defaults/                           Enforced config overlays (merged at deploy time)
  models.policy.json                Pinned hosted-model primary/fallback choices
  security.json                     Elevated tools off, loop detection, rate limits
  logging.json                      File logging, API key redaction patterns
  governance.json                   Context tokens, compaction mode
  model-routing.json                Model routing reference: task -> model mapping, topic suggestions
  secrets-backend.json              Pluggable credential backend definitions (1Password, Vault, AWS SM, Keychain, env)
  prompt-guidelines.md              Model-neutral prompt style guide (Claude, GPT, Gemini)

workspace-templates/                Tracked seed files copied to workspace/ on first deploy
  SOUL.md, USER.md, IDENTITY.md, AGENTS.md, BOOTSTRAP.md, HEARTBEAT.md, TOOLS.md, learnings.md

extensions/                         Optional add-ons, mounted read-only at /home/node/extensions
  notifications/                    Notification buffer + digest system with Telegram topic routing
    buffer.py                       Write notification: --tier low|medium|critical --title --body
    digest.py                       Collect buffer, format digest, deliver to Telegram (routes by topic)
    config.example.json             Tier schedules, topic IDs, chat ID, buffer path
  news-brief/                       RSS -> Ollama -> Telegram daily brief
    config.example.json             Template: feeds, chat ID, model
    news-brief.py                   Main script
    cron-news-brief.sh              Thin wrapper for launchd/cronctl
  backup/
    backup.sh                       Git auto-commit + push tracked changes
  doc-watch/
    doc-watch.py                    Monitor external documentation URLs for changes
    README.md                       Extension setup and configuration

scripts/
  render-secrets-up.sh              Pipeline: op inject -> model policy -> defaults -> workspace init -> deploy
  setup-crons.sh                    Create default cron jobs (idempotent, skips existing)
  setup-telegram-topics.sh          Create Ops + Alerts topics in a Telegram group, update configs
  apply-defaults.py                 Deep-merge defaults/*.json into rendered config
  apply-model-policy.py             Apply pinned model policy
  init-workspace.sh                 Copy workspace-templates/ into workspace/ (first run only)
  bootstrap-secrets-local.sh        Create 1Password service account token
  check-models.sh                   Probe configured models and audit policy
  load-local-env.sh                 Source .env.instance.local and .env.secrets.local into the shell
  resolve-secrets.py                Pluggable secret resolver (1Password, Vault, AWS SM, Keychain, env)

config/                             gitignored -- runtime state (sessions, credentials, live config)
workspace/                          gitignored -- agent working directory
.runtime/                           gitignored -- rendered secrets (.env for docker compose)
logs/                               gitignored -- extension output logs
```

## Volume Mounts

| Host Path | Container Path | Purpose |
|-----------|---------------|---------|
| `./config/` | `/home/node/.openclaw` | OpenClaw home (config, credentials, sessions) |
| `./workspace/` | `/home/node/workspace` | Agent working directory |
| `./extensions/` | `/home/node/extensions` | Extensions (read-only) |

### Model Chain & Auth

- The model fallback chain is defined in `templates/openclaw.json.template`. See `defaults/model-routing.json` for the routing strategy.
- Hosted defaults are pinned in `defaults/models.policy.json`; `bash ./scripts/check-models.sh --adopt` updates that policy only after an explicit opt-in.
- **Model auth strategy:** Gemini uses bundled `google` plugin with `google-gemini-cli` OAuth (free tier); OpenAI prefers Codex OAuth (subscription) with API key as fallback; Anthropic uses API key only (subscription OAuth is banned for third-party tools since Jan 2026).
- `agents.defaults.contextTokens` is set to 50000 to stay within the model's 65K context window (leaving ~15K headroom for system prompt and tool definitions).

### Container & Networking

- Ollama runs natively on the host (port 11434), not inside Docker.
- Container reaches Ollama via `host.docker.internal` (requires `extra_hosts: host-gateway` for Colima).
- Container is limited to 2 GB memory and 2 CPU cores; the model runs on the host.
- Config format is JSON at `config/openclaw.json`.
- There are two tracked config entry points: `templates/openclaw.json.minimal` is the minimal local-only example; `templates/openclaw.json.template` is the richer runtime template rendered by `scripts/render-secrets-up.sh`.
- Gateway port is bound to localhost only (`127.0.0.1:${OPENCLAW_PORT}`) via docker-compose, default `18789`.
- `gateway.bind: lan` is set so the gateway listens on `0.0.0.0` inside the container (required for Docker port forwarding and the Control UI).
- Control UI is enabled at `http://127.0.0.1:${OPENCLAW_PORT}/` via `gateway.controlUi.enabled: true`.
- `templates/openclaw.json.minimal` disables native `web_search`; the rendered runtime template currently enables OpenClaw web search and can still coexist with the DDG skill.
- Ollama concurrency is controlled on the host with `OLLAMA_NUM_PARALLEL`; there is no OpenClaw config field like `models.providers.ollama.maxConcurrent`.
- On macOS/Colima, don't run this repo from `/tmp` or `/private/tmp`; Docker can mount `config/` as effectively empty there. Use a checkout under `/Users/...`.
- The very first probe right after a rebuild can hit a transient `gateway closed (1006 abnormal closure)` if the gateway restarts once during boot; rerun after `./oc health` is clean before treating it as a real failure.
- Parallel instances are supported via separate checkouts, each with its own `.env.instance.local`, `config/`, and `workspace/`. Parallel instances must not share the same Telegram bot token with polling enabled unless you deliberately want them competing for the same updates.
- The default 1Password vault name is `AI-Agents`; override `OP_VAULT` if you use a different vault.

### Cron Schedule

Default crons are created by `scripts/setup-crons.sh`. All nightly crons buffer to the notification system; the digest cron delivers one combined message. See that file for the full schedule.

### Telegram

- Telegram may warn at startup when `groupPolicy` is `"allowlist"` and no group allowlist is configured; this is expected for DM-only use and group messages will simply be dropped unless explicitly enabled later.
- **Telegram topics:** Run `bash scripts/setup-telegram-topics.sh` after adding the bot to a Telegram group with Topics enabled. Creates "Ops" and "Alerts" topics, routes critical notifications to Alerts and routine digests to Ops. See README for manual prerequisites.

### Security

- `config/openclaw.json` contains bot tokens and gateway auth tokens -- never commit it.
- The `config/` directory also contains credentials, session data, and device identity files.
- `scripts/render-secrets-up.sh` and `setup.sh` both force `config/` and `workspace/` to mode `700`; keep those directories private on the host.
- `.gitignore` uses `config/*` to exclude everything under `config/`; all tracked config lives in `templates/` and `defaults/`.
- Never force-add files from `config/`. No PII or credentials in any tracked file.
- Elevated tools are disabled by default in the tracked config sources. Re-enable them only if you have a narrow provider-specific allowlist; do not restore `controlui: ["*"]`.
- **ClawSec** security skill suite is baked into the Docker image (drift detection, integrity checks, CVE advisory feed). Discovered via `skills.load.extraDirs: ["/home/node/skills"]`.

See the README [Security section](README.md#security) for the full list of container-level and behavioral defenses.
