# Autonomous Mode (Phase Audit Loops)

Dex runs the ticket lifecycle as a series of phases, each with its own quality-gated audit loop. When Claude tries to stop during a phase, the Stop hook injects a phase-specific audit prompt that critically reviews the work done. The loop continues until the audit is satisfied and the completion signal is detected.

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
  - Checks for .complete signal file -> if found, advances inline or exits final session
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
  - Writes .complete file + outputs promise -> hook hands off to next phase
  |
  v
Claude continues with the next phase in the same session
```

## Phase Audit Prompts

Each phase has its own audit prompt in `prompts/phase-audits/`:

| Phase | Audit File | What It Reviews |
|-------|-----------|-----------------|
| 0. Setup | `0-setup.md` | Ticket read + assigned, branch renamed + pushed, ticket status In Progress, meta sidecar updated |
| 1. Plan | `1-plan.md` | Completeness, edge cases, dependencies, scope, user approval |
| 2. Implement | `2-implement.md` | Task completion, TDD verification, UI capture evidence, evidence table, Phase 3 risk selection |
| 3. Review | `3-review-loop.md` | Independent `/dxreviewloop` waves reaching the selected 3/6/9 clean gate |
| 4. Verify & Commit | `4-verify.md` | All checks passing, commit quality, pushed to origin |
| 5. PR | `5-pr.md` | Description quality, scope match, draft PR created with `request` reviewers attached |
| 6. Complete | `6-complete.md` | Cycle loop: mark ready, request reviewers, post mention comment, monitor CI/reviews through `/dxwatchpr`, address failures, re-request after each push, close ticket, clean up local worktree/branch |

The review audit (Phase 3) is risk-selected. After the final Phase 2 in-scope
change, the implementation agent applies the ordered rubric and records the
highest matching tier with bounded reason codes. `small` maps to a `light`
profile and 3 consecutive clean waves, `normal` maps to `standard` and 6, and
`complex` maps to `thorough` and 9. Trust boundaries; authentication,
authorization, permissions, secrets, payments, or destructive behavior;
persistence, schemas, or migrations; public API, CLI, configuration, or
compatibility contracts; concurrency or process lifecycle; hooks, guards, CI,
deployment, or packaging; broad cross-module behavior; and material uncertainty
require `complex` review.

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
copies before and after each provider call, and evidence carries an ordered hash
for every supplied item. Missing, changed, or partially covered criteria pause
review without clean credit. Standalone review has no criteria artifact and
carries an explicit `N/A` binding with empty criteria coverage.

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

For browser UI changes, Phase 2 also requires before/after UI capture evidence before handoff to review. `/dxuicapture` stores screenshots, videos, traces, browser logs, and a `visual-evidence.md` upload manifest under `~/.claude/.dex-artifacts/` and links them in the implementation evidence. See [ui-capture.md](ui-capture.md).

Phase 6 (Complete) is autonomous and bounded: it reads `## Reviewers` from `.dex/dex.md` to know who to request reviews from. The user is brought into the loop as a configured reviewer. The autonomous loop waits at least `DEX_COMPLETE_WAIT_MINUTES` (default 5) per cycle for CI and reviews, addresses failures through `/dxwatchpr` and `/dxprreview`, re-requests reviewers after each push, and closes the ticket once CI is green and all successfully requested reviewers approve. Reviewers GitHub says are not requestable for the repository are warnings, not approval gates. After `DEX_COMPLETE_MAX_CYCLES` (default 3) idle cycles with no progress, it pauses with manual follow-up instructions. It never merges the PR.

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

When the user submits a direct prompt during Phase 6, the `UserPromptSubmit` hook writes a `.watch-pause` marker. Scheduled `/dxwatchpr` cycles must no-op while the marker is active, so manual work is not interrupted by CI/review polling commands. The pause expires after `DEX_WATCH_PAUSE_TTL_SECONDS` (default `60m 0s`) unless the user runs `/dxcomplete` or asks to resume watching.

Each watcher cycle also has a runtime lock with a default budget of `2m 0s`. If a later `/loop` tick fires while the previous `/dxwatchpr` cycle is still within that budget, the later tick skips instead of starting overlapping GitHub or CI work. Individual watcher shell commands default to `0m 30s`.

After Phase 1 approval, the Stop hook advances through normal Phase 2-5
handoffs in the same Claude session without asking whether to continue. A phase pauses only when it hits an
explicit escalation condition such as missing credentials/tooling, a destructive
git decision, repeated failed fix attempts, a max phase-audit count, review
findings/blockers/churn, or feedback that needs human judgement.

### Direct human control

The latest direct human instruction always takes priority over the phase loop.
During an active Claude lifecycle, natural instructions such as `stop Dex`,
`leave the review loop`, `mark this phase done`, `skip verification`, `jump to
the PR phase`, or `resume Dex` are applied by the `UserPromptSubmit` hook before
the agent's next tool call. Pause and stop detach the session from Dex's Stop
hook's phase sequencing while preserving the workspace and current phase for a
later resume.

The same controls are available from a terminal and to direct Codex sessions:

```bash
dx control status
dx control pause
dx control stop
dx control done
dx control jump verify
dx control resume
```

Human control does not disable review-wave session isolation or the
destructive-command, secret, and sensitive-file guards. Commit, push, and PR
operations are not blocked by lifecycle phase, with or without a human control
receipt. A requested Phase 3 jump becomes a safe detach if a review child is
still marked in flight; the jump can be retried after that process ends.
Human-marked lifecycle completion also preserves the workspace instead of
running automatic worktree cleanup.

Audit prompts are editable markdown files. Changes take effect on the next loop iteration without reloading shell functions.

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
The `/dxloop` skill creates an `.active` signal file in `~/.claude/.dex-loops/`. The Stop hook checks for this file as an alternative to the environment variable, since env vars can't be injected into a running process.

```bash
# The /dxloop skill does this internally:
touch "$(dx_active_file "$(dx_session_id)")"
```

The `.active` file is cleaned up automatically when the loop completes (`.complete` file found) or reaches max iterations.

**Ownership.** Dex session ids are derived from the repo + worktree/branch path, so two Claude sessions opened in the same checkout resolve the same id. To keep a loop from capturing bystander sessions, the Stop hook records the owning Claude session id (from the hook payload) in an `.owner` file next to `.active`. Env-activated sessions (`DEX_LOOP_ACTIVE=1` with an explicit `DEX_SESSION_ID`) own their loop and (re)claim it on every stop; file-activated sessions claim only when unclaimed and otherwise stay inert. Wrappers clear the claim before each launch so relaunch/`--resume` re-claims cleanly.

**Review-wave passes.** Sessions launched with `DEX_REVIEW_PASS_ACTIVE=1`
(`/dxreviewloop` waves) run under a pass-scoped session id
(`<session>-pass-<N>-<pid>`) and are hard-isolated in the Stop hook. The inline
phase handoff never runs for them, so a wave cannot advance the lifecycle or be
instructed to advance it. Each pass gets a new context-pack path and no prior
review conclusions. This isolation does not restrict ordinary commit, push,
branch, or PR actions; those remain available in every lifecycle phase.

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

This runs the same six-phase lifecycle in the current git checkout. Dex does
not create a worktree, but it still prepares the normal lifecycle branch
(`worktree-ticket-*` or `worktree-task-*`) in the current checkout, using
the default branch's upstream or remote-tracking ref as the starting point just
like worktree mode. It never branches new work from the current feature branch.
Phase 4 commits and pushes that branch. If uncommitted changes are present and
Dex would need to switch or create the lifecycle branch, it stops so you can
commit or stash first. `dx --resume` resumes the most recent worktree or
in-place lifecycle.

## Prompt Loop Mode (`dxloop`)

For ad-hoc tasks that don't need the full phased lifecycle, `dxloop` runs a single prompt in a loop until the AI confirms everything is implemented:

```bash
dxloop Add rate limiting to the /api/users endpoint. Support 100 req/min per API key with Redis backing.
```

This uses the same Stop hook infrastructure as `dx`, but:
- Runs in the **current directory** (no worktree created)
- Uses a single generic audit prompt (`prompts/phase-audits/prompt-loop.md`)
- Completion promise is `PROMPT_COMPLETE`
- Cleans up state files automatically when done

The audit prompt extracts requirements from the original prompt and verifies each one on every iteration, continuing until all requirements are implemented and quality review passes.

Override max iterations: `DEX_LOOP_MAX_ITERATIONS=15 dxloop fix the bug`

## Completion Signals

Each phase has its own completion promise:

| Phase | Promise |
|-------|---------|
| 1 | `PHASE_1_COMPLETE` |
| 2 | `PHASE_2_COMPLETE` |
| 3 | `PHASE_3_COMPLETE` |
| 4 | `PHASE_4_COMPLETE` |
| 5 | `PHASE_5_COMPLETE` |
| 6 | `DEX_TICKET_COMPLETE` |
| dxloop | `PROMPT_COMPLETE` |

Claude should only output the promise after the audit criteria are fully met.

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
finishes, escalation, completion, and pause. Payloads contain normalized tiers,
reason codes, counts, durations, exit reasons, and churn categories. They do not
contain findings, fingerprints, source paths, prompts, diffs, context packs, or
free-form rationale.

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
reached, the hook pauses the current phase and asks the agent to summarize the
blocker. The `.complete` file is not written, so `dx --resume` continues from
the same phase after intervention.

Override with:

```bash
DEX_LOOP_MAX_ITERATIONS=50 dx 999
```

This limit does not bound `/dxreviewloop`'s outer clean-pass loop. Review has no
routine outer maximum; it runs until its selected clean gate succeeds or a
finding, blocker, churn condition, invalid result, provider failure, user
interrupt, or explicitly configured emergency ceiling pauses it.

### Escalation

Even in autonomous mode, Claude stops and escalates to the user for:
- Secrets scan failures (never auto-fix security issues)
- Architectural review comments (need human judgement)
- 3+ failed attempts at the same fix (loop is stuck)
- Scope changes that affect other tickets
- Missing credentials/tooling or destructive git operations that require explicit approval
- Max phase-audit iterations without a completion signal
- Residual review findings, review blockers, or review churn

### Manual Override

The user can always interrupt by providing input or pressing Ctrl+C. Phase state is saved so `dx 999` or `dx --resume` picks up where it left off.

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
- `.complete` — completion signal, written by phase audit prompts or `/dxcomplete`
- `.active` — activation signal for in-session `/dxloop` (alternative to `DEX_LOOP_ACTIVE` env var)
- `.prompt` — original freeform task or `dxloop` prompt, re-injected during audits and kept outside the git checkout
- `.handoff-mode` — marker that this `dx` run should advance phases in-session
- `.paused` — one-shot marker that lets an inline session exit after reporting a safety-net pause
- `.control` — current direct-human pause, stop, complete, or phase-jump receipt; stores a prompt hash rather than prompt text
- `.control-lock` — transition lock that prevents two Stop-hook invocations from applying the same receipt
- `.watch-pause` — marker that scheduled Phase 6 PR watcher should no-op after a direct user prompt
- `.watch-lock` — per-watcher overlap lock that bounds one scheduled `/dxwatchpr` cycle
- `.phase-1.started` / `.phase-1.ready` — Phase 1 markers written by `dxplan`; the Stop hook does not count plan audit iterations until the approval marker exists
- `.phase-2.ready` — Phase 2 marker written by `dximplement` only after every
  acceptance criterion and verification gate is complete and a valid
  current-scope review-risk selection exists; the Stop hook ignores
  `PHASE_2_COMPLETE` without it
- `.phase-3.busy` — Phase 3 marker written by `dxreviewloop` while a review wave is running; the Stop hook does not count audit iterations while waiting
- `.phase-3.busy-notice` — timestamp used to throttle repeated Phase 3 busy-gate notices while the same review pass is still running
- `.review-criteria.json` — strict approved objectives, acceptance criteria,
  and verification requirements created after plan approval; each lifecycle
  assessor and wave gets a temporary child-scoped copy
- `.review-criteria-approval` — versioned approval seal containing the canonical
  criteria hash; replacements require explicit reapproval and invalidate prior
  review authorization
- `.review-selection` — risk tier, selection source, bounded reason codes,
  scope fingerprint, and criteria binding recorded before the first wave and
  rebound after review fixes
- `.review-state` — selected tier, required clean count, iteration, clean count,
  scope fingerprint, and criteria binding used to resume an unchanged review
- `.review-receipt` — successful clean-gate receipt tied to the reviewed scope,
  clean ledger, and criteria binding; Phase 3 does not advance on prose success
  alone
- `.review-context` — pass-scoped compact context pack; each fresh reviewer gets
  a new path and no previous review report
- `.findings` — transient findings fingerprints used only by the outer wrapper
  for repeated/alternating churn detection; fingerprints are not passed to
  reviewers or telemetry
- The session ID is derived from a stable repo key plus the worktree directory name (stable across branch renames and unique across repos)
- Loop files are cleaned up on completion, by `dxrm`, and by `dxclean`
- Old files (7+ days) are pruned by `dxclean`

Phase state is stored in `~/.claude/.dex-phases/`:
- One `.phase` file per worktree, tracking which phase is current (1-6; 7 = ticket complete)
- One `.times` file per worktree, tracking start times for elapsed calculations
- One `.system-context` file per worktree, used by `--append-system-prompt-file` for compaction resilience (regenerated each phase, cleaned up by `SessionEnd` hook)
- One `.branch` file per lifecycle session, used by in-place mode to resume on the correct branch after branch renames or shell navigation
- One `.interventions` file per lifecycle session, recording human control receipts for audit without storing prompt text

UI artifacts are stored separately in `~/.claude/.dex-artifacts/` so screenshots, videos, traces, flow scripts, logs, and PR upload manifests stay out of git.

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DEX_LOOP_ACTIVE` | `0` | Set to `1` to enable the phase audit loop |
| `DEX_LOOP_MAX_ITERATIONS` | `30` | Max iterations per phase before forced stop |
| `DEX_LOOP_MIN_AUDITS` | (per-phase) | Min audit iterations before completion is authorized |
| `DEX_LOOP_PROMISE` | `DEX_TICKET_COMPLETE` | Completion signal for the current phase |
| `DEX_LOOP_PROMPT` | (from file) | Audit prompt injected on each loop iteration |
| `DEX_LOOP_PHASE` | (set by wrapper) | Current phase number (1-6) or `prompt-loop`, used to find audit file |
| `DEX_SESSION_TIMEOUT` | `86400` | Session timeout in seconds (24h). Set to 0 to disable. |
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
| `DEX_REVIEW_CLEAN_PASSES` | tier-based | Optional higher consecutive `CLEAN` requirement; it cannot lower the selected tier's 3/6/9 floor |
| `DEX_REVIEW_PASS_TIMEOUT` | `900` (15m 0s) | Seconds a review wave or risk assessment may run before its provider process tree is stopped and review pauses; `0` disables the timeout |
| `DEX_REVIEW_PASS_NOTICE_INTERVAL` | `120` (2m 0s) | Minimum seconds between repeated Phase 3 busy-gate notices for the same review pass |
| `DEX_REVIEW_PASS_RECHECK_SECONDS` | `45` (0m 45s) | Seconds the Stop hook quietly polls for a busy Phase 3 review pass to finish before re-blocking |
| `DEX_WATCH_CYCLE_TIMEOUT_SECONDS` | `120` (2m 0s) | Maximum runtime budget for one scheduled Phase 6 watcher invocation |
| `DEX_WATCH_COMMAND_TIMEOUT_SECONDS` | `30` (0m 30s) | Maximum runtime for one GitHub/local shell command inside a watcher cycle |
| `DEX_WATCH_PAUSE_TTL_SECONDS` | `3600` (60m 0s) | Seconds scheduled Phase 6 watchers stay paused after a direct user prompt; set to 0 for no automatic expiry |
| `DEX_COMPLETE_MAX_CYCLES` | `3` | Max idle cycles before Phase 6 pauses for manual follow-up |
| `DEX_COMPLETE_WAIT_MINUTES` | `5` | Minimum wait window per Phase 6 cycle (minutes) |
| `DX_ARTIFACT_DIR` | `~/.claude/.dex-artifacts` | Screenshots, videos, traces, and logs produced by Dex |
| `DX_TOOL_DIR` | `~/.claude/.dex-tools` | Dex-managed external tooling cache |
| `DX_RUN_ROOT` | `~/.dex/runs` | Local run directories, event journals, summaries, and run artifacts |
| `DX_RTK_ENABLED` | `1` | Set to `0` to skip RTK token-reduction bootstrap |
| `DX_RTK_BIN` | unset | RTK binary path override for hooks and checks |
| `DX_RTK_INSTALL_DIR` | `$DX_TOOL_DIR/rtk/bin` | RTK binary install directory |
| `DX_RTK_VERSION` | latest release | RTK release pin for Dex installs |

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

Choose the review tier that matches the actual risk: `small` requires 3 clean
waves, `normal` 6, and `complex` 9. Do not lower the tier for security,
contract, migration, concurrency, shell/hook, or broad dependency changes.
`DEX_LOOP_MAX_ITERATIONS` controls phase-audit retries, not the review clean
gate.
