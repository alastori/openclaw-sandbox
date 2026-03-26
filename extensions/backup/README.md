# Backup

Auto-backup extension that commits and pushes tracked file changes to the Git remote. Designed to run from the host via cron, launchd, or cronctl.

## What It Backs Up

- `workspace-templates/` (tracked seed files)
- `extensions/` configs (tracked)
- `defaults/` (tracked overlays)
- Any other tracked file changes in the repo

## What It Does Not Back Up

- `config/` (gitignored -- contains secrets and sessions)
- `.runtime/` (gitignored)
- `workspace/` (gitignored)

For `config/` and `workspace/`, use a separate encrypted backup strategy (e.g., encrypted tar to cloud storage).

## Usage

```bash
bash extensions/backup/backup.sh
```

The script:

1. Checks for uncommitted changes (tracked files only).
2. Stages modified tracked files (`git add -u`).
3. Commits with a timestamped message (`Auto-backup: YYYY-MM-DD HH:MM`).
4. Pushes to `origin` if a remote is configured.
5. Exits cleanly with no error if there is nothing to commit.

## Configuration

No configuration file needed. The script operates on the repo it lives in.

To run on a schedule, add it to your host scheduler:

```bash
# cronctl example
cronctl add --name openclaw-backup --schedule "0 4 * * *" \
  -- bash /path/to/openclaw-sandbox/extensions/backup/backup.sh
```

## Troubleshooting

- **"No changes to back up"** -- All tracked files are clean. This is normal and not an error.
- **Push fails** -- Check that `origin` is configured and you have push access. The local commit still succeeds.
- **Untracked files not committed** -- By design. Only tracked files are staged (`git add -u`). Add new files to tracking manually first.
