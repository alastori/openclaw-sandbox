# OpenClaw Sandbox

Run [OpenClaw](https://github.com/openclaw/openclaw) in a sandboxed Docker container on macOS Apple Silicon, powered by local models via [Ollama](https://ollama.com).

## Architecture

```
macOS Host
├── Ollama (native, Metal GPU acceleration)
│   └── qwen3-coder:30b-a3b-q8_0 (or any model)
│       OpenAI-compatible API on :11434
│
└── Docker Container (sandboxed)
    └── OpenClaw Gateway
        ├── Reaches Ollama via host.docker.internal
        ├── Workspace: ./workspace/ (only writable dir)
        └── Config: ./config/openclaw.json
```

## Prerequisites

- macOS with Apple Silicon (M1/M2/M3/M4)
- [Docker](https://docs.docker.com/desktop/mac/install/) or [Colima](https://github.com/abiosoft/colima)
- [Ollama](https://ollama.com) (`brew install ollama`)
- 32GB+ unified memory (64GB+ recommended for larger models)

## Quick Start

```bash
# 1. Start Ollama and pull a model
brew services start ollama
ollama pull qwen3-coder:30b-a3b-q8_0

# 2. Clone and set up
git clone https://github.com/alastori/openclaw-sandbox.git
cd openclaw-sandbox

# 3. Run setup
./setup.sh
```

The setup script will:
1. Verify Docker and Ollama are running
2. Test container-to-host networking (Colima-compatible)
3. Build the Docker image
4. Initialize config from the example template
5. Start the OpenClaw gateway

## Configuration

Copy the example config and customize:

```bash
cp config/openclaw.json.example config/openclaw.json
```

### Enable web access

By default, OpenClaw agents cannot access the internet. To enable web search and URL fetching, add the `tools` section to `config/openclaw.json`:

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

This is already included in `config/openclaw.json.example`.

You can also install the DuckDuckGo search skill (no API key required):

```bash
docker exec openclaw-sandbox npx clawhub install ddg-web-search --no-input
docker exec openclaw-sandbox mkdir -p /home/node/.openclaw/workspace/skills
docker exec openclaw-sandbox cp -r /home/node/skills/ddg-web-search \
  /home/node/.openclaw/workspace/skills/
docker compose restart
```

After restarting, send `/reset` to the bot to start a fresh session with the new tools.

### Add a Telegram bot

```bash
docker compose run --rm openclaw-gateway openclaw plugins enable telegram
docker compose run --rm openclaw-gateway openclaw channels add \
  --channel telegram --token YOUR_BOT_TOKEN --name YOUR_BOT_NAME
docker compose restart
```

When you first message the bot, it will ask you to approve a pairing code:

```bash
docker exec openclaw-sandbox openclaw pairing approve telegram YOUR_CODE
```

### Add a ChatGPT fallback (uses your existing subscription)

```bash
docker compose run --rm openclaw-gateway openclaw plugins enable copilot-proxy
docker compose restart
docker compose exec -it openclaw-sandbox openclaw models auth login --provider copilot-proxy
docker compose exec openclaw-sandbox openclaw models fallbacks add copilot/gpt-4o
```

### Change the model

Edit `config/openclaw.json` and update the model ID, then restart:

```bash
docker compose restart
```

## Recommended Models

Tested on Mac Studio with 96GB unified memory:

| Model | RAM (Q8) | Speed | Best For |
|-------|----------|-------|----------|
| `qwen3-coder:30b-a3b-q8_0` | ~32GB | ~40-70 tok/s | Agentic tool calling, coding |
| `glm4.7:flash` | ~9GB | ~80+ tok/s | Fast agent loops |
| `qwen3:32b` | ~34GB | ~15-25 tok/s | General purpose |
| `mistral-small3.1` | ~25GB | ~25-40 tok/s | Multimodal, fast |

## Sandbox Security

The Docker container enforces:

- **Non-root user** (`node`, uid 1000)
- **`no-new-privileges`** security option
- **2GB memory limit** (the LLM runs on the host, not in the container)
- **Volume isolation** -- only `./workspace/` is writable by the agent
- **No host filesystem access** -- no access to home directory, documents, or credentials
- **Localhost-only port binding** -- gateway only accessible from the host machine

## Troubleshooting

### Agent says it can't access the internet

Enable `tools.web.fetch` and `tools.web.search` in `config/openclaw.json` (see [Enable web access](#enable-web-access) above), then restart and send `/reset` to the bot.

### Context overflow errors

Increase the context length in Ollama. Create a Modelfile:

```
FROM qwen3-coder:30b-a3b-q8_0
PARAMETER num_ctx 65536
```

Then: `ollama create qwen3-coder-64k -f Modelfile`

Update `config/openclaw.json` to use the new model name and restart.

### Agent not responding

```bash
docker exec openclaw-sandbox openclaw health    # Check health
docker compose logs --tail 20                   # Check for errors
docker compose restart                          # Restart
```

### Colima networking issues

If the container can't reach Ollama on the host, verify `host.docker.internal` resolves:

```bash
docker run --rm --add-host=host.docker.internal:host-gateway alpine \
  sh -c "wget -qO- http://host.docker.internal:11434/v1/models"
```

## Commands

```bash
docker compose logs -f                              # Watch logs
docker compose down                                 # Stop
docker compose up -d                                # Start
docker compose restart                              # Restart after config change
docker exec openclaw-sandbox openclaw health         # Health check
docker exec openclaw-sandbox openclaw models list    # List configured models
docker exec openclaw-sandbox openclaw skills list    # List available skills
```

## License

[MIT](LICENSE)
