Phase 6 (Complete) is the bounded autonomous PR monitoring loop. Phase 5 should
have left the PR ready for review; verify that state and repair it if an
interrupted or pre-existing draft remains. Then request reviews, monitor CI and
review comments through the PR watcher, address failures, and close the ticket
once everyone has approved and CI is green. Do not merge the PR.

This phase runs as a **cycle loop**. Each cycle is one Stop hook iteration. Between cycles you wait — the loop infrastructure handles wall-clock time, not you.

Before posting PR comments, ticket updates, or free-form status summaries, invoke
the `humanizer` skill. Preserve reviewer handles, PR numbers, ticket IDs,
commands, counts, status labels, and required audit wording exactly.

Apply `prompts/issue-hygiene.md` whenever CI, review comments, or completion
work reveals material new context. Reconcile accepted findings once through
the lifecycle owner; do not let scheduled watcher cycles create duplicate
issues. Every cycle summary, including idle and terminal cycles, ends with the
contract's exact `Issue/PR work:` line.

---

## Setup (only on the very first invocation)

Detect the cycle counter and whether setup has already run:

```bash
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh" || exit 1
SESSION_ID="${DEX_SESSION_ID:-$(dx_session_id)}"
COMPLETE_STATE_FILE="$(dx_complete_state_file "$SESSION_ID")"
CYCLE=0
LAST_EPOCH=0
SETUP_DONE=0
if [[ -f "$COMPLETE_STATE_FILE" ]]; then
  SETUP_DONE=1   # state file exists → setup ran in a prior iteration
  RAW=$(cat "$COMPLETE_STATE_FILE" 2>/dev/null || echo "")
  if [[ "$RAW" =~ ^([0-9]+):([0-9]+)$ ]]; then
    CYCLE="${BASH_REMATCH[1]}"
    LAST_EPOCH="${BASH_REMATCH[2]}"
  fi
fi
```

If `SETUP_DONE -eq 0` (state file did not exist — this is the very first invocation), perform the setup steps below. Otherwise skip directly to Monitoring.

The state file is the canonical "setup has run" marker. Do NOT use `CYCLE -eq 0` as the gate — `CYCLE` stays at `0` for the entire first wait window (it only increments when Outcome runs after the window matures), so gating on `CYCLE` would re-run setup on every audit iteration during that window and post duplicate `@mention` comments.

### Verify the PR is ready for review

```bash
PR_NUM=$(gh pr view --json number -q .number)
PR_DRAFT=$(gh pr view --json isDraft -q .isDraft)
if [[ "$PR_DRAFT" == "true" ]]; then
  gh pr ready "$PR_NUM"
fi
```

### Read the reviewer config

Read the `## Reviewers` section from `.dex/dex.md`. Parse rows where the second column is `request` or `mention`. Ignore the placeholder `_none_` row. If the table is empty, skip directly to Monitoring (the user has chosen not to assign anyone).

### Request reviewers (`request` type)

For each `request`-type reviewer, normalize the handle with
`dx_maintenance_request_reviewer "$PR_NUM" "<handle>"`. This strips the leading
`@` for normal usernames, but preserves GitHub CLI's special `@copilot` value
for Copilot review requests. This is idempotent when GitHub accepts the reviewer.
If GitHub says a reviewer is not requestable for this repository, log the warning
and continue. Do not pipe review-request command output into `jq`.
Only reviewers successfully accepted by GitHub as native review requests gate
completion approval. Non-requestable reviewers are warnings, not blockers.

### Post mention comment (`mention` type)

If there are any `mention`-type reviewers, post a single comment on the PR mentioning all of them:

```bash
gh pr comment "$PR_NUM" --body "Requesting review from @bot1 @bot2."
```

Run the body through `humanizer` before posting if you customize it. The point is the `@mention` so the bots see it.

---

## Monitoring (every cycle)

Launch the PR watcher loop if it isn't already running. `/loop` is a built-in Claude Code skill — `/loop <interval> <slash-command>` runs the command on a recurring interval in the background.

```
/loop 5m /dxwatchpr
```

This runs between turns and won't consume context. `/dxwatchpr` checks CI status, fixes CI failures when appropriate, reads review comments, hands them to `/dxprreview`, pushes fixes, replies inline, and resolves review threads when Dex's reply closes the comment.

If the user sends a direct prompt while Phase 6 is active, the `UserPromptSubmit` hook writes a watcher-pause marker. Scheduled `/dxwatchpr` invocations must no-op while that marker is active and must not run GitHub/CI commands. Running `/dxcomplete` or explicitly asking to resume watchers clears the marker. The default pause TTL is `60m 0s`.

Each watcher invocation reads `dx_watch_cycle_timeout_seconds` (default `2m 0s`). If the previous watcher cycle is still locked within that current runtime budget, the next `/loop` tick must no-op instead of overlapping.

---

## Wait window

Each cycle reads its minimum wait from `dx_complete_wait_minutes` (default 5) before declaring the cycle idle and moving on. You don't sleep — you simply stop and let the Stop hook's audit loop re-engage you on the next iteration. Compute elapsed time:

```bash
NOW=$(date +%s)
ELAPSED=$((NOW - LAST_EPOCH))
WAIT_MINUTES=$(dx_complete_wait_minutes "${DEX_SESSION_ID:-$(dx_session_id)}")
WAIT_SECONDS=$((WAIT_MINUTES * 60))
```

If `LAST_EPOCH -eq 0` (very first cycle — setup just ran):
- Set `LAST_EPOCH=$NOW`.
- Write `0:${LAST_EPOCH}` to the state file: `echo "0:${LAST_EPOCH}" > "$COMPLETE_STATE_FILE"`.
- Stop. The wait window starts now; the next iteration will evaluate Outcome only after `WAIT_SECONDS` have elapsed.
- Do NOT proceed to Outcome — there's nothing to evaluate yet.

If `ELAPSED -lt WAIT_SECONDS`, the wait window hasn't elapsed:
- Confirm the watcher loop is still running (one `gh pr view --json` is fine; do NOT run `/dxprreview` directly here — that's the watcher's job).
- Update the state file: `echo "${CYCLE}:${LAST_EPOCH}" > "$COMPLETE_STATE_FILE"`
- Stop. The Stop hook will re-inject this audit on the next iteration; that iteration also will not be authorized to complete until the window has elapsed.

If `ELAPSED -ge WAIT_SECONDS`, the cycle has matured — proceed to Outcome.

---

## Outcome (after wait window matures)

Check overall PR state:

```bash
gh pr checks "$PR_NUM"  # CI status
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

### Case A — All CI green and all successfully requested `request`-type reviewers have approved

Note: `mention`-type reviewers (AI bots) do not issue native GitHub reviews and DO NOT gate completion via review state. Their substantive comments should already be addressed via `/dxprreview` during the cycle, with clear review threads resolved after Dex replies. Only successfully requested `request`-type reviewers' approval status matters for Case A.

Update the ticket (if a tracker is configured — see `dex.md § Integrations`). Print the completion summary (per `skills/dxcomplete/SKILL.md`, the Print Summary step). Cycle is done — proceed to Termination.

### Case B — Pending checks/reviews or unresolved comments, but progress was made

If new commits were pushed during the cycle (`/dxwatchpr` fixed CI or `/dxprreview` addressed comments), re-trigger reviewers:

- For each `request` reviewer: run `dx_maintenance_request_reviewer "$PR_NUM" "<handle>"` again — they get a fresh notification when GitHub accepts the reviewer.
- For each `mention` reviewer: post a new comment such as `Updated: @<handle>, please re-review.` after applying `humanizer`.

Increment the cycle counter (use arithmetic, not parameter expansion — `NEW_CYCLE=$((CYCLE + 1))`), reset `LAST_EPOCH` to now, write `"${NEW_CYCLE}:${NOW}"` to the state file. Stop. Next iteration starts a new wait window.

### Case C — No CI/review progress

The cycle was idle. Re-read `MAX_CYCLES=$(dx_complete_max_cycles "${DEX_SESSION_ID:-$(dx_session_id)}")`, then increment the cycle counter (`NEW_CYCLE=$((CYCLE + 1))`). If `NEW_CYCLE >= MAX_CYCLES` → proceed to Case D bounded-timeout pause. Otherwise, write `"${NEW_CYCLE}:${NOW}"` to the state file and stop. Next iteration starts a new wait window.

### Case D — Bounded-timeout pause or material escalation

Re-read `CI_FIX_ATTEMPTS=$(dx_complete_ci_fix_attempts "${DEX_SESSION_ID:-$(dx_session_id)}")`.
Stop and escalate to the user immediately if:
- The watcher has completed the current `MAX_CYCLES` idle-cycle budget without checks and approvals going green
- CI has failed the same check `CI_FIX_ATTEMPTS` times in a row (`/dxwatchpr` should already escalate)
- A reviewer requested a scope change that affects other tickets
- A secrets scan failed
- Architectural disagreement that needs human judgement

For the bounded-timeout pause, print a notice using the current `MAX_CYCLES`
and `WAIT_MINUTES`, then stop without writing a completion receipt:

```
Autonomous PR monitoring paused after <MAX_CYCLES> idle <WAIT_MINUTES>-minute cycles.
Run /dxwatchpr manually for a one-off CI/review check, or /loop 5m /dxwatchpr to resume watching.
Run /dxcomplete manually when the PR is ready and you want Dex to complete the ticket.
The PR was not merged.
```

Then run the exact generation-bound escalation command printed with the current
launch or audit. It pauses and detaches this run, revokes completion
authorization, and creates no completion receipt. Do not touch a pause marker,
write a control file, or discover a generation yourself.

For hard escalations, print the reason with cited `file:line` evidence, run that
same exact escalation command, and stop without writing a completion receipt.

---

## Termination

Cycle ends successfully only when **Case A** is reached: CI green and all successfully requested reviewers approved. Completion means the ticket is closed and the local Dex worktree/branch can be removed; it never means merging the PR.

Cycle pauses with escalation when:
- `CYCLE >= MAX_CYCLES` and checks/approvals are not green
- Hard escalation (see Case D)

Only Case A may run the exact generation-bound completion command supplied by
the Stop hook. Timeout and hard escalation paths must use the exact escalation
command instead. The user can run `/dxwatchpr` manually for another one-off pass
or `/dxcomplete` to resume completion.

---

## Completion criteria (must all be true before writing the exact receipt)

- The PR is no longer a draft (`gh pr view --json isDraft -q .isDraft` returns `false`)
- All `request` reviewers have been requested at least once
- One mention comment has been posted for `mention` reviewers (if any)
- All CI checks green AND all successfully requested `request`-type reviewers approved AND ticket marked Done (if tracker configured). `mention`-type reviewers and non-requestable reviewers do NOT gate completion.
- Material CI and review findings were handled under
  `prompts/issue-hygiene.md`, and the terminal summary contains `Issue/PR work:`.

Do NOT emit `DEX_TICKET_COMPLETE` until the Stop hook authorizes completion via the audit-iteration threshold. Follow the standard pattern.
