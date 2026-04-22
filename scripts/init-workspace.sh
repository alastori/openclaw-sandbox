#!/usr/bin/env bash
# Copy workspace templates into ./workspace/ if not already populated.
# Safe to run multiple times — never overwrites existing files.
# Matches the docker-compose mount: ./workspace -> /home/node/workspace.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT_DIR/workspace-templates"
DST="$ROOT_DIR/workspace"

if [[ ! -d "$SRC" ]]; then
  echo "error: workspace-templates/ not found" >&2
  exit 1
fi

mkdir -p "$DST"

copied=0
for f in "$SRC"/*; do
  name="$(basename "$f")"
  if [[ ! -f "$DST/$name" ]]; then
    cp "$f" "$DST/$name"
    echo "  Copied $name"
    copied=$((copied + 1))
  fi
done

if [[ $copied -eq 0 ]]; then
  echo "Workspace already initialized (no files copied)."
else
  echo "Initialized workspace with $copied template(s)."
fi
