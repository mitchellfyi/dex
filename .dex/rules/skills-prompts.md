# Skills, Agents, Guards & Prompt Conventions

## Skills

Each skill lives in `skills/<name>/SKILL.md` with markdown content.

- Directory naming: lowercase, `dx`-prefixed (`dxplan`, `dximplement`, etc.)
- Exceptions: the orchestrator is `dex`; the writing pass is `humanizer`
- Reference shared prompts by plain repo-relative path (`prompts/<file>.md`)
- Skills are codebase-agnostic — they discover toolchains at runtime
- Skills auto-discovered after symlink via `dx install`

Use the `humanizer` skill whenever writing or editing copy, documentation,
ticket bodies, PR descriptions, GitHub/tracker comments, review replies,
user-facing messages, code comments, or doc comments. Preserve technical
identifiers, commands, paths, markdown structure, and required attribution while
removing AI-sounding filler.

## Guards

Guards are markdown files with YAML frontmatter in `hooks/guards/` (built-in) or `.dex/guards/` (project-specific).

```yaml
---
name: unique-guard-name
enabled: true
event: bash|file|commit|all
pattern: python-regex
detector: optional-built-in-detector
action: warn|block
match: all|path
case_sensitive: false
allow_pattern: optional-python-regex
env_var: OPTIONAL_ENV_NAME
env_value: optional-exact-value
---
```

- Patterns are Python regexes evaluated by `guard-handler.py`
- `block` exits with code 2 (prevents tool call). `warn` exits 0 (allows it)
- Frontmatter parser is regex-based — flat `key: value` only, no nested objects or arrays
- Built-in guards (by `name:`): `block-claude-attribution`, `block-destructive-commands`,
  `block-raw-codex-delegation`, `block-review-assessment-bash`,
  `block-review-assessment-file-edits`, `warn-await-in-loop`,
  `warn-hardcoded-secrets`, `warn-sensitive-files` — don't duplicate these

## Prompts

Stored in `prompts/`. Referenced by skills by plain repo-relative path
(`prompts/<file>.md`).

- `guardrails.md` — Implementation discipline
- `review.md` — 12-pass review criteria (A-L) with confidence scoring
- `commit-format.md` — Conventional Commits specification
- `pr-description.md` — PR description template
- `ticket-instructions.md` — Ticket intake workflow (injected by SessionStart hook)
- `init-analysis.md` — Codebase analysis prompt (used by `dx init`)
- `phase-audits/*.md` — Numbered 1-6 matching lifecycle phases, plus `prompt-loop.md`
