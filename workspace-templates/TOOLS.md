# TOOLS.md - Local Notes

Skills define how tools work. This file records local runtime details for this OpenClaw sandbox.

## Runtime Model Notes

Update this section when `/home/node/.openclaw/openclaw.json` changes. On the host, that live config is the bind-mounted `config/openclaw.json`; `defaults/models.policy.json` is only an input to the render pipeline.

- Default primary model: `google/gemini-2.5-flash`
- Fallback chain:
  1. `openai-codex/gpt-5.4`
  2. `openai/gpt-5.4`
  3. `anthropic/claude-sonnet-4-6`
  4. `anthropic/claude-opus-4-6`
  5. `ollama/qwen3.6:35b-a3b-q8_0`
  6. `ollama/nemotron-3-super:120b-a12b-q4_K_M`
- Local monitoring cron model: `ollama/qwen3.6:35b-a3b-q8_0`
- Configured model alias outside the fallback chain: `github-copilot/gpt-4o` (Copilot GPT-4o)
- Tool-specific image, video, and music model overrides: none defined in `/home/node/.openclaw/openclaw.json` (host `config/openclaw.json`).
- Source of truth: `./oc config get agents.defaults.model`, `./oc config get agents.defaults.models`, `./oc config get tools`, and `defaults/model-routing.json`.

## Local Inventory

Add environment-specific notes here as they become known:

- Camera names and locations
- SSH hosts and aliases
- Preferred voices for TTS
- Speaker/room names
- Device nicknames
