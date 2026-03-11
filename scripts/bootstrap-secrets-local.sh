#!/usr/bin/env bash

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
cd "$ROOT_DIR"

if ! command -v op >/dev/null 2>&1; then
  echo "error: 1Password CLI (op) is not installed" >&2
  exit 1
fi

if ! op whoami >/dev/null 2>&1; then
  echo "error: 1Password CLI is not authenticated; run 'op signin' on the host first" >&2
  exit 1
fi

OP_VAULT="${OP_VAULT:-OpenClaw}"
OP_ITEM="${OP_ITEM:-OpenClaw Sandbox}"
SERVICE_ACCOUNT_NAME="${SERVICE_ACCOUNT_NAME:-openclaw-sandbox-$(hostname -s)}"
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
echo "Next: ./scripts/render-secrets-up.sh"
