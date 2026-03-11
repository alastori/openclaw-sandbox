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

runtime_tmp_dir="$(mktemp -d .runtime/openclaw.XXXXXX)"
config_tmp_dir="$(mktemp -d config/openclaw.XXXXXX)"
runtime_env_tmp="$runtime_tmp_dir/openclaw.env"
config_tmp="$config_tmp_dir/openclaw.json"

op inject -i .env.secrets.example -o "$runtime_env_tmp"
chmod 600 "$runtime_env_tmp"

op inject -i templates/openclaw.json.template -o "$config_tmp"
chmod 600 "$config_tmp"

if [[ -f config/openclaw.json ]]; then
  backup_path="config/openclaw.json.bak.$(date +%Y%m%d-%H%M%S)"
  cp config/openclaw.json "$backup_path"
  chmod 600 "$backup_path"
  echo "Backed up existing config/openclaw.json to $backup_path"
fi

mv "$runtime_env_tmp" .runtime/openclaw.env
mv "$config_tmp" config/openclaw.json
rmdir "$runtime_tmp_dir" "$config_tmp_dir"

docker compose --env-file .runtime/openclaw.env up -d

echo "Rendered config/openclaw.json and started openclaw-sandbox."
