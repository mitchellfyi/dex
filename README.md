# Dex

Dex turns Claude Code into a ticket-to-PR workflow runner. Give it a ticket
number or a task description and it plans the work, implements it in an isolated
branch/worktree, reviews it until clean, verifies it, opens a PR, watches CI and
review feedback, and cleans up when the PR is ready.

It is built for teams that want AI coding work to finish with the same discipline
they expect from a senior engineer: scoped plans, local quality gates, review
loops, evidence for UI changes, clean commits, and PR follow-through.

## Quick Start

```bash
# One-time install
bash ~/work/dex/install.sh
source ~/.zshrc
dx status

# In a repository you want Dex to understand
cd ~/work/myproject
dx init

# Start a ticket or free-form task
dx 1234
dx "add account export"
```

That is the normal path. `dx init` creates `.dex/` project context so future runs
know your stack, conventions, quality gates, reviewers, guards, and durable
repo memory.

## Why Use Dex

- **Less babysitting:** Dex advances through plan, implementation, review,
  verification, PR, and completion without needing a prompt at every step.
- **Higher trust:** Each phase has a Stop-hook audit. Claude cannot simply claim
  completion; it must satisfy the gate for the current phase.
- **Cleaner branches:** Work runs in `.dex/worktrees/` by default, keeping your
  main checkout usable while tickets progress independently.
- **Review before PR:** Phase 3 runs fresh full-scope review waves until the
  resolved clean-pass gate succeeds.
- **Real verification:** Dex discovers and runs the repo's format, lint,
  typecheck, generation, and test commands instead of assuming one toolchain.
- **UI evidence:** Browser-facing changes can capture before/after screenshots,
  Playwright traces, videos, console logs, and a PR-ready visual manifest.
- **Local run data:** Each provider-backed run gets a stable run ID,
  append-only JSONL events, redacted logs, summaries, and artifact metadata
  under `~/.dex/runs/`.
- **PR follow-through:** Dex can mark a PR ready, request reviewers, watch CI and
  review comments, apply fixes, re-request review after pushes, and close the
  ticket when approved.

## How The Loop Works

```text
dx 1234
  |
  |-- Phase 1: Plan
  |     Explore the ticket and codebase, propose an approach, wait for approval.
  |
  |-- Phase 2: Implement
  |     Build with tests, capture UI evidence when needed, prove criteria are met.
  |
  |-- Phase 3: Review
  |     Run fresh review-wave CLI sessions until the change is clean.
  |
  |-- Phase 4: Verify + Commit
  |     Run quality gates, create atomic conventional commits, push the branch.
  |
  |-- Phase 5: PR
  |     Create the draft PR with description, reviewer routing, and visual handoff.
  |
  `-- Phase 6: Complete
        Mark ready, watch CI/reviews, address feedback, close the ticket, clean up.
```

The important piece is the audit loop. When Claude tries to stop, Dex's Stop hook
checks the phase state and injects the next required audit. Only a passing phase
can advance. Review waves have their own clean-pass counter: a wave that finds
and fixes anything writes `FINDINGS_FIXED:N`, resets the counter, and forces a
fresh full-scope review before Phase 4 can start.

## Common Commands

```bash
dx install                 # Install shell functions, hooks, skills, and tooling
dx status                  # Show global and project setup
dx init                    # Analyze the current repo and create .dex/
dx sync                    # Refresh durable repo memory and rules
dx 1234                    # Run the full lifecycle for a ticket
dx "task description"      # Run the full lifecycle for a free-form task
dx --agent codex --model gpt-5.3-codex "fix flaky import"
dx --no-worktree 1234      # Run the lifecycle in the current checkout
dx run --spec run-spec.json # Run from a structured headless run spec
dxreviewloop               # Review current changes without the full lifecycle
dxcomplete                 # Resume PR completion for the current branch
dx provider current        # Show active agent/provider/model resolution
dx tools bootstrap         # Install/refresh RTK, browser MCPs, docs MCP, and plugins
```

`dex` and `dexter` are aliases for `dx`.

For `dx "task description"`, Phase 1 first produces an implementation plan.
When a ticket tracker is configured, Dex asks after plan approval whether to
continue directly, create a parent ticket, or create a parent plus sub-issues
and choose the first issue to implement.

## Requirements

- Claude Code CLI installed and signed in.
- A git repository.
- `jq` for settings merge/uninstall flows.
- Optional: Codex CLI if you want the `codex-subscription` provider profile.
- Optional: `shellcheck`, language toolchains, and test tools used by your repo.

Dex installs Playwright UI-capture tooling and RTK token-reduction tooling into
`~/.claude/.dex-tools/`. Screenshots, traces, logs, and videos are stored under
`~/.claude/.dex-artifacts/`. Dex does not commit those artifacts.

Run IDs, lifecycle events, logs, summaries, and artifact manifests are stored
locally under `~/.dex/runs/`; see [docs/events.md](docs/events.md).

RTK support is installed by `dx install`, `dx init`, `dx sync`, and
`dx tools bootstrap`. Claude Code sessions get a fail-open Bash rewrite hook;
Codex gets global instructions to prefix shell commands with RTK when compact
output is enough. Set `DX_RTK_ENABLED=0` to skip this bootstrap.

## Project Context

`dx init` creates:

```text
.dex/
  dex.md            Project config, gates, reviewers, integrations
  AGENTS.md         Imports dex.md for agent context
  CLAUDE.md         Claude Code compatibility pointer
  review-rules.md   Optional path-specific review focus
  providers.json    Optional repo-local provider/agent defaults
  rules/            Generated coding conventions
  guards/           Project-specific safety guards
  memory/           Durable repo memory
  worktrees/        Ephemeral Dex worktrees
```

Dex skills are codebase-agnostic. They discover local commands and conventions at
runtime, then use `.dex/` to avoid rediscovering stable project knowledge on
every run.

## Provider Profiles

Dex defaults to the `claude` agent using your session's default model and
effort. You can override one run from the terminal:

```bash
dx --agent claude --model claude-opus-4-7 1234
dx --agent codex --model gpt-5.3-codex "add the export job"
```

For Codex runs, Claude Code remains the lifecycle harness because Dex relies on
Claude Code hooks, skills, plan mode, and same-session handoff. Substantive
coding and review work is delegated through Dex's Codex wrapper.

- `claude-subscription` - direct Claude Code via Claude subscription auth.
- `codex-subscription` - Claude remains the harness while coding/review work is
  delegated through Dex's Codex wrapper using ChatGPT subscription auth.

```bash
dx provider list
dx provider use codex-subscription
dx provider use --repo codex-subscription
dx provider doctor
```

Repo defaults live in `.dex/providers.json`; user defaults live in
`~/.dex/providers.json`. CLI flags win for the current invocation only.

Subscription-safe profiles strip API-provider environment variables from
launched subprocesses and require Dex-managed wrappers for delegated Codex work.

## Background Maintenance

`dx maintain install-workflow` installs the GitHub Actions workflow for scheduled
maintenance, trusted issue intake, and maintenance PR feedback. Repo policy
lives in `.dex/dex.md`: `schedule_mode` and `issue_mode` choose report or
write-capable runs, while `auto_merge` controls whether the wrapper asks GitHub
native auto-merge to merge ready maintenance PRs after required checks and
reviews pass.

## Documentation

- [Autonomous mode](docs/autonomous-mode.md) explains phase hooks, state files,
  review loops, and watcher behavior.
- [Run specs](docs/run-specs.md) covers headless/spec startup with `dx run`.
- [Factory security](docs/factory-security.md) documents the v1 remote worker,
  token, event-ingestion, and credential boundary.
- [Guards](docs/guards.md) covers hook-based safety rules.
- [UI capture](docs/ui-capture.md) covers screenshots, traces, videos, and PR
  visual evidence.

## Status

Dex is V1 software from Synthetic Industry. It assumes fresh V1 installs and does
not carry pre-V1 migration paths.
