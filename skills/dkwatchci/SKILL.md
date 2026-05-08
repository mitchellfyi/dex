---
name: "dkwatchci"
description: "Monitor CI checks for a ready PR, diagnose failures, and fix them when appropriate."
---

# Skill: dkwatchci

Monitor CI checks after a PR is marked ready for review. Diagnose and fix failures.

## When to Use

- Scheduled via `/loop 2m /dkwatchci` from `/dkpr` after `gh pr ready`
- Can also be invoked manually for a one-off CI check

## How It Works

Each invocation is a **single check cycle** — `/loop` handles the scheduling. The session context carries state between invocations naturally.

Each cycle has a hard runtime budget from `DOYAKEN_WATCH_CYCLE_TIMEOUT_SECONDS` (default `2m 0s`). Do not allow a watcher cycle to run longer than that budget or overlap with a later `/loop` tick.

## Arguments

Optional: a PR number (e.g., `/dkwatchci 456`). If omitted, operates on the current branch's open PR.

## Steps

### 0. Respect Manual User Interruptions

Before running any CI, GitHub, or repository commands, check whether a direct user prompt has paused scheduled Phase 6 watchers:

```bash
source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"
SESSION_ID="${DOYAKEN_SESSION_ID:-$(dk_session_id)}"
WATCH_NAME="ci"
if dk_watch_pause_active "$SESSION_ID"; then
  pause_ttl=$(dk_watch_pause_ttl_seconds)
  if [[ "$pause_ttl" -eq 0 ]]; then
    pause_detail="Pause does not expire automatically."
  else
    pause_detail="Pause expires after $(dk_format_duration "$pause_ttl")."
  fi
  echo "Doyaken watcher paused by a recent user prompt. Skipping this scheduled /dkwatchci cycle without running CI commands. ${pause_detail} Run /dkcomplete or ask to resume watchers to clear it."
  exit 0
fi
if ! dk_watch_lock_acquire "$SESSION_ID" "$WATCH_NAME"; then
  cycle_timeout=$(dk_watch_cycle_timeout_seconds)
  echo "Previous /dkwatchci cycle is still within its $(dk_format_duration "$cycle_timeout") runtime budget. Skipping this scheduled tick without running CI commands."
  exit 0
fi
trap 'dk_watch_lock_release "$SESSION_ID" "$WATCH_NAME"' EXIT
```

Every GitHub or local shell command in this watcher must be bounded. Use either the Bash tool timeout with a value no greater than `$(dk_format_duration "$(dk_watch_command_timeout_seconds)")`, or wrap direct commands with:

```bash
dk_run_with_timeout "$(dk_watch_command_timeout_seconds)" <command> [args...]
```

If a command returns `124`, it timed out. Report the timeout using `dk_format_duration`, release the lock via the trap, and exit this cycle.

### 1. Get PR Info

```bash
# Use provided PR number, or detect from current branch
if [[ -n "$1" ]]; then
  PR_NUM="$1"
else
  PR_NUM=$(dk_run_with_timeout "$(dk_watch_command_timeout_seconds)" gh pr view --json number -q .number)
fi
```

### 2. Check CI Status

```bash
dk_run_with_timeout "$(dk_watch_command_timeout_seconds)" gh pr checks "$PR_NUM"
```

Parse each check: name, status (pending/pass/fail), URL.

### 3. Evaluate and Act

**All checks pass:**
1. Cancel the CI monitoring loop: ask to cancel the `/dkwatchci` loop, or use `CronDelete` with the job ID.
2. Report:
   - Total checks: X
   - Time to green (if known)
   - Any flaky tests observed
3. If `/dkwatchpr` loop is also done (all reviews approved, no unresolved comments), proceed to `/dkcomplete`.

**Any checks still pending:**
- Do nothing. Wait for the next loop invocation.

**Any checks failed:**
- Fetch logs and diagnose:
  ```bash
  dk_run_with_timeout "$(dk_watch_command_timeout_seconds)" gh run view <run-id> --log-failed
  ```
- Diagnose the failure from the logs. Common categories:
  - **Formatting/linting** — run the project's formatter/linter locally, commit, push
  - **Type errors** — run the type checker locally, fix errors, commit, push
  - **Test failures** — run the specific failing test locally, diagnose, fix, commit, push
  - **Code generation drift** — run the project's code generator, commit if changes, push
  - **Dependency issues** — check lockfile freshness, install, commit if changes, push
  - **Secrets scan** — **STOP IMMEDIATELY.** Cancel all loops. Alert the user. Do not auto-fix.
  - **Infrastructure failure** (Docker pull timeout, OOM in CI) — suggest `gh run rerun <id> --failed` or escalate
  - **Flaky tests** — if the same test fails intermittently with different error messages or passes on local rerun, treat it as a flaky test. On the first occurrence, retry once via `gh run rerun <id> --failed`. If it fails again on the same test, escalate to the user with the test name and both failure outputs rather than attempting code fixes.
- After fixing:
  1. Verify the fix locally (run the specific check).
  2. Commit with `fix(ci): <description>` and the Doyaken co-author trailer from `prompts/commit-format.md`. Do not add Claude attribution.
  3. Push — triggers a new CI run.
  4. Wait for the next loop invocation to check the new run.

### 4. Escalation

- **Max 3 fix attempts per check.** After 3 failures on the same check, cancel the loop and escalate to the user with:
  - The check name and URL
  - What was tried
  - The error output
- **Secrets scan failure**: Cancel all loops. Escalate immediately. Credential rotation may be needed.
- **Infrastructure failure**: Suggest `gh run rerun <id> --failed` or escalate.

## Timeout

The monitoring loop should be set up alongside a **one-shot 30-minute timeout** via `/dkpr` Step 7. If checks are not all green after 30 minutes, the timeout fires, cancels all monitoring loops, and escalates to the user with a status report.

## Notes

- CI only runs after `gh pr ready` — draft PRs do not trigger CI.
- A push during CI triggers a new run; the old run is cancelled automatically.
- Some checks only run when specific paths change (check the project's CI configuration).
