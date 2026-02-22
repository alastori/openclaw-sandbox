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
- Gateway port is bound to localhost only (`127.0.0.1:18789`) via docker-compose
- `gateway.bind: lan` is set so the gateway listens on `0.0.0.0` inside the container (required for Docker port forwarding and the Control UI)
- Control UI is enabled at `http://127.0.0.1:18789/` via `gateway.controlUi.enabled: true`
- Native `web_search` is disabled (requires Brave API key); web search is provided by the DDG skill via `web_fetch` to DuckDuckGo Lite
- `agents.defaults.contextTokens` is set to 50000 to stay within the model's 65K context window (leaving ~15K headroom for system prompt and tool definitions)

## Security Notes

- `config/openclaw.json` contains bot tokens and gateway auth tokens -- never commit it
- The `config/` directory also contains credentials, session data, and device identity files
- `.gitignore` uses `config/*` with a negation for `!config/openclaw.json.example` -- everything else under `config/` is excluded
- Never force-add files from `config/`
- No PII or credentials in any tracked file
