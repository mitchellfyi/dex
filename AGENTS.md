# AGENTS.md

Instructions for AI coding agents working on the Doyaken codebase.

## What Is Doyaken

Doyaken is a standalone workflow automation framework for Claude Code. It provides autonomous ticket lifecycle management — from planning through PR merge — using worktree isolation, quality-gated phase execution, and codebase-agnostic skill discovery. It works with any repo after a one-time global install.

## Tech Stack

- **Shell (primary):** All CLI logic, hooks, and library code
  - `dk.sh` — **zsh-only** (sourced in `~/.zshrc`, uses zsh syntax like `${(j: :)@}`)
  - `hooks/*.sh` — **bash** (`#!/usr/bin/env bash`)
  - `lib/*.sh` — **bash/zsh-compatible** (sourced by both dk.sh and hooks)
- **Python 3 (stdlib only):** `hooks/guard-handler.py` — guard evaluation, no external dependencies
- **Markdown + YAML frontmatter:** Skills, agents, guards, prompts, rules

## Directory Structure

```
agents/              Sub-agents (symlinked to ~/.claude/agents/)
bin/                 CLI scripts (install, init, config, status, etc.)
docs/                Extended documentation (guards, autonomous mode, UI capture)
hooks/               Claude Code hooks + guard handler
  guards/            Built-in guard rules (markdown with YAML frontmatter)
lib/                 Shared shell libraries (common, codex, git, output, provider, session, ui-capture, worktree)
prompts/             Prompt templates for skills/agents
  phase-audits/      Phase-specific audit prompts (1-6 + prompt-loop)
scripts/             Node/helpers used by Doyaken-managed tooling
skills/              Lifecycle skills (symlinked to ~/.claude/skills/ and individually to $CODEX_HOME/skills/)
dk.sh                Main shell functions (zsh only, ~1900 lines)
settings.json        Hook definitions template
install.sh           Quick-start installer (delegates to bin/install.sh)
```

Per-project (created by `dk init`):
```
.doyaken/
  doyaken.md         Project-specific config (tech stack, quality gates, integrations)
  AGENTS.md          @import of doyaken.md (generated context source of truth)
  CLAUDE.md          @import of AGENTS.md (Claude Code compatibility pointer)
  rules/             Coding conventions (generated from codebase analysis)
  guards/            Project-specific guard rules (generated)
  worktrees/         Worktree directories (gitignored, ephemeral)
```

## Shell Conventions

### Language boundaries — this is critical

Never introduce zsh-only syntax in `lib/` or `hooks/`. Only `dk.sh` may use zsh features.

### Error handling

All scripts use `set -euo pipefail`. Use early returns, not deep nesting.

### Naming

- **Functions:** `dk_` prefix (public), `__dk_` prefix (internal), snake_case
- **Variables:** `local` for locals, `SCREAMING_SNAKE_CASE` with `DOYAKEN_` or `DK_` prefix for env vars
- **Files:** kebab-case for scripts and directories

### Library sourcing

```bash
source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"
```

Sourcing `common.sh` also sources `git.sh`, `session.sh`, `output.sh`, `worktree.sh`, `provider.sh`, `codex.sh`, and `ui-capture.sh`.

### Output

Use `lib/output.sh` helpers (`dk_done`, `dk_ok`, `dk_warn`, `dk_skip`, `dk_info`, `dk_error`) for user-facing messages. Never raw `echo` for status output.

### Re-sourcing safety

In `dk.sh`, every function definition is preceded by `unalias <name> 2>/dev/null; unfunction <name> 2>/dev/null` so the file can be re-sourced without errors.

### Atomic file operations

When writing shared files (e.g., `~/.claude/settings.json`), use temp files + atomic `mv`.

### State files

All ephemeral state goes under `~/.claude/.doyaken-phases/` or `~/.claude/.doyaken-loops/`, keyed by session ID. Never store state inside the repo (except `.doyaken/worktrees/` which is gitignored).

## Skill Conventions

Each skill lives in `skills/<name>/SKILL.md` with YAML frontmatter containing `name` and `description`, followed by markdown instructions. Codex uses this metadata for skill discovery; Claude Code tolerates the same format.

- Directory naming: lowercase, `dk`-prefixed (`dkplan`, `dkimplement`, etc.)
- Exception: the orchestrator is `doyaken` (no prefix)
- Skills reference prompts via `@prompts/<file>.md` import syntax
- Skills are codebase-agnostic — they discover toolchains at runtime
- Claude gets skills via a single `~/.claude/skills -> $DOYAKEN_DIR/skills` symlink
- Codex gets skills via individual symlinks in `$CODEX_HOME/skills/<name>` (`CODEX_HOME` defaults to `~/.codex`) so Doyaken does not replace Codex system/plugin skills

### Vendor skills are NOT bundled

Doyaken does not ship third-party vendor skills (Figma, Asana, Linear, Notion, Slack, HubSpot, Microsoft 365, Gmail, Google Calendar, Fireflies, etc.). These are maintained by their vendors and distributed via Claude's official plugin/MCP integrations.

**Do not commit vendor skills into this repo.** If a vendor skill directory appears in `skills/` (e.g., `skills/figma-*/`), delete it — it was added by a Claude plugin install and should live in the user's `~/.claude/` or be enabled via the official integration, not in Doyaken.

When users need a vendor skill:

| Vendor | How to enable |
|--------|---------------|
| Figma  | <https://help.figma.com/hc/en-us/articles/32132100833559-Guide-to-the-Dev-Mode-MCP-Server> |
| Linear | <https://linear.app/changelog/2025-05-01-mcp> |
| Asana, Notion, Slack, HubSpot, Microsoft 365, Gmail, Google Calendar, Fireflies | Enable the corresponding integration on <https://claude.ai/settings/connectors> |
| Other  | Browse the Claude plugin marketplace via `/plugin` inside Claude Code, or check the vendor's docs for their official MCP/skill integration |

The corresponding MCP servers are listed and authenticated through claude.ai or `claude mcp` — they show up as `mcp__claude_ai_<Vendor>__*` tools and are available to Doyaken's skills automatically when enabled.

## Agent Conventions

Agents live in `agents/*.md` with YAML frontmatter:

```yaml
---
name: agent-name
description: what it does
tools: Read, Glob, Grep, Bash    # allowed tools
model: opus                      # model selection
skills:
  - dkreview                      # skills it can invoke
memory: project                   # memory scope
---
```

## Guard Conventions

Guards are markdown files with YAML frontmatter in `hooks/guards/` (built-in) or `.doyaken/guards/` (project-specific).

```yaml
---
name: unique-guard-name
enabled: true
event: bash|file|commit|all
pattern: python-regex
detector: optional-built-in-detector
action: warn|block
case_sensitive: false
allow_pattern: optional-python-regex
env_var: OPTIONAL_ENV_NAME
env_value: optional-exact-value
---
```

- Patterns are Python regexes evaluated by `guard-handler.py`
- `detector` is optional; use only for built-in syntax-aware guard detectors
- `allow_pattern` is optional; use it only for narrow safe exceptions to a broader `pattern`
- `env_var`/`env_value` are optional; use them to scope a guard to a runtime mode
- `env_var: DK_PROVIDER_ENGINE` has a session-state/config fallback so provider-scoped guards do not depend only on hook environment inheritance
- `block` exits with code 2 (prevents tool call). `warn` exits 0 (allows it).
- Frontmatter parser is regex-based — flat `key: value` only, no nested objects or arrays
- Built-in guards: `claude-attribution`, `destructive-commands`, `raw-codex-delegation`, `sensitive-files`, `hardcoded-secrets` — don't duplicate these

## Prompt Conventions

Stored in `prompts/`. Referenced by skills/agents via `@prompts/<file>.md`.

- `guardrails.md` — Implementation discipline (shared across implement/review skills)
- `review.md` — 10-pass review criteria (A-J) with confidence scoring
- `commit-format.md` — Conventional Commits specification
- `pr-description.md` — PR description template
- `ticket-instructions.md` — Ticket intake workflow (injected by SessionStart hook)
- `init-analysis.md` — Codebase analysis prompt (used by `dk init`)
- `phase-audits/*.md` — Numbered 1-6 matching lifecycle phases, plus `prompt-loop.md`

## Key Architecture Concepts

### Provider launch policy

Doyaken-launched Claude Code sessions must include `--dangerously-skip-permissions` plus `--permission-mode bypassPermissions`. Codex delegation must go through `bin/dkcodex.sh`, which owns `--ignore-user-config` and `--dangerously-bypass-approvals-and-sandbox`; do not reintroduce `--full-auto` for Doyaken-managed Codex work.

### Hook integration

Seven hooks defined in `settings.json`, referenced by paths to Doyaken scripts:

| Hook | Event | Script | Purpose |
|------|-------|--------|---------|
| SessionStart | Startup | `load-ticket-context.sh` | Load ticket context, detect focus areas |
| UserPromptSubmit | User prompt | `user-prompt-submit.sh` | Pause scheduled Phase 6 watchers during manual user work |
| PreToolUse | Before Bash/Edit/Write | `guard-handler.py` | Block/warn on dangerous patterns |
| PostToolUse | After `git commit` | `post-commit-guard.sh` | Validate commit format via guards |
| Stop | Claude tries to stop | `phase-loop.sh` | Phase audit loop (when active) |
| PreCompact | Before compaction | `pre-compact.sh` | Preserve Doyaken context across compaction |
| SessionEnd | Session ends | `session-end.sh` | Record session end metadata |

### Phase audit loops

When `DOYAKEN_LOOP_ACTIVE=1`, the Stop hook intercepts Claude's exit, injects a phase-specific audit prompt, and loops until a `.complete` signal file is written or max iterations (default 30) are reached. For `dk` lifecycles, the hook advances phases inside the same Claude session by updating phase state/config and injecting the next phase instructions. Phase 1 is gated by `.phase-1.started` / `.phase-1.ready` markers from `dkplan`; the hook does not count plan audit iterations or reveal the completion signal until the approved-plan marker exists. Phase 3 uses `.phase-3.busy` while `/dkreviewloop` is waiting on a review subagent; the hook does not count audit iterations during that wait.

### Session IDs

Derived from worktree names (`worktree-<name>`) or branch names (fallback). Used to key all state files. Path-based derivation makes them stable across branch renames.

### Worktree isolation

Each ticket gets its own git worktree in `.doyaken/worktrees/`. The `dk` shell function manages creation, cleanup, and resumption.

Exception: `dk --no-worktree <ticket-or-description>` runs the same phased lifecycle in the current checkout. It still creates or switches to the normal Doyaken lifecycle branch (`worktree-ticket-*` / `worktree-task-*`) from `origin/<default>`; it only skips `git worktree add`. In-place sessions persist their current branch in phase state so resume can switch back or stop rather than continuing on the wrong checkout branch.

## Quality Gates

This project has no test suite, formatter, or unified check command. Linting is via `shellcheck` (if installed) on `dk.sh`, `bin/*.sh`, `hooks/*.sh`, `lib/*.sh`.

When modifying shell scripts, ensure they pass `shellcheck` if you have it available.

## Security Considerations

- Hooks run with the user's full permissions — treat all hook code as security-sensitive
- In `guard-handler.py`, pass subprocess arguments as lists, never `shell=True` with user input
- Exit code 2 means "block" in guards — other non-zero exits are errors, not blocks
- Never store secrets in state files or `settings.json`
- Session IDs are not cryptographically random — don't use them for authentication
- Keep guard patterns efficient — they run on every tool invocation

## Common Tasks

### Adding a new skill

1. Create `skills/<dkname>/SKILL.md`
2. Add YAML frontmatter with `name` and `description`
3. Write the skill prompt as markdown
4. Reference shared prompts via `@prompts/<file>.md`
5. The symlink from `dk install` makes it available as `/<dkname>`

### Adding a new guard

1. Create a `.md` file in `hooks/guards/` (built-in) or `.doyaken/guards/` (project-specific)
2. Add YAML frontmatter with name, enabled, event, pattern, action
3. Write a human-readable message in the markdown body
4. Test the regex pattern against expected inputs

### Adding a new hook script

1. Create the script in `hooks/` with `#!/usr/bin/env bash`
2. Source common.sh: `source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"`
3. Add the hook definition to `settings.json`
4. Use `set -euo pipefail`

### Modifying dk.sh

1. This is zsh-only — zsh syntax is fine here
2. Prefix functions with `unalias/unfunction` guards for re-sourcing safety
3. After editing, users run `dk reload` to apply changes

### Adding a shared library function

1. Add to the appropriate file in `lib/` (`git.sh`, `session.sh`, `output.sh`, `worktree.sh`)
2. Or add a new `lib/<name>.sh` and source it from `common.sh`
3. Must be bash/zsh-compatible — no zsh-only syntax

### Modularizing large scripts

`dk.sh` is the largest file (~1900 lines). When adding shared or self-contained logic, prefer extracting it into `lib/` modules. The pattern:

**When to extract:**
- Same logic appears in 2+ functions → extract to `lib/`
- A function exceeds ~50 lines of self-contained logic → candidate for library
- Logic is needed by both `dk.sh` (zsh) and `hooks/`/`bin/` (bash) → must go to `lib/`

**How to extract:**
1. Create or extend a `lib/<domain>.sh` file (e.g., `worktree.sh`, `session.sh`)
2. Source it from `lib/common.sh` (all scripts get it automatically)
3. Use `dk_` prefix for public functions, `__dk_` for internal
4. Replace inline code in callers with the new function call
5. Verify with `bash -n lib/<file>.sh` (bash compat) and `zsh -n dk.sh` (zsh syntax)

**Current library modules and their responsibilities:**

| Module | Purpose | Key functions |
|--------|---------|---------------|
| `common.sh` | Bootstrap, constants, sources all others | `dk_repo_root()` |
| `codex.sh` | Codex CLI skill installation helpers | `dk_install_codex_skills()`, `dk_count_doyaken_skills()`, `dk_codex_doyaken_skills_complete()`, `dk_uninstall_codex_skills()` |
| `git.sh` | Git helpers | `dk_default_branch()`, `dk_slugify()` |
| `provider.sh` | Provider/model profile resolution, launch wrapping, and diagnostics | `dk_provider_apply()`, `dk_provider_claude()`, `dk_provider_command()`, `dk_provider_doctor()` |
| `session.sh` | Session ID derivation, state file paths | `dk_session_id()`, `dk_provider_state_file()`, `dk_cleanup_session()` |
| `output.sh` | Formatted user-facing output | `dk_done()`, `dk_ok()`, `dk_warn()`, `dk_error()`, etc. |
| `ui-capture.sh` | Playwright/UI capture tooling, artifact paths, MCP bootstrap | `dk_install_ui_capture_tooling()`, `dk_ui_capture_run_dir()`, `dk_ui_capture_playwright_ready()` |
| `worktree.sh` | Worktree management utilities | `dk_wt_branch()`, `dk_wt_remove()`, `dk_cleanup_last_session()`, `dk_cleanup_stale_files()` |

**dk.sh internal structure** (sections in order, approximate):

| Lines | Section | Functions |
|-------|---------|-----------|
| 25-138 | CLI dispatcher | `doyaken()` |
| 139-257 | Provider and phase config | `__dk_refresh_provider()`, `__dk_claude()`, phase arrays |
| 258-509 | Internal helpers | `__dk_is_ticket()`, `__dk_setup_worktree()`, `__dk_build_system_context()` |
| 510-897 | Phase execution | `__dk_run_phases_inline()`, `__dk_run_phases()` |
| 898-984 | Display helpers | `__dk_format_elapsed()`, `__dk_show_header()` |
| 985-1109 | Phased lifecycle | `dk()` |
| 1111-1238 | Prompt loop | `dkloop()` |
| 1240-1490 | Completion and review loops | `dkcomplete()`, `dkreviewloop()` |
| 1492-1665 | Worktree removal | `dkrm()` |
| 1667-1724 | Worktree listing | `dkls()` |
| 1726-1778 | Worktree navigation | `dkcd()` |
| 1780-end | Stale cleanup | `dkclean()` |

**Extraction candidates:**
- Shared provider/model launch logic → `lib/provider.sh`
- Codex skill-link logic → `lib/codex.sh`
- `__dk_show_header()` + `__dk_format_elapsed()` → `lib/display.sh`

**What stays in dk.sh:** Functions that use zsh-specific syntax (`${(j: :)@}`, zsh arrays) or need `unalias/unfunction` re-sourcing guards. The public commands (`dk`, `dkloop`, `dkrm`, `dkls`, `dkclean`, `dkcomplete`, `dkreviewloop`, `doyaken`) must stay because they are shell functions loaded into the user's zsh session.

## Environment Variables

| Variable | Purpose | Default |
|----------|---------|---------|
| `DOYAKEN_DIR` | Installation directory | `$HOME/work/doyaken` |
| `DK_STATE_DIR` | Phase state directory | `~/.claude/.doyaken-phases` |
| `DK_LOOP_DIR` | Loop state directory | `~/.claude/.doyaken-loops` |
| `DK_ARTIFACT_DIR` | Doyaken-generated screenshots, videos, traces, and logs | `~/.claude/.doyaken-artifacts` |
| `DK_TOOL_DIR` | Doyaken-managed external tooling cache | `~/.claude/.doyaken-tools` |
| `DOYAKEN_LOOP_ACTIVE` | Enable phase audit loop | unset |
| `DOYAKEN_LOOP_PHASE` | Current phase (1-6 or "prompt-loop") | unset |
| `DOYAKEN_PHASE_HANDOFF` | Same-session phase handoff marker (`inline` for `dk`) | unset |
| `DOYAKEN_LOOP_PROMISE` | Completion signal string | unset |
| `DOYAKEN_LOOP_MAX_ITERATIONS` | Max loop iterations | 30 |
| `DOYAKEN_REVIEW_PASS_TIMEOUT` | Seconds a Phase 3 review subagent may stay in progress before lifecycle pause | 900 (15m 0s) |
| `DOYAKEN_REVIEW_PASS_NOTICE_INTERVAL` | Minimum seconds between repeated Phase 3 busy-gate notices | 120 (2m 0s) |
| `DOYAKEN_REVIEW_PASS_RECHECK_SECONDS` | Seconds the Stop hook quietly polls for a busy Phase 3 review pass to finish | 45 (0m 45s) |
| `DOYAKEN_WATCH_CYCLE_TIMEOUT_SECONDS` | Maximum runtime budget for one scheduled Phase 6 watcher invocation | 120 (2m 0s) |
| `DOYAKEN_WATCH_COMMAND_TIMEOUT_SECONDS` | Maximum runtime for one GitHub/local shell command inside a watcher cycle | 30 (0m 30s) |
| `DOYAKEN_WATCH_PAUSE_TTL_SECONDS` | Seconds scheduled Phase 6 watchers stay paused after a direct user prompt | 3600 (60m 0s) |
| `DOYAKEN_SESSION_ID` | Unique session ID (set by dkloop for stop hook) | unset |
| `CODEX_HOME` | Codex config root used for Doyaken skill links | `~/.codex` |
| `DK_PROVIDER_PROFILE` | Provider profile override (`claude-subscription`, `codex-subscription`, or custom) | config/default |
| `DK_CLAUDE_MODEL` | Override Claude Code model passed to `--model` | profile model |
| `DK_PLAN_MODEL` | Override Phase 1/plan model | `DK_CLAUDE_MODEL` or profile plan model |
| `DK_CLAUDE_EFFORT` | Override Claude Code `--effort` | profile effort |
| `DK_PLAN_EFFORT` | Override Phase 1/plan effort | `DK_CLAUDE_EFFORT` or profile plan effort |
| `DK_ALLOW_API_BILLED_AUTH` | Allow `dk provider doctor` to tolerate API/gateway env vars | `0` |
| `DK_ALLOW_REPO_GATEWAY_PROVIDER` | Explicitly allow a trusted repo-local gateway/API provider profile for the current invocation | `0` |

## Files to Never Commit

- `.DS_Store`
- `__pycache__/`, `*.pyc`
- `.doyaken/worktrees/` (ephemeral)
- `~/.claude/.doyaken-artifacts/` UI captures (screenshots, videos, traces, logs)
- `~/.claude/settings.json` (user-specific)
- Anything containing secrets or credentials
