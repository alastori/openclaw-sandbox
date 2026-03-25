# HEARTBEAT.md — Periodic Health Checks

When you receive a heartbeat, run through this checklist. Rotate checks across heartbeats (don't do everything every time — pick 2-3 per heartbeat to limit token burn).

## System Health (check 1-2x daily)

- **Provider connectivity:** Run `openclaw models status`. Are all configured providers authenticated? Any expired OAuth tokens? Report quota usage if available.
- **Disk space:** Check `df -h /home/node/.openclaw`. Alert if usage exceeds 80%.
- **Session count:** Run `openclaw sessions list`. Are there stale sessions accumulating? Flag if >20 active sessions.
- **Gateway health:** Run `openclaw health`. Report any warnings.

## Notification buffer (check every heartbeat)

- **Pending notifications:** Check if `/home/node/.openclaw/notifications/critical/` has any files. If so, run `python3 /home/node/extensions/notifications/digest.py --tier critical` immediately.

## Memory maintenance (check every few days)

- Review recent `memory/YYYY-MM-DD.md` files (last 3-5 days).
- Identify significant lessons, decisions, or user preferences worth keeping long-term.
- Update `MEMORY.md` with distilled insights. Remove anything stale.
- Check `learnings.md` — are any lessons obsolete? Remove them.

## Quiet hours

- **23:00-08:00:** Only report critical issues. Skip all other checks.
- **If nothing needs attention:** Reply `HEARTBEAT_OK` — don't manufacture work.
