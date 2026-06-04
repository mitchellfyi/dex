---
name: "dxwatchpr"
description: "Monitor a ready PR for CI failures and review feedback, fix issues when appropriate, and hand completion back to dxcomplete."
---

# Skill: dxwatchpr

Monitor a ready PR for both CI status and review feedback. This is the only scheduled Phase 6 watcher.

## When to Use

- Scheduled via `/loop 5m /dxwatchpr` from `/dxcomplete` after `gh pr ready`
- Can also be invoked manually for a one-off CI/review check

## How It Works

Each invocation is a **single check cycle**. `/loop` handles scheduling. The session context carries state between invocations naturally.

Each cycle has a hard runtime budget from `DEX_WATCH_CYCLE_TIMEOUT_SECONDS` (default `2m 0s`). Do not allow a watcher cycle to run longer than that budget or overlap with a later `/loop` tick.

## Arguments

Optional: a PR number (e.g., `/dxwatchpr 456`). If omitted, operates on the current branch's open PR.

## Steps

### 0. Respect Manual User Interruptions

Before running any PR, CI, GitHub, or repository commands, check whether a direct user prompt has paused scheduled Phase 6 watchers:

```bash
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"
SESSION_ID="${DEX_SESSION_ID:-$(dx_session_id)}"
WATCH_NAME="pr"
if dx_watch_pause_active "$SESSION_ID"; then
  pause_ttl=$(dx_watch_pause_ttl_seconds)
  if [[ "$pause_ttl" -eq 0 ]]; then
    pause_detail="Pause does not expire automatically."
  else
    pause_detail="Pause expires after $(dx_format_duration "$pause_ttl")."
  fi
  echo "Dex watcher paused by a recent user prompt. Skipping this scheduled /dxwatchpr cycle without running PR or CI commands. ${pause_detail} Run /dxcomplete or ask to resume watching to clear it."
  exit 0
fi
if ! dx_watch_lock_acquire "$SESSION_ID" "$WATCH_NAME"; then
  cycle_timeout=$(dx_watch_cycle_timeout_seconds)
  echo "Previous /dxwatchpr cycle is still within its $(dx_format_duration "$cycle_timeout") runtime budget. Skipping this scheduled tick without running PR or CI commands."
  exit 0
fi
trap 'dx_watch_lock_release "$SESSION_ID" "$WATCH_NAME"' EXIT
```

Every GitHub or local shell command in this watcher must be bounded. Use either the Bash tool timeout with a value no greater than `$(dx_format_duration "$(dx_watch_command_timeout_seconds)")`, or wrap direct commands with:

```bash
dx_run_with_timeout "$(dx_watch_command_timeout_seconds)" <command> [args...]
```

If a command returns `124`, it timed out. Report the timeout using `dx_format_duration`, release the lock via the trap, and exit this cycle.

### 1. Get PR Info

```bash
REPO=$(dx_run_with_timeout "$(dx_watch_command_timeout_seconds)" gh repo view --json nameWithOwner -q .nameWithOwner)

# Use provided PR number, or detect from current branch
if [[ -n "$1" ]]; then
  PR_NUM="$1"
else
  PR_NUM=$(dx_run_with_timeout "$(dx_watch_command_timeout_seconds)" gh pr view --json number -q .number)
fi
```

Capture the local head SHA before making changes:

```bash
PRE_HEAD=$(git rev-parse HEAD)
```

### 2. Check and Fix CI

```bash
dx_run_with_timeout "$(dx_watch_command_timeout_seconds)" gh pr checks "$PR_NUM"
```

Parse each check: name, status (pending/pass/fail), URL.

**All checks pass:**
- Record that CI is green for this cycle.

**Any checks still pending:**
- Do not diagnose yet. Continue to review/comment checks, then wait for the next loop invocation.

**Any checks failed:**
- Fetch logs and diagnose:
  ```bash
  dx_run_with_timeout "$(dx_watch_command_timeout_seconds)" gh run view <run-id> --log-failed
  ```
- Diagnose the failure from the logs. Common categories:
  - **Formatting/linting**: run the project's formatter/linter locally, commit, push
  - **Type errors**: run the type checker locally, fix errors, commit, push
  - **Test failures**: run the specific failing test locally, diagnose, fix, commit, push
  - **Code generation drift**: run the project's code generator, commit if changes, push
  - **Dependency issues**: check lockfile freshness, install, commit if changes, push
  - **Secrets scan**: STOP IMMEDIATELY. Cancel the watcher. Alert the user. Do not auto-fix.
  - **Infrastructure failure** (Docker pull timeout, OOM in CI): suggest `gh run rerun <id> --failed` or escalate
  - **Flaky tests**: if the same test fails intermittently with different error messages or passes on local rerun, retry once via `gh run rerun <id> --failed`. If it fails again on the same test, escalate with the test name and both failure outputs rather than attempting code fixes.
- After fixing:
  1. Verify the fix locally with the specific failed check.
  2. Commit with `fix(ci): <description>` and the Dex co-author trailer from `prompts/commit-format.md`. Do not add Claude attribution.
  3. Push. This triggers a new CI run.
  4. Continue to review/comment checks in this cycle if there is enough budget; otherwise exit and let the next loop invocation pick up the new run.

### 3. Check Reviews and Comments

```bash
dx_run_with_timeout "$(dx_watch_command_timeout_seconds)" gh api "repos/$REPO/pulls/$PR_NUM/reviews"
dx_run_with_timeout "$(dx_watch_command_timeout_seconds)" gh api "repos/$REPO/pulls/$PR_NUM/comments"
dx_run_with_timeout "$(dx_watch_command_timeout_seconds)" gh api graphql --paginate \
  -f owner="${REPO%%/*}" \
  -f name="${REPO#*/}" \
  -F number="$PR_NUM" \
  -f query='
query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $endCursor) {
        nodes {
          id
          isResolved
          comments(first: 100) { nodes { id } }
        }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}'
```

### 4. Address Comments

If there are unaddressed comments (comments not yet replied to or resolved):

Run `/dxprreview` to critically evaluate and respond to each comment. `dxprreview` replies inline by default and does not pause to ask how replies should be delivered.

`/dxprreview` will:
- Classify each comment (bug, security, request-change, question, suggestion, nitpick, approval)
- Critically evaluate whether to fix, push back, answer, or escalate
- Implement and push fixes for accepted comments
- Reply to every comment inline with reasoning
- Resolve each inline review thread after replying when the reply clearly closes the comment
- Return a list of escalations (if any)

If `/dxprreview` reports escalations, proceed to Step 7 (Escalation).

### 5. Re-Request Reviewers After a Push

If this cycle pushed any new commits (from a CI fix or `/dxprreview`), re-trigger reviewers so they get a fresh notification that there's something new to look at. Read the `## Reviewers` section of `.dex/dex.md`:

```bash
POST_HEAD=$(git rev-parse HEAD)
if [[ "$PRE_HEAD" != "$POST_HEAD" ]]; then
  source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"
  # For each request-type reviewer:
  for h in "${REQUEST_REVIEWERS[@]}"; do
    dx_maintenance_request_reviewer "$PR_NUM" "$h"
  done
  # For each mention-type reviewer, post a fresh comment:
  if [[ ${#MENTION_REVIEWERS[@]} -gt 0 ]]; then
    handles=$(printf '%s ' "${MENTION_REVIEWERS[@]}")
    handles="${handles% }"
    # Run this comment body through the `humanizer` skill before posting.
    gh pr comment "$PR_NUM" --body "Updated: ${handles}, please re-review."
  fi
fi
```

`dx_maintenance_request_reviewer` wraps idempotent `gh pr edit --add-reviewer` requests and treats non-requestable reviewers as warnings. Re-running on a reviewer that's already requested triggers a fresh notification on supported clients without duplicating the request.

### 6. Evaluate Completion

**All checks pass, all successfully requested reviews approved, no unresolved comments:**
1. Cancel the PR monitoring loop: use `CronDelete` with the job ID.
2. Report:
   - Total checks: X (all passed)
   - Total reviews: X (Y approved, Z with comments)
   - Comments addressed: N
   - Source breakdown: automated vs human
3. Proceed to `/dxcomplete` so Phase 6 can run final verification, close the ticket, and end the session.

Invoke the `humanizer` skill on any free-form PR comments or status prose before publishing or printing them. Preserve reviewer handles, check names, counts, SHAs, and commands exactly.

**Checks pending, reviews pending, or comments unresolved:**
- Do nothing further. Wait for the next loop invocation.

### 7. Escalation

STOP, cancel the watcher, and escalate to the user when:
- The same CI check fails 3 times after attempted fixes.
- A secrets scan fails. Credential rotation may be needed.
- A reviewer requests a significant architectural change (affects multiple files, changes the approach).
- There is a disagreement with a reviewer on the correct approach.
- A reviewer's comment is unclear and you can't determine the right fix.
- A human reviewer explicitly requests changes that conflict with the approved plan, require scope/architecture judgement, or remain unclear after reading the surrounding code.

Clear, in-scope human feedback should be handled autonomously through `/dxprreview`; do not pause only because the commenter is human.

## Timeout

The scheduled watcher is bounded by Phase 6: `/dxcomplete` defaults to 3 idle cycles of 5 minutes each. When that window expires, Dex pauses with a notice telling the user to run `/dxwatchpr` manually for a one-off CI/review check, `/loop 5m /dxwatchpr` to resume watching, or `/dxcomplete` when the PR is ready to complete the ticket.

## Notes

- CI only runs after `gh pr ready`; draft PRs do not trigger CI.
- A push during CI triggers a new run; the old run is cancelled automatically.
- Some checks only run when specific paths change (check the project's CI configuration).
- Automated reviewers typically respond within 5-10 minutes.
- Human reviewers may take hours; the bounded watch window is intentionally short.
- Do not dismiss review comments. Always reply, even if the fix is trivial.
