#!/usr/bin/env bash
# bootstrap-secrets-local.sh — Create a 1Password service account and write
# the local secrets bootstrap file (.env.secrets.local).
#
# Usage:
#     bash scripts/bootstrap-secrets-local.sh
#     OP_VAULT='My Vault' OP_ITEM='My Item' bash scripts/bootstrap-secrets-local.sh
#
# Prerequisites:
#     - 1Password CLI (op) installed and authenticated (interactive session)
#     - A vault (default: AI-Agents) with an item (default: OpenClaw Sandbox)
#       containing the API keys and tokens
#
# What it creates:
#     - A new 1Password service account with read-only access to the vault
#     - .env.secrets.local with OP_SERVICE_ACCOUNT_TOKEN, OP_VAULT, OP_ITEM
#
# Idempotency:
#     Refuses to run if .env.secrets.local already exists. Delete it first
#     to recreate the service account token.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

# shellcheck disable=SC1091
source "$ROOT_DIR/scripts/load-local-env.sh"

if ! command -v op >/dev/null 2>&1; then
  echo "error: 1Password CLI (op) is not installed" >&2
  exit 1
fi

if ! op whoami >/dev/null 2>&1; then
  echo "error: 1Password CLI is not authenticated; run 'op signin' on the host first" >&2
  exit 1
fi

OP_VAULT="${OP_VAULT:-AI-Agents}"
OP_ITEM="${OP_ITEM:-OpenClaw Sandbox}"
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-${COMPOSE_PROJECT_NAME}-$(hostname -s)}"
OUTPUT_FILE="${OUTPUT_FILE:-.env.secrets.local}"

if [[ -f "$OUTPUT_FILE" ]]; then
  echo "error: $OUTPUT_FILE already exists; remove it first if you want to recreate the service account token" >&2
  exit 1
fi

if ! op vault get "$OP_VAULT" >/dev/null 2>&1; then
  echo "error: vault '$OP_VAULT' was not found in 1Password" >&2
  exit 1
fi

if ! op item get "$OP_ITEM" --vault "$OP_VAULT" >/dev/null 2>&1; then
  echo "error: item '$OP_ITEM' was not found in vault '$OP_VAULT'" >&2
  exit 1
fi

token="$(op service-account create "$SERVICE_ACCOUNT_NAME" --vault "$OP_VAULT:read_items" --raw)"

{
  printf 'OP_SERVICE_ACCOUNT_TOKEN=%q\n' "$token"
  printf 'OP_VAULT=%q\n' "$OP_VAULT"
  printf 'OP_ITEM=%q\n' "$OP_ITEM"
} > "$OUTPUT_FILE"

chmod 600 "$OUTPUT_FILE"

unset token

echo "Wrote $OUTPUT_FILE"
echo "Service account: $SERVICE_ACCOUNT_NAME"
echo "Next: bash ./scripts/render-secrets-up.sh"
