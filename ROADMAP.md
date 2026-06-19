# Roadmap

Forward-looking work for openclaw-sandbox: things blocked on upstream changes,
deferred experiments, and improvements waiting on a trigger event. Each entry
explains the goal, why it is currently parked, and the condition under which
it should be revisited.

This file is the canonical place to record "watch this and revisit later"
items. Resolved entries get deleted (not marked done in place); the git
history is the audit trail.

## Watching upstream

### Model catalog refresh (GPT-5.5, Opus 4.7)

**Goal:** Adopt OpenAI GPT-5.5 (released 2026-04-23) and Anthropic Claude
Opus 4.7 (released 2026-04-16) as soon as OpenClaw's model catalog
recognises them.

**Current state:** [`defaults/models.policy.json`](defaults/models.policy.json)
pins `openai-codex/gpt-5.4` and `anthropic/claude-opus-4-6`. OpenClaw
2026.6.8 recognises `anthropic/claude-opus-4-7` and
`github-copilot/gpt-5.5`, but not `openai-codex/gpt-5.5`.

**Why blocked:** GPT-5.5 is currently available in the OpenClaw catalog
through GitHub Copilot, not through the Codex OAuth provider id that this
repo uses for the primary subscription coding fallback. Repinning the
heavy cron path should be tested deliberately rather than folded into the
runtime upgrade.

**Definition of done:** A released OpenClaw version recognises a GPT-5.5
model on the subscription-backed provider path we want to use, and the
candidate chain passes `./scripts/check-models.sh` plus a forced
`nightly-doc-drift` or `weekly-memory-synthesis` cron run.
