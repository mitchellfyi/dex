# Doyaken

Standalone workflow automation for Claude Code. Autonomous ticket lifecycle, worktree isolation, coding conventions — works with any repo.

## Quick Start

```bash
# One-time global install
bash ~/work/doyaken/install.sh
source ~/.zshrc
dk status

# Bootstrap a repo (analyzes codebase with Claude Code CLI)
cd ~/work/myproject
dk init

# Start work on a ticket
dk 999
```

## Why Claude Code, not Codex?

Doyaken is built on Claude Code-specific primitives, not a portable agent abstraction. The lifecycle relies on:

- **Stop hook** — phase audit loops re-inject quality checks until Claude passes them
- **`--fork-session`** — fresh context window per phase while keeping the named session for `--resume`
- **Plan mode** — `EnterPlanMode` / `ExitPlanMode` give Phase 1 a read-only quality gate
- **`--append-system-prompt-file`** — phase scope and completion protocol survive context compaction
- **Skills, SessionStart hooks, status line, `--from-pr`** — all wired through Claude Code's harness

Codex CLI doesn't currently expose equivalents, so swapping backends would mean re-implementing the audit loop, plan mode, and per-phase context handoff from scratch. Until that lands, `dk` requires the `claude` CLI on your `PATH`.

### Provider profiles

Claude Code cannot use the OpenAI API or Codex CLI as a backend through settings alone: it speaks Claude Code's Anthropic-compatible API shape and expects Claude Code features such as hooks, skills, sessions, and plan mode. Doyaken keeps Claude Code as the outer harness and lets you choose how substantive model work is routed.

Built-in profiles:

- `claude-subscription` — direct Claude Code using Claude subscription OAuth. This is the default.
- `codex-subscription` — Claude Code remains the lifecycle harness, but phase prompts delegate substantive coding/review work to the local Codex CLI using ChatGPT subscription auth. The OpenAI Codex Claude Code plugin is optional for slash commands.

`codex-subscription` reduces Claude Code usage; it is not a zero-Claude fallback. Claude Code still has to start, load hooks/skills, and orchestrate the lifecycle, so a fully exhausted Claude Code quota can still block `dk`.

```bash
dk provider list
dk provider current
dk provider doctor
dk provider use codex-subscription
dk provider use --repo codex-subscription
```

For subscription-safe modes, Doyaken strips Anthropic API, gateway, Bedrock, Vertex, Foundry, OpenAI API/base-url, and Claude model override variables from launched Claude Code and Codex CLI subprocesses. `dk provider doctor` warns when these variables would risk API billing or override profile routing.

`codex-subscription` preflights the local Codex CLI before launching Claude. Delegated work goes through Doyaken's `bin/dkcodex.sh` wrapper, which enforces `--ignore-user-config` so `~/.codex/config.toml` cannot switch work to a custom/API provider. A built-in PreToolUse guard blocks raw Codex agent-work commands such as `codex`, `codex exec`, `codex e`, `codex review`, direct `dk_provider_codex` helper delegation, API-key login forms, shell-nested forms including literal variable-expanded and escape-decoded `bash -c`/`eval`/stdin payloads, generated heredoc scripts, direct executable script paths, readable executed or sourced script files, Python/Node/Ruby/Perl interpreter payloads that launch Codex, fail-closed unresolved/unreadable script paths, launch wrappers such as `nice`, `timeout`, `xargs`, and `find -exec`, package-runner forms such as `npx codex`, `npx -c "codex exec ..."`, `npm exec --call "codex exec ..."`, and `npx @openai/codex@latest`, and non-literal stdin/process-substitution generators piped into shells while this provider profile is active, so delegated work has to pass through the wrapper. The guard reads Doyaken's current session provider state first when a session id is present, with hook environment/config fallback, so it does not rely only on hook subprocess environment inheritance. Codex must be installed and signed in with ChatGPT, plus the OpenAI Codex Claude Code plugin if you want the plugin slash commands:

```text
/plugin marketplace add openai/codex-plugin-cc
/plugin install codex@openai-codex
/reload-plugins
/codex:setup
```

Manual smoke tests for the Codex delegation path:

```bash
dk provider use codex-subscription
dk provider doctor

# In a Claude Code session launched by Doyaken, this should be blocked by the guard:
codex exec "review this repository"

# The wrapper should be allowed, including dash-leading prompt text:
bash "$DOYAKEN_DIR/bin/dkcodex.sh" exec -- "- review the current diff"
```

For env sanitization, temporarily set `OPENAI_API_KEY` or `ANTHROPIC_BASE_URL`, then run `dk provider doctor`; subscription-safe profiles should report the variable as unsafe until it is unset.

Manual evidence captured for this change used `codex-cli 0.125.0`, `Claude Code 2.1.123`, and `ShellCheck 0.11.0`. `dk provider doctor` passed the Claude/Codex CLI, `--ignore-user-config`, ChatGPT login, and plugin checks in `codex-subscription` mode. Guard smoke tests blocked raw Codex, helper, package-runner, shell/interpreter/heredoc/generated-script, escape-decoded, and launcher-wrapper delegation paths; allowed Codex help/status and safe print/echo cases; and confirmed the wrapper rejects caller-supplied Codex options. The post-commit guard detected and reported hidden `git commit` after Bash completion through shell, interpreter, generated-script, escape-decoded, and launcher-wrapper paths.

Custom subscription profiles can be defined globally in `~/.doyaken/providers.json` or per repo in `.doyaken/providers.json`. Every custom profile must declare its `engine` and supported `auth` mode. Gateway profiles are custom because they need a real base URL, auth policy, and model id for your gateway; define them globally unless you explicitly opt into a trusted repo profile for one invocation with `DK_ALLOW_REPO_GATEWAY_PROVIDER=1`.

```json
{
  "default": "codex-custom",
  "profiles": {
    "codex-custom": {
      "engine": "codex-plugin",
      "auth": "chatgpt-subscription",
      "model": "opus",
      "plan_model": "opus",
      "effort": "max"
    },
    "gateway-local": {
      "engine": "anthropic-gateway",
      "auth": "api-token",
      "base_url": "http://localhost:4000",
      "auth_env": "LITELLM_MASTER_KEY",
      "model": "your-gateway-model",
      "plan_model": "your-gateway-model",
      "effort": "xhigh"
    }
  }
}
```

Built-in profile names are reserved; custom profiles should use their own names. Omit `codex_model` to let the Codex CLI use its configured default, or set it only to a model id you know your installed Codex CLI supports.

`dk provider use --repo <profile>` can select built-in profiles or subscription-safe profiles defined in that repo's `.doyaken/providers.json`. Repo defaults are intentionally self-contained and do not depend on profiles that exist only in a user's global config. Repo gateway/API defaults are not auto-activated, and repo configs cannot use common ambient credential env vars such as `GITHUB_TOKEN`, `ANTHROPIC_API_KEY`, or `OPENAI_API_KEY` as gateway auth.

Gateway mode requires a real Anthropic-compatible gateway exposing `/v1/messages`. Doyaken rejects `https://api.openai.com` as a gateway base URL because the request and streaming schemas are different.

## Lifecycle

When you run `dk 999`, Doyaken creates an isolated git worktree and runs Claude through six autonomous phases. Each phase is a separate Claude Code session (`--fork-session`), so every phase starts with a fresh context window. The user is brought into the loop as a configured reviewer in Phase 6 — the autonomous loop waits for their review (and any other configured reviewers) and only closes the ticket once everyone has approved.

If you want the same lifecycle without a separate checkout, run `dk --no-worktree <ticket-or-description>`. In-place mode still creates or switches to the normal Doyaken branch (`worktree-ticket-*` / `worktree-task-*`) in the current checkout; it just skips `git worktree add`. Phase 4 commits and pushes that branch. If the current checkout has uncommitted changes and Doyaken needs to switch/create the lifecycle branch, it stops so you can commit or stash first.

```
dk 999
  │
  ├─ Phase 1: Plan          Claude explores codebase, presents approaches, user approves
  ├─ Phase 2: Implement     TDD implementation, completeness verification
  ├─ Phase 3: Review        Adversarial code review (3 clean passes, fresh sessions)
  ├─ Phase 4: Verify        Format, lint, typecheck, test → commit + push
  ├─ Phase 5: PR            Generate description, create draft PR + attach reviewers
  └─ Phase 6: Complete      Mark ready, request reviews, monitor CI, address comments,
                            re-request reviewers each push, close ticket
```

| Phase | Skills | What Happens | User Action |
|-------|--------|-------------|-------------|
| 1. Plan | `/dkplan` | Reads ticket, explores code, presents 2-3 approaches, drafts plan | Approve plan |
| 2. Implement | `/dkimplement` | TDD per task, evidence table, completeness check | Only for scope/requirement changes |
| 3. Review | `/dkreview` + self-reviewer | Adversarial 4-pass review, 3 consecutive clean passes required | — |
| 4. Verify & Commit | `/dkverify` + `/dkcommit` | Quality gates, atomic conventional commits, push | — |
| 5. PR | `/dkpr` | PR description, create draft PR, attach `request`-type reviewers | — |
| 6. Complete | `/dkcomplete` + `/dkwatchci` + `/dkwatchpr` | Mark ready, request reviews, post `@mention` comments, monitor, address comments, close ticket | Review/approve when configured; respond only to escalations |

After Phase 1 approval, `dk` keeps advancing through Phases 2-5 without asking whether to continue. It stops for human input only when requirements change, credentials/tooling are missing, a destructive git decision is needed, repeated CI failures occur, max audit/review iterations are reached, reviewer feedback needs human judgement, or Phase 6 is waiting for CI/reviewer approval.

### Audit Loop

Each phase runs inside an audit loop. Phase 1 still uses Plan Mode for the user approval gate; after approval, the Stop hook handles the shell handoff. When Claude tries to stop, the Stop hook intercepts and injects a phase-specific quality audit. Claude must pass the audit before the hook authorizes completion.

```
Claude does work → tries to stop
  │
  ▼
Stop hook fires
  ├─ .complete file exists?  → exit Claude Code, advance to next phase
  ├─ Max iterations reached? → exit Claude Code, pause for intervention
  ├─ Below min audit passes? → BLOCK, inject audit prompt (no completion instructions)
  └─ At/above min passes?   → BLOCK, inject audit prompt WITH completion instructions
                                │
                                ▼
                              Claude follows audit → fixes issues → tries to stop → loop repeats
```

### Review Sub-Loop (Phase 3)

Phase 3 uses a **shell-managed sub-loop** on top of the standard audit loop. Each review iteration is a fresh Claude session (`--fork-session`), ensuring each adversarial review starts with a clean context. The shell tracks consecutive CLEAN results:

```
Shell starts review sub-loop (clean_passes=0)
  │
  ▼
Launch fresh Claude session with Stop hook (MIN_AUDITS=1)
  ├─ Claude runs /dkreview + 4-pass manual review + self-reviewer agent
  ├─ Builds merged findings inventory, fixes issues
  ├─ Writes review result signal: "CLEAN" or "FINDINGS:N"
  └─ Stop hook verifies, allows completion
  │
  ▼
Shell reads review result
  ├─ CLEAN → clean_passes++ → if ≥3: advance to Phase 4
  └─ FINDINGS → clean_passes=0 → fresh session → loop repeats
```

Each review iteration runs:
1. `/dkreview` — deterministic + 10-pass semantic review
2. Manual 4-pass review (Logic, Structure, Security, Holistic)
3. `self-reviewer` agent — independent adversarial review
4. Merged findings inventory → batch fix → re-verify

Default: 3 consecutive clean passes required. Override: `DOYAKEN_REVIEW_CLEAN_PASSES=5`.

Claude never learns how to signal completion on its own — the hook provides the `.complete` file path and promise string only after enough clean passes. This prevents premature completion.

### Session Timeout

Default: 24 hours for the entire `dk` run (all phases). Override: `DOYAKEN_SESSION_TIMEOUT=14400` (4h). Set to 0 to disable.

### Escalation

Even in autonomous mode, Claude stops and escalates to the user for:
- Secrets scan failures (never auto-fix security issues)
- Architectural review comments (need human judgement)
- 3+ failed attempts at the same fix (loop is stuck)
- Scope changes that affect other tickets
- Missing credentials/tooling or destructive git operations that require explicit approval
- Max audit/review iterations without a completion signal

The user can always interrupt with Ctrl+C. Between phases, state is saved so `dk 999` or `dk --resume` picks up where it left off.

See [docs/autonomous-mode.md](docs/autonomous-mode.md) for full architecture.

## What needs `dk init`?

Most Doyaken features work immediately after `dk install` — no per-project setup required:

| Feature | Needs `dk init`? | Notes |
|---------|:---:|-------|
| `dkloop <prompt>` | No | Works in any git repo |
| `dkcomplete` | No | Works in any git repo with a PR |
| `dkreviewloop` | No | Works in any git repo with detectable changes |
| `/dkloop`, `/dkplan`, `/dkimplement`, etc. | No | Skills work in any Claude Code session |
| Codex skill discovery | No | `dk install` links Doyaken skills into `$CODEX_HOME/skills` (default `~/.codex/skills`) when Codex CLI is present |
| Hooks (guards, commit validation, ticket context) | No | Installed globally by `dk install` |
| Agents (self-reviewer) | No | Symlinked globally by `dk install` |
| `dk <number>` / `dk "description"` | No | Worktrees work in any git repo |

**What `dk init` adds:** It runs Claude Code CLI to analyze your specific codebase and generates project-tailored configuration in `.doyaken/`:

- **Quality gates** (`doyaken.md`) — discovers your format, lint, typecheck, and test commands from package.json, Makefile, CI config, etc. Without init, skills discover these at runtime (slower, may miss non-obvious commands).
- **Coding conventions** (`rules/`) — generates rule files from observed patterns (naming, file structure, error handling). Without init, Claude infers conventions from context each time.
- **Project-specific guards** (`guards/`) — creates guards for files that should never be committed (environment files, generated configs). Without init, only the universal guards (destructive commands, secrets, sensitive files) are active.
- **Integration config** — configures ticket tracker (Linear, GitHub Issues), Figma, Sentry, etc. Without init, skills skip tracker updates.
- **Codex skill repair** — if Codex CLI is installed, refreshes Doyaken skill links in `$CODEX_HOME/skills` (default `~/.codex/skills`) without replacing Codex's own system skills.

In short: everything works without init, but init makes it faster and more accurate by caching project knowledge.

## Commands

```bash
# Global
dk install           # Symlink Claude skills/agents, Codex skills, hooks, shell functions
dk uninstall         # Remove global symlinks, hooks, Codex skill links, and Doyaken settings
dk status            # Show what's installed and where

# Per-project
dk init              # Bootstrap current repo — analyzes codebase, generates config
dk config            # Configure integrations (ticket tracker, Figma, Sentry, etc.)
dk uninit            # Remove Doyaken from current repo

# Worktrees
dk <number>          # Create worktree, run full autonomous lifecycle (Plan → Complete)
dk "<description>"   # Same, for a task without a ticket number
dk --no-worktree <task> # Run the full lifecycle in the current checkout
dk --resume          # Resume a previous session
dk revert <N> [phase] # Revert worktree to a phase checkpoint
dk log [session_id]  # Show structured phase execution log
dkrm <number|name>  # Remove worktree
dkrm --all          # Remove all worktrees
dkls                # List active worktrees
dkcd                # cd to repo root
dkcd <number|slug>  # cd to a worktree (fuzzy match)
dkclean             # Prune stale worktrees, gone branches, orphan branches

# Standalone completion (recovery / non-dk PRs)
dkcomplete           # Run Phase 6 manually on the current branch's PR

# Standalone review (3-clean-passes loop, no full lifecycle)
dkreviewloop         # Shell function — spawns full Claude CLI sessions per pass (terminal)
/dkreviewloop        # Skill — orchestrates fresh Agent-tool subagents per pass (in-session)

# Prompt loop (no worktree or ticket needed)
dkloop <prompt>     # Run a prompt until fully implemented (from terminal)
/dkloop <prompt>    # Same, but from inside an existing Claude Code session

# Maintenance
dk reload            # Reload shell functions after editing dk.sh
dk provider current  # Show active Claude/Codex/gateway execution profile
dk provider doctor   # Check subscription-safe provider setup
```

## Structure

```
doyaken/
  agents/                    # Sub-agents -> symlinked to ~/.claude/agents/
    self-reviewer.md         # Read-only code reviewer with persistent memory
  bin/                       # CLI scripts
    install.sh               # Global install
    uninstall.sh             # Global uninstall
    init.sh                  # Per-project bootstrap (uses Claude Code CLI)
    uninit.sh                # Per-project removal
    config.sh                # Integration configuration (ticket tracker, Figma, etc.)
    status.sh                # Show installation status
  docs/                      # Extended documentation
    guards.md                # Guard system (hookify-style rules)
    autonomous-mode.md       # Phase audit loops and autonomous execution
  skills/                    # Lifecycle skills -> symlinked to ~/.claude/skills/
                             # Each skill is a directory containing SKILL.md
    doyaken/                 # Orchestrate full ticket lifecycle
    dkplan/                  # Implementation planning (multi-approach)
    dkimplement/             # TDD implementation with completeness verification
    dkreview/                # Four-phase agentic review with confidence scoring
    dkverify/                # Discover and run project quality gates
    dkcommit/                # Atomic conventional commits
    dkpr/                    # PR description, reviews, monitoring
    dkwatchci/              # CI monitoring via /loop
    dkwatchpr/              # PR review monitoring via /loop
    dkprreview/              # Critically evaluate and address PR review comments
    dkcomplete/              # Final verification, ticket closure
    dkloop/                  # In-session prompt loop (run until done)
    dkreviewloop/            # In-session 3-clean-passes review via fresh Agent subagents
  lib/                       # Shared shell library (sourced by dk.sh and hook scripts)
    common.sh                # Constants, bootstrap (sources other lib files)
    codex.sh                 # Codex CLI skill-link helpers
    git.sh                   # Git helpers (default branch detection, slugify)
    provider.sh              # Provider/model profile resolution and diagnostics
    session.sh               # Session ID and state file path helpers
    output.sh                # Formatted output ([done], [ok], [warn], etc.)
  hooks/                     # Hook scripts (referenced from ~/.claude/settings.json)
    load-ticket-context.sh   # SessionStart — ticket context + focus area detection
    post-commit-guard.sh     # PostToolUse — commit validation via guards
    guard-handler.py         # PreToolUse — markdown-based guard evaluation
    phase-loop.sh            # Stop — phase audit loop (quality-gated execution)
    guards/                  # Markdown guard rules (universal)
      destructive-commands.md
      raw-codex-delegation.md
      sensitive-files.md
      hardcoded-secrets.md
  prompts/                   # Prompts referenced by skills and agents
    review.md                # 10-pass review criteria + confidence scoring
    guardrails.md            # AI discipline + implementation principles (referenced by skills)
    pr-description.md        # PR description template
    commit-format.md         # Conventional commit format + grouping rules
    ticket-instructions.md   # Ticket intake workflow (injected by SessionStart hook)
    init-analysis.md         # Codebase analysis prompt (used by dk init)
    phase-audits/            # Phase-specific audit prompts (injected by Stop hook)
      1-plan.md              # Plan quality audit
      2-implement.md         # Implementation completeness audit
      3-review.md            # Adversarial code review audit (shell sub-loop)
      4-verify.md            # Verification + commit audit
      5-pr.md                # PR quality audit
      6-complete.md          # Phase 6 cycle-loop audit (mark ready, monitor, close)
      prompt-loop.md         # Prompt loop audit (used by dkloop)
  dk.sh                      # Shell functions (dk, dkrm, dkls, dkclean, dkloop, doyaken)
  install.sh                 # Quick-start installer (delegates to bin/install.sh)
  settings.json              # Hook definitions template
```

### Per-project structure (created by `dk init`)

```
.doyaken/
  doyaken.md                 # Project-specific config (generated by Claude Code CLI)
  CLAUDE.md                  # @import of doyaken.md (auto-discovered by Claude Code)
  rules/                     # Coding conventions (generated from codebase analysis)
  guards/                    # Project-specific guard rules (generated)
  worktrees/                 # Worktree directories (created by dk)
```

Claude Code automatically discovers `CLAUDE.md` files in the project directory and all subdirectories (see [Claude Code docs: CLAUDE.md](https://docs.anthropic.com/en/docs/claude-code/memory#claudemd)). `.doyaken/CLAUDE.md` uses the `@doyaken.md` import directive to pull in the generated project config, so Claude sees it as part of the project context in every session.

## Internals

### Init (codebase analysis)

`dk init` creates a `.doyaken/` directory, then uses **Claude Code CLI** to analyze the codebase and generate project-specific configuration:

- **Quality gates** — discovers format, lint, typecheck, test commands from package.json, Makefile, CI config
- **Coding conventions** — generates rule files from observed patterns in the codebase
- **Guards** — creates guards for files that should never be committed (environment files, generated configs)
- **Integrations** — asks which integrations to use (ticket tracker, Figma, Sentry, Vercel, Grafana)

Flags:
- `--skip-analysis` — skip codebase analysis (still runs integration config unless `--skip-config` is also set)
- `--skip-config` — skip integration configuration (run `dk config` later)

To reconfigure integrations at any time: `dk config`

### Skills (immediate updates)

Claude skills are symlinked as a directory: `~/.claude/skills/ -> ~/work/doyaken/skills/`. Claude Code auto-discovers them as slash commands (`/doyaken`, `/dkplan`, etc.).

Codex skills are linked individually into `$CODEX_HOME/skills/<skill-name> -> ~/work/doyaken/skills/<skill-name>` (`CODEX_HOME` defaults to `~/.codex`). Doyaken does not replace the Codex skills directory, because Codex stores system and plugin skills there too. `dk install` creates these links globally, and `dk init` repairs them when Codex CLI is present.

Edit a skill file — change takes effect in the next Claude or Codex invocation that loads that skill.

All skills are **codebase-agnostic**. They discover the project's toolchain, conventions, and quality gates from the codebase itself rather than prescribing specific commands.

### Agents (immediate updates)

Agents are symlinked: `~/.claude/agents/ -> ~/work/doyaken/agents/`. Claude Code auto-discovers them and delegates tasks based on their descriptions.

### Hooks (immediate updates)

Hooks are defined in `~/.claude/settings.json` with paths to Doyaken scripts (see [Claude Code hooks](https://docs.anthropic.com/en/docs/claude-code/hooks)). Four hook types:

| Hook | Event | Script | Purpose |
|------|-------|--------|---------|
| SessionStart | Session begins | `load-ticket-context.sh` | Load ticket context, detect focus areas |
| PreToolUse | Before Bash/Edit/Write | `guard-handler.py` | Block/warn on dangerous patterns |
| PostToolUse | After Bash (git commit) | `post-commit-guard.sh` | Validate commits via guards |
| Stop | Claude tries to stop | `phase-loop.sh` | Phase audit loop (when active) |

### Guards (immediate updates)

Markdown files with YAML frontmatter. Universal guards (destructive commands, sensitive files, hardcoded secrets) ship with Doyaken in `hooks/guards/`. Project-specific guards are generated during `dk init` in `.doyaken/guards/`. See [docs/guards.md](docs/guards.md).

### Shell Functions (reload needed)

`dk.sh` defines `dk`, `dkrm`, `dkls`, `dkclean`, `dkloop`, `dkcomplete`, `dkreviewloop`, and `doyaken`. After editing, run `dk reload` to apply.

## Confidence Scoring

Self-review findings include a confidence score (0-100). Only findings scoring >= 50 are reported:

| Score | Meaning |
|-------|---------|
| 90-100 | Certain — verifiable bug, missing guard |
| 75-89 | Highly confident — real issue with evidence |
| 50-74 | Moderately confident — likely issue |
| 0-49 | Filtered out — noise, pre-existing, or linter territory |

## Adding a New Project

1. `cd` into the repo
2. `dk init` — analyzes the codebase and generates `.doyaken/` config
3. Review the generated config in `.doyaken/` — edit rules and guards as needed
4. Commit `.doyaken/` to the repo (worktree artifacts are gitignored)

To re-run codebase analysis after significant changes:
```bash
dk init --skip-config
```

## Configuration

### Environment

`DOYAKEN_DIR` — Override the install location (default: `$HOME/work/doyaken`). Set before running install or sourcing dk.sh.

`CODEX_HOME` — Override the Codex config root used for Doyaken skill links (default: `~/.codex`).

`DK_ALLOW_REPO_GATEWAY_PROVIDER=1` — Explicitly allow a trusted repo-local gateway/API provider profile for the current invocation. Prefer global gateway profiles in `~/.doyaken/providers.json`.

### Guards

Project-specific guards are generated during `dk init` in `.doyaken/guards/`. You can also add guards manually — see [docs/guards.md](docs/guards.md) for the format and examples.

### Autonomous mode

Control via environment variables:

| Variable | Default | Description |
|----------|---------|-------------|
| `DOYAKEN_LOOP_ACTIVE` | `0` | Enable the phase audit loop (set automatically by `dk`) |
| `DOYAKEN_LOOP_MAX_ITERATIONS` | `30` | Max iterations before forced stop |
| `DOYAKEN_LOOP_MIN_AUDITS` | Per-phase | Min audit iterations before completion authorized |
| `DOYAKEN_SESSION_TIMEOUT` | `86400` | Session timeout in seconds (24h). Set to 0 to disable. |
| `DOYAKEN_PHASE_N_MIN_AUDITS` | — | Per-phase override (e.g., `DOYAKEN_PHASE_2_MIN_AUDITS=5`) |
| `DOYAKEN_REVIEW_CLEAN_PASSES` | `3` | Consecutive clean review iterations required (Phase 3) |
| `DOYAKEN_REVIEW_MAX_ITERATIONS` | `10` | Max review iterations before Phase 3 pauses for intervention |
| `DOYAKEN_COMPLETE_MAX_CYCLES` | `3` | Max idle review cycles before Phase 6 escalates |
| `DOYAKEN_COMPLETE_WAIT_MINUTES` | `30` | Minimum wait window per Phase 6 cycle (minutes) |

### Reviewers

Phase 6 reads the `## Reviewers` section of `.doyaken/doyaken.md` to decide who to request reviews from. Two assignment types per row:

| Type | Mechanism | Use for |
|------|-----------|---------|
| `request` | `gh pr edit --add-reviewer <handle>` | Humans, GitHub Copilot, anything GitHub recognises as a reviewer |
| `mention` | `@<handle>` posted as a PR comment | AI agents that watch mentions but don't accept native review requests |

Defaults written by `dk config`:
- The current authenticated GitHub user (auto-detected via `gh api user`) as `request`
- `Copilot` as `request`

Edit `.doyaken/doyaken.md § Reviewers` directly or rerun `dk config` to change. After each push (review-fix commit), Phase 6 re-requests `request` reviewers and re-posts the `@mention` comment so reviewers know there's something new to look at.
