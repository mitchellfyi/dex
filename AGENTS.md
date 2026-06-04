# AGENTS.md

Instructions for AI coding agents working on the Dex codebase.

## What Is Dex

Dex is a standalone workflow automation framework for Claude Code. It provides autonomous ticket lifecycle management — from planning through ready-for-merge PR completion — using worktree isolation, quality-gated phase execution, and codebase-agnostic skill discovery. It works with any repo after a one-time global install. Dex lives at <https://dexcode.ai> and is owned and run by Synthetic Industry (<https://syntheticindustry.ai/>).

## Tech Stack

- **Shell (primary):** All CLI logic, hooks, and library code
  - `dx.sh` — **zsh-only** (sourced in `~/.zshrc`, uses zsh syntax like `${(j: :)@}`)
  - `hooks/*.sh` — **bash** (`#!/usr/bin/env bash`)
  - `lib/*.sh` — **bash/zsh-compatible** (sourced by both dx.sh and hooks)
- **Python 3 (stdlib only):** `hooks/guard-handler.py` — guard evaluation, no external dependencies
- **Markdown + YAML frontmatter:** Skills, guards, prompts, rules

## Directory Structure

```
bin/                 CLI scripts (install, init, config, status, etc.)
docs/                Extended documentation (guards, autonomous mode, UI capture)
hooks/               Claude Code hooks + guard handler
  guards/            Built-in guard rules (markdown with YAML frontmatter)
lib/                 Shared shell libraries (common, codex, git, output, provider, session, ui-capture, worktree)
prompts/             Prompt templates for skills and CLI harness workflows
  phase-audits/      Phase-specific audit prompts (1-6 + prompt-loop)
scripts/             Node/helpers used by Dex-managed tooling
skills/              Lifecycle skills (linked into ~/.claude/skills/ and individually to $CODEX_HOME/skills/)
dx.sh                Main shell functions (zsh only, ~2800 lines)
settings.json        Hook definitions template
install.sh           Quick-start installer (delegates to bin/install.sh)
```

Per-project (created by `dx init`):
```
.dex/
  dex.md         Project-specific config (tech stack, quality gates, integrations)
  AGENTS.md          @import of dex.md (generated context source of truth)
  CLAUDE.md          @import of AGENTS.md (Claude Code compatibility pointer)
  review-rules.md    Optional path-specific focus for Dex review waves
  providers.json      Optional repo-local provider/agent defaults
  rules/             Coding conventions (generated from codebase analysis)
  guards/            Project-specific guard rules (generated)
  worktrees/         Worktree directories (gitignored, ephemeral)
```

## Shell Conventions

### Language boundaries — this is critical

Never introduce zsh-only syntax in `lib/` or `hooks/`. Only `dx.sh` may use zsh features.

### Error handling

All scripts use `set -euo pipefail`. Use early returns, not deep nesting.

### Naming

- **Functions:** `dx_` prefix (public), `__dx_` prefix (internal), snake_case
- **Variables:** `local` for locals, `SCREAMING_SNAKE_CASE` with `DEX_` or `DX_` prefix for env vars
- **Files:** kebab-case for scripts and directories

### Library sourcing

```bash
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"
```

Sourcing `common.sh` also sources `git.sh`, `session.sh`, `output.sh`, `worktree.sh`, `provider.sh`, `codex.sh`, `ui-capture.sh`, `rtk.sh`, `events.sh`, `agent-tools.sh`, and `maintenance.sh`.

### Output

Use `lib/output.sh` helpers (`dx_done`, `dx_ok`, `dx_warn`, `dx_skip`, `dx_info`, `dx_error`) for user-facing messages. Never raw `echo` for status output.

### Re-sourcing safety

In `dx.sh`, every function definition is preceded by `unalias <name> 2>/dev/null; unfunction <name> 2>/dev/null` so the file can be re-sourced without errors.

### Atomic file operations

When writing shared files (e.g., `~/.claude/settings.json`), use temp files + atomic `mv`.

### State files

All ephemeral state goes under `~/.claude/.dex-phases/` or `~/.claude/.dex-loops/`, keyed by session ID. Never store state inside the repo (except `.dex/worktrees/` which is gitignored).

## Skill Conventions

Each skill lives in `skills/<name>/SKILL.md` with YAML frontmatter containing `name` and `description`, followed by markdown instructions. Codex uses this metadata for skill discovery; Claude Code tolerates the same format.

- Directory naming: lowercase, `dx`-prefixed (`dxplan`, `dximplement`, etc.)
- Exceptions: the orchestrator is `dex`; the writing pass is `humanizer`
- Skills reference prompts via `@prompts/<file>.md` import syntax
- Skills are codebase-agnostic — they discover toolchains at runtime
- Claude gets skills via a single `~/.claude/skills -> $DEX_DIR/skills` symlink when possible; if `~/.claude/skills` is already a directory, `dx install` preserves unrelated skills and installs Dex skill symlinks inside it
- Codex gets skills via individual symlinks in `$CODEX_HOME/skills/<name>` (`CODEX_HOME` defaults to `~/.codex`) so Dex does not replace Codex system/plugin skills

### Writing copy and comments

Use the `humanizer` skill whenever writing or editing copy, documentation,
ticket bodies, PR descriptions, GitHub/tracker comments, review replies,
user-facing messages, code comments, or doc comments. Preserve technical
identifiers, commands, paths, markdown structure, and required attribution while
removing AI-sounding filler.

### Vendor skills are NOT bundled

Dex does not ship third-party vendor skills (Figma, Asana, Linear, Notion, Slack, HubSpot, Microsoft 365, Gmail, Google Calendar, Fireflies, etc.). These are maintained by their vendors and distributed via Claude's official plugin/MCP integrations.

**Do not commit vendor skills into this repo.** If a vendor skill directory appears in `skills/` (e.g., `skills/figma-*/`), delete it — it was added by a Claude plugin install and should live in the user's `~/.claude/` or be enabled via the official integration, not in Dex.

When users need a vendor skill:

| Vendor | How to enable |
|--------|---------------|
| Figma  | <https://help.figma.com/hc/en-us/articles/32132100833559-Guide-to-the-Dev-Mode-MCP-Server> |
| Linear | <https://linear.app/changelog/2025-05-01-mcp> |
| Asana, Notion, Slack, HubSpot, Microsoft 365, Gmail, Google Calendar, Fireflies | Enable the corresponding integration on <https://claude.ai/settings/connectors> |
| Other  | Browse the Claude plugin marketplace via `/plugin` inside Claude Code, or check the vendor's docs for their official MCP/skill integration |

The corresponding MCP servers are listed and authenticated through claude.ai or `claude mcp` — they show up as `mcp__claude_ai_<Vendor>__*` tools and are available to Dex's skills automatically when enabled.

Dex may install a narrow official tooling allowlist during `dx install`,
`dx init`, and `dx sync`: Dex Claude/Codex skill links, browser MCPs,
OpenAI docs MCP, the OpenAI Codex Claude plugin when Codex is installed,
`frontend-design` for detected frontend repos, official language LSP
plugins for detected TypeScript/JavaScript, Python, Rust, or Go repos, and the
RTK token-reduction binary plus Dex-managed RTK hook/instruction files. Do not
add broad behavior-changing plugins, community marketplaces, or vendor
integration plugins to the default bootstrap path.

## Guard Conventions

Guards are markdown files with YAML frontmatter in `hooks/guards/` (built-in) or `.dex/guards/` (project-specific).

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
- `env_var: DX_PROVIDER_ENGINE` has a session-state/config fallback so provider-scoped guards do not depend only on hook environment inheritance
- `block` exits with code 2 (prevents tool call). `warn` exits 0 (allows it).
- Frontmatter parser is regex-based — flat `key: value` only, no nested objects or arrays
- Built-in guards: `claude-attribution`, `destructive-commands`, `raw-codex-delegation`, `sensitive-files`, `hardcoded-secrets` — don't duplicate these

## Prompt Conventions

Stored in `prompts/`. Referenced by skills and CLI harness prompts via
`@prompts/<file>.md`.

- `guardrails.md` — Implementation discipline (shared across implement/review skills)
- `review.md` — 12-pass review criteria (A-L) with confidence scoring
- `review-wave.md` — Review-wave contract and domain output schema (used by `/dxreview --single-pass` and Phase 3)
- `commit-format.md` — Conventional Commits specification
- `pr-description.md` — PR description template
- `ticket-instructions.md` — Ticket intake workflow (injected by SessionStart hook)
- `init-analysis.md` — Codebase analysis prompt (used by `dx init`)
- `phase-audits/*.md` — Numbered 1-6 matching lifecycle phases, plus `prompt-loop.md`

## Key Architecture Concepts

### Provider launch policy

Dex exposes stable agent names (`claude`, `codex`) through `dx --agent`, while
`lib/provider.sh` owns the mapping to provider profiles and engines. Keep new
agent support behind that provider layer rather than branching on agent names
throughout `dx.sh`.

Dex-launched Claude Code sessions must include `--dangerously-skip-permissions` plus `--permission-mode bypassPermissions`. Codex delegation must go through `bin/dxcodex.sh`, which owns `--ignore-user-config` and `--dangerously-bypass-approvals-and-sandbox`; do not reintroduce `--full-auto` for Dex-managed Codex work. `dx --model <model>` targets the selected agent: Claude gets `claude --model`, while Codex gets `codex exec --model` through the wrapper.

### Hook integration

Seven hooks defined in `settings.json`, referenced by paths to Dex scripts:

| Hook | Event | Script | Purpose |
|------|-------|--------|---------|
| SessionStart | Startup | `load-ticket-context.sh` | Load ticket context, detect focus areas |
| UserPromptSubmit | User prompt | `user-prompt-submit.sh` | Pause scheduled Phase 6 watchers during manual user work |
| PreToolUse | Before Bash/Edit/Write | `guard-handler.py` | Block/warn on dangerous patterns |
| PostToolUse | After `git commit` | `post-commit-guard.sh` | Validate commit format via guards |
| Stop | Claude tries to stop | `phase-loop.sh`, `stop-sound.sh` | Phase audit loop (when active) plus best-effort macOS sound notification |
| PreCompact | Before compaction | `pre-compact.sh` | Preserve Dex context across compaction |
| SessionEnd | Session ends | `session-end.sh` | Record session end metadata |

### Phase audit loops

When `DEX_LOOP_ACTIVE=1`, the Stop hook intercepts Claude's exit, injects a phase-specific audit prompt, and loops until a `.complete` signal file is written or max iterations (default 30) are reached. For `dx` lifecycles, the hook advances phases inside the same Claude session by updating phase state/config and injecting the next phase instructions. Phase 1 is gated by `.phase-1.started` / `.phase-1.ready` markers from `dxplan`; the hook does not count plan audit iterations or reveal the completion signal until the approved-plan marker exists. Phase 3 uses `.phase-3.busy` while `/dxreviewloop` is waiting on a review wave; the hook does not count audit iterations during that wait.

### Session IDs

Derived from a stable repo key plus worktree names (`worktree-<name>`) or branch names (fallback). Used to key all state files. Path-based derivation makes worktree sessions stable across branch renames while the repo key prevents cross-repo collisions in the global state directories.

### Worktree isolation

Each ticket gets its own git worktree in `.dex/worktrees/`. The `dx` shell function manages creation, cleanup, and resumption.

Exception: `dx --no-worktree <ticket-or-description>` runs the same phased lifecycle in the current checkout. It still creates or switches to the normal Dex lifecycle branch (`worktree-ticket-*` / `worktree-task-*`) from the default branch's upstream or remote-tracking ref; it only skips `git worktree add`. In-place sessions persist their current branch in phase state so resume can switch back or stop rather than continuing on the wrong checkout branch.

## Quality Gates

This project has no test suite, formatter, or unified check command. Linting is via `shellcheck` (if installed) on `dx.sh`, `bin/*.sh`, `hooks/*.sh`, `lib/*.sh`.

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

1. Create `skills/<dxname>/SKILL.md` (`skills/<name>/SKILL.md` only for approved non-`dx` exceptions such as `humanizer`)
2. Add YAML frontmatter with `name` and `description`
3. Write the skill prompt as markdown
4. Reference shared prompts via `@prompts/<file>.md`
5. The symlink from `dx install` makes it available as `/<dxname>`

### Adding a new guard

1. Create a `.md` file in `hooks/guards/` (built-in) or `.dex/guards/` (project-specific)
2. Add YAML frontmatter with name, enabled, event, pattern, action
3. Write a human-readable message in the markdown body
4. Test the regex pattern against expected inputs

### Adding a new hook script

1. Create the script in `hooks/` with `#!/usr/bin/env bash`
2. Source common.sh: `source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"`
3. Add the hook definition to `settings.json`
4. Use `set -euo pipefail`

### Modifying dx.sh

1. This is zsh-only — zsh syntax is fine here
2. Prefix functions with `unalias/unfunction` guards for re-sourcing safety
3. After editing, users run `dx reload` to apply changes

### Adding a shared library function

1. Add to the appropriate file in `lib/` (`git.sh`, `session.sh`, `output.sh`, `worktree.sh`)
2. Or add a new `lib/<name>.sh` and source it from `common.sh`
3. Must be bash/zsh-compatible — no zsh-only syntax

### Modularizing large scripts

`dx.sh` is the largest file (~2800 lines). When adding shared or self-contained logic, prefer extracting it into `lib/` modules. The pattern:

**When to extract:**
- Same logic appears in 2+ functions → extract to `lib/`
- A function exceeds ~50 lines of self-contained logic → candidate for library
- Logic is needed by both `dx.sh` (zsh) and `hooks/`/`bin/` (bash) → must go to `lib/`

**How to extract:**
1. Create or extend a `lib/<domain>.sh` file (e.g., `worktree.sh`, `session.sh`)
2. Source it from `lib/common.sh` (all scripts get it automatically)
3. Use `dx_` prefix for public functions, `__dx_` for internal
4. Replace inline code in callers with the new function call
5. Verify with `bash -n lib/<file>.sh` (bash compat) and `zsh -n dx.sh` (zsh syntax)

**Current library modules and their responsibilities:**

| Module | Purpose | Key functions |
|--------|---------|---------------|
| `common.sh` | Bootstrap, constants, sources all others | `dx_repo_root()` |
| `agent-tools.sh` | Conservative Claude/Codex tooling bootstrap | `dx_bootstrap_agent_tooling()`, `dx_install_safe_official_claude_plugins()`, `dx_install_openai_docs_mcp_servers()` |
| `codex.sh` | Codex CLI skill installation helpers | `dx_install_codex_skills()`, `dx_count_dex_skills()`, `dx_codex_dex_skills_complete()`, `dx_uninstall_codex_skills()` |
| `events.sh` | Run IDs, local run directories, JSONL event journals, redacted logs, artifact manifests, summaries | `dx_run_prepare()`, `dx_event_emit()`, `dx_run_log_append()`, `dx_run_register_artifact()`, `dx_run_write_summary()` |
| `git.sh` | Git helpers | `dx_default_branch()`, `dx_slugify()` |
| `maintenance.sh` | Background maintenance config, workflow install, run IDs, locks, and reviewer normalization | `dx_maintenance_event_mode()`, `dx_maintenance_install_workflow()`, `dx_maintenance_run_id()`, `dx_maintenance_request_reviewer()` |
| `provider.sh` | Provider/model profile resolution, launch wrapping, and diagnostics | `dx_provider_apply()`, `dx_provider_claude()`, `dx_provider_command()`, `dx_provider_doctor()` |
| `rtk.sh` | RTK token-reduction bootstrap and checks | `dx_install_rtk_tooling()`, `dx_check_rtk_tooling()`, `dx_rtk_resolved_binary()` |
| `session.sh` | Session ID derivation, state file paths | `dx_session_id()`, `dx_provider_state_file()`, `dx_cleanup_session()` |
| `output.sh` | Formatted user-facing output | `dx_done()`, `dx_ok()`, `dx_warn()`, `dx_error()`, etc. |
| `ui-capture.sh` | Playwright/UI capture tooling, artifact paths, MCP bootstrap | `dx_install_ui_capture_tooling()`, `dx_ui_capture_run_dir()`, `dx_ui_capture_playwright_ready()` |
| `worktree.sh` | Worktree management utilities | `dx_wt_branch()`, `dx_wt_remove()`, `dx_cleanup_last_session()`, `dx_cleanup_stale_files()` |

**dx.sh internal structure** (sections in order, approximate):

| Lines | Section | Functions |
|-------|---------|-----------|
| 35-156 | CLI dispatcher | `__dx_cli()`, `dex()`, `dexter()` |
| 157-373 | Provider and phase config | `__dx_refresh_provider()`, `__dx_claude()`, phase arrays |
| 374-1449 | Internal helpers, phase execution, display helpers | `__dx_is_ticket()`, `__dx_setup_worktree()`, `__dx_run_phases()` |
| 1450-1665 | Phased lifecycle and aliases | `dx()`, `dex()`, `dexter()` |
| 1666-1925 | Prompt loop and refinement | `dxloop()`, `dxrefine()` |
| 1926-2361 | Completion and review loops | `dxcomplete()`, `dxreviewloop()` |
| 2362-2567 | Worktree removal | `dxrm()` |
| 2568-2626 | Worktree listing | `dxls()` |
| 2627-2680 | Worktree navigation | `dxcd()` |
| 2681-end | Stale cleanup | `dxclean()` |

**Extraction candidates:**
- Shared provider/model launch logic → `lib/provider.sh`
- Codex skill-link logic → `lib/codex.sh`
- `__dx_show_header()` + `__dx_format_elapsed()` → `lib/display.sh`

**What stays in dx.sh:** Functions that use zsh-specific syntax (`${(j: :)@}`, zsh arrays) or need `unalias/unfunction` re-sourcing guards. The public commands (`dx`, `dxloop`, `dxrm`, `dxls`, `dxclean`, `dxcomplete`, `dxreviewloop`, `dex`, `dexter`) must stay because they are shell functions loaded into the user's zsh session.

## Environment Variables

| Variable | Purpose | Default |
|----------|---------|---------|
| `DEX_DIR` | Installation directory | `$HOME/work/dex` |
| `DX_STATE_DIR` | Phase state directory | `~/.claude/.dex-phases` |
| `DX_LOOP_DIR` | Loop state directory | `~/.claude/.dex-loops` |
| `DX_ARTIFACT_DIR` | Dex-generated screenshots, videos, traces, and logs | `~/.claude/.dex-artifacts` |
| `DX_TOOL_DIR` | Dex-managed external tooling cache | `~/.claude/.dex-tools` |
| `DX_RUN_ROOT` | Dex run directories, event journals, summaries, and run artifacts | `~/.dex/runs` |
| `DEX_RUN_ID` | Current run ID passed into hooks/provider subprocesses | unset |
| `DX_RTK_ENABLED` | Enable RTK token-reduction bootstrap (`0` disables) | `1` |
| `DX_RTK_BIN` | Override RTK binary path used by Dex hooks/checks | unset |
| `DX_RTK_INSTALL_DIR` | RTK binary install directory | `$DX_TOOL_DIR/rtk/bin` |
| `DX_RTK_VERSION` | Pin RTK release installed by Dex | latest GitHub release |
| `DEX_LOOP_ACTIVE` | Enable phase audit loop | unset |
| `DEX_LOOP_PHASE` | Current phase (1-6 or "prompt-loop") | unset |
| `DEX_PHASE_HANDOFF` | Same-session phase handoff marker (`inline` for `dx`) | unset |
| `DEX_LOOP_PROMISE` | Completion signal string | unset |
| `DEX_LOOP_MAX_ITERATIONS` | Max loop iterations | 30 |
| `DEX_REVIEW_PASS_TIMEOUT` | Seconds a Phase 3 review wave may stay in progress before lifecycle pause | 900 (15m 0s) |
| `DEX_REVIEW_PASS_NOTICE_INTERVAL` | Minimum seconds between repeated Phase 3 busy-gate notices | 120 (2m 0s) |
| `DEX_REVIEW_PASS_RECHECK_SECONDS` | Seconds the Stop hook quietly polls for a busy Phase 3 review pass to finish | 45 (0m 45s) |
| `DEX_WATCH_CYCLE_TIMEOUT_SECONDS` | Maximum runtime budget for one scheduled Phase 6 watcher invocation | 120 (2m 0s) |
| `DEX_WATCH_COMMAND_TIMEOUT_SECONDS` | Maximum runtime for one GitHub/local shell command inside a watcher cycle | 30 (0m 30s) |
| `DEX_WATCH_PAUSE_TTL_SECONDS` | Seconds scheduled Phase 6 watchers stay paused after a direct user prompt | 3600 (60m 0s) |
| `DEX_COMPLETE_MAX_CYCLES` | Max idle PR watch cycles before Phase 6 pauses for manual follow-up | 3 |
| `DEX_COMPLETE_WAIT_MINUTES` | Minimum wait window per Phase 6 cycle (minutes) | 5 |
| `DEX_SESSION_ID` | Unique session ID (set by dxloop for stop hook) | unset |
| `CODEX_HOME` | Codex config root used for Dex skill links | `~/.codex` |
| `DX_AGENT` / `DX_AGENT_OVERRIDE` | Agent override (`claude` or `codex`) | profile/default |
| `DX_MODEL` / `DX_MODEL_OVERRIDE` | Model override for the selected agent | profile/default |
| `DX_PROVIDER_PROFILE` | Provider profile override (`claude-subscription`, `codex-subscription`, or custom) | config/default |
| `DX_CLAUDE_MODEL` | Override Claude Code model passed to `--model` | profile model |
| `DX_PLAN_MODEL` | Override Phase 1/plan model | `DX_CLAUDE_MODEL` or profile plan model |
| `DX_CODEX_MODEL` | Resolved Codex model passed through `bin/dxcodex.sh` | profile/default |
| `DX_CLAUDE_EFFORT` | Override Claude Code `--effort` | profile effort |
| `DX_PLAN_EFFORT` | Override Phase 1/plan effort | `DX_CLAUDE_EFFORT` or profile plan effort |
| `DX_ALLOW_API_BILLED_AUTH` | Allow `dx provider doctor` to tolerate API/gateway env vars | `0` |
| `DX_ALLOW_REPO_GATEWAY_PROVIDER` | Explicitly allow a trusted repo-local gateway/API provider profile for the current invocation | `0` |

## Files to Never Commit

- `.DS_Store`
- `__pycache__/`, `*.pyc`
- `.dex/worktrees/` (ephemeral)
- `~/.claude/.dex-artifacts/` UI captures (screenshots, videos, traces, logs)
- `~/.claude/settings.json` (user-specific)
- Anything containing secrets or credentials
