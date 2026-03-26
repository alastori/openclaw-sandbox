#!/usr/bin/env bash
# load-local-env.sh — Source per-checkout env files into the current shell.
#
# This script is sourced (not executed) by other scripts in this directory.
# It loads .env.instance.local and .env.secrets.local if they exist, then
# exports COMPOSE_PROJECT_NAME and OPENCLAW_PORT with sensible defaults.
#
# Env vars set:
#     COMPOSE_PROJECT_NAME  (default: openclaw-sandbox)
#     OPENCLAW_PORT         (default: 18789)
#     Plus any vars defined in the two env files (OP_SERVICE_ACCOUNT_TOKEN,
#     OP_VAULT, OP_ITEM, etc.)
#
# Idempotency:
#     Safe to source multiple times. Already-set vars are not overwritten
#     by the default assignments.

set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

for env_file in "$ROOT_DIR/.env.instance.local" "$ROOT_DIR/.env.secrets.local"; do
  if [[ -f "$env_file" ]]; then
    set -a
    # shellcheck disable=SC1090
    source "$env_file"
    set +a
  fi
done

: "${COMPOSE_PROJECT_NAME:=openclaw-sandbox}"
: "${OPENCLAW_PORT:=18789}"

export COMPOSE_PROJECT_NAME OPENCLAW_PORT
