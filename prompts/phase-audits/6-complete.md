Phase 6 (Complete) is the autonomous CI/review monitoring loop. The PR was created in Phase 5; your job is to mark it ready, request reviews, monitor for comments, address them, and close the ticket once everyone has approved and CI is green.

This phase runs as a **cycle loop**. Each cycle is one Stop hook iteration. Between cycles you wait — the loop infrastructure handles wall-clock time, not you.

---

## Setup (only on the very first invocation)

Detect the cycle counter and whether setup has already run:

```bash
source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"
SESSION_ID="${DOYAKEN_SESSION_ID:-$(dk_session_id)}"
COMPLETE_STATE_FILE="$(dk_complete_state_file "$SESSION_ID")"
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

### Mark the PR ready for review

```bash
PR_NUM=$(gh pr view --json number -q .number)
PR_DRAFT=$(gh pr view --json isDraft -q .isDraft)
if [[ "$PR_DRAFT" == "true" ]]; then
  gh pr ready "$PR_NUM"
fi
```

### Read the reviewer config

Read the `## Reviewers` section from `.doyaken/doyaken.md`. Parse rows where the second column is `request` or `mention`. Ignore the placeholder `_none_` row. If the table is empty, skip directly to Monitoring (the user has chosen not to assign anyone).

### Request reviewers (`request` type)

For each `request`-type reviewer, call `gh pr edit "$PR_NUM" --add-reviewer "<handle>"` (strip the leading `@` if present — `gh` doesn't want it). This is idempotent — GitHub no-ops if already requested.

### Post mention comment (`mention` type)

If there are any `mention`-type reviewers, post a single comment on the PR mentioning all of them:

```bash
gh pr comment "$PR_NUM" --body "Requesting review from @bot1 @bot2 — please take a look."
```

Customize the body to whatever fits. The point is the `@mention` so the bots see it.

---

## Monitoring (every cycle)

Launch the watcher loops if they aren't already running. `/loop` is a built-in Claude Code skill — `/loop <interval> <slash-command>` runs the command on a recurring interval in the background.

```
/loop 2m /dkwatchci
/loop 5m /dkwatchpr
```

These run between turns and won't consume context. `/dkwatchci` will fix CI failures and re-push. `/dkwatchpr` will read review comments, hand them to `/dkprreview`, push fixes, and reply.

If the user sends a direct prompt while Phase 6 is active, the `UserPromptSubmit` hook writes a watcher-pause marker. Scheduled `/dkwatchci` and `/dkwatchpr` invocations must no-op while that marker is active and must not run GitHub/CI commands. Running `/dkcomplete` or explicitly asking to resume watchers clears the marker. The default pause TTL is `60m 0s`.

---

## Wait window

Each cycle must wait at least `DOYAKEN_COMPLETE_WAIT_MINUTES` minutes (default 30) before declaring the cycle "stuck" and moving on. You don't sleep — you simply stop and let the Stop hook's audit loop re-engage you on the next iteration. Compute elapsed time:

```bash
NOW=$(date +%s)
ELAPSED=$((NOW - LAST_EPOCH))
WAIT_MINUTES="${DOYAKEN_COMPLETE_WAIT_MINUTES:-30}"
WAIT_SECONDS=$((WAIT_MINUTES * 60))
```

If `LAST_EPOCH -eq 0` (very first cycle — setup just ran):
- Set `LAST_EPOCH=$NOW`.
- Write `0:${LAST_EPOCH}` to the state file: `echo "0:${LAST_EPOCH}" > "$COMPLETE_STATE_FILE"`.
- Stop. The wait window starts now; the next iteration will evaluate Outcome only after `WAIT_SECONDS` have elapsed.
- Do NOT proceed to Outcome — there's nothing to evaluate yet.

If `ELAPSED -lt WAIT_SECONDS`, the wait window hasn't elapsed:
- Confirm the watcher loops are still running (one `gh pr view --json` is fine; do NOT run `/dkprreview` directly here — that's the watcher's job).
- Update the state file: `echo "${CYCLE}:${LAST_EPOCH}" > "$COMPLETE_STATE_FILE"`
- Stop. The Stop hook will re-inject this audit on the next iteration; that iteration also will not be authorized to complete until the window has elapsed.

If `ELAPSED -ge WAIT_SECONDS`, the cycle has matured — proceed to Outcome.

---

## Outcome (after wait window matures)

Check overall PR state:

```bash
gh pr checks "$PR_NUM"  # CI status
gh api repos/$(gh repo view --json nameWithOwner -q .nameWithOwner)/pulls/$PR_NUM/reviews
```

### Case A — All CI green and all `request`-type reviewers have approved

Note: `mention`-type reviewers (AI bots) do not issue native GitHub reviews and DO NOT gate completion via review state. Their substantive comments should already be addressed via `/dkprreview` during the cycle. Only `request`-type reviewers' approval status matters for Case A.

Update the ticket (if a tracker is configured — see `doyaken.md § Integrations`). Print the completion summary (per `skills/dkcomplete/SKILL.md` Step 5). Cycle is done — proceed to Termination.

### Case B — Pending reviews or unresolved comments, but progress was made

If new commits were pushed during the cycle (`/dkprreview` addressed comments), re-trigger reviewers:

- For each `request` reviewer: `gh pr edit "$PR_NUM" --add-reviewer "<handle>"` again — they get a fresh notification that there's something new.
- For each `mention` reviewer: post a new comment `@<handle> updated — please re-review.`

Increment the cycle counter (use arithmetic, not parameter expansion — `NEW_CYCLE=$((CYCLE + 1))`), reset `LAST_EPOCH` to now, write `"${NEW_CYCLE}:${NOW}"` to the state file. Stop. Next iteration starts a new wait window.

### Case C — No comments, no new commits, no approvals

The cycle was idle. Increment the cycle counter (`NEW_CYCLE=$((CYCLE + 1))`). If `NEW_CYCLE >= DOYAKEN_COMPLETE_MAX_CYCLES` → proceed to Case D escalation. Otherwise, write `"${NEW_CYCLE}:${NOW}"` to the state file and stop. Next iteration starts a new wait window.

### Case D — Hard escalation

Stop and escalate to the user immediately if:
- CI has failed the same check 3 times in a row (`/dkwatchci` should already escalate)
- A reviewer requested a scope change that affects other tickets
- A secrets scan failed
- Architectural disagreement that needs human judgement

Print the escalation reason with cited file:line evidence and stop without writing the completion signal.

---

## Termination

Cycle ends successfully when **Case A** is reached: CI green and all configured reviewers approved.

Cycle ends with escalation when:
- `CYCLE >= DOYAKEN_COMPLETE_MAX_CYCLES` (default 3) and no approvals yet
- Hard escalation (see Case D)

In either ending, stop. The Stop hook authorizes completion through the standard `.complete` mechanism after the audit pass — only emit the completion promise when Case A is met OR escalation conditions render the autonomous loop unable to make further progress.

---

## Completion criteria (must all be true to write `.complete`)

- The PR is no longer a draft (`gh pr view --json isDraft -q .isDraft` returns `false`)
- All `request` reviewers have been requested at least once
- One mention comment has been posted for `mention` reviewers (if any)
- Either: all CI checks green AND all `request`-type reviewers approved AND ticket marked Done (if tracker configured) — OR: a documented escalation has been printed and acknowledged. `mention`-type reviewers do NOT gate completion.

Do NOT emit `DOYAKEN_TICKET_COMPLETE` until the Stop hook authorizes completion via the audit-iteration threshold. Follow the standard pattern.
