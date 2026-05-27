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
| 2. Implement | `2-implement.md` | Task completion, TDD verification, UI capture evidence, evidence table |
| 3. Review | `3-review-loop.md` | `/dxreviewloop` requiring the resolved profile's clean full-scope review waves |
| 4. Verify & Commit | `4-verify.md` | All checks passing, commit quality, pushed to origin |
| 5. PR | `5-pr.md` | Description quality, scope match, draft PR created with `request` reviewers attached |
| 6. Complete | `6-complete.md` | Cycle loop: mark ready, request reviewers, post mention comment, monitor CI/reviews through `/dxwatchpr`, address failures, re-request after each push, close ticket, clean up local worktree/branch |

The review audit (Phase 3) is adaptive. Phase 3 runs `/dxreviewloop`, which
starts from `DEX_REVIEW_PROFILE=auto`: light for tiny/docs-only changes,
standard for normal changes, and thorough for high-risk or broad changes. Each
wave builds a compact context pack, runs deterministic checks, harvests issues in
the fresh wave session, runs targeted domain sweeps when the profile requires
them, verifies findings, batch-fixes verified issues, and
rechecks affected surfaces. A wave that fixes anything writes `FINDINGS_FIXED:N`,
which resets the outer clean counter. A wave can write `ESCALATE_THOROUGH:reason`
when the profile is too shallow.

For browser UI changes, Phase 2 also requires before/after UI capture evidence before handoff to review. `/dxuicapture` stores screenshots, videos, traces, browser logs, and a `visual-evidence.md` upload manifest under `~/.claude/.dex-artifacts/` and links them in the implementation evidence. See [ui-capture.md](ui-capture.md).

Phase 6 (Complete) is autonomous and bounded: it reads `## Reviewers` from `.dex/dex.md` to know who to request reviews from. The user is brought into the loop as a configured reviewer. The autonomous loop waits at least `DEX_COMPLETE_WAIT_MINUTES` (default 5) per cycle for CI and reviews, addresses failures through `/dxwatchpr` and `/dxprreview`, re-requests reviewers after each push, and closes the ticket once everything is approved and CI is green. After `DEX_COMPLETE_MAX_CYCLES` (default 3) idle cycles with no progress, it pauses with manual follow-up instructions. It never merges the PR.

When the user submits a direct prompt during Phase 6, the `UserPromptSubmit` hook writes a `.watch-pause` marker. Scheduled `/dxwatchpr` cycles must no-op while the marker is active, so manual work is not interrupted by CI/review polling commands. The pause expires after `DEX_WATCH_PAUSE_TTL_SECONDS` (default `60m 0s`) unless the user runs `/dxcomplete` or asks to resume watching.

Each watcher cycle also has a runtime lock with a default budget of `2m 0s`. If a later `/loop` tick fires while the previous `/dxwatchpr` cycle is still within that budget, the later tick skips instead of starting overlapping GitHub or CI work. Individual watcher shell commands default to `0m 30s`.

After Phase 1 approval, the Stop hook advances through normal Phase 2-5
handoffs in the same Claude session without asking whether to continue. A phase pauses only when it hits an
explicit escalation condition such as missing credentials/tooling, a destructive
git decision, repeated failed fix attempts, max audit/review iterations, or
feedback that needs human judgement.

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
Claude on Opus 4.7 unless `.dex/providers.json` or `~/.dex/providers.json`
selects a different provider profile. `dx --model <model>` passes the model to
the selected agent: Claude receives it through `claude --model`, while Codex
receives it through Dex's Codex wrapper as `codex exec --model`.

**From inside an existing Claude Code session** (via `/dxloop` skill):
The `/dxloop` skill creates an `.active` signal file in `~/.claude/.dex-loops/`. The Stop hook checks for this file as an alternative to the environment variable, since env vars can't be injected into a running process.

```bash
# The /dxloop skill does this internally:
touch "$(dx_active_file "$(dx_session_id)")"
```

The `.active` file is cleaned up automatically when the loop completes (`.complete` file found) or reaches max iterations.

To run without the audit loop:

```bash
cd .dex/worktrees/ticket-999
claude --model claude-opus-4-7 --dangerously-skip-permissions --permission-mode bypassPermissions  # No DEX_LOOP_ACTIVE set, no .active file
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
`origin/<default>` as the starting point just like worktree mode. Phase 4 commits
and pushes that branch. If uncommitted changes are present and Dex would need
to switch or create the lifecycle branch, it stops so you can commit or stash
first. `dx --resume` resumes the most recent worktree or in-place lifecycle.

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
fresh full-scope review waves.

## Status Line

During autonomous phases (2-6), a custom status line displays live information in the Claude Code TUI:
- Current phase number (e.g., `Phase 2/6`)
- Audit loop iteration count (e.g., `Audit 3/30`)
- Total elapsed time (e.g., `4m 22s`)

The status line is driven by `bin/status-line.sh` which reads state files from `~/.claude/.dex-phases/` and `~/.claude/.dex-loops/`. It is injected per-session via `--settings` and does not affect the global settings.

## Run Events

Provider-backed Dex commands create a run ID and a local event journal under
`~/.dex/runs/<run_id>/`. The main lifecycle emits `run.*` and `phase.*` events
as the Stop hook advances, blocks, or completes phases. `dx init` and `dx sync`
also emit run-level start and finish events.

Events are append-only JSONL for machines. Human-facing phase logs still live in
`~/.claude/.dex-phases/<session_id>.log`. See [events.md](events.md) for the
schema and storage layout.

## Safety Controls

### Max Iterations

Default: 30 iterations per phase. When the limit is reached, the Stop hook pauses the current phase and asks Claude to summarize the blocker. The `.complete` file is NOT written, so `dx --resume` continues from the same phase after intervention.

Override with:

```bash
DEX_LOOP_MAX_ITERATIONS=50 dx 999
```

### Escalation

Even in autonomous mode, Claude stops and escalates to the user for:
- Secrets scan failures (never auto-fix security issues)
- Architectural review comments (need human judgement)
- 3+ failed attempts at the same fix (loop is stuck)
- Scope changes that affect other tickets
- Missing credentials/tooling or destructive git operations that require explicit approval
- Max audit/review iterations without a completion signal

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
- `.watch-pause` — marker that scheduled Phase 6 PR watcher should no-op after a direct user prompt
- `.watch-lock` — per-watcher overlap lock that bounds one scheduled `/dxwatchpr` cycle
- `.phase-1.started` / `.phase-1.ready` — Phase 1 markers written by `dxplan`; the Stop hook does not count plan audit iterations until the approval marker exists
- `.phase-2.ready` — Phase 2 marker written by `dximplement` only after every acceptance criterion and verification gate is complete; the Stop hook ignores `PHASE_2_COMPLETE` without it
- `.phase-3.busy` — Phase 3 marker written by `dxreviewloop` while a review wave is running; the Stop hook does not count audit iterations while waiting
- `.phase-3.busy-notice` — timestamp used to throttle repeated Phase 3 busy-gate notices while the same review pass is still running
- `.review-context` — compact context pack shared by one or more Phase 3 review waves
- The session ID is derived from a stable repo key plus the worktree directory name (stable across branch renames and unique across repos)
- Loop files are cleaned up on completion, by `dxrm`, and by `dxclean`
- Old files (7+ days) are pruned by `dxclean`

Phase state is stored in `~/.claude/.dex-phases/`:
- One `.phase` file per worktree, tracking which phase is current (1-6; 7 = ticket complete)
- One `.times` file per worktree, tracking start times for elapsed calculations
- One `.system-context` file per worktree, used by `--append-system-prompt-file` for compaction resilience (regenerated each phase, cleaned up by `SessionEnd` hook)
- One `.branch` file per lifecycle session, used by in-place mode to resume on the correct branch after branch renames or shell navigation

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
| `DEX_PHASE_N_MIN_AUDITS` | (per-phase) | Per-phase override for min audit iterations (e.g., `DEX_PHASE_2_MIN_AUDITS=5`) |
| `DEX_REVIEW_PROFILE` | `auto` | Starting Phase 3 review depth: `auto`, `light`, `standard`, or `thorough` |
| `DEX_REVIEW_CLEAN_PASSES` | profile-based | Exact consecutive `CLEAN` review waves required to advance Phase 3 |
| `DEX_REVIEW_MAX_ITERATIONS` | profile-based | Exact max review iterations before Phase 3 pauses |
| `DEX_REVIEW_PASS_TIMEOUT` | `900` (15m 0s) | Seconds a Phase 3 review wave may stay in progress before the lifecycle pauses |
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

The max iterations safety net (default 30) will always allow Claude to stop eventually. If you need to force-stop immediately, press Ctrl+C.

### Phase handoff does not continue

The Stop hook should inject the next phase directly into the Claude screen. If
you return to a shell prompt and nothing starts, run:

```bash
dx --resume
```

### Loop stops too early

Check that `DEX_LOOP_ACTIVE=1` is set in the environment. The `dx` command sets this automatically, but manual `claude` invocations don't.

### High API costs

Reduce `DEX_LOOP_MAX_ITERATIONS` for smaller tickets. The default of 30 is tuned for medium-sized features. For simple bug fixes, 10-15 is sufficient.
