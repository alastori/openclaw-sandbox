# OpenClaw Sandbox

Sandboxed Docker setup for running OpenClaw with local LLMs via Ollama on macOS Apple Silicon.

Note: `CLAUDE.md` in the project root is a symlink to this file.

## Project Structure

```
Dockerfile                      Container image (node:22-bookworm-slim + openclaw CLI + python3)
docker-compose.yml              Orchestration with security constraints
setup.sh                        One-command setup script
oc                              Host-side shortcut: ./oc <cmd> = docker exec ... openclaw <cmd>
config/openclaw.json.example    Template config (tracked, no secrets)
config/openclaw.json            Live config (gitignored, contains secrets)
.env.secrets.example            Secret reference map for the current backend
.env.secrets.local              Local bootstrap token/config (gitignored)
templates/openclaw.json.template Runtime config template rendered into config/openclaw.json
scripts/render-secrets-up.sh    Render secrets + start the container
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
- Gateway port is bound to localhost only (`127.0.0.1:18789`) via docker-compose
- `gateway.bind: lan` is set so the gateway listens on `0.0.0.0` inside the container (required for Docker port forwarding and the Control UI)
- Control UI is enabled at `http://127.0.0.1:18789/` via `gateway.controlUi.enabled: true`
- `config/openclaw.json.example` disables native `web_search`; the rendered runtime template currently enables OpenClaw web search and can still coexist with the DDG skill
- `agents.defaults.contextTokens` is set to 50000 to stay within the model's 65K context window (leaving ~15K headroom for system prompt and tool definitions)
- Ollama concurrency is controlled on the host with `OLLAMA_NUM_PARALLEL`; there is no OpenClaw config field like `models.providers.ollama.maxConcurrent`
- Telegram may warn at startup when `groupPolicy` is `"allowlist"` and no group allowlist is configured; this is expected for DM-only use and group messages will simply be dropped unless explicitly enabled later

## Security Notes

- `config/openclaw.json` contains bot tokens and gateway auth tokens -- never commit it
- The `config/` directory also contains credentials, session data, and device identity files
- `.gitignore` uses `config/*` with a negation for `!config/openclaw.json.example` -- everything else under `config/` is excluded
- Never force-add files from `config/`
- No PII or credentials in any tracked file
- Elevated tools (shell exec, file write) are restricted to the Control UI via `tools.elevated.allowFrom`. Other channels (Telegram, etc.) cannot use elevated tools unless explicitly added to the allowlist — see `config/openclaw.json.example` for the format
