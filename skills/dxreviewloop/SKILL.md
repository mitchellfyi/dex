---
name: "dxreviewloop"
description: "Run adaptive full-scope Dex review waves until the resolved clean-pass gate succeeds."
---

# Skill: dxreviewloop

Run `/dxreview --single-pass` in fresh review-wave sessions until the resolved
review profile reaches its consecutive `CLEAN` gate. This is the default Review
phase used by `dx`.

## Workspace Boundary

`/dxreviewloop` is a one-off review command unless it is invoked from an active
`dx` lifecycle. Run it in the current checkout exactly as found.

Do not run `dx <ticket-or-description>`, `dx --no-worktree`, Phase 0 setup, or
any branch/worktree setup from this skill. Do not create, switch, rename, or
delete branches or worktrees. "Fresh review-wave session" means a fresh review
context for the same checkout; it does not mean a fresh git workspace.

## Profiles

The shell wrapper starts with `DEX_REVIEW_PROFILE` or `auto`:

- `light`: 1 clean pass, max 4 iterations, core domain sweep.
- `standard`: 2 clean passes, max 6 iterations, core sweep plus targeted domain
  sweeps.
- `thorough`: 3 clean passes, max 20 iterations, all domain sweeps.

Exact gates still override profiles:

```bash
DEX_REVIEW_CLEAN_PASSES=3 DEX_REVIEW_MAX_ITERATIONS=20 dxreviewloop
```

A wave may write `ESCALATE_THOROUGH:reason` when the current profile is too
shallow. The outer loop resets the clean counter and continues with thorough
defaults unless exact gates were pinned.

## Scope

Review the full current change set when one exists:

- committed branch changes, preferably `git diff origin/<default>...HEAD`
- staged changes via `git diff --cached`
- unstaged changes via `git diff`
- untracked files represented with `git diff --no-index -- /dev/null <file>`

If no changes or comparable branch diff exist, default to reviewing the entire
tracked codebase. Do not stop only because `git diff` is empty; use the
caller-supplied file inventory commands as the authoritative scope.

## Per-Pass Contract

Each iteration is a fresh review-wave CLI session. It must fix verified findings
that are safe to fix in the caller-supplied scope.

A pass that only reports findings is incomplete. If a wave finds verified issues,
the orchestrator fixes them, re-runs the affected checks/review, writes
`FINDINGS_FIXED:N`, resets the clean counter, and immediately continues the loop.
Do not stop after a finding report. Stop only after the clean-pass gate succeeds,
or when a real blocker remains after attempted local resolution.

Every wave runs under a **pass-scoped session id**, never the lifecycle session
id. The wave process inherits this session's loop environment
(`DEX_LOOP_ACTIVE`, `DEX_PHASE_HANDOFF`, `DEX_SESSION_ID`); launched without
overrides, the wave's own Stop hook would act on the lifecycle's shared state —
including running the inline phase handoff that advances the phase and
instructs the wave to commit and push. Override all of it at launch.

When running inside a `dx` lifecycle, mark the pass busy before waiting on the
fresh wave and remove the marker immediately after it returns:

```bash
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh" || exit 1
SESSION_ID="${DEX_SESSION_ID:-$(dx_session_id)}"
[[ -n "$SESSION_ID" ]] || { echo "ERROR: empty session id" >&2; exit 1; }
PASS_SESSION_ID="${SESSION_ID}-pass-${ITERATION}-$$"
BUSY_FILE="$(dx_phase_busy_file "$SESSION_ID" 3)"
printf '%s\t%s\n' "$(date +%s)" "dxreviewloop pass ${ITERATION}/${MAX_ITERATIONS}; clean ${CLEAN_COUNT}/${REQUIRED_CLEAN}" > "$BUSY_FILE"
dx_cleanup_session "$PASS_SESSION_ID"
touch "$(dx_active_file "$PASS_SESSION_ID")"
printf '%s\n' "3:PHASE_3_COMPLETE:${DEX_DIR:-$HOME/work/dex}/prompts/phase-audits/3-review.md:1" > "$(dx_loop_config_file "$PASS_SESSION_ID")"

# Launch and wait for exactly one fresh review-wave CLI session, with the
# lifecycle loop env overridden so the wave is isolated:
#   DEX_SESSION_ID="$PASS_SESSION_ID" \
#   DEX_REVIEW_PASS_ACTIVE=1 \
#   DEX_PHASE_HANDOFF="" \
#   DEX_LOOP_ACTIVE=1 \
#   DEX_LOOP_PHASE=3 \
#   DEX_LOOP_PROMISE=PHASE_3_COMPLETE \
#   claude ... "<review-wave prompt>"

RESULT=$(cat "$(dx_review_result_file "$PASS_SESSION_ID")" 2>/dev/null || echo "UNKNOWN")
if ! dx_review_result_valid "$RESULT" ||
   ! dx_review_context_valid "$(dx_review_context_file "$PASS_SESSION_ID")" ||
   ! dx_review_findings_hash_valid "$(dx_findings_file "$PASS_SESSION_ID")"; then
  dx_cleanup_session "$PASS_SESSION_ID"
  rm -f "$BUSY_FILE" "$(dx_phase_busy_notice_file "$SESSION_ID" 3)"
  echo "Review pass returned incomplete or invalid state" >&2
  exit 1
fi
# Preserve the wave's findings hash for the lifecycle Stop hook's semantic
# stuck-loop detection before the pass-scoped state is removed. Skip CLEAN
# waves: they hash the literal EMPTY inventory, so consecutive clean passes
# (the success gate) would read as recurring identical findings.
if [[ "$RESULT" != "CLEAN" && -f "$(dx_findings_file "$PASS_SESSION_ID")" ]]; then
  cat "$(dx_findings_file "$PASS_SESSION_ID")" >> "$(dx_findings_file "$SESSION_ID")" 2>/dev/null || true
fi
dx_cleanup_session "$PASS_SESSION_ID"
rm -f "$BUSY_FILE" "$(dx_phase_busy_notice_file "$SESSION_ID" 3)"
if [[ "$RESULT" == BLOCKED:* ]]; then
  echo "dxreviewloop blocked: ${RESULT#BLOCKED:}" >&2
  exit 1
fi
```

The review-session prompt must include the full-scope commands, review profile,
context-pack path from `dx_review_context_file "$PASS_SESSION_ID"`, the result
path from `dx_review_result_file "$PASS_SESSION_ID"`, the pass completion path
from `dx_complete_file "$PASS_SESSION_ID"`, and instruction to follow
`prompts/review-wave.md`. Never hand a wave the lifecycle session id or its
completion path: the lifecycle `.complete` file is the Phase 3 handoff signal
and only this orchestrator session may write it, after the clean-pass gate
succeeds. Waves must not commit or push; the Stop hook and guards enforce this
for sessions launched with `DEX_REVIEW_PASS_ACTIVE=1`.

The fresh wave session is already the independent reviewer; profiles determine
how many domain sweeps it performs.

If fresh review-wave CLI sessions are unavailable, stop with
`BLOCKED:review-session-unavailable`; do not simulate fresh passes in the same
context.

## Counting

- `CLEAN`: increment clean count.
- `FINDINGS_FIXED:N`, `FINDINGS:N`: reset clean count and continue.
- `BLOCKED:reason`: stop the outer loop immediately and report the reason.
- `ESCALATE_THOROUGH:reason`: reset clean count and continue as thorough.
- Missing/unknown result: treat as non-clean and stop if unrecoverable.

Only `CLEAN` can increment the counter.

## Report

Print:

```markdown
## dxreviewloop Result

- Scope: full current change set | entire codebase
- Profile: light | standard | thorough
- Iterations: N / max
- Consecutive clean: M / required
- Result: SUCCESS | SAFETY-NET-EXIT | BLOCKED
- Findings fixed this run: K
```

If the loop exits without success, list residual or recurring findings. Do not
commit, push, create or update PRs, or request external reviewers.
