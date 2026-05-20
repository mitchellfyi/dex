---
name: "dkreview"
description: "Run one full-scope Doyaken review wave with adaptive depth, verifier triage, and batch fixes."
---

# Skill: dkreview

Run one full-scope review wave. Direct `/dkreview` invocations still dispatch to
`/dkreviewloop`; single-pass mode is for `/dkreviewloop` and Phase 3.

## Dispatch

If invoked without `--single-pass` or `--no-loop`, invoke skill `dkreviewloop`
and stop.

Run the single-pass workflow only when the invocation includes `--single-pass`,
`--no-loop`, or explicitly says it is running from `/dkreviewloop`. If unsure,
prefer the loop.

## Single-Pass Workflow

Follow `prompts/review-wave.md` as the source of truth. In one wave:

1. Review the full current change set from caller-supplied diff/stat/name
   commands, or discover committed, staged, unstaged, and untracked changes.
2. Build the compact context pack first in `dk_review_context_file`.
3. Run deterministic checks before semantic review.
4. Harvest candidate issues according to the supplied profile:
   - `light`: orchestrator harvest; run `review-verifier` only if candidates or
     escalation risk exist
   - `standard`: orchestrator harvest, targeted specialists for concrete changed
     domains, plus `review-verifier`
   - `thorough`: full specialist roster plus `review-verifier`
5. Verify, deduplicate, and rank candidate findings before fixing.
6. Batch-fix all verified findings, then re-run affected checks and targeted
   review once.
7. Write the review result signal and findings hash.

Collect all candidate issues before fixing anything. Do not add a separate
general reviewer just to harvest issues; the fresh review-wave loop already owns
that pass. The point is one aggressive inventory followed by one batch fix.

If no plan or ticket criteria are supplied by the current caller, mark
criteria-dependent evidence as `N/A`. Do not infer acceptance criteria from stale
session prompt files, previous turns, session titles, AGENTS instructions, or
unrelated tickets.

## Result Signal

When `DOYAKEN_SESSION_ID` is available, write exactly one result:

```bash
source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"
SESSION_ID="${DOYAKEN_SESSION_ID:-$(dk_session_id)}"
echo "<result>" > "$(dk_review_result_file "$SESSION_ID")"
```

Allowed results:

- `CLEAN`
- `FINDINGS_FIXED:N`
- `FINDINGS:N`
- `BLOCKED:reason`
- `ESCALATE_THOROUGH:reason`

Only `CLEAN` means the wave found zero verified findings and applied zero fixes.
Any fix writes `FINDINGS_FIXED:N`. If the current profile is too shallow for the
observed risk, write `ESCALATE_THOROUGH:reason`.

Also append the findings hash described in `prompts/review-wave.md`.

## Final Report

End with the `Review Wave Result` block from `prompts/review-wave.md`. Do not
commit, push, create PRs, update PRs, or request external reviewers.
