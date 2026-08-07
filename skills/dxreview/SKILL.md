---
name: "dxreview"
description: "Run one full-scope Dex review wave with adaptive depth, verifier pass, and batch fixes."
---

# Skill: dxreview

Run one full-scope review wave. Direct `/dxreview` invocations still dispatch to
`/dxreviewloop`; single-pass mode is for `/dxreviewloop` and Phase 3.

## Dispatch

If invoked without `--single-pass` or `--no-loop`, invoke skill `dxreviewloop`
and stop.

Run the single-pass workflow only when the invocation includes `--single-pass`,
`--no-loop`, or explicitly says it is running from `/dxreviewloop`. If unsure,
prefer the loop.

## Single-Pass Workflow

Follow `prompts/review-wave.md` as the source of truth. In one wave:

1. Review the caller-supplied scope. Usually this is the full current change set
   from diff/stat/name commands; when no change set exists, `/dxreviewloop`
   supplies a whole-codebase file inventory instead.
2. Build the compact context pack first in `dx_review_context_file`.
3. Run deterministic checks before semantic review.
4. Create lightweight repro probes for suspected correctness, contract, or
   regression findings when the repo has runnable tests or scripts.
5. Harvest candidate issues according to the supplied profile:
   - `light`: core domain sweep
   - `standard`: core sweep plus targeted domain sweeps for concrete changed
     surfaces
   - `thorough`: all domain sweeps across the full caller-supplied scope
6. Verify, deduplicate, and rank candidate findings before fixing.
7. Batch-fix all verified findings, then re-run affected checks and targeted
   review once.
8. Write the review result signal and findings hash.

Run in the current checkout. Do not run `dx <ticket-or-description>`, Phase 0
setup, or any branch/worktree setup from this skill. Do not create, switch,
rename, or delete branches or worktrees.

Collect all candidate issues before fixing anything. The fresh review-wave CLI
session already owns the independent review pass. The point is one aggressive
inventory followed by one batch fix.

Do not stop after only reporting verified findings. If verified findings are
safe to fix in scope, fix them, re-run affected checks/review, and write
`FINDINGS_FIXED:N`. Write `FINDINGS:N` only for residual verified findings that
remain after a concrete local fix attempt is blocked, unsafe, or requires user
judgment.

If no plan or ticket criteria are supplied by the current caller, mark
criteria-dependent evidence as `N/A`. Do not infer acceptance criteria from stale
session prompt files, previous turns, session titles, AGENTS instructions, or
unrelated tickets.

## Result Signal

When `DEX_SESSION_ID` is available, write exactly one result:

```bash
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh" || exit 1
SESSION_ID="${DEX_SESSION_ID:-$(dx_session_id)}"
[[ -n "$SESSION_ID" ]] || { echo "ERROR: empty session id — refusing to write unkeyed state" >&2; exit 1; }
echo "<result>" > "$(dx_review_result_file "$SESSION_ID")"
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
