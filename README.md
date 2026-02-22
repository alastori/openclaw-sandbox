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

### Add a Telegram bot

```bash
docker compose run --rm openclaw-gateway openclaw plugins enable telegram
docker compose run --rm openclaw-gateway openclaw channels add \
  --channel telegram --token YOUR_BOT_TOKEN --name YOUR_BOT_NAME
docker compose restart
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

## Commands

```bash
docker compose logs -f                              # Watch logs
docker compose down                                 # Stop
docker compose up -d                                # Start
docker compose restart                              # Restart after config change
docker exec openclaw-sandbox openclaw health         # Health check
docker exec openclaw-sandbox openclaw models list    # List configured models
```

## Networking Note (Colima)

If using Colima instead of Docker Desktop, `host.docker.internal` requires the `extra_hosts` directive in `docker-compose.yml` (already configured). This allows the container to reach Ollama on the host.

## License

[MIT](LICENSE)
