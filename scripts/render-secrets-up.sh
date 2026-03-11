#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v op >/dev/null 2>&1; then
  echo "error: 1Password CLI (op) is not installed" >&2
  exit 1
fi

if [[ -f .env.secrets.local ]]; then
  set -a
  # shellcheck disable=SC1091
  source .env.secrets.local
  set +a
fi

: "${OP_SERVICE_ACCOUNT_TOKEN:?Set OP_SERVICE_ACCOUNT_TOKEN or create .env.secrets.local}"
: "${OP_VAULT:?Set OP_VAULT in the environment or .env.secrets.local}"
: "${OP_ITEM:?Set OP_ITEM in the environment or .env.secrets.local}"

mkdir -p .runtime config
chmod 700 .runtime

if ! op whoami >/dev/null 2>&1; then
  echo "error: 1Password CLI could not authenticate with the configured service account token" >&2
  exit 1
fi

op inject -i .env.secrets.example -o .runtime/openclaw.env
chmod 600 .runtime/openclaw.env

op inject -i templates/openclaw.json.template -o config/openclaw.json
chmod 600 config/openclaw.json

docker compose --env-file .runtime/openclaw.env up -d

echo "Rendered config/openclaw.json and started openclaw-sandbox."
