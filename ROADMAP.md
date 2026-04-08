# Roadmap

Forward-looking work for openclaw-sandbox: things blocked on upstream changes,
deferred experiments, and improvements waiting on a trigger event. Each entry
explains the goal, why it is currently parked, and the condition under which
it should be revisited.

This file is the canonical place to record "watch this and revisit later"
items. Resolved entries get deleted (not marked done in place); the git
history is the audit trail.

## Watching upstream

### Local-model monitoring crons

**Goal:** Run `nightly-auth-health` and `cascade-detect` (see
[`scripts/setup-crons.sh`](scripts/setup-crons.sh)) on a local Ollama model
instead of `google/gemini-2.5-flash`, so they keep firing during the exact
failure mode they exist to detect: a hosted-provider auth outage that breaks
every other cron. The April 2026 incident (commit `9ef8bac`, 4-day silent
cascade) is the precedent.

**Current state:** Both monitoring crons run on `google/gemini-2.5-flash`.
This works in the common case, but goes stale during a Gemini outage. The
cron-list dashboard and missing morning digest are the externally visible
signal in that scenario.

**Why blocked:** OpenClaw 2026.4.5 has a hardcoded ~60s LLM HTTP request
timeout in its provider client. Direct Ollama calls return tool calls in
2-5s warm; the same model called through OpenClaw consistently times out at
60.6s and falls over to the next chain entry. Verified across all three
Gemma 4 variants (`e2b-it-q8_0`, `e4b-it-q8_0`, `26b-a4b-it-q8_0`) and
`qwen3-coder:30b-a3b-q8_0`. The timeout is not exposed via any documented
config knob (`agents.defaults.timeoutSeconds`, cron `--timeout`,
`--timeout-seconds`, `injectNumCtxForOpenAICompat`, agent `--light-context`,
`--tools` allow-list — none bypass it). Likely root cause: OpenClaw's
streaming client waits for OpenAI-style streaming chunks that Ollama does
not emit when returning `tool_calls`, so the connection idles until the
fetch timeout fires.

**Tool-call format note:** The Gemma 4 family emits correctly-formatted
OpenAI `tool_calls` (verified via direct `/v1/chat/completions`).
`qwen3-coder` emits a Llama-style `<function=exec>` block that OpenClaw
does not parse. So even if the timeout were lifted, qwen3-coder would still
not be a viable monitoring model: it returns `ok` while silently producing
output the gateway cannot dispatch as a tool call. Gemma 4 is the right
family. The timeout is the only blocker.

**Issues to watch:**

| Issue | Title | Status |
|-------|-------|--------|
| [openclaw/openclaw#43946](https://github.com/openclaw/openclaw/issues/43946) | Configurable LLM request timeout per provider/model | Open |
| [openclaw/openclaw#59604](https://github.com/openclaw/openclaw/issues/59604) | Requests abort after ~1 minute despite agents.defaults.timeoutSeconds | Open |
| [openclaw/openclaw#59098](https://github.com/openclaw/openclaw/issues/59098) | Embedded agent times out with Ollama while direct Ollama works | Open |
| [openclaw/openclaw#52818](https://github.com/openclaw/openclaw/issues/52818) | Ollama cold-start timeout silently exfiltrates data via fallback chain | Open |
| [openclaw/openclaw#41871](https://github.com/openclaw/openclaw/issues/41871) | Local Ollama models still hang in OpenClaw 2026.3.8 | Open |
| [openclaw/openclaw#61487](https://github.com/openclaw/openclaw/issues/61487) | LLM HTTP request timeout hardcoded at ~60s | Closed (config workaround that does not generalize) |

**Definition of done:** Any one of the following lands in a released
OpenClaw version, then we retest:

1. A provider-level `requestTimeout` / `timeoutMs` field is exposed in the
   Ollama provider schema (the fix proposed in #43946).
2. The streaming client falls back to non-streaming mode when the model
   returns `tool_calls` without emitting incremental deltas.
3. A per-cron `--llm-request-timeout-ms` flag is added that actually
   propagates to the HTTP fetch layer.

**Retest plan when unblocked:**

1. `ollama pull gemma4:e2b-it-q8_0` (already pulled as of 2026-04-08).
2. Pin it as the local fallback in
   [`templates/openclaw.json.template`](templates/openclaw.json.template)
   and [`defaults/models.policy.json`](defaults/models.policy.json), with
   `reasoning: false` and `maxTokens: 8192`.
3. Set `OLLAMA_KEEP_ALIVE=-1` in
   `~/Library/LaunchAgents/homebrew.mxcl.ollama.plist` so the model stays
   warm across requests.
4. Repoint `nightly-auth-health` and `cascade-detect` in
   [`scripts/setup-crons.sh`](scripts/setup-crons.sh) from
   `$MODEL_LIGHT` to `ollama/gemma4:e2b-it-q8_0`.
5. Run each cron via `./oc cron run <id>` and verify the script actually
   executed (notification file lands in
   `config/notifications/{low,medium,critical}/`) and the run summary
   does not contain a `<function=exec>` hallucination.

**Last verified blocked:** 2026-04-08 against OpenClaw 2026.4.5
(`3e72c03`), Mac Studio M3 with 96 GB unified memory, Ollama 0.20.2.
Direct `/v1/chat/completions` with `gemma4:e2b-it-q8_0` warm: 2.1s for
9.5K prompt tokens. OpenClaw cron with the same model warm and the same
input size: 60.6s timeout, every attempt.
