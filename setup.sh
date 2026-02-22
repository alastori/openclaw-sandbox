#!/usr/bin/env bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
CONFIG_DIR="$SCRIPT_DIR/config"
WORKSPACE_DIR="$SCRIPT_DIR/workspace"

echo "=== OpenClaw Sandbox Setup ==="
echo ""

# -------------------------------------------------------------------
# 1. Pre-flight checks
# -------------------------------------------------------------------
echo "[1/6] Checking prerequisites..."

if ! command -v docker &>/dev/null; then
    echo "ERROR: Docker is not installed. Install Docker or Colima first."
    exit 1
fi

if ! docker info &>/dev/null; then
    echo "ERROR: Docker daemon is not running. Start Colima or Docker Desktop."
    exit 1
fi

if ! command -v ollama &>/dev/null; then
    echo "ERROR: Ollama is not installed. Run: brew install ollama"
    exit 1
fi

# Verify Ollama is reachable
OLLAMA_URL="http://localhost:11434/v1/models"
if curl -sf "$OLLAMA_URL" &>/dev/null; then
    echo "  Ollama detected on port 11434"
    echo "  Available models:"
    curl -sf "$OLLAMA_URL" | python3 -c "
import sys, json
data = json.load(sys.stdin)
for m in data.get('data', []):
    print(f'    - {m[\"id\"]}')
" 2>/dev/null || echo "    (none -- pull a model with: ollama pull qwen3-coder:30b-a3b-q8_0)"
else
    echo "  WARNING: Ollama not responding on port 11434."
    echo "  Start Ollama: brew services start ollama"
fi

# -------------------------------------------------------------------
# 2. Test Docker-to-host networking
# -------------------------------------------------------------------
echo ""
echo "[2/6] Testing Docker-to-host networking..."
if docker run --rm --add-host=host.docker.internal:host-gateway alpine \
    sh -c "wget -qO- http://host.docker.internal:11434/v1/models" &>/dev/null; then
    echo "  Docker can reach Ollama via host.docker.internal"
else
    echo "  WARNING: Cannot reach Ollama from inside Docker."
    echo "  Make sure Ollama is running: brew services start ollama"
fi

# -------------------------------------------------------------------
# 3. Create directories
# -------------------------------------------------------------------
echo ""
echo "[3/6] Creating config and workspace directories..."
mkdir -p "$CONFIG_DIR" "$WORKSPACE_DIR"

# -------------------------------------------------------------------
# 4. Build the image
# -------------------------------------------------------------------
echo ""
echo "[4/6] Building Docker image..."
cd "$SCRIPT_DIR"
docker compose build

# -------------------------------------------------------------------
# 5. Initialize config if needed
# -------------------------------------------------------------------
echo ""
echo "[5/6] Configuring OpenClaw..."

if [ ! -f "$CONFIG_DIR/openclaw.json" ]; then
    if [ ! -f "$CONFIG_DIR/openclaw.json.example" ]; then
        echo "ERROR: config/openclaw.json.example not found. Re-clone the repo."
        exit 1
    fi
    cp "$CONFIG_DIR/openclaw.json.example" "$CONFIG_DIR/openclaw.json"
    echo "  Created config from template."

    # Set gateway mode
    docker compose run --rm openclaw-gateway openclaw config set gateway.mode local 2>/dev/null

    echo ""
    echo "  To add a Telegram bot:"
    echo "    docker compose run --rm openclaw-gateway openclaw plugins enable telegram"
    echo "    docker compose run --rm openclaw-gateway openclaw channels add \\"
    echo "      --channel telegram --token YOUR_BOT_TOKEN --name YOUR_BOT_NAME"
    echo ""
else
    echo "  Config already exists, skipping."
fi

# -------------------------------------------------------------------
# 6. Start the gateway
# -------------------------------------------------------------------
echo ""
echo "[6/6] Starting OpenClaw gateway..."
docker compose up -d

echo ""
echo "  Waiting for startup..."
sleep 8

# Health check
if docker exec openclaw-sandbox openclaw health 2>/dev/null; then
    echo ""
else
    echo "  Gateway starting up... check 'docker compose logs -f' for details."
fi

echo ""
echo "=== Setup Complete ==="
echo ""
echo "  Web UI:     http://127.0.0.1:18789"
echo "  Dashboard:  ./oc dashboard        # prints URL with auth token"
echo "  Workspace:  $WORKSPACE_DIR"
echo "  Config:     $CONFIG_DIR/openclaw.json"
echo ""
echo "  Commands (./oc is a shortcut for openclaw inside the container):"
echo "    ./oc health                     # Health check"
echo "    ./oc models list                # List configured models"
echo "    ./oc sessions                   # List active sessions"
echo "    docker compose logs -f          # View logs"
echo "    docker compose restart          # Restart after config change"
echo "    docker compose down             # Stop"
