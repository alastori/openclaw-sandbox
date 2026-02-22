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

The setup script verifies prerequisites, tests networking, builds the Docker image, initializes config, and starts the gateway.

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

The LLM runs natively on the host for full Metal GPU acceleration. The Docker container only runs the OpenClaw gateway, capped at 2 GB RAM and 2 CPU cores.

## Common Commands

```bash
docker compose up -d              # Start
docker compose down               # Stop
docker compose restart            # Restart after config changes
docker compose logs -f            # Watch logs
docker exec openclaw-sandbox openclaw health   # Health check
```

## Configuration

The setup script creates `config/openclaw.json` from the included example template. You can also copy it manually:

```bash
cp config/openclaw.json.example config/openclaw.json
```

After any config change, restart the gateway with `docker compose restart`.

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
docker exec openclaw-sandbox openclaw pairing approve telegram YOUR_CODE
```

</details>

### Enable web access

Web access is enabled by default in the example config. If you removed it, re-add this block to `config/openclaw.json`:

<details>
<summary>Manual config</summary>

```json
{
  "tools": {
    "web": {
      "search": { "enabled": true },
      "fetch": { "enabled": true }
    },
    "elevated": { "enabled": true }
  }
}
```

Restart the gateway and send `/reset` to the bot to pick up the new tools.

</details>

You can optionally install the DuckDuckGo search skill (no API key required):

<details>
<summary>Install DuckDuckGo skill</summary>

```bash
docker exec openclaw-sandbox npx clawhub install ddg-web-search --no-input
docker exec openclaw-sandbox mkdir -p /home/node/.openclaw/workspace/skills
docker exec openclaw-sandbox cp -r /home/node/skills/ddg-web-search \
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
docker exec openclaw-sandbox openclaw health    # Check health
docker compose logs --tail 20                   # Check for errors
docker compose restart                          # Restart
```
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
