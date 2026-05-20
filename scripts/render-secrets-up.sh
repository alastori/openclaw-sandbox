#!/usr/bin/env bash
# render-secrets-up.sh — Render secrets from 1Password, apply config overlays,
# and start the OpenClaw container.
#
# Usage:
#     bash scripts/render-secrets-up.sh
#
# Prerequisites:
#     - 1Password CLI (op) installed
#     - OP_SERVICE_ACCOUNT_TOKEN set (via .env.secrets.local or environment)
#     - OP_VAULT and OP_ITEM set
#     - templates/openclaw.json.template and .env.secrets.example present
#     - defaults/models.policy.json present
#
# Pipeline steps:
#     1. Loads env from .env.instance.local and .env.secrets.local
#     2. Validates 1Password authentication
#     3. Renders .runtime/openclaw.env via `op inject` from .env.secrets.example
#     4. Renders config/openclaw.json via `op inject` from the template
#     5. Substitutes non-secret env vars (TELEGRAM_BOT_NAME, OPENCLAW_PORT)
#     6. Applies model policy (scripts/apply-model-policy.py)
#     7. Deep-merges enforced defaults (scripts/apply-defaults.py)
#     8. Initializes workspace templates on first run (scripts/init-workspace.sh)
#     9. Backs up existing config/openclaw.json
#    10. Starts the container with docker compose
#
# What it changes:
#     - Writes .runtime/openclaw.env (API keys, mode 600)
#     - Writes config/openclaw.json (rendered config, mode 600)
#     - Creates config/ and workspace/ directories (mode 700)

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

MODEL_POLICY_FILE="${MODEL_POLICY_FILE:-defaults/models.policy.json}"
DEFAULTS_DIR="${DEFAULTS_DIR:-defaults}"

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/load-local-env.sh"

case "$ROOT_DIR" in
  /tmp/*|/private/tmp/*)
    echo "error: deploying from $ROOT_DIR is not supported on macOS/Colima; bind-mounted config appears empty inside Docker from /tmp. Clone under /Users/... instead." >&2
    exit 1
    ;;
esac

if [[ ! -f "$MODEL_POLICY_FILE" ]]; then
  echo "error: $MODEL_POLICY_FILE not found" >&2
  exit 1
fi

mkdir -p .runtime config workspace
chmod 700 .runtime
chmod 700 config workspace

# --- Secret resolution ---
# New path: pluggable backend via resolve-secrets.py (if mapping file exists)
# Legacy path: op inject (if no mapping file, falls back to original behavior)

MAPPING_FILE="$ROOT_DIR/config/secrets-mapping.yaml"

if [[ -f "$MAPPING_FILE" ]]; then
  echo "Using pluggable secret resolver (config/secrets-mapping.yaml)..."
  python3 scripts/resolve-secrets.py
  # Load resolved secrets into environment for config template rendering
  set -a
  # shellcheck disable=SC1091
  source .runtime/openclaw.env
  set +a
else
  echo "Using legacy 1Password op inject..."
  if ! command -v op >/dev/null 2>&1; then
    echo "error: 1Password CLI (op) is not installed" >&2
    exit 1
  fi
  : "${OP_SERVICE_ACCOUNT_TOKEN:?Set OP_SERVICE_ACCOUNT_TOKEN or create .env.secrets.local}"
  : "${OP_VAULT:?Set OP_VAULT in the environment or .env.secrets.local}"
  : "${OP_ITEM:?Set OP_ITEM in the environment or .env.secrets.local}"
  if ! op whoami >/dev/null 2>&1; then
    echo "error: 1Password CLI could not authenticate with the configured service account token" >&2
    exit 1
  fi
  runtime_tmp_dir="$(mktemp -d .runtime/openclaw.XXXXXX)"
  runtime_env_tmp="$runtime_tmp_dir/openclaw.env"
  op inject -i .env.secrets.example -o "$runtime_env_tmp"
  chmod 600 "$runtime_env_tmp"
  mv "$runtime_env_tmp" .runtime/openclaw.env
  rmdir "$runtime_tmp_dir"
  set -a
  # shellcheck disable=SC1091
  source .runtime/openclaw.env
  set +a
fi

# --- Config template rendering ---
config_tmp_dir="$(mktemp -d config/openclaw.XXXXXX)"
config_tmp="$config_tmp_dir/openclaw.json"

# Render config template: substitute op:// refs (if present) and env vars
if command -v op >/dev/null 2>&1 && [[ -n "${OP_SERVICE_ACCOUNT_TOKEN:-}" ]]; then
  op inject -i templates/openclaw.json.template -o "$config_tmp"
else
  # No op CLI — do plain env var substitution only
  cp templates/openclaw.json.template "$config_tmp"
fi
chmod 600 "$config_tmp"

# Substitute non-secret env vars that op inject doesn't handle.
: "${TELEGRAM_BOT_NAME:=my_openclaw_bot}"
: "${OPENCLAW_PORT:=18789}"
: "${TELEGRAM_GROUP_ID:=}"
sed -i.bak "s|\${TELEGRAM_BOT_NAME}|${TELEGRAM_BOT_NAME}|g" "$config_tmp"
sed -i.bak "s|\${OPENCLAW_PORT}|${OPENCLAW_PORT}|g" "$config_tmp"
rm -f "$config_tmp.bak"

# If a Telegram group ID is configured, persist the full allowlist state
# into the rendered config so it survives re-renders. The template ships
# with groupPolicy: "disabled" (closed-by-default DM-only); when the
# user opts into group access via setup-telegram-topics.sh, that script
# writes TELEGRAM_GROUP_ID (and the operator writes TELEGRAM_ALLOW_FROM)
# to .env.instance.local, and the render flow restores the full state:
#   - groupPolicy -> "allowlist"
#   - channels.telegram.groups[<chat-id>] = { requireMention: false }
#   - channels.telegram.groupAllowFrom = [<user-ids>]
: "${TELEGRAM_ALLOW_FROM:=}"
if [[ -n "${TELEGRAM_GROUP_ID}" && -z "${TELEGRAM_ALLOW_FROM}" ]]; then
  cat >&2 <<'EOF'
error: TELEGRAM_GROUP_ID is set but TELEGRAM_ALLOW_FROM is empty.
       Activating a group with groupPolicy: "allowlist" and an empty
       channels.telegram.groupAllowFrom exposes slash/native commands
       to every member of the configured group in OpenClaw's Telegram
       command auth path.
       Set TELEGRAM_ALLOW_FROM=<comma-separated Telegram user IDs> in
       .env.instance.local, then re-run scripts/render-secrets-up.sh.
EOF
  exit 1
fi

if [[ -n "${TELEGRAM_GROUP_ID}" ]]; then
  python3 -c "
import json
path = '$config_tmp'
with open(path) as f:
    cfg = json.load(f)
tg = cfg.setdefault('channels', {}).setdefault('telegram', {})
tg['groupPolicy'] = 'allowlist'

groups = tg.setdefault('groups', {})
chat_id = '${TELEGRAM_GROUP_ID}'
if chat_id not in groups:
    groups[chat_id] = {'requireMention': False}

allow_raw = '${TELEGRAM_ALLOW_FROM}'
allow = [s.strip() for s in allow_raw.split(',') if s.strip()]
tg['groupAllowFrom'] = allow

with open(path, 'w') as f:
    json.dump(cfg, f, indent=2)
    f.write('\n')
"
fi

python3 scripts/apply-model-policy.py "$config_tmp" "$MODEL_POLICY_FILE"
python3 scripts/apply-defaults.py "$config_tmp" "$DEFAULTS_DIR"

# Initialize workspace templates if first run
bash scripts/init-workspace.sh

if [[ -f config/openclaw.json ]]; then
  backup_path="config/openclaw.json.bak.$(date +%Y%m%d-%H%M%S)"
  cp config/openclaw.json "$backup_path"
  chmod 600 "$backup_path"
  echo "Backed up existing config/openclaw.json to $backup_path"
fi

mv "$config_tmp" config/openclaw.json
rmdir "$config_tmp_dir"

docker compose --env-file .runtime/openclaw.env up -d

echo "Rendered config/openclaw.json and started the OpenClaw gateway on port $OPENCLAW_PORT."
