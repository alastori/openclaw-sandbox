#!/usr/bin/env bash
# Auto-backup: git commit + push workspace and config changes.
# Designed to run from the host via cron or launchd.
#
# Usage: bash extensions/backup/backup.sh
#
# What it backs up:
#   - workspace-templates/ (tracked)
#   - extensions/ configs (tracked)
#   - defaults/ (tracked)
#   - Any other tracked file changes
#
# What it does NOT back up:
#   - config/ (gitignored, contains secrets/sessions)
#   - .runtime/ (gitignored)
#   - workspace/ (gitignored)
#
# For config/workspace backup, use a separate encrypted backup strategy
# (e.g., encrypted tar to cloud storage).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$ROOT_DIR"

# Check if there are any changes to commit
if git diff --quiet HEAD && git diff --cached --quiet && [ -z "$(git ls-files --others --exclude-standard)" ]; then
  echo "No changes to back up."
  exit 0
fi

# Stage tracked file changes only (no untracked files unless explicitly added)
git add -u

# Check again after staging
if git diff --cached --quiet; then
  echo "No staged changes to commit."
  exit 0
fi

TIMESTAMP=$(date +"%Y-%m-%d %H:%M")
git commit -m "Auto-backup: $TIMESTAMP"

# Push if a remote is configured
if git remote get-url origin >/dev/null 2>&1; then
  git push origin HEAD
  echo "Backed up and pushed at $TIMESTAMP."
else
  echo "Backed up locally at $TIMESTAMP (no remote configured)."
fi
