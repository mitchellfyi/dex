---
name: "dkreviewloop"
description: "Run adaptive full-scope Doyaken review waves until the resolved clean-pass gate succeeds."
---

# Skill: dkreviewloop

Run `/dkreview --single-pass` in fresh review-wave sessions until the resolved
review profile reaches its consecutive `CLEAN` gate. This is the default Review
phase used by `dk`.

## Profiles

The shell wrapper starts with `DOYAKEN_REVIEW_PROFILE` or `auto`:

- `light`: 1 clean pass, max 4 iterations, orchestrator harvest.
- `standard`: 2 clean passes, max 6 iterations, orchestrator harvest plus
  targeted specialists.
- `thorough`: 3 clean passes, max 10 iterations, full specialist roster.

Exact gates still override profiles:

```bash
DOYAKEN_REVIEW_CLEAN_PASSES=3 DOYAKEN_REVIEW_MAX_ITERATIONS=20 dkreviewloop
```

A wave may write `ESCALATE_THOROUGH:reason` when the current profile is too
shallow. The outer loop resets the clean counter and continues with thorough
defaults unless exact gates were pinned.

## Scope

Review the full current change set:

- committed branch changes, preferably `git diff origin/<default>...HEAD`
- staged changes via `git diff --cached`
- unstaged changes via `git diff`
- untracked files represented with `git diff --no-index -- /dev/null <file>`

If no changes exist, stop and tell the user there is nothing to review.

## Per-Pass Contract

Each iteration is a fresh review-wave orchestrator. It may fix verified findings;
specialist/verifier agents it invokes are read-only.

When running inside a `dk` lifecycle, mark the pass busy before waiting on the
fresh wave and remove the marker immediately after it returns:

```bash
source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"
SESSION_ID="${DOYAKEN_SESSION_ID:-$(dk_session_id)}"
BUSY_FILE="$(dk_phase_busy_file "$SESSION_ID" 3)"
printf '%s\t%s\n' "$(date +%s)" "dkreviewloop pass ${ITERATION}/${MAX_ITERATIONS}; clean ${CLEAN_COUNT}/${REQUIRED_CLEAN}" > "$BUSY_FILE"
# spawn and wait for exactly one fresh review-wave session
rm -f "$BUSY_FILE" "$(dk_phase_busy_notice_file "$SESSION_ID" 3)"
```

The subagent/session prompt must include the full-scope commands, review profile,
context-pack path from `dk_review_context_file`, result path, and instruction to
follow `prompts/review-wave.md`.

Do not add a second general reviewer for light/standard mode. The fresh wave
orchestrator is already the independent reviewer; specialists are reserved for
targeted or thorough coverage.

If fresh review-wave sessions are unavailable, stop with
`BLOCKED:agent-tool-unavailable`; do not simulate fresh passes in the same
context.

## Counting

- `CLEAN`: increment clean count.
- `FINDINGS_FIXED:N`, `FINDINGS:N`, `BLOCKED:reason`: reset clean count.
- `ESCALATE_THOROUGH:reason`: reset clean count and continue as thorough.
- Missing/unknown result: treat as non-clean and stop if unrecoverable.

Only `CLEAN` can increment the counter.

## Report

Print:

```markdown
## dkreviewloop Result

- Scope: full current change set
- Profile: light | standard | thorough
- Iterations: N / max
- Consecutive clean: M / required
- Result: SUCCESS | SAFETY-NET-EXIT | BLOCKED
- Findings fixed this run: K
```

If the loop exits without success, list residual or recurring findings. Do not
commit, push, create or update PRs, or request external reviewers.
