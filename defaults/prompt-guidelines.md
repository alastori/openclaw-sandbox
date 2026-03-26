# Prompt Guidelines by Model

Reference for writing effective prompts across the models in this stack.
Not loaded by OpenClaw — this is documentation for humans and for crons
that optimize or audit workspace prompts.

Sources:

Anthropic (Claude):
- Prompting best practices: https://platform.claude.com/docs/en/build-with-claude/prompt-engineering/claude-prompting-best-practices
- What's new in Claude 4.6: https://platform.claude.com/docs/en/about-claude/models/whats-new-claude-4-6
- Migration guide (4.5 → 4.6): https://platform.claude.com/docs/en/about-claude/models/migration-guide
- Interactive prompt tutorial: https://github.com/anthropics/prompt-eng-interactive-tutorial
- Prompt engineering overview: https://docs.anthropic.com/en/docs/build-with-claude/prompt-engineering/overview

OpenAI (GPT-5.4):
- Prompt guidance for GPT-5.4: https://developers.openai.com/api/docs/guides/prompt-guidance
- GPT-5 prompting guide (cookbook): https://cookbook.openai.com/examples/gpt-5/gpt-5_prompting_guide
- Codex prompting guide: https://developers.openai.com/cookbook/examples/gpt-5/codex_prompting_guide
- Prompt engineering guide: https://platform.openai.com/docs/guides/prompt-engineering

Google (Gemini):
- Prompting strategies: https://ai.google.dev/gemini-api/docs/prompting-strategies
- Gemini 3 prompting guide (Vertex AI): https://docs.cloud.google.com/vertex-ai/generative-ai/docs/start/gemini-3-prompting-guide

## Universal Principles (work across all models)

- Be clear, direct, and specific. State the goal upfront.
- Use structured formatting (XML tags or consistent markdown).
- Provide 3-5 few-shot examples for format-sensitive tasks.
- Place long context/documents first, instructions last.
- Give motivation ("why") alongside instructions ("what").
- Prefer positive framing ("do X") over negative ("don't do Y").
- Define explicit completion criteria ("done means...").

## Model-Specific Differences

### Claude (Opus 4.6 / Sonnet 4.6)

**Tone:**
- Calm, direct language. No aggressive emphasis.
- ALL CAPS, "CRITICAL!", "YOU MUST", "NEVER EVER" actively hurt performance.
  Use normal language: "Use this tool when..." instead of "CRITICAL: You MUST use this tool when..."
- Positive framing strongly preferred. Instead of "Do not use markdown" →
  "Your response should be flowing prose paragraphs."

**Structure:**
- XML tags are native — Anthropic trains on them internally. Use `<instructions>`,
  `<context>`, `<example>` tags for unambiguous parsing.
- Giving context/motivation behind rules significantly improves compliance
  ("never use ellipses because TTS can't pronounce them").

**Tool use:**
- Opus 4.6 overtriggers on aggressive tool prompts designed for older models.
  Remove "If in doubt, use [tool]" — the model already triggers appropriately.
- Naturally orchestrates sub-agents without explicit instruction.
  Add guardrails to reduce overuse, not encourage it.

**Thinking:**
- Uses adaptive thinking. Do NOT prompt "think step by step" — use the
  effort parameter instead. Prompting to think harder adds latency without benefit.
- "Think thoroughly" produces better reasoning than prescriptive step-by-step plans.

**Avoid:**
- Prefilled responses (deprecated in 4.6)
- Over-prompting thoroughness (model is already proactive)
- "NEVER EVER" style constraints (overtriggers safety behavior)

### GPT-5.4

**Tone:**
- Structured, contract-like prompting works best.
- Explicit negative constraints are effective: "Never skip prerequisite tool calls",
  "Do not parallelize tool calls with dependencies."
- ALL CAPS is acceptable but not required.

**Structure:**
- XML tags for modular rule isolation: `<output_contract>`, `<tool_persistence_rules>`,
  `<completeness_contract>`, `<verification_loop>`.
- Define explicit instruction priority: "User instructions override default style,
  tone, formatting, and initiative preferences."
- CTCO pattern not officially endorsed despite community adoption.

**Tool use:**
- Explicit persistence rules: tell the model when to call tools and when to stop.
- Completeness contracts prevent premature stopping on multi-step tasks.
- Smaller models (mini, nano) need more explicit step-by-step scaffolding.

**Thinking:**
- Reasoning effort is a parameter, not a prompt concern.
- Saying "think hard about this" literally triggers the reasoning model —
  avoid unless you want that behavior.
- Increase reasoning effort LAST, after improving the prompt itself.

**Avoid:**
- Vague success criteria (model needs explicit "done" definition)
- Mixing reasoning-effort prompts with the effort parameter
- Assuming parallel tool calls are safe (explicit dependency declarations needed)

### Gemini (2.5 Flash / 3.1 Pro)

**Tone:**
- Precision over persuasion. Direct, well-structured, no fluff.
- By default provides minimal/direct answers — explicitly request detail
  or conversational style when needed.
- Avoid overly broad negatives. Instead of "do not infer" →
  "perform calculations based strictly on provided text."

**Structure:**
- XML tags recommended (`<context>`, `<task>`, `<role>`, `<constraints>`).
- Markdown headings acceptable but less preferred.
- Do NOT mix XML and markdown in the same prompt.
- Place core requests and critical constraints as the LAST lines of instructions.
- Few-shot examples are critical — "prompts without few-shot examples are
  likely to be less effective."

**Tool use:**
- Context-first, instructions-last ordering.
- Use bridging phrases after large data blocks: "Based on the information above..."
- For grounded tasks: "You are a strictly grounded assistant limited to
  the information provided."

**Thinking:**
- For complex tasks, prompt to "plan or self-critique before providing
  the final answer."
- Explicit validation: "review your generated output against the user's
  original constraints."
- Set thinking level to LOW and "think silently" for latency-sensitive tasks.

**Avoid:**
- Changing temperature from default 1.0 (causes looping/degraded performance)
- Assuming verbose output (model defaults to terse — ask for detail explicitly)
- Inconsistent formatting in few-shot examples (model is sensitive to whitespace)

## Model-Neutral Style (default for this project)

The workspace templates in this project follow a model-neutral style that
works across all three providers:

1. **Calm, direct tone** — works for Claude (required), GPT (acceptable), Gemini (preferred)
2. **Positive framing** — works for Claude (required), GPT (acceptable), Gemini (acceptable)
3. **XML tags where helpful** — native for Claude, supported by GPT and Gemini
4. **Motivation with instructions** — helps Claude significantly, doesn't hurt others
5. **No ALL CAPS emphasis** — required for Claude, neutral for others
6. **Explicit completion criteria** — helps GPT significantly, good practice for all

This style accepts a small effectiveness loss on GPT (which tolerates aggressive
language) in exchange for working well everywhere. For power users running a
dedicated GPT topic, consider adding explicit negative constraints and
contract-style output definitions — GPT responds well to those.

## Applying These Guidelines

### For workspace templates (SOUL.md, AGENTS.md, etc.)
Use the model-neutral style. These files are read by whichever model is
active in the session. They must work across all providers.

### For cron messages
Match the style to the model assigned to the cron:
- Gemini Flash crons: direct, minimal, structured
- Codex GPT crons: can use explicit negative constraints and contracts
- Opus crons (if any): calm, positive, give motivation

### For per-topic optimization
If a Telegram topic is always used with one model (e.g., Coding with GPT-5.4),
the user can add topic-specific instructions that match that model's style.
This is a power-user optimization, not a default.
