#!/usr/bin/env bash

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
