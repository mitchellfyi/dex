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
  `hooks/shell_parse.py` — the shell-command reading both of them share;
  `scripts/*.py` — helpers `lib/` invokes with `python3` or imports via
  `PYTHONPATH` (redaction, settings merging, lifecycle-control parsing, run-log
  tee, project state). No external dependencies
- **Node (no dependencies):** `scripts/ui-capture.cjs` — the Playwright
  UI-capture driver
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
research/            Review-loop benchmark harness (scenario repos, oracles, orchestrator) — not shipped functionality
scripts/             Python/Node helpers imported by lib/ and Dex-managed tooling
skills/              Lifecycle skills (linked into ~/.claude/skills/ and individually to $CODEX_HOME/skills/)
templates/           Files Dex installs into other repos (the dx-maintain GitHub workflow)
tests/               Test suite: check.sh (static), run-all.sh (manifest runner), *-test.sh
.github/workflows/   CI plus the DexCode plan, Dependabot-guard, and maintenance workflows
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

### bin/ script tiers

User-facing `bin/` scripts (`init.sh`, `status.sh`, `config.sh`, …) take
`-h`/`--help` and print a `usage()` block. Internal ones invoked only by Dex
itself (`activate-loop.sh`, `complete-receipt.sh`, `escalate.sh`,
`install-settings.sh`, `session-runtime-owner.sh`) validate arity and print a
bare `Usage:` line — they have no human callers to help. Keep a new script in
the tier its callers put it in.

### Library sourcing

```bash
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"
```

Sourcing `common.sh` sources every other module in `lib/` — see the module table below for
what each one owns.

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

Dex ships no third-party vendor skills (Figma, Asana, Linear, Notion, Slack, HubSpot,
Microsoft 365, Gmail, Google Calendar, Fireflies). Their vendors distribute them through
Claude's official plugin/MCP integrations.

**Never commit one here.** A vendor skill directory under `skills/` (e.g. `skills/figma-*/`)
came from a plugin install; delete it. It belongs in the user's `~/.claude/` or behind the
official integration.

`skills/synced/` is the exception: Claude Code writes claude.ai organization skills to
`~/.claude/skills/synced/`, and `~/.claude/skills` links to it. Gitignored — leave it, Claude
Code recreates it.

To enable one:

| Vendor | How to enable |
|--------|---------------|
| Figma  | <https://help.figma.com/hc/en-us/articles/32132100833559-Guide-to-the-Dev-Mode-MCP-Server> |
| Linear | <https://linear.app/changelog/2025-05-01-mcp> |
| Asana, Notion, Slack, HubSpot, Microsoft 365, Gmail, Google Calendar, Fireflies | Enable the corresponding integration on <https://claude.ai/settings/connectors> |
| Other  | Browse the Claude plugin marketplace via `/plugin` inside Claude Code, or check the vendor's docs for their official MCP/skill integration |

Those MCP servers authenticate through claude.ai or `claude mcp`, appear as
`mcp__claude_ai_<Vendor>__*`, and reach Dex's skills automatically once enabled.

`dx install`, `dx init` and `dx sync` may install a narrow official allowlist: Dex
Claude/Codex skill links, browser MCPs, OpenAI docs MCP, the OpenAI Codex Claude plugin when
Codex is installed, `frontend-design` for frontend repos, official LSP plugins for detected
TypeScript/JavaScript, Python, Rust or Go, and the RTK binary with its Dex-managed
hook/instruction files. Never add broad behaviour-changing plugins, community marketplaces or
vendor integrations to that path.

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
  `warn-await-in-loop`, `warn-hardcoded-secrets`, `warn-sensitive-files`,
  `warn-ccr-live-state`
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
- `freeform-intake.md` — Phase 0 prompt triage, issue creation approval, and recorded intake decision
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

Launch rules:

- Claude: always `--dangerously-skip-permissions` plus `--permission-mode bypassPermissions`.
- Codex: always through `bin/dxcodex.sh`. Never reintroduce `--full-auto`.
- Interactive lifecycles: `codex [PROMPT]` or `codex resume <session-id> [PROMPT]`, with
  `--dangerously-bypass-approvals-and-sandbox`, `--dangerously-bypass-hook-trust`, and
  session-scoped `SessionStart`/`Stop` hooks.
- Non-interactive delegation: `--ignore-user-config` plus `--dangerously-bypass-approvals-and-sandbox`.
- Internal read-only: `DX_CODEX_READ_ONLY=1` with
  `--ignore-user-config --sandbox read-only --ephemeral`, and no bypass flag.
- `dx --model <model>` targets the selected agent through its native model flag. Only
  codex-plugin profiles resolve a `codex_model` override; other engines use the Codex default.

Codex's app server may run hooks outside the launcher's environment, so the wrapper passes its
allowlisted, non-secret context both in the hook commands and through
`shell_environment_policy.set`. Never put credentials there.

Both interactive providers capture their exact conversation ID at startup for crash-safe
resumption. Claude's stable Dex session name and Codex's cwd-scoped `--last` remain fallbacks
for lifecycles created before capture existed. The wrapper works under any profile, so a
Claude-engine run can hand individual tasks to Codex.

### CCR router live state

`scripts/ccr/` is not ordinary repo code: it drives the user's live client
configuration. `~/.claude/settings.json` (apiKeyHelper, `ANTHROPIC_BASE_URL`,
model picker), `~/.codex/config.toml` (the `dex-ccr` provider), and
`~/.dex/router/` (`config.json`, `backend.json`, and the ownership record
`credentials/native-client-settings.json`) are what let the user run claude
and codex at all. An agent that corrupts them takes away the user's ability
to run any local agent, including one that could repair the damage. The
`warn-ccr-live-state` guard flags ad-hoc interpreter access to these modules
and state paths; these rules are what its message points at.

- Never exercise router internals (`clientSettings`, `syncContext`,
  `saveBackend`, `state.write`) ad hoc against the real home directory. Tests
  sandbox with `DEX_ROUTER_HOME=$(mktemp -d)` plus fixture
  `CLAUDE_CONFIG_DIR`/`CODEX_HOME`; copy `tests/ccr-native.test.cjs`.
- Real changes go through the CLI (`dx router …` =
  `node scripts/ccr/cli.cjs router …`). It holds the config lock, reads the
  live gateway from `state.backend()`, and keeps `config.native.enabled` in
  step with the installed client files. A direct `clientSettings("enable", …)`
  call with a hand-built `{ gateway }` wrote
  `ANTHROPIC_BASE_URL=undefined/plugins/dex` into the live settings once and
  deadlocked `native enable` and `native disable`.
- Invariants: gateway ports survive restarts only while
  `config.native.enabled` is true, and both client files pin the port;
  `native enable` refuses to run when the ownership record and the live files
  disagree; `native disable` restores only when the flag is true. Drift
  between flag, record, and files is a lockout.
- If the live state is already inconsistent, follow the recovery steps in
  docs/subscription-routing.md § Failures and recovery. Snapshot every file
  before touching anything.

### Hook integration

Hooks defined in `settings.json`, referenced by paths to Dex scripts:

| Hook | Matcher | Script | Purpose |
|------|---------|--------|---------|
| SessionStart | `startup` | `capture-provider-session.sh`, `load-ticket-context.sh` | Save the exact provider conversation ID, load ticket context, and detect focus areas |
| UserPromptSubmit | (all) | `user-prompt-submit.sh` | Pause scheduled Phase 6 watchers during manual user work |
| PreToolUse | `Bash` | `guard-handler.py` (`DEX_GUARD_EVENT=bash`) | Block/warn on dangerous commands |
| PreToolUse | `Bash` | `rtk-claude-hook.sh` | Optional RTK output-filtering rewrite; runs after the guard and fails open |
| PreToolUse | `Edit\|Write\|MultiEdit\|NotebookEdit` | `guard-handler.py` (`DEX_GUARD_EVENT=file`) | Block/warn on dangerous file edits |
| PostToolUse | `Bash` | `post-commit-guard.sh` | Validate commit format via guards |
| Stop | Interactive agent tries to stop | `phase-loop.sh`, `stop-sound.sh` | Phase audit loop (when active) plus best-effort macOS sound notification |
| PreCompact | Before compaction | `pre-compact.sh` | Preserve Dex context across compaction |
| SessionEnd | Session ends | `session-end.sh` | Record session end metadata |

### Phase audit loops

When `DEX_LOOP_ACTIVE=1`, the Stop hook intercepts Claude's exit and injects a
phase-specific audit prompt. Normal gate advancement requires the exact
generation-bound completion receipt the hook authorized for that session and
phase; a bare `.complete` marker is not authorization. A human or agent `done`,
`waive`, or `jump` control records a waiver or skip instead of claiming the gate passed. The loop
stops for intervention after its configured audit limit, which defaults to 30.
For `dx` lifecycles, the hook advances phases inside the same interactive provider session by
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

The outer review loop is separate. The Phase 2 agent selects `small`, `normal` or `complex`;
those map to consecutive-clean requirements of 1, 2 and 3 and soft wave budgets of 3, 6 and 9.

- Every assessor and wave gets a temporary pass-scoped copy of the approved criteria.
- The sealed criteria hash and global policy bind to resumable state, the risk selection,
  per-item evidence, every clean ledger row, and the success receipt.
- Receipt validation reopens retained proofs and recomputes every clean-pass attestation.
- Standalone waves use the explicit `standalone` criteria binding. A standalone loop with no
  override, and legacy or resumed lifecycles with no valid current-scope selection, start from
  a fresh read-only assessor.
- Spending the wave budget pauses without a completion receipt and without losing valid clean
  credit. An attributed `review.max-waves` override changes the budget, never the assurance.
- Changed or partly covered criteria, residual findings, blockers, churn, invalid results and
  provider failures also pause the loop.

### Session IDs

Derived from a stable repo key plus worktree names (`worktree-<name>`) or branch names (fallback). Used to key all state files. Path-based derivation makes worktree sessions stable across branch renames while the repo key prevents cross-repo collisions in the global state directories.

### Worktree isolation

Free-form `dx "<prompt>"` requests first choose session only (default) or the
full workflow. `--session` and `--workflow` bypass the menu; non-terminal
prompts require a mode. Ticket IDs and workspace flags select the lifecycle.
Session-only runs use the current checkout and selected provider without
worktree creation or phase audits. `DEX_SESSION_ONLY=1` suppresses ticket
intake and lifecycle hooks; its unique `prompt-` state must not overwrite
the checkout's provider alias or the last lifecycle session.

Each ticket gets its own git worktree in `.dex/worktrees/`. The `dx` shell function manages creation, cleanup, and resumption.

Exception: `dx --no-worktree <ticket-or-description>` runs the same phased lifecycle in the current checkout. It still creates or switches to the normal Dex lifecycle branch (`worktree-ticket-*` / `worktree-task-*`) from the default branch's upstream or remote-tracking ref; it only skips `git worktree add`. In-place sessions persist their current branch in phase state so resume can switch back or stop rather than continuing on the wrong checkout branch.

## Provisioned Host Parity

When a task also changes a provisioned development host, read that infrastructure
repository's instructions. Keep Dex generic — host-specific defaults and activation belong
there. Check router policy, provider compatibility, native-client setup, hooks and installer
changes against the host's provisioning templates.

- A live workaround needs matching versioned source and a removal step.
- A published fix needs its activation step applied when authorized, or reported as pending:
  updating source does not replace code already loaded by a router or other service.
- Preserve active sessions, private configuration and deliberate overrides.
- Verify the source revision *and* the effective host configuration with the host's supported
  diagnostics before declaring parity.

## Quality Gates

Focused shell tests live under `tests/`. No formatter; verification is static checks plus the
test suite.

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

A test whose assertion is a wall-clock bound cannot share the machine. Put it in the `serial`
lane in `tests/manifest.tsv`, and optionally note why near its shebang:

```bash
# dex-test-lane: serial
# <why this one measures time>
```

`tests/manifest.tsv` is authoritative. `service` and `serial` tests run
exclusively; `fast` and `slow` tests may run in parallel. If a legacy
`# dex-test-lane:` marker is present, the runner verifies that it agrees with
the manifest instead of using it to select the lane.

Use it only when the bound is genuinely about elapsed time. A slow test is not a serial test;
the lane is not a place to hide flakiness with another cause.

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

`dx.sh` is the largest shell file. Prefer extracting shared or self-contained logic into
`lib/` modules.

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

**Current library modules and their responsibilities:** see
[docs/reference.md](docs/reference.md#shared-library-modules) — every module in `lib/`, what
it owns, and its key functions. `common.sh` sources all of them except itself and
`router.sh`, which `lib/provider.sh` sources lazily.

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

The full table — every variable, its purpose and its default — is in
[docs/reference.md](docs/reference.md#environment-variables). Read it when you need a
specific variable rather than carrying all of them in every session.

## Files to Never Commit

- `.DS_Store`
- `__pycache__/`, `*.pyc`
- `.dex/worktrees/` (ephemeral)
- `~/.claude/.dex-artifacts/` UI captures (screenshots, videos, traces, logs)
- `~/.claude/settings.json` (user-specific)
- Anything containing secrets or credentials
