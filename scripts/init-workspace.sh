#!/usr/bin/env bash
# Copy workspace templates into the active OpenClaw workspace if missing.
# Safe to run multiple times. Never overwrites existing files.
# Matches the default OpenClaw home workspace:
#   ./config/workspace -> /home/node/.openclaw/workspace
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="$ROOT_DIR/workspace-templates"
DST="$ROOT_DIR/config/workspace"
LEGACY_DST="$ROOT_DIR/workspace"

if [[ ! -d "$SRC" ]]; then
  echo "error: workspace-templates/ not found" >&2
  exit 1
fi

mkdir -p "$DST"
chmod 700 "$ROOT_DIR/config" "$DST"

copied=0
legacy_copied=0
workspace_had_files=false
if [[ -n "$(find "$DST" -maxdepth 1 -type f -print -quit)" ]]; then
  workspace_had_files=true
fi
LEGACY_MIGRATE_FILES=(
  AGENTS.md
  HEARTBEAT.md
  IDENTITY.md
  MEMORY.md
  SOUL.md
  TOOLS.md
  USER.md
  learnings.md
)

copy_if_missing() {
  local src="$1"
  local dst="$2"
  local name
  name="$(basename "$src")"
  if [[ ! -f "$dst/$name" ]]; then
    rsync -a "$src" "$dst/$name"
    echo "  Copied $name"
    return 0
  fi
  return 1
}

# Older versions seeded ./workspace even though the gateway's active default
# workspace is under ./config/workspace. Preserve any top-level legacy notes by
# copying them into the active workspace only when the active file is missing.
if [[ -d "$LEGACY_DST" ]]; then
  for name in "${LEGACY_MIGRATE_FILES[@]}"; do
    f="$LEGACY_DST/$name"
    if [[ -f "$f" ]] && copy_if_missing "$f" "$DST"; then
      legacy_copied=$((legacy_copied + 1))
    fi
  done
fi

for f in "$SRC"/*; do
  if [[ "$workspace_had_files" == true && "$(basename "$f")" == "BOOTSTRAP.md" ]]; then
    continue
  fi
  if [[ -f "$f" ]] && copy_if_missing "$f" "$DST"; then
    copied=$((copied + 1))
  fi
done

if [[ $copied -eq 0 && $legacy_copied -eq 0 ]]; then
  echo "Active workspace already initialized at config/workspace (no files copied)."
else
  echo "Initialized active workspace at config/workspace with $legacy_copied legacy file(s) and $copied template(s)."
fi
