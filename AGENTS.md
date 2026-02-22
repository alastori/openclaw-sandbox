# OpenClaw Sandbox

Sandboxed Docker setup for running OpenClaw with local LLMs via Ollama on macOS Apple Silicon.

## Project Structure

- `Dockerfile` - OpenClaw container image (Node 22 + openclaw CLI)
- `docker-compose.yml` - Container orchestration with security constraints
- `setup.sh` - One-command setup script
- `config/` - OpenClaw config directory (mounted into container, gitignored except example)
- `config/openclaw.json.example` - Template config (no secrets)
- `workspace/` - Agent workspace (only dir the agent can write to, gitignored)

## Key Details

- Uses Colima (not Docker Desktop), so `host.docker.internal` requires `extra_hosts: host-gateway` in docker-compose
- Ollama runs on the host at port 11434, not inside Docker
- Container is memory-limited to 2GB (model runs on host, not in container)
- Config format is JSON at `config/openclaw.json`
- The `config/` directory is gitignored because it contains secrets (bot tokens, gateway auth tokens)
- Only `config/openclaw.json.example` is tracked in git

## Security Notes

- Never commit `config/openclaw.json` -- it contains bot tokens and gateway auth tokens
- The `.gitignore` excludes all of `config/` except the example file
- No PII or credentials should appear in any tracked file
