# Autonomous Mode (Phase Audit Loops)

Doyaken runs the ticket lifecycle as a series of phases, each with its own quality-gated audit loop. When Claude tries to stop during a phase, the Stop hook injects a phase-specific audit prompt that critically reviews the work done. The loop continues until the audit is satisfied and the completion signal is detected.

## How It Works

```
User runs: dk 999
  |
  v
Wrapper creates worktree, starts Phase 1
(`dk --no-worktree` skips worktree creation and uses the current checkout)
  |
  v
Claude starts with DOYAKEN_LOOP_ACTIVE=1
  |
  v
Claude works on the phase (e.g., /dkplan, /dkimplement)
  |
  v
Claude tries to stop
  |
  v
Stop hook (phase-loop.sh) intercepts:
  - Checks for .complete signal file -> if found, cleans up state, allows stop
  - Checks iteration count -> if max reached, allows stop
  - Checks min audit iterations -> if below threshold, blocks WITHOUT completion instructions
  - If at/above threshold: blocks but INCLUDES completion instructions
  |
  v
Claude reviews its own work critically (audit loop)
  - Finds issues -> fixes them -> tries to stop -> hook re-injects audit
  - Finds nothing, below min iterations -> tries to stop -> hook blocks, no completion yet
  - Finds nothing, at/above min iterations -> hook provides completion instructions
  - Writes .complete file + outputs promise -> stop allowed
  |
  v
Wrapper advances to next phase (new Claude Code session)
```

## Phase Audit Prompts

Each phase has its own audit prompt in `prompts/phase-audits/`:

| Phase | Audit File | What It Reviews |
|-------|-----------|-----------------|
| 1. Plan | `1-plan.md` | Completeness, edge cases, dependencies, scope, user approval |
| 2. Implement | `2-implement.md` | Task completion, TDD verification, evidence table |
| 3. Review | `3-review.md` | Adversarial code review: /dkreview, 4-pass manual, self-reviewer agent |
| 4. Verify & Commit | `4-verify.md` | All checks passing, commit quality, pushed to origin |
| 5. PR | `5-pr.md` | Description quality, scope match, draft PR created with `request` reviewers attached |
| 6. Complete | `6-complete.md` | Cycle loop: mark ready, request reviewers, post mention comment, monitor, address comments, re-request after each push, close ticket |

The review audit (Phase 3) is the most rigorous — it runs as a shell-managed sub-loop with fresh Claude sessions per iteration. Each iteration runs `/dkreview`, a 4-pass manual review, and the self-reviewer agent. The shell requires 3 consecutive CLEAN iterations before advancing.

Phase 6 (Complete) is autonomous: it reads `## Reviewers` from `.doyaken/doyaken.md` to know who to request reviews from. The user is brought into the loop as a configured reviewer — the autonomous loop waits at least `DOYAKEN_COMPLETE_WAIT_MINUTES` (default 30) per cycle for reviews to come in, addresses any comments via `/dkprreview`, re-requests reviewers after each push, and closes the ticket once everything is approved and CI is green. After `DOYAKEN_COMPLETE_MAX_CYCLES` (default 3) idle cycles with no progress, it escalates to the user.

Audit prompts are editable markdown files. Changes take effect on the next loop iteration without reloading shell functions.

## Activation

Two activation mechanisms, depending on context:

**From the terminal** (via `dk` or `dkloop`):
```bash
dk 999  # Sets DOYAKEN_LOOP_ACTIVE=1 in the environment
dkloop "add rate limiting"  # Same mechanism
```

**From inside an existing Claude Code session** (via `/dkloop` skill):
The `/dkloop` skill creates an `.active` signal file in `~/.claude/.doyaken-loops/`. The Stop hook checks for this file as an alternative to the environment variable, since env vars can't be injected into a running process.

```bash
# The /dkloop skill does this internally:
touch "$(dk_active_file "$(dk_session_id)")"
```

The `.active` file is cleaned up automatically when the loop completes (`.complete` file found) or reaches max iterations.

To run without the audit loop:

```bash
cd .doyaken/worktrees/ticket-999
claude --model opus  # No DOYAKEN_LOOP_ACTIVE set, no .active file
```

## In-Place Lifecycle (`dk --no-worktree`)

For tickets or tasks where you do not want a separate checkout, use:

```bash
dk --no-worktree 999
dk --no-worktree "fix login bug"
```

This runs the same six-phase lifecycle in the current git checkout. Doyaken does
not create a worktree, but it still prepares the normal lifecycle branch
(`worktree-ticket-*` or `worktree-task-*`) in the current checkout, using
`origin/<default>` as the starting point just like worktree mode. Phase 4 commits
and pushes that branch. If uncommitted changes are present and Doyaken would need
to switch or create the lifecycle branch, it stops so you can commit or stash
first. `dk --resume` resumes the most recent worktree or in-place lifecycle.

## Prompt Loop Mode (`dkloop`)

For ad-hoc tasks that don't need the full phased lifecycle, `dkloop` runs a single prompt in a loop until the AI confirms everything is implemented:

```bash
dkloop Add rate limiting to the /api/users endpoint. Support 100 req/min per API key with Redis backing.
```

This uses the same Stop hook infrastructure as `dk`, but:
- Runs in the **current directory** (no worktree created)
- Uses a single generic audit prompt (`prompts/phase-audits/prompt-loop.md`)
- Completion promise is `PROMPT_COMPLETE`
- Cleans up state files automatically when done

The audit prompt extracts requirements from the original prompt and verifies each one on every iteration, continuing until all requirements are implemented and quality review passes.

Override max iterations: `DOYAKEN_LOOP_MAX_ITERATIONS=15 dkloop fix the bug`

## Completion Signals

Each phase has its own completion promise:

| Phase | Promise |
|-------|---------|
| 1 | `PHASE_1_COMPLETE` |
| 2 | `PHASE_2_COMPLETE` |
| 3 | `PHASE_3_COMPLETE` |
| 4 | `PHASE_4_COMPLETE` |
| 5 | `PHASE_5_COMPLETE` |
| 6 | `DOYAKEN_TICKET_COMPLETE` |
| dkloop | `PROMPT_COMPLETE` |

Claude should only output the promise after the audit criteria are fully met.

## Compaction Resilience

Long-running sessions (especially Phase 2) can trigger conversation compaction when the context window fills. Two mechanisms ensure Claude retains phase awareness after compaction:

**System prompt context file** (`--append-system-prompt-file`): For phases 2-6, `dk.sh` generates a context file at `~/.claude/.doyaken-phases/<session_id>.system-context` containing the current phase, completion protocol, and worktree path. This is passed via `--append-system-prompt-file` and persists through compaction as part of the system prompt.

**PreCompact hook**: The `PreCompact` hook fires before compaction begins and reminds Claude to re-orient using its system context. This is a supplementary safety net alongside the system prompt file.

## Session Forking

At every phase boundary (Phase 2-6), sessions are forked with `--fork-session`. This creates a new session while preserving a summary of the previous conversation, giving each phase a fresh context budget. The system prompt context file ensures essential state (phase number, scope boundaries) survives the fork.

Phase 3 (Review) additionally forks within its own sub-loop — each review iteration is a fresh Claude session, ensuring each adversarial review starts with a clean context.

## Status Line

During autonomous phases (2-6), a custom status line displays live information in the Claude Code TUI:
- Current phase number (e.g., `Phase 2/6`)
- Audit loop iteration count (e.g., `Audit 3/30`)
- Total elapsed time (e.g., `4m 22s`)

The status line is driven by `bin/status-line.sh` which reads state files from `~/.claude/.doyaken-phases/` and `~/.claude/.doyaken-loops/`. It is injected per-session via `--settings` and does not affect the global settings.

## Safety Controls

### Max Iterations

Default: 30 iterations per phase. When the limit is reached, the Stop hook prints a message ("Phase audit loop reached max iterations (30). Allowing stop."), cleans up the iteration state file and `.active` file (if present), and exits 0 — allowing Claude to stop normally. The `.complete` file is NOT written, so the `dk` wrapper treats this as an interruption and saves state for resume.

Override with:

```bash
DOYAKEN_LOOP_MAX_ITERATIONS=50 dk 999
```

### Escalation

Even in autonomous mode, Claude stops and escalates to the user for:
- Secrets scan failures (never auto-fix security issues)
- Architectural review comments (need human judgement)
- 3+ failed attempts at the same fix (loop is stuck)
- Scope changes that affect other tickets

### Manual Override

The user can always interrupt by providing input or pressing Ctrl+C. Between phases, the wrapper saves state so `dk 999` or `dk --resume` picks up where it left off.

### PR-Linked Resumption

After a PR has been created (Phase 5 done), you can resume the session linked to that PR from any machine:

```bash
dk --from-pr 42         # Resume by PR number
dk --from-pr https://github.com/org/repo/pull/42  # Or by URL
```

This is useful for one-off interventions (e.g., addressing a review comment) without needing the full phased lifecycle.

## State Management

Loop state is stored in `~/.claude/.doyaken-loops/`:
- `.state` — iteration count (e.g., `worktree-ticket-999.state`)
- `.complete` — completion signal, written by phase audit prompts or `/dkcomplete`
- `.active` — activation signal for in-session `/dkloop` (alternative to `DOYAKEN_LOOP_ACTIVE` env var)
- The session ID is derived from the worktree directory name (stable across branch renames)
- All three file types are cleaned up on completion, by `dkrm`, and by `dkclean`
- Old files (7+ days) are pruned by `dkclean`

Phase state is stored in `~/.claude/.doyaken-phases/`:
- One `.phase` file per worktree, tracking which phase is current (1-6; 7 = ticket complete)
- One `.times` file per worktree, tracking start times for elapsed calculations
- One `.system-context` file per worktree, used by `--append-system-prompt-file` for compaction resilience (regenerated each phase, cleaned up by `SessionEnd` hook)

## Environment Variables

| Variable | Default | Description |
|----------|---------|-------------|
| `DOYAKEN_LOOP_ACTIVE` | `0` | Set to `1` to enable the phase audit loop |
| `DOYAKEN_LOOP_MAX_ITERATIONS` | `30` | Max iterations per phase before forced stop |
| `DOYAKEN_LOOP_MIN_AUDITS` | (per-phase) | Min audit iterations before completion is authorized |
| `DOYAKEN_LOOP_PROMISE` | `DOYAKEN_TICKET_COMPLETE` | Completion signal for the current phase |
| `DOYAKEN_LOOP_PROMPT` | (from file) | Audit prompt injected on each loop iteration |
| `DOYAKEN_LOOP_PHASE` | (set by wrapper) | Current phase number (1-6) or `prompt-loop`, used to find audit file |
| `DOYAKEN_SESSION_TIMEOUT` | `86400` | Session timeout in seconds (24h). Set to 0 to disable. |
| `DOYAKEN_PHASE_N_MIN_AUDITS` | (per-phase) | Per-phase override for min audit iterations (e.g., `DOYAKEN_PHASE_2_MIN_AUDITS=5`) |
| `DOYAKEN_REVIEW_CLEAN_PASSES` | `3` | Consecutive clean review iterations required to advance Phase 3 |
| `DOYAKEN_REVIEW_MAX_ITERATIONS` | `10` | Max review iterations before advancing Phase 3 (safety net) |
| `DOYAKEN_COMPLETE_MAX_CYCLES` | `3` | Max idle cycles before Phase 6 escalates |
| `DOYAKEN_COMPLETE_WAIT_MINUTES` | `30` | Minimum wait window per Phase 6 cycle (minutes) |

## Troubleshooting

### Loop doesn't stop

The max iterations safety net (default 30) will always allow Claude to stop eventually. If you need to force-stop immediately, press Ctrl+C.

### Loop stops too early

Check that `DOYAKEN_LOOP_ACTIVE=1` is set in the environment. The `dk` command sets this automatically, but manual `claude` invocations don't.

### High API costs

Reduce `DOYAKEN_LOOP_MAX_ITERATIONS` for smaller tickets. The default of 30 is tuned for medium-sized features. For simple bug fixes, 10-15 is sufficient.
