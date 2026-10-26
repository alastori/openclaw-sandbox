# TOOLS.md - Local Notes

Skills define how tools work. This file records local runtime details for this OpenClaw sandbox.

## Runtime Model Notes

Update this section when `/home/node/.openclaw/openclaw.json` changes. On the host, that live config is the bind-mounted `config/openclaw.json`; `defaults/models.policy.json` is only an input to the render pipeline.

- Default primary model: `google/gemini-2.5-flash` (alias: Gemini 2.5 Flash)
- Fallback chain:
  1. `openai-codex/gpt-5.4` (alias: GPT-5.4 Codex)
  2. `openai/gpt-5.4` (alias: GPT-5.4 API)
  3. `anthropic/claude-sonnet-4-6` (alias: Sonnet 4.6)
  4. `anthropic/claude-opus-4-6` (alias: Opus 4.6)
  5. `ollama/qwen3.6:35b-a3b-q8_0` (alias: Qwen 3.6 Local)
  6. `ollama/nemotron-3-super:120b-a12b-q4_K_M` (alias: Nemotron 3 Super Local)
- Monitoring crons run scripts as command payloads. They do not require a model. The host sandbox repo defines their payloads in `scripts/setup-crons.sh`.
- Configured model alias outside the fallback chain: `github-copilot/gpt-4o` (Copilot GPT-4o)
- Tool-specific image, video, and music model overrides: none defined in `/home/node/.openclaw/openclaw.json` (host `config/openclaw.json`).
- Inspect live values in `/home/node/.openclaw/openclaw.json`. On the host, use `./oc config get agents.defaults.model`, `./oc config get agents.defaults.models`, and `./oc config get tools`.
- The routing reference `defaults/model-routing.json` lives in the host sandbox repo. It is not mounted into the active workspace.

## Governance And Tool Security

These values describe the tracked full-setup defaults. Check the live config before treating them as runtime facts.

- Context budget: `agents.defaults.contextTokens=50000`.
- Compaction: `agents.defaults.compaction.mode=safeguard`.
- Elevated tools are disabled.
- Loop detection thresholds: warning `10`, critical `20`, global circuit breaker `30`.
- Exec timeout: `120s`.
- Ollama provider denies `web_search`, `web_fetch`, and `browser_navigate`.

## Plugins And Skills

The full runtime template enables `telegram` and `copilot-proxy`. It loads extra skills from `/home/node/skills`. The Docker image installs the ClawSec suite there. Check the live config and installed files when auditing an existing deployment.

## Local Inventory

Add environment-specific notes here as they become known:

- Camera names and locations
- SSH hosts and aliases
- Preferred voices for TTS
- Speaker/room names
- Device nicknames
