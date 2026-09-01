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
# One-time install (clone anywhere; ~/work/dex is the default DEX_DIR)
git clone https://github.com/mitchellfyi/dex.git ~/work/dex
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
- **Review before PR:** Phase 3 runs independent full-scope review waves until
  the agent-selected risk tier's clean-pass gate succeeds.
- **Real verification:** Dex discovers and runs the repo's format, lint,
  typecheck, generation, and test commands instead of assuming one toolchain.
- **UI proof:** `/dxproof` (also `/dxcapture`) reconstructs the branch baseline
  and records a captioned before/after walkthrough for the current UI diff.
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
  |-- Phase 0: Setup
  |     Resolve the task, create or select the workspace, and prepare the branch.
  |
  |-- Phase 1: Plan
  |     Explore the ticket and codebase, propose an approach, wait for approval.
  |
  |-- Phase 2: Implement
  |     Build with tests, commit and push green increments, prove criteria, then select review risk.
  |
  |-- Phase 3: Review
  |     Run fresh review-wave CLI sessions to the selected tier's global clean gate.
  |
  |-- Phase 4: Verify + Commit
  |     Run final gates, commit review or verification repairs, confirm the remote is current.
  |
  |-- Phase 5: PR
  |     Create the draft PR with description, reviewer routing, and visual handoff.
  |
  `-- Phase 6: Complete
        Mark ready, watch CI/reviews, address feedback, close the ticket, clean up.
```

The important piece is the audit loop. When Claude tries to stop, Dex's Stop hook
checks the phase state and injects the next required audit. Normal gate
advancement requires the generated, generation-bound receipt for that phase.
Review waves have their own clean-pass counter: a wave that finds
and fixes anything writes `FINDINGS_FIXED:N`, resets the counter, and forces a
fresh full-scope review before Phase 4 can start. Before Phase 3, the
implementation agent selects `small`, `normal`, or `complex`. Dex requires 1,
2, or 3 clean waves, respectively. A standalone
`dxreviewloop` without an explicit tier/profile override starts with a read-only
risk assessor. Every counted wave runs in a fresh context without prior review
conclusions or telemetry.

The review loop has no routine outer iteration limit. It continues until the
clean gate succeeds. Residual findings, blockers, churn, invalid results, and
provider failures pause the loop for intervention rather than being treated as
clean or retried indefinitely. The 1/2/3 gates are global so review assurance
does not vary by repository. `DEX_REVIEW_CLEAN_PASSES` can raise the launch gate
but cannot lower it. An attributed
`dx control override review.clean-passes <1-30>` can change the live target;
lowering it still requires that many independent clean waves and records the
review phase as waived. A full `dx control waive review.clean-passes` skips the
remaining review gate.

Publishing follows phase ownership: Phase 2 publishes implementation commits,
Phase 3 leaves review fixes in the working tree, Phase 4 publishes review and
verification repairs, and Phase 5 owns PR creation. These boundaries are prompt
contracts rather than hard Git restrictions. Human and agent controls can pause
or stop Dex, change a phase/session runtime default, waive a named assurance
gate, or jump to another phase. Every exception records its source and reason;
skipped and waived outcomes stay separate from passed gates. See [session
policy overrides](docs/autonomous-mode.md#session-policy-overrides).

The clean-pass bookkeeping is designed to stop a review loop drifting into a
false pass — wrong scope, changed criteria, a reused result, a lost finding —
and every such case pauses without credit. It is not a defense against an agent
deliberately forging its own receipts: the whole chain runs under one UID with
no secret the reviewer lacks. Keep the human review gate on the PR. See
[Autonomous mode](docs/autonomous-mode.md#what-the-integrity-chain-does-and-does-not-cover).

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
dx --resume                # Resume the lifecycle for the current workspace
dx --from-pr 42            # Start a lifecycle from an existing pull request
dxreviewloop               # Resolve risk (or honor an override), then review to its clean gate
dxcomplete                 # Resume PR completion for the current branch
dx provider current        # Show active agent/provider/model resolution
dx control pause           # Pause, stop, or hand control back to a running lifecycle
dx control recover review --reason "review owner stopped after interrupt"
dx control override review.pass-timeout 2400 --source agent --reason "checks need longer"
dx control override review.clean-passes 2 --source human --reason "two clean waves approved"
dx control waive review.clean-passes --source human --reason "approved in this session"
dx sessions list           # List trusted lifecycle sessions in this repository
dx sessions doctor         # Diagnose inconsistent, dead, or unsafe session state
dx test                    # Test Dex here, or verify another initialized project
dx log                     # Show recent run events and summaries
dx tools bootstrap         # Install/refresh RTK, browser MCPs, docs MCP, and plugins
```

Inside Claude Code, run `/dxproof` to capture the current UI diff as a captioned
before/after walkthrough. `/dxcapture` is the same command under an alias.

Inside a lifecycle, the compact controls are `/dxpause`, `/dxskip`,
`/dxjump verify`, `/dxresume`, and `/dxrecover`. Skip advances from whichever
phase is active and records an attributed waiver. Recover is only for a stale
Phase 3 fence whose review owner stopped after an interrupt; it leaves the
lifecycle paused so you can choose resume or skip.

`dx login`, `dx logout`, and `dx whoami` manage the optional DexCode connection
that syncs run events and artifacts; see [docs/events.md](docs/events.md).

`dx worker register` enrolls this machine so DexCode can dispatch runs to it,
and `dx worker run` polls for them, executes each one, and reports the result,
up to the concurrency the worker is registered for. The worker pulls: DexCode
never connects to this machine. Use `dx worker run --once --dry-run` to prove
the wiring without doing any work, and `dx worker service` to print a launchd
agent or systemd unit that keeps it running.

A worker serves its whole organisation — every project and repository in it,
unless an allowlist narrows that. To serve several organisations from one
machine, register once per organisation
(`dx worker register --organisation <slug>`); `dx worker run` then polls them
all. Each organisation issues its own credential and can revoke it without
touching the others, which a single cross-organisation token could not offer.

`dex` and `dexter` are aliases for `dx`.

For `dx "task description"`, Phase 1 first produces an implementation plan.
When a ticket tracker is configured, Dex asks after plan approval whether to
continue directly, create a parent ticket, or create a parent plus sub-issues
and choose the first issue to implement.

## Requirements

- **zsh as your interactive shell.** `dx.sh` uses zsh-only syntax and is sourced
  from `~/.zshrc`. The installer runs under any shell and writes the same files,
  but warns when `$SHELL` is not zsh, because nothing it installs will load for
  you until you get there.
- Claude Code CLI installed and signed in.
- A git repository.
- Python 3 (standard library only).
- GitHub CLI (`gh`), signed in — required for PR creation, reviewer routing, CI
  watching, and GitHub Issues ticket tracking.
- Optional: Node.js and npm, used for Playwright UI-capture tooling.
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
- [UI proof](docs/ui-capture.md) covers manual `/dxproof` captures, lifecycle
  decisions, captioned before/after walkthroughs, temporary artifacts, and PR
  handoff.
- [Events](docs/events.md) documents run IDs, local run directories, event
  journals, and the optional DexCode sync.
- [RTK token reduction](docs/rtk-token-reduction.md) covers the optional
  output-filtering CLI and how to disable it.

## Contributing

Verify changes with `dx test dex` (static checks followed by the manifest test
suite). CI runs static checks on Linux and test shards on Linux and macOS.
`dx.sh` is zsh-only; `lib/`, `hooks/`, and `bin/` must stay
bash-compatible down to bash 3.2, which is what macOS ships. See
[AGENTS.md](AGENTS.md) for conventions.

## Status

Dex is V1 software from Synthetic Industry. It assumes fresh V1 installs and does
not carry pre-V1 migration paths.
