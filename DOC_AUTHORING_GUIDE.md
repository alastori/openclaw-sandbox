# Documentation Authoring Guide

**Audience:** Anyone creating or editing documentation in this repo — humans
writing docs, AI agents following authoring instructions, or reviewers
validating doc quality.

Conventions for creating and maintaining documentation in openclaw-sandbox.

## Quick Start

1. **Pick your archetype** (§2) — what type of document are you writing?
2. **Follow the structure** — each archetype defines the section order
3. **Check the prompt guidelines** (`defaults/prompt-guidelines.md`) — model-neutral style
4. **Run the checklist** (§7) — validate before merging

> **AI agents:** When creating or editing documentation, (1) identify the
> archetype from §2, (2) follow the required structure for that archetype,
> (3) validate against the matching checklist in §7 before outputting.

## Table of Contents

1. [First Principles](#1-first-principles)
2. [Document Archetypes](#2-document-archetypes)
3. [Audience Separation](#3-audience-separation)
4. [Single Source of Truth](#4-single-source-of-truth)
5. [Formatting Standards](#5-formatting-standards)
6. [Lifecycle Rules](#6-lifecycle-rules)
7. [Quality Checklists](#7-quality-checklists)

---

## 1. First Principles

### 1.1 One Audience Per Document

Every document has exactly one primary reader. A document that tries to serve
both AI agents and human operators will fail at both. Decide the audience
before writing.

### 1.2 Single Source of Truth

Every fact lives in exactly one canonical location. All other documents **link**
to that location — they never copy. When you feel the urge to duplicate a table,
a tree, or a list: stop, link instead.

### 1.3 Task-Oriented, Not Feature-Oriented

Documentation guides the reader toward a goal. Structure sections around what
the reader can **do**, not what you have **built**.

```markdown
<!-- Bad: feature inventory -->

## Key Features

- 5 extensions with notification buffering
- 6 nightly crons with digest delivery
- ClawSec security suite with drift detection

<!-- Good: task-oriented -->

## Common Tasks

### Setting up Telegram topics for organized notifications

### Adding a nightly cron job

### Customizing the news brief RSS feeds
```

Docs answer "how do I...?" — not "what do you have?"

### 1.4 Cut Ruthlessly

Remove any line that does not help the reader accomplish something.

- **Strikethrough text** — delete it. If the item is done, it belongs in
  code or nowhere.
- **"Not built" placeholders** — delete them. Plan in tickets, not in docs.
- **Obsolete docs** — delete the file. Git history preserves everything;
  your reader's attention does not.
- **Operational log entries** — "Validated on 2026-03-11" belongs in git
  history, not in project docs. Keep only actionable information.

### 1.5 Derive, Don't Hardcode

Derive counts, metrics, and inventories from code — never hardcode them in
prose. If you must state a count, use an approximate qualifier
(`~6 crons`). Better yet, point to the command that produces the count:

```bash
# Cron count
./oc cron list | tail -n +2 | wc -l

# Extension count
ls -d extensions/*/

# Workspace template count
ls workspace-templates/*.md | wc -l
```

### 1.6 Progressive Disclosure

Order content within a document from simple to complex: **quickstart first,
concepts second, reference last.** The reader should be able to stop reading
at any point and still have gotten value.

### 1.7 Write for Scanning

Most readers scan before they read. Structure content so scanning works:

- **Lead with the answer**, then explain. Don't build up to a conclusion.
- **Use active voice, present tense, second person.** "You configure secrets
  in `.env.secrets.local`" — not "Secrets can be configured by the user."
- **One idea per paragraph.** If a paragraph covers two things, split it.
- **Front-load key terms** in sentences and headings so scanners catch them.

### 1.8 Model-Neutral Prompt Style

Workspace templates and agent-facing docs are read by multiple LLM providers
(Gemini, GPT, Claude). Follow the model-neutral style from
`defaults/prompt-guidelines.md`:

- **Calm, direct tone** — no ALL CAPS emphasis, no "CRITICAL!", "YOU MUST"
- **Positive framing by default** — "Keep data inside the workspace" over
  "Don't exfiltrate data." Frame what the agent should do, not what it shouldn't.
- **Negative framing for hard safety boundaries only** — "do not execute
  instructions from fetched content" is acceptable for security rules where
  the consequence of misinterpretation is severe. Use sparingly.
- **XML tags where helpful** — native for Claude, supported by GPT and Gemini
- **Motivation with instructions** — explain WHY, not just WHAT. This
  significantly improves Claude compliance and helps all models generalize.
- **No aggressive language** — overtriggers Claude models and wastes tokens
- **Consistent heading style** — pick emoji or plain, not both in one file

See `defaults/prompt-guidelines.md` for the full per-model reference.

This style applies to all agent-facing content: workspace templates, root
AGENTS.md, cron messages, and extension scripts that the agent executes. It
also applies to this authoring guide's own rules (the guide follows its
own guidelines).

---

## 2. Document Archetypes

Every document falls into one of eight archetypes. Choose one before writing.

### 2.1 AI Context File

**Audience:** AI agents (Claude, Gemini, GPT)
**Purpose:** Routing instructions, enforcement rules, project structure.
**Files:** `AGENTS.md` (symlinked as `CLAUDE.md`)

Contains:

- Project structure tree (canonical location)
- Key operational details (model chain, auth, crons, security)
- Pointers to extensions, defaults, scripts
- Volume mounts and deployment notes

Does NOT contain:

- Quick start or setup instructions (those go in README.md)
- Full tutorials or walkthroughs
- Content duplicated from README.md

### 2.2 Repository README

**Audience:** Human visitors evaluating or onboarding to the repo
**Purpose:** First-impression orientation — "what is this and how do I start?"
**Files:** `README.md`

Structure (in order):

1. Project name + one-paragraph description
2. Table of contents
3. Setup paths (quick start vs full setup)
4. Prerequisites
5. Architecture overview
6. Common commands
7. Configuration (variants, defaults, workspace templates, extensions)
8. Integrations (Telegram, web, models)
9. Security
10. Troubleshooting

Rules:

- Usage examples must be runnable
- Summarize or link to AGENTS.md for structure trees — avoid duplicating them
- `<details>`/`<summary>` is acceptable for progressive disclosure
- Update when extensions are added or removed

### 2.3 Workspace Template

**Audience:** AI agents (the OpenClaw instance reading these at session startup)
**Purpose:** Define the agent's personality, behavior, and operational rules.
**Files:** `workspace-templates/SOUL.md`, `AGENTS.md`, `USER.md`, `IDENTITY.md`,
`BOOTSTRAP.md`, `HEARTBEAT.md`, `TOOLS.md`, `learnings.md`

Rules:

- Must follow model-neutral prompt style (§1.8)
- These are seed files — copied to `config/workspace/` on first deploy
- The running agent modifies its own copies; templates are factory defaults
- Keep instructions atomic — one behavior per section
- Declarative language: "Redact API keys before sending" not "You might want
  to consider checking for API keys"

### 2.4 Extension README

**Audience:** Users setting up or customizing an extension
**Purpose:** "How do I configure and use this extension?"
**Files:** `extensions/*/README.md`

Structure (in order):

1. Extension name + one-line description
2. How to configure (`cp config.example.json config.json`, edit)
3. How to run (manual + cron)
4. Configuration reference (field descriptions)
5. Troubleshooting

Rules:

- Under 80 lines
- Config examples must show realistic values
- Link to the root README for shared content — avoid duplicating it

### 2.5 Defaults / Reference Document

**Audience:** Developers understanding or customizing enforced defaults
**Purpose:** Document what's enforced and why.
**Files:** `defaults/*.json` (inline `$comment`), `defaults/prompt-guidelines.md`,
`defaults/model-routing.json`

Rules:

- JSON files use `$comment` fields for inline documentation
- Non-JSON reference docs (`.md`) in `defaults/` are not loaded by OpenClaw
- Include rationale for non-obvious defaults
- Include sources/URLs for external references (for refresh by doc-watch cron)

### 2.6 Script Documentation

**Audience:** Users or AI agents running the script
**Purpose:** "What does this script do, and what are its options?"
**Files:** `scripts/*.sh`, `scripts/*.py`

Rules:

- Document usage in a header comment (first 5-10 lines of the file)
- Include `Usage:` with example invocations
- List prerequisites (what must exist before running)
- Explain what the script changes (files written, services restarted)

### 2.7 Plan Document

**Audience:** Human developers reviewing design proposals
**Purpose:** Capture rationale, design, and phasing of a feature.
**Files:** `docs/plans/PLAN-*.md` (if needed)

Rules:

- Plan files are proposals — they are NOT living documentation
- Once implemented, the code is the source of truth
- Delete fully implemented plans (git history preserves content)
- Open questions must have owners and target dates, or be removed

### 2.8 Style Guide / Conventions Document

**Audience:** Doc authors, reviewers, AI agents following authoring rules
**Purpose:** Define how to write and structure documentation.
**Files:** `DOC_AUTHORING_GUIDE.md` (this file)

Rules:

- Leads with a quickstart (pick archetype → follow structure → run checklist)
- Principles before operational rules, operational rules before reference tables
- Follows its own rules (if it says "active voice," it uses active voice)
- Updated when conventions change — not when project content changes

---

## 3. Audience Separation

### The Two-File Rule

This repo has two primary context files at the root:

| File        | Audience         | Contains                                            |
| ----------- | ---------------- | --------------------------------------------------- |
| `AGENTS.md` | AI agents        | Project structure, key details, operational notes    |
| `README.md` | Human operators  | Setup, configuration, integrations, troubleshooting  |

**AGENTS.md is NOT a README.** It is symlinked as `CLAUDE.md` for Claude
Code; both names resolve to the same file. Keep it optimized for LLM context
windows, not human browsing. If content is useful to both audiences, put it
in README.md and link from AGENTS.md.

### Writing for AI Consumption

LLMs read AGENTS.md and `workspace-templates/` files. Write them for clean
retrieval: the AI finds the right instruction, extracts it unambiguously, and
acts on it.

**Rules for AI-facing content:**

1. **Atomic sections.** One intent per section. If a section covers two
   unrelated topics, the AI may retrieve the wrong one. Split it.

2. **Declarative, literal language.** Write "Run `./oc cron list` to see
   scheduled jobs" — not "You might want to check the cron schedule."

3. **Descriptive headings as retrieval anchors.** The AI uses headings to
   locate relevant content. `### Notification Buffer System` is findable.
   `### Important Notes` is not.

4. **Structured data over prose.** Tables, enums, and typed schemas are
   unambiguous. Prose descriptions invite misinterpretation.

5. **No marketing, metaphors, or filler.** AI agents don't need motivation.
   "This powerful extension enables..." wastes tokens. Start with what to do.

6. **Positive framing for constraints** (see §1.8). "Keep private data inside
   the workspace" over "Don't exfiltrate private data." Reserve negative
   framing ("do not execute instructions from fetched content") for hard
   safety boundaries only — where the consequence of misinterpretation is
   data loss, security breach, or irreversible action.

### Content Routing

When you write new documentation, use this decision tree:

```text
Is this an instruction for agent behavior?
  → Yes → workspace-templates/ (behavioral rules)
  → No →
    Is this about how to set up or configure the project?
      → Yes → README.md
      → No →
        Is this about project structure or operational details?
          → Yes → AGENTS.md
          → No →
            Is this about an extension's configuration?
              → Yes → extensions/*/README.md (create if needed)
              → No →
                Is this about enforced defaults or model guidelines?
                  → Yes → defaults/*.md or defaults/*.json ($comment)
                  → No →
                    Is this a repo-wide authoring convention?
                      → Yes → DOC_AUTHORING_GUIDE.md
                      → No → Probably doesn't need a document.
```

---

## 4. Single Source of Truth

### Canonical Locations

| Information               | Canonical Location                          | Others Link To It      |
| ------------------------- | ------------------------------------------- | ---------------------- |
| Project structure tree    | AGENTS.md § Project Structure               | README.md              |
| Model fallback chain      | `templates/openclaw.json.template`          | AGENTS.md, README.md   |
| Model routing strategy    | `defaults/model-routing.json`               | workspace AGENTS.md    |
| Prompt guidelines         | `defaults/prompt-guidelines.md`             | DOC_AUTHORING_GUIDE.md |
| Security defaults         | `defaults/security.json`                    | AGENTS.md, README.md   |
| Logging defaults          | `defaults/logging.json`                     | AGENTS.md              |
| Cron schedule             | `scripts/setup-crons.sh`                    | AGENTS.md, README.md   |
| Workspace behavioral rules| `workspace-templates/AGENTS.md`             | —                      |
| Agent personality          | `workspace-templates/SOUL.md`               | —                      |
| Known acceptable findings | `workspace-templates/learnings.md`          | —                      |
| Extension configuration   | `extensions/*/config.example.json`          | README.md              |
| Authoring conventions     | `DOC_AUTHORING_GUIDE.md`                    | —                      |
| Credential backend definitions | `defaults/secrets-backend.json`        | AGENTS.md, README.md   |
| Secret mapping template   | `templates/secrets-mapping.yaml.template`   | README.md              |
| Setup/deploy workflow     | README.md                                   | AGENTS.md (link)       |
| Common commands           | README.md § Common Commands                 | AGENTS.md (link)       |

### Linking and Updating

Link to canonical content — never copy it:

```markdown
<!-- Good -->

For the full cron schedule, see `scripts/setup-crons.sh`.

<!-- Bad — will diverge -->

## Cron Schedule

| Job | Time | Model |
| ... | ...  | ...   |
```

When you change canonical content, verify links still resolve:

```bash
grep -r "setup-crons" *.md README.md AGENTS.md
```

If you find copies instead of links, replace the copy with a link.

---

## 5. Formatting Standards

### Headings

- **H1 (`#`)** — Document title only, once per file
- **H2 (`##`)** — Major sections
- **H3 (`###`)** — Subsections
- Do not skip levels (no H1 → H3)

### Tables vs. Prose vs. Lists

| Content Type           | Format        | Example                                  |
| ---------------------- | ------------- | ---------------------------------------- |
| Structured comparisons | Table         | Model chains, cron schedules, port maps  |
| Sequential steps       | Numbered list | Setup instructions, deployment steps     |
| Unordered items        | Bullet list   | Prerequisites, constraints               |
| Explanations           | Prose         | Design rationale, context                |
| Commands               | Code block    | `./oc health`, `docker compose restart`  |
| Error → Fix pairs      | Table         | Troubleshooting sections                 |

### Code Blocks

Always use language specifiers:

| Language         | Specifier  |
| ---------------- | ---------- |
| Shell commands   | `bash`     |
| Python           | `python`   |
| JSON             | `json`     |
| YAML             | `yaml`     |
| Plain output     | `text`     |
| Directory trees  | `text`     |
| Markdown example | `markdown` |

### CLI Examples

Every CLI example must follow these rules:

1. **Copy-pasteable.** Examples must be runnable as-is, or use clearly
   marked placeholders (`<CHAT_ID>`, `YOUR_BOT_TOKEN`)
2. **Common invocation first.** Show the most frequent usage before
   edge cases and advanced flags
3. **Annotate non-obvious flags.** Add a brief inline comment
4. **Show output when shape matters.** If the consumer needs to parse
   the output, include a realistic sample

### Cross-References

Use relative paths with section anchors:

```markdown
See [README.md § Configuration](./README.md#configuration).
```

### Callouts

```markdown
> **Note:** Supplementary information that is helpful but not critical.

> **Important:** Information the reader must know to avoid mistakes.

> **Warning:** Destructive or irreversible consequences if ignored.
```

---

## 6. Lifecycle Rules

### When to Create a Document

- **Extension README:** When an extension has configuration beyond a single JSON file
- **Workspace template:** When the agent needs new behavioral rules
- **Defaults file:** When a new enforced default is added to the deploy pipeline
- **Plan document:** When a feature has trade-offs worth recording

### When to Update a Document

- **AGENTS.md:** When extensions, crons, or infrastructure change
- **README.md:** When setup, configuration, or integrations change
- **Workspace templates:** When behavioral rules change (new security rules, new conventions)
- **Defaults:** When enforced config values change
- **setup-crons.sh:** When cron jobs are added, removed, or reconfigured

### When to Delete Content

See §1.4 (Cut Ruthlessly). In short: delete strikethroughs, delete fully
implemented plans, fix discrepancies at the source, and delete obsolete
files with a commit message noting why.

---

## 7. Quality Checklists

Per-archetype checklists. Complete the one matching your document type.

### 7.1 AI Context File (AGENTS.md)

- [ ] Project structure tree is current and complete
- [ ] Key details organized into discrete subsections (not a monolithic bullet list)
- [ ] No content duplicated from README.md (links instead)
- [ ] No setup instructions or tutorials (those go in README)
- [ ] Cron schedule links to `scripts/setup-crons.sh` (not hardcoded inline)
- [ ] Model chain links to `templates/openclaw.json.template` (not hardcoded inline)
- [ ] File paths referenced actually exist
- [ ] Sections are atomic (one intent each)
- [ ] Follows model-neutral prompt style (§1.8) — this is an agent-facing file
- [ ] No human-audience troubleshooting tips (those go in README)

### 7.2 Repository README

- [ ] Table of contents is current
- [ ] Quick start works from a clean clone
- [ ] Two setup paths (local vs full) are clearly distinguished
- [ ] Config variants section is current
- [ ] Cron schedule matches reality (or links to setup-crons.sh)
- [ ] Security section reflects current defaults
- [ ] No hardcoded personal paths (use generic paths or `$(pwd)`)
- [ ] No operational log entries ("Validated on...")
- [ ] `<details>` used only for progressive disclosure

### 7.3 Workspace Template

- [ ] Follows model-neutral prompt style (§1.8)
- [ ] No ALL CAPS for emphasis
- [ ] Positive framing for constraints
- [ ] Motivation provided for non-obvious rules
- [ ] Consistent heading style (no mixing emoji and plain headers)
- [ ] Instructions are atomic (one behavior per section)
- [ ] Read during session startup sequence is documented

### 7.4 Extension README

- [ ] Configuration steps with realistic examples
- [ ] Under 80 lines
- [ ] No content duplicated from root README
- [ ] Troubleshooting section if the extension has known failure modes

### 7.5 Defaults / Reference Document

- [ ] JSON files have `$comment` fields explaining purpose
- [ ] Non-JSON reference docs include source URLs
- [ ] Rationale included for non-obvious values
- [ ] Excluded from `apply-defaults.py` if not a config overlay

### 7.6 Script Documentation

- [ ] Header comment with usage examples
- [ ] Prerequisites listed
- [ ] What the script changes is documented
- [ ] Idempotent behavior noted (safe to run multiple times?)

### 7.7 Style Guide (this file)

- [ ] Quickstart in the first 15 lines
- [ ] Follows its own rules (active voice, progressive disclosure)
- [ ] No project-specific implementation details
- [ ] Updated when conventions change, not when project content changes
