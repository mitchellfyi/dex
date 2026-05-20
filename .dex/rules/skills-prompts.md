# Skills, Agents, Guards & Prompt Conventions

## Skills

Each skill lives in `skills/<name>/SKILL.md` with markdown content.

- Directory naming: lowercase, `dx`-prefixed (`dxplan`, `dximplement`, etc.)
- Exceptions: the orchestrator is `dex`; the writing pass is `humanizer`
- Reference shared prompts via `@prompts/<file>.md` import syntax
- Skills are codebase-agnostic — they discover toolchains at runtime
- Skills auto-discovered after symlink via `dx install`

Use the `humanizer` skill whenever writing or editing copy, documentation,
ticket bodies, PR descriptions, GitHub/tracker comments, review replies,
user-facing messages, code comments, or doc comments. Preserve technical
identifiers, commands, paths, markdown structure, and required attribution while
removing AI-sounding filler.

## Agents

Agents live in `agents/*.md` with YAML frontmatter:
```yaml
---
name: agent-name
description: what it does
tools: Read, Glob, Grep, Bash
model: opus
skills:
  - dxreview
memory: project
---
```

## Guards

Guards are markdown files with YAML frontmatter in `hooks/guards/` (built-in) or `.dex/guards/` (project-specific).

```yaml
---
name: unique-guard-name
enabled: true
event: bash|file|commit|all
pattern: python-regex
action: warn|block
case_sensitive: false
---
```

- Patterns are Python regexes evaluated by `guard-handler.py`
- `block` exits with code 2 (prevents tool call). `warn` exits 0 (allows it)
- Frontmatter parser is regex-based — flat `key: value` only, no nested objects or arrays
- Built-in guards: `claude-attribution`, `destructive-commands`, `hardcoded-secrets`, `raw-codex-delegation`, `sensitive-files` — don't duplicate these

## Prompts

Stored in `prompts/`. Referenced by skills/agents via `@prompts/<file>.md`.

- `guardrails.md` — Implementation discipline
- `review.md` — 12-pass review criteria (A-L) with confidence scoring
- `commit-format.md` — Conventional Commits specification
- `pr-description.md` — PR description template
- `ticket-instructions.md` — Ticket intake workflow (injected by SessionStart hook)
- `init-analysis.md` — Codebase analysis prompt (used by `dx init`)
- `phase-audits/*.md` — Numbered 1-6 matching lifecycle phases, plus `prompt-loop.md`
