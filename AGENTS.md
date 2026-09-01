# AGENTS.md

Instructions for AI coding agents working on the Dex codebase.

## What Is Dex

Dex is a standalone workflow automation framework for Claude Code and the Codex CLI. It provides autonomous ticket lifecycle management — from planning through ready-for-merge PR completion — using worktree isolation, quality-gated phase execution, and codebase-agnostic skill discovery. It works with any repo after a one-time global install. Dex lives at <https://dexcode.ai> and is owned and run by Synthetic Industry (<https://syntheticindustry.ai/>).

## Tech Stack

- **Shell (primary):** All CLI logic, hooks, and library code
  - `dx.sh` — **zsh-only** (sourced in `~/.zshrc`, uses zsh syntax like `${(j: :)@}`)
  - `hooks/*.sh` — **bash** (`#!/usr/bin/env bash`)
  - `lib/*.sh` — **bash/zsh-compatible** (sourced by both dx.sh and hooks)
- **Python 3 (stdlib only):** `hooks/guard-handler.py` — guard evaluation;
  `hooks/git-commit-target.py` — did this command create a commit, and where;
  `hooks/shell_parse.py` — the shell-command reading both of them share. No
  external dependencies
- **Markdown + YAML frontmatter:** Skills, guards, prompts, rules

## Directory Structure

```
bin/                 CLI scripts (install, init, config, status, etc.)
docs/                Extended documentation (guards, autonomous mode, run specs, UI capture)
hooks/               Claude Code hooks, guard handler, shared shell parser
  guards/            Built-in guard rules (markdown with YAML frontmatter)
lib/                 Shared shell libraries sourced by common.sh; see the module table below
prompts/             Prompt templates for skills and CLI harness workflows
  phase-audits/      Phase-specific audit prompts (0-6 + prompt-loop)
scripts/             Python/Node helpers imported by lib/ and Dex-managed tooling
skills/              Lifecycle skills (linked into ~/.claude/skills/ and individually to $CODEX_HOME/skills/)
dx.sh                Main shell functions (zsh only)
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

The reverse also holds, and is easier to miss: `lib/` is *sourced by* `dx.sh`,
so it runs under zsh even though it is written for bash. Names zsh treats
specially cannot be used as ordinary variables there:

```bash
local status=0    # zsh: read-only; the declaration fails
local path="$1"   # zsh: tied to PATH, so the next command is not found
```

Both of those shipped. `tests/zsh-reserved-names.py` (run by `tests/check.sh`)
rejects the whole set. shellcheck cannot see it — the names are ordinary in
bash — and neither can the test suite, which runs under bash. `hooks/` and
`bin/` have bash shebangs and are not affected.

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

Sourcing `common.sh` also sources every other module in `lib/`: `agent-tools.sh`,
`attribution.sh`, `codex.sh`, `completion.sh`, `dexcode.sh`, `events.sh`, `factory.sh`, `git.sh`,
`lifecycle-control.sh`, `lock.sh`, `maintenance.sh`, `output.sh`, `override.sh`, `project-state.sh`,
`provider.sh`, `review.sh`, `review-controller.sh`, `review-loop.sh`,
`review-policy.sh`, `rtk.sh`, `run-spec.sh`, `session-catalog.sh`, `session-management.sh`,
`session-runtime.sh`, `session.sh`, `ui-capture.sh`,
`worker.sh`, and `worktree.sh`.

### Output

Use `lib/output.sh` helpers (`dx_done`, `dx_ok`, `dx_warn`, `dx_skip`, `dx_info`, `dx_error`) for user-facing messages. Never raw `echo` for status output.

### Re-sourcing safety

In `dx.sh`, every function definition is preceded by `unalias <name> 2>/dev/null; unfunction <name> 2>/dev/null` so the file can be re-sourced without errors.

### The runtime surface

`lib/` imports helpers from `scripts/` (for example `dex_redact.py` and
`run-log-tee.py`, invoked with `PYTHONPATH="$DEX_DIR/scripts"`). Anything that
vendors a *subset* of the repo has to carry `scripts/` too, or those imports
fail at run time and the calling function degrades silently. The pinned agent
runtime in `research/review-loop/lib.sh` is one such consumer, and its contents
are asserted by an allowlist in `tests/review-evaluation-harness-test.sh` —
widening that list is a deliberate act, not a formality.

Before adding a new cross-directory dependency from `lib/`, check who copies
parts of the repo rather than all of it.

### Atomic file operations

When writing shared files (e.g., `~/.claude/settings.json`), use temp files + atomic `mv`.

### State files

All ephemeral state goes under `~/.claude/.dex-phases/` or `~/.claude/.dex-loops/`, keyed by session ID. Persistent init and attribution provenance may live in the repository's Git directory so `dx uninit` can restore user configuration safely. Never store state in tracked project files (except `.dex/worktrees/`, which is gitignored).

## Skill Conventions

Each skill lives in `skills/<name>/SKILL.md` with YAML frontmatter containing `name` and `description`, followed by markdown instructions. Codex uses this metadata for skill discovery; Claude Code tolerates the same format.

- Directory naming: lowercase, `dx`-prefixed (`dxplan`, `dximplement`, etc.)
- Exceptions: the orchestrator is `dex`; the writing pass is `humanizer`
- Skills reference prompts by plain repo-relative path (`prompts/<file>.md`)
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
match: all|path
case_sensitive: false
allow_pattern: optional-python-regex
env_var: OPTIONAL_ENV_NAME
env_value: optional-exact-value
---
```

- Patterns are Python regexes evaluated by `guard-handler.py`
- `detector` is optional; use only for built-in syntax-aware guard detectors
- `allow_pattern` is optional; use it only for narrow safe exceptions to a broader `pattern`
- `match: path` scopes a `file` guard to the edited path; without it the pattern also sees the file's contents, so a location rule fires on prose that mentions the location
- `env_var`/`env_value` are optional; use them to scope a guard to a runtime mode
- `env_var: DX_PROVIDER_ENGINE` has a session-state/config fallback so provider-scoped guards do not depend only on hook environment inheritance
- `block` exits with code 2 (prevents tool call). `warn` exits 0 (allows it).
- Frontmatter parser is regex-based — flat `key: value` only, no nested objects or arrays
- Built-in guards (in `hooks/guards/`, listed by their `name:` value — don't duplicate these):
  `warn-claude-attribution`, `warn-destructive-commands`, `warn-raw-codex-delegation`,
  `warn-review-assessment-bash`, `warn-review-assessment-file-edits`,
  `warn-await-in-loop`, `warn-hardcoded-secrets`, `warn-sensitive-files`
- Every built-in guard advises rather than denies. The message reaches the agent as context
  and the tool call proceeds — the agent is expected to read it and decide, which is why the
  wording is guidance rather than a verdict. `action: block` still works for anyone who wants
  a hard stop; only then does the fail-closed behaviour below apply.
- A `block` guard fails closed: one that times out, crashes, or cannot be loaded denies the
  tool call. With every guard on `warn`, those same failures skip the guard and are reported
  on stderr. See docs/guards.md § Failure Behavior.
- During an active lifecycle, a specific project block can be softened to an
  attributed warning with `dx control override guard.<name> allow`. The record
  must name its human or agent source and reason. Unsafe override state grants
  nothing, so the original block remains in force.
- An exact standalone Dex control invocation is the break-glass path and is
  evaluated before guard loading. It can reach `bin/control.sh` even through a
  catch-all project block or missing built-in guard set. Shell wrappers,
  substitutions, redirections, pipelines, separators, and appended commands
  are not exempt.

## Prompt Conventions

Stored in `prompts/`. Skills reference them by plain repo-relative path, e.g.
"read the implementation guardrails from `prompts/guardrails.md`".

- `guardrails.md` — Implementation discipline (shared across implement/review skills)
- `review-risk-assessment.md` — Deterministic small/normal/complex review-tier selection before review waves
- `review.md` — 12-pass review criteria (A-L) with confidence scoring
- `review-wave.md` — Review-wave contract and domain output schema (used by `/dxreview --single-pass` and Phase 3)
- `commit-format.md` — Conventional Commits specification
- `pr-description.md` — PR description template
- `ticket-instructions.md` — Ticket intake workflow (injected by SessionStart hook)
- `issue-hygiene.md` — Lifecycle-wide duplicate search, issue/PR reconciliation,
  linked follow-up creation, external-write ownership, and phase reporting
- `init-analysis.md` — Codebase analysis prompt (used by `dx init`)
- `phase-audits/*.md` — Numbered 0-6 matching lifecycle phases (Phase 0 is Setup), plus `prompt-loop.md`; `3-review-loop.md` is the lifecycle Phase 3 audit and `3-review.md` the per-wave audit the review loop injects

## Key Architecture Concepts

### Provider launch policy

Dex exposes stable agent names (`claude`, `codex`) through `dx --agent`, while
`lib/provider.sh` owns the mapping to provider profiles and engines. Keep new
agent support behind that provider layer rather than branching on agent names
throughout `dx.sh`.

Dex-launched Claude Code sessions must include `--dangerously-skip-permissions` plus `--permission-mode bypassPermissions`. Codex delegation must go through `bin/dxcodex.sh`. Normal delegated work uses `--ignore-user-config` with `--dangerously-bypass-approvals-and-sandbox`; do not reintroduce `--full-auto`. Internal read-only launches set `DX_CODEX_READ_ONLY=1` and use `--ignore-user-config --sandbox read-only --ephemeral` without the dangerous bypass flag. The wrapper works under any provider profile, so a Claude-engine run can hand individual tasks to Codex; only codex-plugin profiles resolve a `codex_model` override, other engines use the Codex session default. `dx --model <model>` targets the selected agent: Claude gets `claude --model`, while Codex gets `codex exec --model` through the wrapper.

### Hook integration

Hooks defined in `settings.json`, referenced by paths to Dex scripts:

| Hook | Matcher | Script | Purpose |
|------|---------|--------|---------|
| SessionStart | `startup` | `load-ticket-context.sh` | Load ticket context, detect focus areas |
| UserPromptSubmit | (all) | `user-prompt-submit.sh` | Pause scheduled Phase 6 watchers during manual user work |
| PreToolUse | `Bash` | `guard-handler.py` (`DEX_GUARD_EVENT=bash`) | Block/warn on dangerous commands |
| PreToolUse | `Bash` | `rtk-claude-hook.sh` | Optional RTK output-filtering rewrite; runs after the guard and fails open |
| PreToolUse | `Edit\|Write\|MultiEdit\|NotebookEdit` | `guard-handler.py` (`DEX_GUARD_EVENT=file`) | Block/warn on dangerous file edits |
| PostToolUse | `Bash` | `post-commit-guard.sh` | Validate commit format via guards |
| Stop | Claude tries to stop | `phase-loop.sh`, `stop-sound.sh` | Phase audit loop (when active) plus best-effort macOS sound notification |
| PreCompact | Before compaction | `pre-compact.sh` | Preserve Dex context across compaction |
| SessionEnd | Session ends | `session-end.sh` | Record session end metadata |

### Phase audit loops

When `DEX_LOOP_ACTIVE=1`, the Stop hook intercepts Claude's exit and injects a
phase-specific audit prompt. Normal gate advancement requires the exact
generation-bound completion receipt the hook authorized for that session and
phase; a bare `.complete` marker is not authorization. A human or agent `done`,
`waive`, or `jump` control records a waiver or skip instead of claiming the gate passed. The loop
stops for intervention after its configured audit limit, which defaults to 30.
For `dx` lifecycles, the hook advances phases inside the same Claude session by
updating phase state/config and injecting the next phase instructions. Phase 1
is gated by `.phase-1.started` / `.phase-1.ready` markers from `dxplan`; the
hook does not count plan audit iterations or expose the receipt command until
the approved-plan marker and strict review-criteria artifact exist, then seals
the artifact's canonical hash. Phase 3 uses `.phase-3.busy` while
`/dxreviewloop` is waiting on a review wave; the hook does not count audit
iterations during that wait.

Operational limits are soft defaults. `dx control override <gate> <value>`
stores a phase- or session-scoped policy change with attribution, reason, and
optional expiry; hooks and provider wrappers re-read it while the lifecycle is
running. `review.clean-passes` may lower the effective target while preserving
real independent clean-wave evidence; its receipt binds the override and the
phase outcome is waived. A named `dx control waive` skips the remaining gate.
Neither path forges a success result. The active agent may ask the human or
self-override when justified. Private state validation, transition ownership,
atomic writes, and quiescing an active review child are runtime invariants and
remain fail-closed.

If an interrupt kills the Phase 3 review owner before it clears its busy fence,
the Stop hook reports the dead PID and prints the supported recovery command.
Agents must run that exact standalone `bin/control.sh recover review --source
agent --reason ...` command instead of deleting state by hand. Use it only for
the dead-owner diagnosis: it refuses live or malformed state, revokes
completion, and leaves Phase 3 paused for `/dxresume` or `/dxskip`.

The outer review loop is separate. In the normal flow, the Phase 2 agent selects `small`, `normal`, or `complex`. Dex maps those tiers to fixed global consecutive-clean requirements of 1, 2, and 3. A standalone loop without an explicit override starts with a fresh read-only assessor. Each lifecycle assessor and wave gets a temporary pass-scoped copy of the approved criteria. The sealed criteria hash and global policy are bound to resumable state, the risk selection, per-item evidence, every clean ledger row, and the success receipt. Receipt validation reopens retained proof copies and recomputes every clean-pass attestation. Standalone waves use the explicit `standalone` criteria binding. Legacy or resumed lifecycles with no valid current-scope selection may use a fresh read-only assessor before the first wave. The loop has no routine maximum and pauses on changed or partially covered criteria, residual findings, blockers, churn, invalid results, or provider failure.

### Session IDs

Derived from a stable repo key plus worktree names (`worktree-<name>`) or branch names (fallback). Used to key all state files. Path-based derivation makes worktree sessions stable across branch renames while the repo key prevents cross-repo collisions in the global state directories.

### Worktree isolation

Each ticket gets its own git worktree in `.dex/worktrees/`. The `dx` shell function manages creation, cleanup, and resumption.

Exception: `dx --no-worktree <ticket-or-description>` runs the same phased lifecycle in the current checkout. It still creates or switches to the normal Dex lifecycle branch (`worktree-ticket-*` / `worktree-task-*`) from the default branch's upstream or remote-tracking ref; it only skips `git worktree add`. In-place sessions persist their current branch in phase state so resume can switch back or stop rather than continuing on the wrong checkout branch.

## Quality Gates

This project has focused shell test scripts under `tests/`. There is no
formatter; verification is static checks plus the test suite.

| Check | Command | Notes |
|-------|---------|-------|
| Static | `bash tests/check.sh` | `zsh -n` on the zsh files, `bash -n` plus `shellcheck -S warning` on every other shell file the repo ships (`lib/`, `hooks/`, `bin/`, `tests/`, and `research/` including the scenario rubrics), `py_compile`, the embedded-Python, bare-assertion, and zsh-reserved-name checks, `node --check`. Optional tools are skipped with a notice. |
| Tests | `bash tests/run-all.sh` | Runs the tests registered in `tests/manifest.tsv` with their declared lane, platform, timeout, and isolation. Filter with `bash tests/run-all.sh review worktree`. |
| One test | `bash tests/<name>-test.sh` | For iterating on a single surface. |

CI runs static checks on Linux and the manifest test shards on Linux and macOS
for every push to `main` and every pull request.

Run `bash tests/check.sh` before PR handoff, and at minimum run the focused tests
covering the surface you changed while you work. Commits are coherent working
checkpoints and do not require the full suite to be green; report failing or
pending checks honestly and keep repairing them. The review-loop suites are
slow (10+ minutes each); `tests/run-all.sh` parallelizes them, so prefer it over
serial runs.

### The serial lane

A test whose assertion is a wall-clock bound cannot share the machine with
several others. Put it in the `serial` lane in `tests/manifest.tsv`. A test may
also document the reason near its shebang:

```bash
# dex-test-lane: serial
# <why this one measures time>
```

`tests/manifest.tsv` is authoritative. `service` and `serial` tests run
exclusively; `fast` and `slow` tests may run in parallel. If a legacy
`# dex-test-lane:` marker is present, the runner verifies that it agrees with
the manifest instead of using it to select the lane.

Reach for it only when a bound is genuinely about elapsed time. A slow test is
not a serial test — the lane is not a place to hide flakiness that has another
cause.

### Writing an assertion

Write `[[ … ]] || assert_at $LINENO`, and source `tests/helpers.sh`. A bare
`[[ … ]]` is not an assertion on bash 3.2 — `/bin/bash` on macOS, and what the
macOS CI leg runs — because `set -e` does not apply to that keyword there. 365
assertions across the suite were inert on that leg; one could claim
`"master" == "THIS-IS-WRONG"` and the test still reported success. `false` and
every ordinary command do trip errexit; only `[[ … ]]` does not.

Keep the bare form only where the status is the value being returned — a
predicate function, or a helper the caller checks. `tests/helpers.sh` also
installs an ERR trap, so any other errexit death names its line instead of
leaving the runner with "FAIL(1)" over an empty log.

## Security Considerations

- Hooks run with the user's full permissions — treat all hook code as security-sensitive
- In `guard-handler.py`, pass subprocess arguments as lists, never `shell=True` with user input
- `hooks/shell_parse.py` is the single reading of a shell command, shared by the guard
  handler and the commit-target parser. Teach it a capability once and both get it; a
  local copy in one hook is how they drifted before. `tests/parser-drift-test.sh` fails
  on any hook that redefines a name the shared module owns
- Exit code 2 means "block" in guards — other non-zero exits are errors, not blocks. No
  built-in guard uses it: they all advise, and the agent decides. A guard's job here is to
  put the right thing in front of whoever is about to act, not to be the thing that stops them
- Never store secrets in state files or `settings.json`
- Session IDs are not cryptographically random — don't use them for authentication
- Keep guard patterns efficient — they run on every tool invocation
- The review-loop attestation chain (sealed criteria, ledger, receipts) detects drift, not forgery: it is keyless and runs under the same UID as the review waves it constrains. Don't describe it as tamper-proof. See docs/autonomous-mode.md § What The Integrity Chain Does And Does Not Cover
- Pass credentials to `curl` via `--config` on stdin, never `-H` in argv, which is world-readable in `ps`

## Common Tasks

### Adding a new skill

1. Create `skills/<dxname>/SKILL.md` (`skills/<name>/SKILL.md` only for approved non-`dx` exceptions such as `humanizer`)
2. Add YAML frontmatter with `name` and `description`
3. Write the skill prompt as markdown
4. Reference shared prompts by plain repo-relative path (`prompts/<file>.md`)
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
3. After editing, users run `dx reload` to apply shell changes and refresh Claude hook settings

### Adding a shared library function

1. Add to the appropriate file in `lib/` (`git.sh`, `session.sh`, `output.sh`, `worktree.sh`)
2. Or add a new `lib/<name>.sh` and source it from `common.sh`
3. Must be bash/zsh-compatible — no zsh-only syntax

### Modularizing large scripts

`dx.sh` is the largest shell file. When adding shared or self-contained logic,
prefer extracting it into `lib/` modules. The pattern:

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
| `lock.sh` | Advisory directory locks with owner records and serialized stale recovery | `dx_lock_acquire()`, `dx_lock_release()`, `dx_lock_with()` |
| `agent-tools.sh` | Conservative Claude/Codex tooling bootstrap | `dx_bootstrap_agent_tooling()`, `dx_install_safe_official_claude_plugins()`, `dx_install_openai_docs_mcp_servers()` |
| `attribution.sh` | Commit/PR attribution installation, hook chaining, and restoration | `dx_install_repo_attribution()`, `dx_uninstall_repo_attribution()`, `dx_commit_attribution_message()` |
| `codex.sh` | Codex CLI skill installation helpers | `dx_install_codex_skills()`, `dx_count_dex_skills()`, `dx_codex_dex_skills_complete()`, `dx_uninstall_codex_skills()` |
| `completion.sh` | Generation-bound completion expectations, receipts, validation, and cleanup | `dx_completion_issue()`, `dx_completion_write_receipt()`, `dx_completion_consume()` |
| `dexcode.sh` | DexCode login, org connections, run registration/sync, artifact upload | `dx_dexcode_login()`, `dx_dexcode_command()`, `dx_dexcode_prepare_run_sync()`, `dx_dexcode_upload_artifact()` |
| `events.sh` | Run IDs, local run directories, JSONL event journals, redacted logs, artifact manifests, summaries | `dx_run_prepare()`, `dx_event_emit()`, `dx_run_log_append()`, `dx_run_register_artifact()`, `dx_run_write_summary()` |
| `factory.sh` | Optional Dex Factory event sync over HTTP | `dx_factory_sync_pending_events()`, `dx_factory_events_endpoint()`, `dx_factory_sync_requested()` |
| `git.sh` | Git helpers, including safe tracker-branch adoption | `dx_default_branch()`, `dx_ticket_branch_prepare()`, `dx_slugify()` |
| `lifecycle-control.sh` | Human/agent lifecycle pause, stop, phase transition, ownership, and audit receipts | `dx_write_lifecycle_control()`, `dx_lifecycle_control_read()`, `dx_lifecycle_control_lock_acquire()` |
| `maintenance.sh` | Background maintenance config, workflow install, run IDs, locks, and reviewer normalization | `dx_maintenance_event_mode()`, `dx_maintenance_install_workflow()`, `dx_maintenance_run_id()`, `dx_maintenance_request_reviewer()` |
| `override.sh` | Session policy journal, validation, expiry, and effective-value resolution | `dx_override_set()`, `dx_override_clear()`, `dx_override_list()`, `dx_override_effective()` |
| `provider.sh` | Provider/model profile resolution, launch wrapping, and diagnostics | `dx_provider_apply()`, `dx_provider_claude()`, `dx_provider_command()`, `dx_provider_doctor()` |
| `project-state.sh` | Init ownership snapshots and conservative project cleanup | `dx_project_state_begin()`, `dx_project_state_finalize()`, `dx_project_state_remove_managed()` |
| `review.sh` | Scope-bound review selection/state, evidence, retained proofs, ledgers, receipts, result parsing, churn detection, and telemetry JSON | `dx_review_evidence_valid()`, `dx_review_ledger_valid()`, `dx_review_write_receipt()`, `dx_review_findings_churn_kind()`, `dx_review_event_json()` |
| `review-loop.sh` | The review loop itself plus its helpers: wave orchestration, tier assessment, run telemetry, pause and interrupt handling, scope snapshots. `dxreviewloop` in dx.sh is a thin wrapper over it | `dx_review_loop_run()`, `__dx_review_emit_event()`, `__dx_review_scope_snapshot()` |
| `review-controller.sh` | Pure review-loop state transitions and atomic findings history | `dx_review_transition()`, `dx_review_findings_history_append()` |
| `review-policy.sh` | Trusted default-branch clean-pass policy resolution and binding | `dx_review_policy_resolve()`, `dx_review_policy_for_tier()` |
| `rtk.sh` | RTK token-reduction bootstrap and checks | `dx_install_rtk_tooling()`, `dx_check_rtk_tooling()`, `dx_rtk_resolved_binary()` |
| `run-spec.sh` | Structured headless run spec validation, fetch, normalization, and journal prep | `dx_run_spec_normalize()`, `dx_run_spec_fetch()`, `dx_run_spec_prepare_journal()` |
| `session-catalog.sh` | Read-only, repo-scoped lifecycle inventory and exact selector resolution | `dx_session_catalog_records()`, `dx_session_catalog_record()`, `dx_session_catalog_select()` |
| `session-runtime.sh` | PID-reuse-safe lifecycle runtime leases and health | `dx_session_runtime_start()`, `dx_session_runtime_heartbeat()`, `dx_session_runtime_finish()` |
| `session.sh` | Session ID derivation, state file paths | `dx_session_id()`, `dx_provider_state_file()`, `dx_cleanup_session()` |
| `session-management.sh` | Strict internal lifecycle-session cleanup transactions | `__dx_session_management_cleanup_exact()` |
| `output.sh` | Formatted user-facing output | `dx_done()`, `dx_ok()`, `dx_warn()`, `dx_error()`, etc. |
| `ui-capture.sh` | Playwright/UI capture tooling, artifact paths, MCP bootstrap | `dx_install_ui_capture_tooling()`, `dx_ui_capture_run_dir()`, `dx_ui_capture_playwright_ready()` |
| `worker.sh` | DexCode worker registration and the poll/claim/lease/settle daemon | `dx_worker_command()`, `dx_worker_register()`, `dx_worker_daemon()` |
| `worktree.sh` | Worktree management utilities | `dx_wt_branch()`, `dx_wt_remove()`, `dx_cleanup_last_session()`, `dx_cleanup_stale_files()` |

**dx.sh internal structure** (sections in file order). Locate any of these with
`grep -n '^<name>()' dx.sh` — line numbers are deliberately omitted here because
they go stale on every edit:

| Section | Functions |
|---------|-----------|
| CLI dispatcher | `__dx_cli()`, `dex()`, `dexter()` |
| Provider and phase config | `__dx_refresh_provider()`, `__dx_claude()`, phase arrays |
| Internal helpers, phase execution, display helpers | `__dx_is_ticket()`, `__dx_setup_worktree()`, `__dx_run_phases_inline()` |
| Phased lifecycle and aliases | `dx()` |
| Prompt loop and refinement | `dxloop()`, `dxrefine()` |
| Completion and review loops | `dxcomplete()`; `dxreviewloop()` delegates to `dx_review_loop_run()` in lib/review-loop.sh |
| Worktree removal | `dxrm()` |
| Worktree listing | `dxls()` |
| Worktree navigation | `dxcd()` |
| Stale cleanup | `dxclean()` |

**Extraction candidates:** provider/model launch logic and Codex skill-link
logic have both moved out, to `lib/provider.sh` and `lib/codex.sh`. Duration
formatting has too: there is one `dx_format_duration()` in `lib/output.sh` and
`dx.sh` calls it. What is left is `__dx_show_header()`, which prints the
lifecycle banner — it reads phase state and outcome files, so moving it means
moving that reading too, not just the printing.

The provider seam is why `__dx_claude` and `__dx_provider_prompt` still exist as one-line
passthroughs: three test files redefine `__dx_claude` to stand in for the provider CLI, so
callers must reach the provider by that name rather than calling `lib/provider.sh` directly.
They live in `lib/review-loop.sh` beside the loop that uses them.

**What stays in dx.sh:** Functions that use zsh-specific syntax (`${(j: :)@}`, zsh arrays) or need `unalias/unfunction` re-sourcing guards. The public commands (`dx`, `dxloop`, `dxrm`, `dxls`, `dxclean`, `dxcomplete`, `dxreviewloop`, `dex`, `dexter`) must stay because they are shell functions loaded into the user's zsh session.

## Environment Variables

The environment values below are launch defaults. Active lifecycle consumers
re-read the corresponding `dx control override` records without a provider
relaunch. Review can use an override-bound lower target; named assurance
waivers remain separate from passed results. See `docs/autonomous-mode.md` for
the gate map.

| Variable | Purpose | Default |
|----------|---------|---------|
| `DEX_DIR` | Installation directory | `$HOME/work/dex` |
| `DX_STATE_DIR` | Phase state directory | `~/.claude/.dex-phases` |
| `DX_LOOP_DIR` | Loop state directory | `~/.claude/.dex-loops` |
| `DX_ARTIFACT_DIR` | Dex-generated screenshots, videos, traces, and logs | `~/.claude/.dex-artifacts` |
| `DX_TOOL_DIR` | Dex-managed external tooling cache | `~/.claude/.dex-tools` |
| `DX_RUN_ROOT` | Dex run directories, event journals, summaries, and run artifacts | `~/.dex/runs` |
| `DEX_RUN_ID` | Current run ID passed into hooks/provider subprocesses | unset |
| `DEX_HEADLESS_RUN` | Internal marker for lifecycle sessions started by `dx run` | unset |
| `DEX_HEADLESS_RUN_SPEC_FILE` | Normalized run spec path passed into the launched lifecycle | unset |
| `DEX_HEADLESS_REQUIRES_PLAN_APPROVAL` | Whether Phase 1 must wait for interactive plan approval | spec value |
| `DX_RTK_ENABLED` | Enable RTK token-reduction bootstrap (`0` disables) | `1` |
| `DX_RTK_BIN` | Override RTK binary path used by Dex hooks/checks | unset |
| `DX_RTK_INSTALL_DIR` | RTK binary install directory | `$DX_TOOL_DIR/rtk/bin` |
| `DX_RTK_VERSION` | Pin RTK release installed by Dex | latest GitHub release |
| `DX_RTK_HTTP_TIMEOUT_SECONDS` | Seconds one RTK download may take | 20 for release metadata, 180 for the binary |
| `DX_SESSION_RUNTIME_OWNER_START_TIMEOUT_MILLISECONDS` | Internal wait for a runtime supervisor to publish ready state; retry-time override, not a lifecycle gate | 15000 |
| `DX_SESSION_RUNTIME_OWNER_FINISH_TIMEOUT_MILLISECONDS` | Internal wait for a runtime supervisor to publish terminal state; retry-time override, not a lifecycle gate | 5000 |
| `DX_TIMEOUT_PROCESS_SCAN_TIMEOUT_SECONDS` | Internal bound for one macOS `lsof` scan while cleaning up a supervised process tree; invalid values fall back to the default | 3 |
| `DEX_LOOP_ACTIVE` | Enable phase audit loop | unset |
| `DEX_LOOP_PHASE` | Current phase (1-6 or "prompt-loop") | unset |
| `DEX_PHASE_HANDOFF` | Same-session phase handoff marker (`inline` for `dx`) | unset |
| `DEX_LOOP_PROMISE` | Human-readable completion acknowledgement; the generated receipt command carries authorization | unset |
| `DEX_LOOP_MAX_ITERATIONS` | Max loop iterations | 30 |
| `DEX_PHASE_TIMEOUT` | Seconds any one phase may run; `0` disables it | `0` (the session budget covers it) |
| `DEX_PHASE_<N>_TIMEOUT` | Same, for one phase only (e.g. `DEX_PHASE_2_TIMEOUT=3600`); wins over `DEX_PHASE_TIMEOUT` | unset |
| `DEX_STOP_SOUND` | Play a sound when Claude stops (macOS only); `0` turns it off | `1` |
| `DEX_STOP_SOUND_FILE` | Play this sound file instead of a random system one | unset |
| `DEX_SKIP_TOOL_BOOTSTRAP` | `1` makes `dx init` skip the Claude/Codex tooling bootstrap, for callers that already ran it | `0` |
| `DEX_SYNC_BUDGET_MINUTES` | Runtime budget for one `dx sync` provider run | 60 |
| `DEX_MAINTAIN_BUDGET_MINUTES` | Runtime budget for one scheduled maintenance run | 60 |
| `DEX_MAINTAIN_RESPOND_BUDGET_MINUTES` | Runtime budget for one maintenance PR feedback run | 30 |
| `DEX_REVIEW_TIER` | Canonical explicit review-risk override (`small`, `normal`, or `complex`); takes precedence over `DEX_REVIEW_PROFILE` | agent-selected |
| `DEX_REVIEW_PROFILE` | Legacy review-depth alias (`light`, `standard`, or `thorough`) | unset |
| `DX_REVIEW_PROFILE` | Older spelling of `DEX_REVIEW_PROFILE`, still read as a fallback | unset |
| `DEX_REVIEW_CLEAN_PASSES` | Optional higher clean-wave requirement; cannot lower the selected tier's global policy gate | global policy (1/2/3) |
| `DEX_REVIEW_DISABLE_MCP` | Disable inherited MCP servers in review waves (`0` restores them); read-only assessors always disable them | `1` |
| `DEX_REVIEW_PASS_TIMEOUT` | Seconds a review wave or risk assessment may run before its provider process tree is stopped and review pauses; `0` disables it | Profile-based: 15m assessment/light, 30m standard, 60m thorough |
| `DEX_REVIEW_PASS_RECHECK_SECONDS` | Seconds the Stop hook quietly polls for a busy Phase 3 review pass to finish | 45 (45s) |
| `DEX_WATCH_CYCLE_TIMEOUT_SECONDS` | Maximum runtime budget for one scheduled Phase 6 watcher invocation; a cycle past it hands over to the next tick, and a watcher that exits hands over at once. `0` means no budget | 120 (2m 0s) |
| `DEX_WATCH_COMMAND_TIMEOUT_SECONDS` | Maximum runtime for one GitHub/local shell command inside a watcher cycle | 30 (30s) |
| `DEX_WATCH_PAUSE_TTL_SECONDS` | Seconds scheduled Phase 6 watchers stay paused after a direct user prompt | 3600 (1h 0m) |
| `DEX_COMPLETE_MAX_CYCLES` | Max idle PR watch cycles before Phase 6 pauses for manual follow-up | 3 |
| `DEX_COMPLETE_WAIT_MINUTES` | Minimum wait window per Phase 6 cycle (minutes) | 5 |
| `DEX_SESSION_ID` | Unique session ID (set by dxloop for stop hook) | unset |
| `DEX_REVIEW_ASSESSMENT_ACTIVE` | Internal marker for the read-only preflight risk assessor | unset |
| `DEX_REVIEW_PASS_ACTIVE` | Marks a session as a single-shot review-wave pass so its Stop hook can never run the parent lifecycle's inline phase handoff | unset |
| `CODEX_HOME` | Codex config root used for Dex skill links | `~/.codex` |
| `DX_AGENT` / `DX_AGENT_OVERRIDE` | Agent override (`claude` or `codex`) | profile/default |
| `DX_MODEL` / `DX_MODEL_OVERRIDE` | Model override for the selected agent | profile/default |
| `DX_PROVIDER_PROFILE` | Provider profile override (`claude-subscription`, `codex-subscription`, or custom) | config/default |
| `DX_CLAUDE_MODEL` | Override Claude Code model passed to `--model` | profile model, else session default |
| `DX_PLAN_MODEL` | Override Phase 1/plan model | `DX_CLAUDE_MODEL`, profile plan model, else session default |
| `DX_CODEX_MODEL` | Resolved Codex model passed through `bin/dxcodex.sh` | profile codex model, else Codex default |
| `DX_CODEX_READ_ONLY` | Internal marker that switches Codex delegation to an ephemeral read-only sandbox and forbids dangerous bypass flags | `0` |
| `DX_CLAUDE_EFFORT` | Override Claude Code `--effort` | profile effort, else session default |
| `DX_PLAN_EFFORT` | Override Phase 1/plan effort | `DX_CLAUDE_EFFORT`, profile plan effort, else session default |
| `DX_ALLOW_API_BILLED_AUTH` | Allow `dx provider doctor` to tolerate API/gateway env vars | `0` |
| `DX_ALLOW_REPO_GATEWAY_PROVIDER` | Explicitly allow a trusted repo-local gateway/API provider profile for the current invocation | `0` |
| `DX_ALLOW_FORK_PR_CHECKOUT` | Skill-level opt-in letting `/dxprreview` check out fork PRs | `0` |

## Files to Never Commit

- `.DS_Store`
- `__pycache__/`, `*.pyc`
- `.dex/worktrees/` (ephemeral)
- `~/.claude/.dex-artifacts/` UI captures (screenshots, videos, traces, logs)
- `~/.claude/settings.json` (user-specific)
- Anything containing secrets or credentials
