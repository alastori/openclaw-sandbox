# Roadmap

Forward-looking work for openclaw-sandbox: things blocked on upstream changes,
deferred experiments, and improvements waiting on a trigger event. Each entry
explains the goal, why it is currently parked, and the condition under which
it should be revisited.

This file is the canonical place to record "watch this and revisit later"
items. Resolved entries get deleted (not marked done in place); the git
history is the audit trail.

## Watching upstream

### OpenClaw version pin (2026.4.5)

**Goal:** Track upstream OpenClaw releases past 2026.4.5 so we can adopt
them as soon as they are compatible with our hardened container image.

**Current state:** [`Dockerfile`](Dockerfile) pins
`ARG OPENCLAW_VERSION=2026.4.5`. Tested 2026.4.21 on 2026-04-22; the
gateway starts but every CLI call and the Telegram plugin itself fail
because the plugin loader tries to `mkdir .../dist/extensions/telegram/node_modules`
and then `npm install` at runtime. Our
[`docker-compose.yml`](docker-compose.yml) sets `read_only: true` on the
rootfs (hardening from commit `3f44a44`), so the mkdir aborts with
`ENOENT` and the gateway can no longer resolve `grammy` (the Telegram bot
framework).

**Why blocked:** The regression is in OpenClaw's plugin packaging between
2026.4.5 and 2026.4.21. Older versions install plugin deps as part of
`npm install -g openclaw@...` at image build time; newer versions defer
that to first CLI/gateway load, which requires a writable plugin dir.
Dropping `read_only: true` would unblock the upgrade but give back the
hardening gain the image was specifically built for.

**Definition of done:** Any one of the following lands in a released
OpenClaw version:

1. Plugin `node_modules` are installed as part of the published npm
   package (so `npm install -g openclaw@...` yields a self-contained
   install tree, no runtime mkdir).
2. A Dockerfile-time command like `openclaw plugins install-deps` is
   documented and stable, callable as a single `RUN` step so the image
   build materialises the plugin tree before `read_only: true` takes
   effect.
3. The plugin loader falls back gracefully when its install dir is
   read-only (e.g. resolves deps from a pre-populated adjacent path, or
   no-ops with a warning instead of throwing).

**Retest plan when unblocked:**

1. `OPENCLAW_VERSION=<new-version> docker compose build`
2. `docker compose up -d`
3. `./oc health` should return `Telegram: ok` and session-store rows.
4. `./oc cron list` should list all 9 crons without `MODULE_NOT_FOUND`.
5. If green, flip the Dockerfile `ARG OPENCLAW_VERSION=<new-version>`
   and delete this roadmap entry.

**Last verified blocked:** 2026-04-22 against OpenClaw 2026.4.21
(`f788c88`), Mac Studio M3, Docker Desktop. Gateway starts (container
reports `healthy`) but `./oc cron list` fails with
`Cannot find module 'grammy'` and `./oc health` fails with the plugin
`mkdir` ENOENT.

### Model catalog refresh (GPT-5.5, Opus 4.7)

**Goal:** Adopt OpenAI GPT-5.5 (released 2026-04-23) and Anthropic Claude
Opus 4.7 (released 2026-04-16) as soon as OpenClaw's model catalog
recognises them.

**Current state:** [`defaults/models.policy.json`](defaults/models.policy.json)
pins `openai-codex/gpt-5.4` and `anthropic/claude-opus-4-6`. We tried
upgrading to 5.5 and 4.7 on 2026-04-24 and reverted in commit `52260ab`
because OpenClaw 2026.4.5 returns `Unknown model: openai-codex/gpt-5.5`
(and the same for `claude-opus-4-7`) at the provider client, before any
upstream API is hit. The chain falls through to whatever still works.

**Why blocked:** OpenClaw 2026.4.5's bundled model catalog predates these
releases. There is no user-facing knob to register an unrecognised model
id with an existing provider; the catalog ships in the published npm
package.

**Definition of done:** A released OpenClaw version recognises both
`openai-codex/gpt-5.5` and `anthropic/claude-opus-4-7` in its catalog.
At that point repin and retest end-to-end via `./scripts/check-models.sh`
plus a `./oc cron run <heavy-cron>`.

**Retest plan when unblocked:** Apply the same edit set as commit
`2907d73` (pre-revert state), re-render via
`scripts/render-secrets-up.sh`, restart the gateway, and confirm the
heavy crons (`nightly-doc-drift`, `weekly-memory-synthesis`) execute on
gpt-5.5 instead of cascading.

### Gateway `logging.file` config ignored

**Goal:** Have the gateway honour the `logging.file` path from
[`defaults/logging.json`](defaults/logging.json) so logs persist across
container restarts and `cascade-detect` has a stable history window.

**Current state:** On startup the gateway announces
`[gateway] log file: /tmp/openclaw/openclaw-<date>.log` regardless of the
`logging.file` value read from `openclaw.json`. `./oc config get logging`
returns the configured path, but the writer targets `/tmp/openclaw/`. To
work around this we bind-mount `./config/gateway-logs:/tmp/openclaw` in
[`docker-compose.yml`](docker-compose.yml) so the rotated logs live on
virtiofs instead of tmpfs. The workaround was applied 2026-04-24; commit
history has the details.

**Why blocked:** The provider client ignores the schema-declared
`logging.file` key. There is no documented override other than changing
the hardcoded source path (which we can't do from config) or redirecting
at the filesystem layer (which we did).

**Definition of done:** A released OpenClaw version actually writes to
`logging.file`, at which point we can drop the `/tmp/openclaw` bind mount
and move logs back under `/home/node/.openclaw/logs/`.

**Retest plan:** After an OpenClaw upgrade, `docker compose up -d` without
the `gateway-logs` mount, then tail `/home/node/.openclaw/logs/openclaw*.log`
while the gateway is running. If the file mtime advances, the bug is
fixed and the mount can be removed.
