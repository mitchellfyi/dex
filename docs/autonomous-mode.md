# Autonomous Mode (Phase Audit Loops)

Dex runs the ticket lifecycle as a series of phases, each with its own
quality-gated audit loop. When Claude tries to stop during a phase, the Stop
hook injects a phase-specific audit prompt that critically reviews the work.
Normal advancement requires the exact generation-bound completion receipt Dex
authorized for that session and phase.

## How It Works

```
User runs: dx 999
  |
  v
Wrapper creates worktree, starts Phase 0 (Setup)
(`dx --no-worktree` skips worktree creation and uses the current checkout)
  |
  v
Claude starts with DEX_LOOP_ACTIVE=1
  |
  v
Claude works on the phase (e.g., /dxplan, /dximplement)
  |
  v
Claude tries to stop
  |
  v
Stop hook (phase-loop.sh) intercepts:
  - Applies any direct human pause, stop, waiver, or phase-jump request first
  - Validates the exact completion context and generated receipt
  - If the receipt is valid -> consumes it, then advances inline or exits
  - If Phase 1 plan approval marker is missing -> blocks without counting an audit iteration
  - Checks iteration count -> if max reached, pauses for intervention
  - Checks min audit iterations -> if below threshold, blocks WITHOUT completion instructions
  - If at/above threshold: blocks but INCLUDES completion instructions
  |
  v
Claude reviews its own work critically (audit loop)
  - Finds issues -> fixes them -> tries to stop -> hook re-injects audit
  - Finds nothing, below min iterations -> tries to stop -> hook blocks, no completion yet
  - Finds nothing, at/above min iterations -> hook provides completion instructions
  - Runs the exact receipt command + outputs the acknowledgement -> hook hands off
  |
  v
Claude continues with the next phase in the same session
```

## Phase Audit Prompts

Each phase has its own audit prompt in `prompts/phase-audits/`:

| Phase | Audit File | What It Reviews |
|-------|-----------|-----------------|
| 0. Setup | `0-setup.md` | Ticket read + assigned, duplicate/related search complete, existing PR reconciled, eligible remote branch adopted or new branch prepared, ticket status In Progress, meta sidecar updated |
| 1. Plan | `1-plan.md` | Completeness, edge cases, dependencies, scope, user approval |
| 2. Implement | `2-implement.md` | Task completion, TDD verification, coherent checkpoint history pushed as work develops, UI proof decision, evidence table, Phase 3 risk selection |
| 3. Review | `3-review-loop.md` | Independent `/dxreviewloop` waves, accepted-fix checkpoints pushed, selected tier's global clean gate reached |
| 4. Verify | `4-verify.md` | Final PR checks passing, verification repair checkpoints pushed, branch current on origin |
| 5. PR | `5-pr.md` | Description quality, scope match, current visual media attached or handed off with a warning, draft PR created with `request` reviewers attached |
| 6. Complete | `6-complete.md` | Cycle loop: mark ready, request reviewers, post mention comment, monitor CI/reviews through `/dxwatchpr`, address failures, re-request after each push, close ticket, clean up local worktree/branch |

During Phase 0, `dx_ticket_branch_prepare` resolves the branch name supplied by
the tracker. If that branch exists on `origin`, Dex fetches its current tip and
adopts it when it has an open pull request or no pull request. The local branch
then tracks `origin/<tracker-branch>`. A branch with only closed or merged pull
requests requires explicit direction. Dirty worktrees, conflicting local
history, remote failures, and unavailable PR state also stop setup without
replacing the lifecycle branch. When the branch does not exist locally or on
`origin`, Dex renames the untouched placeholder and leaves it unpushed until
Phase 2 creates the first implementation commit.

Issue and PR hygiene is shared across the lifecycle through
`prompts/issue-hygiene.md`. Phase 0 performs the full duplicate and related-work
search, reconciles accepted comment decisions into the working issue, and
updates an existing open PR when its title or body is stale. Later phases repeat
that work only when planning, implementation, review, verification, CI, or
reviewer feedback adds material context. Related bounded work stays in the same
PR; concrete distinct work becomes a linked follow-up after another duplicate
search. Fresh review-wave children report candidates but never write to the
tracker, leaving one lifecycle owner to perform each external write. Every
phase reports issue and PR work explicitly, including unchanged and N/A cases.

The review audit (Phase 3) is risk-selected. After the final Phase 2 in-scope
change, the implementation agent applies the ordered rubric and records the
highest matching tier with bounded reason codes. `small` maps to a `light`
profile, `normal` maps to `standard`, and `complex` maps to `thorough`. The
global consecutive clean-wave requirements are 1, 2, and 3. Trust boundaries;
authentication, authorization, permissions, secrets, payments, or destructive
behavior; persistence, schemas, or migrations; public API, CLI, configuration,
or compatibility contracts; concurrency or process lifecycle; hooks, guards,
CI, deployment, or packaging; broad cross-module behavior; and material
uncertainty that prevents the supplied scope or its verification from being
bounded require `complex` review.

The 1/2/3 policy is fixed across repositories. Dex stores its binding in the
selection, resumable state, pass evidence, clean ledger, and final receipt.
`DEX_REVIEW_CLEAN_PASSES` may raise the requirement for a run, but it cannot
lower it.

Phase 2 selection is mandatory in the normal lifecycle flow. If a legacy or
resumed lifecycle has no valid selection for its current scope, `dxreviewloop`
uses a fresh read-only lifecycle assessor as a recovery path before the first
wave. It records `lifecycle-assessor` as the selection source; the fallback is
not a replacement for the Phase 2 requirement.

A standalone `dxreviewloop` invocation without an explicit tier/profile
override starts with a read-only assessor that chooses and records the tier
before the first wave. The assessment is not a clean pass. Each review wave then
runs in a fresh pass-scoped CLI session, builds a new compact context pack, runs
deterministic checks before semantic review, verifies findings, batch-fixes safe
findings, and rechecks affected surfaces. Later reviewers receive no prior
reports, findings, fingerprints, clean counts, telemetry, or stale conversation
context.

Phase 1 also saves the approved objectives, acceptance criteria, and
verification requirements in a strict JSON artifact. Lifecycle assessors and
review waves receive a fresh child-scoped copy, never the parent path. The
Phase 1 transition seals the canonical criteria hash. An explicitly reapproved
replacement increments the seal revision and clears prior selection, state,
ledger, and receipts. The sealed hash is bound to state, every clean ledger row,
the risk selection, evidence, and the final receipt. Dex checks both criteria
copies before and after each provider call. Evidence version 3 carries the exact
ordered hash and outcome for every supplied item, plus one to eight substantive
references into the pass's context pack. The manifest is also bound to the
current policy and pass. Dex attests the manifest, context pack, result,
profile, and findings fingerprint together before appending a clean ledger row.
Missing, changed, stale, or partially covered criteria pause review without
clean credit. Standalone review has no criteria artifact and uses a
`standalone` binding with empty criteria-evidence arrays.

Only a wave with zero verified findings and zero fixes writes `CLEAN`. A wave
that fixes anything writes `FINDINGS_FIXED:N`, resets the counter, and forces a
fresh review of the updated scope. A valid upward escalation also resets the
counter. `FINDINGS:N`, `BLOCKED:reason-code`, `CHURN:reason-code`, invalid
results, provider failures, and deterministic findings-fingerprint churn pause
the loop. The outer review loop has no iteration maximum.

Only one review loop may own a checkout at a time. The wrapper acquires an
atomic checkout-scoped lock before it reads or writes review state and reclaims
the lock only when its recorded process is no longer running. Each review wave
is wrapped by `DEX_REVIEW_PASS_TIMEOUT`; a timeout terminates the full provider
process tree, clears the Phase 3 busy marker, records `pass_timeout`, and pauses
with a concrete recovery step. State and receipts stay outside the repository
and are accepted only while their independently hashed HEAD, staged, unstaged,
and untracked scope still matches.

Phase 2 treats UI proof as an explicit agent judgment. `/dxuicapture` can produce a short before/after or after-only walkthrough when it improves the review, record a reasoned `SKIPPED` decision for a visible but disproportionate case, or record `N/A` when nothing changes in the browser. A human can request the full diff-aware capture at any time with `/dxproof` or its `/dxcapture` alias. Generated videos, screenshots, traces, captions, browser logs, and the handoff manifest stay under `~/.claude/.dex-artifacts/`; the lifecycle surfaces their status without turning capture into a hard product-correctness gate. For `READY` proof, Phase 5 attaches the current image/video bundle to the PR when GitHub CLI supports `--attach`. Older clients and incomplete uploads keep a visible local handoff. See [ui-capture.md](ui-capture.md).

Phase 6 (Complete) is autonomous and bounded: it reads `## Reviewers` from `.dex/dex.md` to know who to request reviews from. The user is brought into the loop as a configured reviewer. The autonomous loop re-reads `dx_complete_wait_minutes` (default 5) and `dx_complete_max_cycles` (default 3) each cycle, addresses failures through `/dxwatchpr` and `/dxprreview`, re-requests reviewers after each push, and closes the ticket once CI is green and all successfully requested reviewers approve. Reviewers GitHub says are not requestable for the repository are warnings, not approval gates. When the current idle budget is exhausted, it pauses with manual follow-up instructions. It never merges the PR.

DX maintain has a separate GitHub Actions path for background maintenance. The
installed workflow can run on schedules, manual dispatch, trusted `issues`
events, and maintenance PR feedback. Issue and schedule modes are read from
`.dex/dex.md` (`issue_mode`, `schedule_mode`, then `default_mode`). Issue event
actors must have write, maintain, or admin access before Dex launches the
provider. The workflow collects issue JSON before token scrubbing and passes it
as untrusted context files to `dx maintain`.

Write-capable maintenance jobs consume a sealed bundle from the earlier
credential-free provider job. Dex creates the state and patch files without
overwriting existing paths, stores only relative bundle members, bounds their
sizes, and verifies the patch's SHA-256 receipt before applying it. A missing,
linked, moved, or modified bundle member stops publication before GitHub write
credentials are used.

Maintenance PRs remain draft by default. If trusted `.dex/dex.md` config sets
`auto_merge` to `true`, the wrapper creates a ready maintenance PR and requests
GitHub native auto-merge for the exact published head with
`gh pr merge --auto --match-head-commit`. Dex does not use admin bypass, and the
provider session still never receives GitHub write credentials.

When the user submits a direct prompt during Phase 6, the `UserPromptSubmit` hook writes a `.watch-pause` marker. Scheduled `/dxwatchpr` cycles must no-op while the marker is active, so manual work is not interrupted by CI/review polling commands. The pause uses `dx_watch_pause_ttl_seconds` (default `60m 0s`) unless the user runs `/dxcomplete` or asks to resume watching.

Each watcher cycle also has a runtime lock with a default budget of `2m 0s`. If a later `/loop` tick fires while the previous `/dxwatchpr` cycle is still within that budget, the later tick skips instead of starting overlapping GitHub or CI work. Individual watcher shell commands default to `0m 30s`.

After Phase 1 approval, the Stop hook advances through normal Phase 2-5
handoffs in the same Claude session without asking whether to continue. A phase pauses only when it hits an
explicit escalation condition such as missing credentials/tooling, a destructive
git decision, repeated failed fix attempts, a max phase-audit count, review
findings/blockers/churn, or feedback that needs human judgement.

### Session policy overrides

Those escalation points and runtime budgets are defaults, not immutable
restrictions. The active Claude Code or Codex agent may ask the human for an
exception, or make one itself when the safe choice is clear and waiting would
be counterproductive. Changes are applied through the same provider-neutral
control command, so they take effect inside the current lifecycle without
relaunching the provider:

```bash
# Change one operational default for the current phase.
dx control override review.pass-timeout 2400 --source agent \
  --reason "The thorough checks need a longer provider window"

# Keep an override for the rest of the session, or give it a time limit.
dx control override watch.command-timeout 90 --scope session \
  --for-seconds 1800 --source human \
  --reason "Repository API calls are slow today"

# Remove a policy change.
dx control clear-override watch.command-timeout --scope session \
  --source agent --reason "API latency has recovered"

# Keep independent review but lower its target for this scope.
dx control override review.clean-passes 2 --source human \
  --reason "Two clean waves are sufficient for this unusually expensive scope"

# Skip the rest of an assurance gate and advance through the locked transition.
dx control waive review.clean-passes --source agent \
  --reason "Provider failures prevent independent waves; direct review and deterministic checks are complete"
```

Overrides are phase-scoped unless `--scope session` is supplied. `--for-seconds`
adds an expiry; `0` means no expiry. `dx control status` shows the effective
records with source and reason. Unsupported gate names are rejected instead of
creating inert policy records. When a human authorizes the exception in chat,
the agent records `--source human`; an agent-originated exception requires a
reason.

The built-in operational gates are:

| Gate | Value and consumer |
|------|--------------------|
| `phase.timeout` | Non-negative seconds for the live phase watchdog; `0` disables that deadline. Dex does not impose a whole-session deadline. |
| `phase.min-audits` | Minimum Stop-hook audits before normal completion |
| `loop.max-iterations`, `loop.stall-timeout`, `loop.stall-escalate` | Audit-loop attempt and stall budgets |
| `review.clean-passes` | Effective target from 1 through 30; lowering the trusted tier target requires real clean waves and records Phase 3 as waived |
| `review.pass-timeout`, `review.recheck-seconds` | Review provider and quiet Phase 3 recheck budgets; `0` disables the provider deadline |
| `watch.pause-ttl`, `watch.cycle-timeout`, `watch.command-timeout` | Phase 6 watcher pause, lease, and command budgets |
| `complete.max-cycles`, `complete.wait-minutes` | Phase 6 idle-cycle and wait defaults |
| `failure.attempts-per-strategy`, `failure.max-strategies`, `complete.ci-fix-attempts` | Recovery and repeated-CI-failure escalation defaults |
| `sync.budget-minutes` | `dx sync` provider budget |
| `maintain.budget-minutes`, `maintain.respond-budget-minutes` | Maintenance provider budgets |
| `maintain.command-timeout-seconds`, `maintain.max-surfaces`, `maintain.max-prs` | Maintenance prompt limits and PR cap |
| `guard.<guard-name>` | `allow` turns a matching project `block` guard into an attributed warning; `enforce` restores it |

`review.clean-passes` supports two distinct exceptions. A numeric override
keeps independent review and requires the chosen number of genuine `CLEAN`
waves; a target below global policy produces an override-bound receipt and a
`waived` Phase 3 outcome. `dx control waive review.clean-passes` skips the
remaining gate and advances without a review receipt. Other assurance gates,
such as `verification.required-gates`, use the named waiver path. Neither form
labels an unverified check as passed.

Provider deadlines for review, `dx sync`, and maintenance are live. Their
supervisors re-read policy once per second, so increasing, shortening,
disabling, clearing, or expiring an override affects the process already
running. Isolated provider children receive the parent id as
`DEX_POLICY_SESSION_ID`; an agent inside one can target it with
`dx control --session "$DEX_POLICY_SESSION_ID" ...`.

The standalone control invocation is Dex's break-glass path. An exact
`dx control ...`, `dex control ...`, or installed `bin/control.sh ...` Bash
tool call bypasses blocking guards and a missing built-in guard set, then lets
the control CLI validate and audit the requested change. The exemption does not
cover `bash -c`, `env`, substitutions, redirects, pipes, separators, or any
appended command.

State integrity is not a soft gate. Dex still requires a valid private override
journal, transition ownership, atomic state changes, and a quiesced Phase 3
child before crossing its boundary. Malformed policy state grants nothing and
pauses consumers that rely on it.

### Direct human control

The latest direct human instruction always takes priority over the phase loop.
During an active Claude lifecycle, natural instructions such as `stop Dex`,
`leave the review loop`, `mark this phase done`, `skip verification`, `jump to
the PR phase`, or `resume Dex` are applied by the `UserPromptSubmit` hook before
the agent's next tool call. Pause and stop detach the session from Dex's Stop
hook's phase sequencing while preserving the workspace and current phase for a
later resume.

The compact forms are `/dxpause`, `/dxskip`, `/dxjump verify`, `/dxresume`, and
`/dxrecover`. `/dxskip` works in any active phase and moves to the next one;
`/dxjump <phase>` names the destination. Skip records the current phase as
waived, while jump records crossed phases as skipped. Neither claims that a
bypassed gate passed.

The same controls are available from a terminal and to direct Codex sessions:

```bash
dx control status
dx control pause
dx control stop
dx control done
dx control jump verify
dx control resume
```

Human control does not disable review-wave session isolation. Built-in guards
remain advisory. A project guard configured as `block` remains blocking unless
the human or agent records its specific `guard.<name>=allow` override. Commit,
push, and PR operations are not blocked by lifecycle phase, with or without a
control receipt. The lifecycle prompt contract tells Phase 2 to record
implementation checkpoints, Phase 3 review waves to record accepted-fix
checkpoints, and Phase 4 to record verification repairs while making the final
PR gate pass. Phase 5 owns PR creation. A requested Phase 3 jump becomes a safe
detach if a review child is still marked in flight; the jump can be retried
after that process ends. Once the provider exits from a valid Phase 7
transaction, human-marked completion uses the same local worktree and branch
cleanup as an ordinary completion.

#### Interrupted review recovery

A hard interrupt can stop the Phase 3 review owner before it clears
`.phase-3.busy`. The Stop hook checks the PID stored in that fence. When the PID
is dead, it pauses immediately and prints the supported recovery command
instead of waiting for the normal review timeout.

Use `/dxrecover` in the owning interactive session. An agent or terminal should
use an attributed standalone command:

```bash
bash "$DEX_DIR/bin/control.sh" recover review --source agent \
  --reason "review owner stopped after interrupt"
```

Use recovery only after an interrupt or process failure and only when Dex
reports that the recorded owner is no longer running. The command independently
checks the PID and refuses a live owner, a missing fence, or malformed state.
It revokes completion authorization, removes the stale review fence and its
sidecars, and leaves Phase 3 paused. It does not grant clean-review credit or
mark the phase skipped. Continue with `/dxresume` to retry Phase 3 or `/dxskip`
to move on with an explicit waiver. Do not delete the fence by hand.

Audit prompts are editable markdown files. Changes take effect on the next loop iteration without reloading shell functions.

### What The Integrity Chain Does And Does Not Cover

The sealed criteria hash, clean ledger, retained proofs, attestations, and
receipt exist to stop a review loop from *drifting* into a false pass: a wave
that reviewed the wrong scope, resumed against changed criteria, reused a stale
result, counted an assessment as a clean pass, or lost a finding between
sessions. Every one of those ends in a pause with no clean credit, and the
recorded failure names which binding did not match. That is the property Dex
relies on, and it holds.

It is not a defense against a review wave that is actively trying to defeat it.
The chain is keyless SHA-256 over values the wave can see, computed by library
code the wave can read, writing to state files the wave can write, all under one
UID. A wave that chose to could recompute the whole chain rather than earn it.
Closing that gap needs something the wave does not have — a per-run secret held
only by the orchestrator, or a ledger written by a process the wave cannot
reach — and neither exists today.

So: the review loop raises the cost of an accidental or lazy pass to the point
where earning it is easier than faking it, and it makes every counted pass
auditable after the fact. Treat it as protection against a confused agent, not
a hostile one, and keep the human review gate on the resulting PR.

One lower-cost gap is worth knowing about specifically. A selection file that
records `source=environment` is trusted without re-applying the deterministic
tier floor, so a resumed loop can adopt a cheaper tier than the assessor would
have chosen. The clean-wave counts themselves remain bound to Dex's global
policy.

## Activation

Two activation mechanisms, depending on context:

**From the terminal** (via `dx` or `dxloop`):
```bash
dx 999  # Sets DEX_LOOP_ACTIVE=1 in the environment
dx --agent codex --model gpt-5.3-codex 999  # One-run agent/model override
dxloop "add rate limiting"  # Same mechanism
```

`dx --agent <name>` currently supports `claude` and `codex`. The default is
Claude using your session's default model and effort, unless
`.dex/providers.json` or `~/.dex/providers.json` selects a provider profile
that pins them. `dx --model <model>` passes the model to the selected agent:
Claude receives it through `claude --model`, while Codex receives it through
Dex's Codex wrapper as `codex exec --model`.

**From inside an existing Claude Code session** (via `/dxloop` skill):
The skill prepares a shell-safe terminal command for the dedicated `dxloop`
wrapper. It does not claim that it can retrofit hook ownership into the current
Claude session, and it does not start a nested provider. Run the returned
command in a terminal to start the loop with its own session ID and generated
completion context.

The wrappers create and retire `.active`, `.config`, and completion receipt
state. Do not create or remove those files by hand.

**Ownership.** Dex session ids are derived from the repo + worktree/branch path,
so two Claude sessions opened in the same checkout resolve the same id. To keep
a loop from capturing bystander sessions, the Stop hook records the owning
Claude session id from the hook payload in an `.owner` file. Wrapper-launched
Claude sessions have an explicit `DEX_SESSION_ID` and reclaim that ownership on
each stop. Direct Codex runs do not publish an unowned `.active` marker; their
wrapper validates and consumes the receipt itself.

**Review-wave passes.** Sessions launched with `DEX_REVIEW_PASS_ACTIVE=1`
(`/dxreviewloop` waves) run under a pass-scoped session id
(`<session>-pass-<N>-<pid>`) and are hard-isolated in the Stop hook. The inline
phase handoff never runs for them, so a wave cannot advance the lifecycle or be
instructed to advance it. Each pass gets a new context-pack path and no prior
review conclusions. A lifecycle Phase 3 wave commits and pushes coherent
accepted-fix checkpoints as it works, but it cannot switch branches or create
or update a PR. Standalone review waves follow their caller's publication
boundary. These are prompt contracts; review-wave isolation does not
technically block Git or PR actions.

Risk assessors are stricter than review waves: they run without Bash or file
editing, with inherited MCP servers disabled. Codex assessors use
the read-only ephemeral sandbox. The wrapper also fingerprints the checkout
before and after assessment and rejects any decision from a mutating assessor.

To run without the audit loop:

```bash
cd .dex/worktrees/ticket-999
claude --dangerously-skip-permissions --permission-mode bypassPermissions  # No DEX_LOOP_ACTIVE set, no .active file
```

## In-Place Lifecycle (`dx --no-worktree`)

For tickets or tasks where you do not want a separate checkout, use:

```bash
dx --no-worktree 999
dx --no-worktree "fix login bug"
```

This runs the same Phase 0-6 lifecycle in the current git checkout. Dex does
not create a worktree, but it still prepares the normal lifecycle branch
(`worktree-ticket-*` or `worktree-task-*`) in the current checkout, using
the default branch's upstream or remote-tracking ref as the starting point just
like worktree mode. It never branches new work from the current feature branch.
Phase 0 leaves the new branch local. Phase 2 commits small coherent checkpoints
early and often and pushes each one immediately, using the first real
implementation commit to establish upstream tracking. Phase 3 does the same for
accepted review fixes. Phase 4 is the final PR gate and records any repair
checkpoints produced while making the required pipeline pass. If Phase 2
produces no branch-specific commit, the new branch stays local and the lifecycle
pauses for user direction instead of entering the PR flow. The user may stop
the lifecycle as no-change or choose an explicit lifecycle control action. If
uncommitted changes are present and Dex would need to switch or create the
lifecycle branch, it stops so you can commit or stash first. `dx --resume`
resumes the most recent worktree or in-place lifecycle.

## Prompt Loop Mode (`dxloop`)

For ad-hoc tasks that do not need the full ticket lifecycle, `dxloop` plans the
prompt, then runs its implementation audit until the exact completion receipt
is accepted:

```bash
dxloop Add rate limiting to the /api/users endpoint. Support 100 req/min per API key with Redis backing.
```

This uses the same Stop hook infrastructure as `dx`, but:
- Runs in the **current directory** (no worktree created)
- Uses a planning context followed by the generic implementation audit in
  `prompts/phase-audits/prompt-loop.md`
- Gives each context its own generated completion generation
- Retires its completion authority when done and fails closed on a pause or
  missing receipt

The audit prompt extracts requirements from the original prompt and verifies each one on every iteration, continuing until all requirements are implemented and quality review passes.

Override max iterations: `DEX_LOOP_MAX_ITERATIONS=15 dxloop fix the bug`

## Completion Acknowledgements

Each phase has a human-readable acknowledgement:

| Phase | Acknowledgement |
|-------|---------|
| 0 | `PHASE_0_COMPLETE` |
| 1 | `PHASE_1_COMPLETE` |
| 2 | `PHASE_2_COMPLETE` |
| 3 | `PHASE_3_COMPLETE` |
| 4 | `PHASE_4_COMPLETE` |
| 5 | `PHASE_5_COMPLETE` |
| 6 | `DEX_TICKET_COMPLETE` |
| dxloop | `PROMPT_COMPLETE` |

The acknowledgement is useful in logs, but it does not authorize advancement.
The Stop hook supplies a literal generation-bound receipt command only after
the current gate is eligible to pass. Claude must run that exact command and
then output the acknowledgement. Human waivers and jumps use the separate
control receipt path and are recorded as waived or skipped, not passed.

## Compaction Resilience

Long-running sessions (especially Phase 2) can trigger conversation compaction when the context window fills. Two mechanisms ensure Claude retains phase awareness after compaction:

**System prompt context file** (`--append-system-prompt-file`): `dx.sh` generates a context file at `~/.claude/.dex-phases/<session_id>.system-context` containing lifecycle context, completion protocol, and worktree path. This is passed via `--append-system-prompt-file` and persists through compaction as part of the system prompt. In same-session mode, the Stop hook's latest phase handoff instruction supersedes the initial phase label in this file.

**PreCompact hook**: The `PreCompact` hook fires before compaction begins and reminds Claude to re-orient using its system context. This is a supplementary safety net alongside the system prompt file.

## Phase Handoff

Phases hand off inside the same Claude session. The Stop hook updates the phase state/config files, injects the next phase instructions, and exits with the hook-blocking status so Claude keeps working without requiring `/exit` or a manual resume.

Phase 3 still gets independent review coverage because `/dxreviewloop` spawns
fresh full-scope review waves and keeps prior review history outside each
reviewer's context.

## Status Line

During autonomous phases (2-6), a custom status line displays live information in the Claude Code TUI:
- Current phase number (e.g., `Phase 2/6`)
- Audit loop iteration count (e.g., `Audit 3/30`)
- Total elapsed time (e.g., `4m 22s`)

The status line is driven by `bin/status-line.sh` which reads state files from `~/.claude/.dex-phases/` and `~/.claude/.dex-loops/`. It is injected per-session via `--settings` and does not affect the global settings.

## Run Events

Provider-backed Dex commands create a run ID and local run data under
`~/.dex/runs/<run_id>/`. The main lifecycle emits `run.*` and `phase.*` events
as the Stop hook advances, blocks, or completes phases. `dx init` and `dx sync`
also emit run-level start and finish events.

Events are append-only JSONL for machines. `logs.txt` stores redacted
human-readable run detail, and `artifacts/manifest.json` records local evidence
files such as run summaries. The existing TSV phase log still lives in
`~/.claude/.dex-phases/<session_id>.log` for backward compatibility. See
[events.md](events.md) for the schema and storage layout.

Phase 3 records structured `review.*` events for tier selection, pass starts and
finishes, escalation, completion, and pause. A read-only risk assessor also
emits `review.tier.assessed` before its choice is resolved against the
deterministic floor and trusted policy. Payloads contain normalized tiers,
policy counts, reason codes, counts, durations, exit reasons, and churn
categories. They do not contain findings, fingerprints, source paths, prompts,
diffs, context packs, per-criterion evidence, or free-form rationale.

## Headless Run Specs

`dx run --spec <file>` and `dx run --spec-url <url>` start the same lifecycle
from a structured JSON run spec. This mode is intended for Factory or worker
launches where repo, source, harness, workflow, and sync context arrive as data
instead of an interactive CLI prompt.

Dex validates the spec, writes the normalized copy to
`~/.dex/runs/<run_id>/spec.json`, applies harness and sync settings, then
launches the in-place lifecycle in `repository.working_directory`. Manual CLI
usage is unchanged. See [run-specs.md](run-specs.md) for the spec schema and
startup commands.

## Safety Controls

### Phase Audit Iterations

The Stop-hook audit defaults to 30 iterations per phase. When that limit is
reached, the hook revokes the current completion authorization, pauses the
current phase, and asks the agent to summarize the blocker. `dx --resume`
continues from the same phase with a fresh generation after intervention.

Override with:

```bash
DEX_LOOP_MAX_ITERATIONS=50 dx 999
```

This limit does not bound `/dxreviewloop`'s outer clean-pass loop. Review has no
routine outer maximum; it runs until its selected clean gate succeeds or a
finding, blocker, churn condition, invalid result, provider failure, user
interrupt, or direct intervention pauses it.

### Escalation

Even in autonomous mode, Claude stops and escalates to the user for:
- Secrets scan failures (never auto-fix security issues)
- Architectural review comments (need human judgement)
- 3+ failed attempts at the same fix (loop is stuck)
- Scope changes that affect other tickets
- Missing credentials/tooling or destructive git operations that require explicit approval
- Max phase-audit iterations without an accepted completion receipt
- Residual review findings, review blockers, or review churn

### Manual Override

The user can always interrupt by providing input or pressing Ctrl+C. Phase state is saved so `dx 999` or `dx --resume` picks up where it left off.

### Session Diagnostics

The session catalog is read-only. It uses trusted state and runtime leases
rather than file age to distinguish live, dead, corrupt, and unverifiable
sessions:

```bash
dx sessions list
dx sessions show ticket:999
dx sessions doctor
dx sessions list --all
```

`list`, `show`, and `doctor` default to the current repository and hide internal
review children. `--include-children` exposes those children for diagnosis.
Only `list` accepts `--all`, and it can report only repositories recoverable
from trusted metadata or validated runtime records. These commands do not
resume, pause, repair, or delete a session.

### PR-Linked Resumption

After a PR has been created (Phase 5 done), you can resume the session linked to that PR from any machine:

```bash
dx --from-pr 42         # Resume by PR number
dx --from-pr https://github.com/org/repo/pull/42  # Or by URL
```

This is useful for one-off interventions (e.g., addressing a review comment) without needing the full phased lifecycle.

## State Management

Loop state is stored in `~/.claude/.dex-loops/`:
- `.state` — iteration count (e.g., `repo-myapp-123456789-worktree-ticket-999.state`)
- `.config` — canonical mode, purpose, phase, and completion generation for the current loop
- `.completion-expectation` — private expected completion context and generation
- `.completion-receipt.<generation>` — the exact generated receipt accepted once for that expectation
- `.completion-lock` — persistent per-session coordination inode for completion issue, consume, and revocation
- `.complete` — legacy compatibility marker; migrated contexts do not treat it as authorization
- `.active` — wrapper-managed activation marker for Claude Stop-hook sessions
- `.prompt` — original freeform task or `dxloop` prompt, re-injected during audits and kept outside the git checkout
- `.handoff-mode` — marker that this `dx` run should advance phases in-session
- `.paused` — one-shot marker that lets an inline session exit after reporting a safety-net pause
- `.control` — current human- or agent-originated pause, stop, complete, or phase-jump receipt; human prompts are represented by a hash rather than prompt text
- `.control-lock` — transition lock that prevents two Stop-hook invocations from applying the same receipt
- `.watch-pause` — marker that scheduled Phase 6 PR watcher should no-op after a direct user prompt
- `.watch-lock` — per-watcher overlap lock that bounds one scheduled `/dxwatchpr` cycle
- `.pause-state` — machine-readable reason/source for the current pause
- `.complete-state` — Phase 6 cycle bookkeeping (`cycle:last_check_epoch`); the Stop hook holds its wait window from this
- `.owner` — Claude session id that claimed the loop; bystander sessions in the same checkout stay inert
- `.phase-0.ready` — Phase 0 marker written after ticket setup; the Stop hook blocks the Phase 0 stop without it
- `.phase-1.started` / `.phase-1.ready` — Phase 1 markers written by `dxplan`; the Stop hook does not count plan audit iterations until the approval marker exists
- `.phase-2.ready` — Phase 2 marker written by `dximplement` only after every
  acceptance criterion and verification gate is complete and a valid
  current-scope, policy-bound review-risk selection exists; the Stop hook
  ignores `PHASE_2_COMPLETE` without it
- `.phase-3.busy` — Phase 3 marker written by `dxreviewloop` while a review wave is running; the Stop hook does not count audit iterations while waiting, detects a dead recorded owner, and directs the agent to attributed recovery rather than manual deletion
- `.phase-3.busy-cancel` / `.phase-3.busy-quiesced` — the cancellation request and the owner's acknowledgement in the review-child quiesce protocol
- `.review-criteria.json` — strict approved objectives, acceptance criteria,
  and verification requirements created after plan approval; each lifecycle
  assessor and wave gets a temporary child-scoped copy
- `.review-criteria-approval` — versioned approval seal containing the canonical
  criteria hash; replacements require explicit reapproval and invalidate prior
  review authorization
- `.review-selection` — risk tier, selection source, bounded reason codes,
  scope fingerprint, criteria binding, and trusted policy binding recorded
  before the first wave and rebound after review fixes
- `.review-state` — selected tier, required clean count, iteration, clean count,
  scope fingerprint, criteria binding, and trusted policy binding used to
  resume an unchanged review
- `.review-evidence.json` — pass-scoped evidence version 3 with exact ordered
  criterion hashes, outcomes, substantive context references, and policy and
  pass bindings; the child copy is removed after validation
- `.review-proofs/` — private, read-only copies of every counted clean pass's
  evidence manifest and context pack; receipt validation reopens these copies
  and recomputes every ledger attestation
- `.review-ledger` — accepted consecutive clean-pass records, each bound to one
  pass identity and its attestation of the evidence, context, result, profile,
  and findings fingerprint
- `.review-receipt` — successful clean-gate receipt tied to the reviewed scope,
  clean ledger, criteria binding, and trusted policy binding; Phase 3 does not
  advance on prose success alone
- `.review-context` — pass-scoped compact context pack; each fresh reviewer gets
  a new path and no previous review report
- `.review-baseline.json` — scope-bound passing evidence for expensive,
  explicitly project-wide deterministic commands; semantic findings are never
  stored here
- `.review-metrics.json` — pass-scoped context, checks, scouting, and verifier
  durations used for review performance telemetry
- `.findings` — transient findings fingerprints used only by the outer wrapper
  for repeated/alternating churn detection; fingerprints are not passed to
  reviewers or telemetry
- The session ID is derived from a stable repo key plus the worktree directory name (stable across branch renames and unique across repos)
- Loop files are cleaned up on successful completion and by the workflow's
  explicit session cleanup paths
- `dxclean` still prunes an enumerated set of legacy file families older than
  seven days; age alone is not a session-health verdict

Phase state is stored in `~/.claude/.dex-phases/`:
- One `.phase` file per worktree, tracking which phase is current (0-6; 7 = ticket complete)
- One `.times` file per worktree, tracking start times for elapsed calculations
- One `.system-context` file per worktree, used by `--append-system-prompt-file` for compaction resilience (regenerated each phase, cleaned up by `SessionEnd` hook)
- One `.branch` file per lifecycle session, used by in-place mode to resume on the correct branch after branch renames or shell navigation
- One `.interventions` file per lifecycle session, recording human control receipts for audit without storing prompt text
- One `.overrides` journal per lifecycle session, recording active, cleared,
  and waived agent/human policy decisions with scope, optional expiry, and
  reason; waiver rows remain audit history and are not exposed as live values
- One `.phase-outcomes` file per lifecycle session — the durable terminal outcome ledger (completed/skipped/waived) behind the progress header symbols
- One `.human-complete` file per lifecycle session when a human marked the lifecycle done, preserving the completion attribution in the terminal proof
- One `.meta` file per lifecycle or declared review child, with trusted
  workspace and parent/child provenance used by the session catalog
- One `.run-id` file linking the lifecycle to its durable journal under
  `~/.dex/runs/`
- One `.runtime` record while a provider-backed workflow owns the session,
  plus a persistent `.runtime-lock` inode used to serialize ownership and
  terminal status updates

UI artifacts are stored separately in `~/.claude/.dex-artifacts/` so screenshots, videos, traces, flow scripts, logs, and PR attachment manifests stay out of git. GitHub receives only the current images and videos selected by the bundle; diagnostic and editable artifacts remain local or in DexCode.

## Environment Variables

These values provide launch-time defaults. A valid active-session override is
read again by its consumer and takes precedence without a relaunch. Review can
use an override-bound lower target; other assurance gates use
`dx control waive`. Neither mechanism weakens the meaning of a passed outcome.

| Variable | Default | Description |
|----------|---------|-------------|
| `DEX_LOOP_ACTIVE` | `0` | Set to `1` to enable the phase audit loop |
| `DEX_LOOP_MAX_ITERATIONS` | `30` | Max iterations per phase before forced stop |
| `DEX_LOOP_STALL_TIMEOUT` | `300` | Seconds between audit iterations before a stall is counted |
| `DEX_LOOP_STALL_ESCALATE` | `3` | Consecutive stalls before the failure-recovery escalation prompt |
| `DEX_LOOP_MIN_AUDITS` | (per-phase) | Min audit iterations before completion is authorized |
| `DEX_LOOP_PROMISE` | `DEX_TICKET_COMPLETE` | Human-readable completion acknowledgement; the generated receipt command carries authorization |
| `DEX_LOOP_PROMPT` | (from file) | Audit prompt injected on each loop iteration |
| `DEX_LOOP_PHASE` | (set by wrapper) | Current phase number (0-6) or `prompt-loop`, used to find audit file |
| `DEX_PHASE_TIMEOUT` | `0` | Seconds any one phase may run; 0 leaves the session budget in charge |
| `DEX_PHASE_N_TIMEOUT` | unset | Per-phase override (e.g. `DEX_PHASE_2_TIMEOUT=3600`); wins over `DEX_PHASE_TIMEOUT` |
| `DEX_STOP_SOUND` | `1` | Play a sound when Claude stops (macOS only); set to 0 to turn it off |
| `DEX_STOP_SOUND_FILE` | unset | Play this sound file instead of a random system one |
| `DEX_RUN_ID` | set by Dex | Current run ID passed into hooks and provider subprocesses |
| `DEX_FACTORY_SYNC` | auto | Enable optional Factory event sync; `false`, `0`, `no`, or `off` disables it |
| `DEX_FACTORY_URL` | unset | Base Factory URL for event submission |
| `DEX_FACTORY_EVENTS_ENDPOINT` | unset | Exact Factory event endpoint; supports `{run_id}` replacement |
| `DEX_FACTORY_TOKEN` | unset | Bearer token for Factory event submission |
| `DEX_FACTORY_RUN_TOKEN` | unset | Run-scoped bearer token fallback for Factory event submission |
| `DEX_RUN_TOKEN` | unset | Generic run token fallback for Factory event submission |
| `DEX_FACTORY_BATCH_SIZE` | `50` | Maximum events per Factory sync request |
| `DEX_FACTORY_MAX_BATCHES_PER_FLUSH` | `20` | Maximum queued event batches to send in one flush |
| `DEX_FACTORY_TIMEOUT_SECONDS` | `5` | Factory HTTP request timeout |
| `DEX_FACTORY_RETRY_BASE_SECONDS` | `1` | Initial retry backoff after a failed Factory sync request |
| `DEX_FACTORY_RETRY_MAX_SECONDS` | `60` | Maximum retry backoff for Factory sync |
| `DEX_HEADLESS_RUN` | unset | Internal marker for lifecycle sessions started by `dx run` |
| `DEX_HEADLESS_RUN_SPEC_FILE` | unset | Normalized run spec path passed into the launched lifecycle |
| `DEX_HEADLESS_REQUIRES_PLAN_APPROVAL` | spec value | Whether Phase 1 must wait for interactive plan approval |
| `DEX_PHASE_N_MIN_AUDITS` | (per-phase) | Per-phase override for min audit iterations (e.g., `DEX_PHASE_2_MIN_AUDITS=5`) |
| `DEX_REVIEW_TIER` | agent-selected | Canonical explicit risk-tier override: `small`, `normal`, or `complex`; takes precedence over the legacy profile alias |
| `DEX_REVIEW_PROFILE` | unset | Legacy alias: `light`, `standard`, or `thorough` map to `small`, `normal`, or `complex` |
| `DEX_REVIEW_CLEAN_PASSES` | resolved policy | Launch-only higher consecutive `CLEAN` requirement; use the attributed `review.clean-passes` session override to lower or change a running loop |
| `DEX_REVIEW_PASS_TIMEOUT` | profile-based | Seconds a review wave or risk assessment may run before its provider process tree is stopped and review pauses; defaults are 15 minutes for risk assessment and light waves, 30 minutes for standard waves, and 60 minutes for thorough waves; `0` disables the timeout |
| `DEX_REVIEW_PASS_RECHECK_SECONDS` | `45` (45s) | Seconds the Stop hook quietly polls for a busy Phase 3 review pass to finish before re-blocking |
| `DEX_WATCH_CYCLE_TIMEOUT_SECONDS` | `120` (2m 0s) | Maximum runtime budget for one scheduled Phase 6 watcher invocation. A cycle that outruns it hands the lease to the next tick; a watcher that exits hands it over immediately, without waiting out the budget. `0` means no budget, as it does for the phase timeouts |
| `DEX_WATCH_COMMAND_TIMEOUT_SECONDS` | `30` (30s) | Maximum runtime for one GitHub/local shell command inside a watcher cycle |
| `DEX_WATCH_PAUSE_TTL_SECONDS` | `3600` (1h 0m) | Seconds scheduled Phase 6 watchers stay paused after a direct user prompt; set to 0 for no automatic expiry |
| `DEX_COMPLETE_MAX_CYCLES` | `3` | Max idle cycles before Phase 6 pauses for manual follow-up |
| `DEX_COMPLETE_WAIT_MINUTES` | `5` | Minimum wait window per Phase 6 cycle (minutes) |
| `DX_ARTIFACT_DIR` | `~/.claude/.dex-artifacts` | Screenshots, videos, traces, and logs produced by Dex |
| `DX_TOOL_DIR` | `~/.claude/.dex-tools` | Dex-managed external tooling cache |
| `DX_RUN_ROOT` | `~/.dex/runs` | Local run directories, event journals, summaries, and run artifacts |
| `DX_RTK_ENABLED` | `1` | Set to `0` to skip RTK token-reduction bootstrap |
| `DX_RTK_BIN` | unset | RTK binary path override for hooks and checks |
| `DX_RTK_INSTALL_DIR` | `$DX_TOOL_DIR/rtk/bin` | RTK binary install directory |
| `DX_RTK_VERSION` | latest release | RTK release pin for Dex installs |

### Internal safety deadlines

Not every timeout is a workflow gate. Short guard-evaluation alarms, state-lock
acquisition limits, commit-parser bounds, HTTP connect/request deadlines, and
tool-bootstrap download limits protect a single internal operation. They do
not authorize or deny a lifecycle outcome, and they are not accepted as
`dx control override` gate names. Their owning command either exposes an
explicit flag or environment setting, or reports the failure so the operation
can be retried. This separation keeps the session policy registry honest: every
accepted gate name has a live consumer.

Runtime-supervisor startup and finish waits are in this internal category. They
default to 15,000ms and 5,000ms and can be changed for a retried command with
`DX_SESSION_RUNTIME_OWNER_START_TIMEOUT_MILLISECONDS` and
`DX_SESSION_RUNTIME_OWNER_FINISH_TIMEOUT_MILLISECONDS`. On macOS, the
supervisor uses the native process API for identity checks and limits its
`lsof` fallback to three seconds so a stalled system query cannot delay the
timeout it is enforcing. A retried command can change that fallback bound with
`DX_TIMEOUT_PROCESS_SCAN_TIMEOUT_SECONDS` (1–30).

## Troubleshooting

### Loop doesn't stop

The phase Stop-hook audit pauses after `DEX_LOOP_MAX_ITERATIONS` attempts. The
outer review loop intentionally has no routine maximum and continues until its
clean gate succeeds or a deterministic pause condition occurs. Press Ctrl+C to
interrupt immediately; unchanged review state can resume later.

### Phase handoff does not continue

The Stop hook should inject the next phase directly into the Claude screen. If
you return to a shell prompt and nothing starts, run:

```bash
dx --resume
```

### Loop stops too early

Check that `DEX_LOOP_ACTIVE=1` is set in the environment. The `dx` command sets this automatically, but manual `claude` invocations don't.

### High API costs

Choose the review tier that matches the actual risk. The global clean-wave
requirements are 1 for `small`, 2 for `normal`, and 3 for `complex`. Do not
lower the tier for security, contract, migration, concurrency, shell/hook, or
broad dependency changes. `DEX_LOOP_MAX_ITERATIONS` controls phase-audit
retries, not the review clean gate.
