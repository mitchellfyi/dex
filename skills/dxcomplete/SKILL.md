---
name: "dxcomplete"
description: "Run Phase 6 of the Dex lifecycle: ready the PR, request reviewers, monitor CI and reviews through the PR watcher, address failures, and close the ticket."
---

# Skill: dxcomplete

Phase 6 of the autonomous lifecycle. Marks the PR ready, requests configured reviewers, posts `@mention` comments, monitors CI and reviews through `/dxwatchpr`, addresses failures, and closes the ticket once everything is green and approved. It never merges the PR.

This skill runs as a **cycle loop** driven by `prompts/phase-audits/6-complete.md`. The Stop hook re-injects the audit prompt every iteration; each cycle waits at least `DEX_COMPLETE_WAIT_MINUTES` minutes before checking outcomes. Defaults are 5 minutes per cycle and 3 cycles before pausing for manual follow-up.

## When to Use

- Phase 6 of the autonomous lifecycle (invoked by `dx` after Phase 5)
- Standalone via the `dxcomplete` shell command (recovery / non-`dx` PRs)

## Autonomy Contract

Phase 6 runs unattended until CI is green and configured reviewers approve, or
until the bounded watch window or an explicit escalation condition is hit. Do
not ask the user whether to continue between wait cycles. Waiting for
CI/reviewers is handled by the Stop hook cycle loop and configured
`DEX_COMPLETE_WAIT_MINUTES`.

Before posting PR comments, ticket updates, or final prose summaries, invoke the
`humanizer` skill. Preserve reviewer handles, PR numbers, ticket IDs, commands,
tables, counts, and status labels exactly.

## Steps

### 0. Resume Phase 6 Watcher

`/dxcomplete` is the explicit signal to resume autonomous Phase 6 monitoring. Clear any pause left by a direct user prompt before launching `/dxwatchpr`:

```bash
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"
SESSION_ID="${DEX_SESSION_ID:-$(dx_session_id)}"
dx_clear_watch_pause "$SESSION_ID"
```

### 1. Read Reviewer Config

Read the `## Reviewers` section of `.dex/dex.md`. Parse rows into two lists:
- `REQUEST_REVIEWERS` — rows where Type is `request`
- `MENTION_REVIEWERS` — rows where Type is `mention`

Request reviewers with `dx_maintenance_request_reviewer`, which normalizes
handles before calling `gh pr edit --add-reviewer`. This strips leading `@` from
normal usernames but preserves GitHub CLI's special `@copilot` reviewer value.
If GitHub says a reviewer is not requestable for this repository, log the
warning and continue; do not pipe the error text into `jq`.
Only reviewers successfully accepted by GitHub as native review requests gate
completion approval. Non-requestable reviewers are warnings, not blockers.
Keep the original `@` form for `@mention` comments.

If the section is missing, contains only the `_none_` placeholder, or both lists are empty, log a notice and skip the reviewer-related steps (the user has chosen not to assign anyone).

### 2. Initial Setup (only on the very first invocation)

Check whether `dx_complete_state_file` exists. If it does NOT exist, perform setup. If it DOES exist, setup ran in a prior iteration — skip to Step 3.

(Gating on the state file rather than on the cycle counter prevents setup from re-running on every audit iteration during the first wait window — the cycle counter doesn't increment until after the window matures.)

When setup runs:

1. **Mark the PR ready** if it's still a draft:
   ```bash
   PR_NUM=$(gh pr view --json number -q .number)
   PR_DRAFT=$(gh pr view --json isDraft -q .isDraft)
   [[ "$PR_DRAFT" == "true" ]] && gh pr ready "$PR_NUM"
   ```

2. **Re-sync request reviewers** (idempotent):
   ```bash
   source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"
   for h in "${REQUEST_REVIEWERS[@]}"; do
     dx_maintenance_request_reviewer "$PR_NUM" "$h"
   done
   ```

3. **Post mention comment** (single comment listing all `mention` reviewers):
   ```bash
   if [[ ${#MENTION_REVIEWERS[@]} -gt 0 ]]; then
     handles=$(printf '%s ' "${MENTION_REVIEWERS[@]}")
     handles="${handles% }"
     gh pr comment "$PR_NUM" --body "Requesting review from ${handles}."
   fi
   ```

### 3. Launch Monitoring Loop

`/loop <interval> <slash-command>` runs a slash command on a recurring interval in the background. Launch the PR watcher if it is not already running:

```
/loop 5m /dxwatchpr
```

This checks CI status, fixes CI failures when appropriate, addresses review comments via `/dxprreview`, resolves clear review threads after replying, and cancels itself when checks are green and all successfully requested reviews are approved.

If the user sends a direct prompt during Phase 6, the `UserPromptSubmit` hook pauses scheduled watcher cycles for `DEX_WATCH_PAUSE_TTL_SECONDS` (default `60m 0s`). During that pause the watcher skill must skip GitHub/CI commands until the user runs `/dxcomplete` or asks to resume watching.

Each scheduled watcher invocation is also bounded by `DEX_WATCH_CYCLE_TIMEOUT_SECONDS` (default `2m 0s`). If a prior `/dxwatchpr` cycle is still within that budget, the next scheduled tick must skip without running GitHub/CI commands.

### 4. Wait Window

Each cycle waits at least `DEX_COMPLETE_WAIT_MINUTES` minutes (default 5) between outcome checks. You don't sleep — you just stop, and the Stop hook re-injects the audit on the next iteration. The audit checks elapsed time and only authorizes outcome evaluation once the window has elapsed.

### 5. Outcome Evaluation (after wait window)

Check overall PR state:

```bash
gh pr checks "$PR_NUM"
gh api repos/$(gh repo view --json nameWithOwner -q .nameWithOwner)/pulls/$PR_NUM/reviews
REPO=$(gh repo view --json nameWithOwner -q .nameWithOwner)
gh api graphql --paginate \
  -f owner="${REPO%%/*}" \
  -f name="${REPO#*/}" \
  -F number="$PR_NUM" \
  -f query='
query($owner: String!, $name: String!, $number: Int!, $endCursor: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      reviewThreads(first: 100, after: $endCursor) {
        nodes { id isResolved }
        pageInfo { hasNextPage endCursor }
      }
    }
  }
}'
```

- **All CI green AND all successfully requested `request` reviewers approved** → proceed to Step 6 (final verification + close).
- **New commits were pushed** (e.g., `/dxwatchpr` fixed CI or `/dxprreview` addressed comments) → re-request reviewers and re-post the mention comment so reviewers know there's something new. Increment cycle, reset wait window.
- **Cycle was idle** (no new commits, no new approvals, checks/reviews not green) → increment cycle. If `cycle_count >= DEX_COMPLETE_MAX_CYCLES`, pause with the manual follow-up notice; otherwise keep waiting.
- **Hard escalation** (3 same-check CI fails, scope change requested, secrets failure, architectural disagreement) → stop and escalate immediately with cited evidence.

### 6. Final Verification

Once Case A in Step 5 is met:

1. **CI**: All checks green (`gh pr checks $PR_NUM` reports all pass).
2. **Reviews**: All successfully requested `request` reviewers approved, no unresolved comments.
3. **Mention reviewers**: Best-effort — if a `mention` reviewer commented with an actionable concern, it should already have been addressed by `/dxprreview`, with clear review threads resolved after Dex replies. The mention reviewers don't gate completion via review state.
4. **Tasks**: All implementation tasks marked completed.

If any condition is not met, return to Step 5 (do not advance to closure).

### 7. Update Ticket

Mark the ticket as Done via the configured tracker (see `dex.md § Integrations`). Add a final summary — what was implemented, key decisions, follow-up work. Skip if no tracker configured — the PR is the record.

Invoke the `humanizer` skill on the final ticket summary before posting it. Keep commit SHAs, PR links, ticket IDs, reviewer handles, and verification details exact.

### 8. Print Summary

```
Ticket: <id> — <title>       (or "No ticket — <branch name>")
URL:    <ticket-url>          (if available)
PR:     <pr-url>
Status: Ticket complete — PR ready for maintainer merge

Files changed: X
Lines: +Y / -Z
Commits: N (including N_review review-fix commits)
Tests: M new test cases

Reviews:
  - <reviewer>: <status> (N comments addressed)
  ...

CI: All checks green (X/X passed)
Cycles: <cycle_count>
```

### 9. Signal Completion and Local Cleanup

After all verification passes and the summary is printed, stop. The Stop hook authorizes completion via the standard `.complete` mechanism — emit `DEX_TICKET_COMPLETE` only when the hook tells you to. The shell wrapper removes the local Dex worktree and local lifecycle branch after successful completion.

If the 3-cycle watch window expires before checks and approvals are green, print:

```
Autonomous PR monitoring paused after 3 idle 5-minute cycles.
Run /dxwatchpr manually for a one-off CI/review check, or /loop 5m /dxwatchpr to resume watching.
Run /dxcomplete manually when the PR is ready and you want Dex to complete the ticket.
The PR was not merged.
```

Do not emit `DEX_TICKET_COMPLETE` on this timeout path.

## Notes

- Do not merge the PR — that's the user's decision (autonomous merging is intentionally out of scope).
- If follow-up work was identified during implementation, mention it in the summary but do not create new tickets unless asked.
- The ticket should be marked "Done" (if a tracker is available) once CI and reviews are green; the actual merge happens only when a maintainer accepts the PR.
- Hard escalations (secrets, scope conflict, architectural disagreement, 3+ CI failures on the same check) stop the loop and surface a structured escalation to the user — never auto-resolve these.
