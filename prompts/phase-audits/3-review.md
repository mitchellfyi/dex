Before stopping, complete exactly one full Dex review wave for the current
`/dxreviewloop` iteration.

You are in the **Review phase**. Your job in this iteration is to review the
caller-supplied scope, fix verified findings that are safe to fix, write the
review result signal, and then stop so the outer loop can decide whether the
clean-pass counter advances or resets.

Run in the current checkout. Do not run `dx <ticket-or-description>`, Phase 0
setup, or any branch/worktree setup from this review skill. Do not create,
switch, rename, or delete branches or worktrees.

## Required Workflow

1. Invoke the Skill tool with skill: `dxreview` and `--single-pass`.
2. Follow `prompts/review-wave.md` as the source of truth.
3. Use the full-scope diff/stat/file-name commands supplied by the caller. If any
   other prompt suggests only `origin/<default>...HEAD`, override it with the
   supplied full-scope commands. If the caller supplies an entire-codebase
   inventory because no current change set exists, review that codebase scope
   and do not stop only because `git diff` is empty.
4. Build or refresh the review context pack in global Dex state using
   `dx_review_context_file`. This is the first substantive action: write a
   non-empty skeleton pack, `test -s` it, and read back the first 80 lines before
   broad semantic exploration or domain-specific review.
5. Run deterministic checks first.
6. Harvest candidate issues according to the current review profile:
   - `light`: core domain sweep
   - `standard`: core sweep plus targeted domain sweeps for concrete changed
     surfaces
   - `thorough`: all domain sweeps
7. Run an explicit verifier pass over candidate findings.
8. Batch-fix verified findings in severity order.
9. Re-run deterministic checks and targeted review for changed surfaces.
10. Write the review result signal.

## Result Signal Rules

Write exactly one of these values to `$(dx_review_result_file "$SESSION_ID")`:

- `CLEAN`
- `FINDINGS_FIXED:N`
- `FINDINGS:N`
- `BLOCKED:reason`
- `ESCALATE_THOROUGH:reason`

`CLEAN` is allowed only when this wave found zero verified findings and applied
zero fixes.

If this wave found and fixed any verified finding, write `FINDINGS_FIXED:N`.
That is a successful pass execution, but it intentionally resets the outer clean
counter. Do not keep reviewing inside the same iteration just to turn it into
`CLEAN`.

Do not stop after only reporting verified findings. If verified findings are
safe to fix in scope, fix them, re-run affected checks/review, and write
`FINDINGS_FIXED:N`.

If verified findings remain after a concrete local fix attempt is blocked,
unsafe, or requires user judgment, write `FINDINGS:N`. If required
tooling/context is missing and cannot be resolved locally, write
`BLOCKED:reason`.

If the current review profile is too shallow for the observed risk, write
`ESCALATE_THOROUGH:reason` so the outer loop restarts with thorough review.

If the current session cannot review a required domain with enough confidence,
write `ESCALATE_THOROUGH:reason` for depth gaps or `BLOCKED:reason` for missing
local tooling/context.

Do not infer acceptance criteria from stale session prompt files, previous
conversation turns, session titles, AGENTS instructions, or unrelated ticket
context. If the caller did not explicitly supply criteria for this review
iteration, mark plan-dependent sections `N/A`.

Also write the single findings hash described in `prompts/review-wave.md`. The
outer loop appends validated non-clean hashes to its stuck-loop history.

## Completion Criteria For This Iteration

All of these must be true before you stop:

- The full caller-supplied scope was reviewed.
- The context pack was created or refreshed.
- Deterministic checks were run or explicitly marked unavailable.
- Candidate issues were harvested for the current profile, with non-applicable
  domains marked `N/A`.
- Findings were verified before any fix was applied.
- Verified findings were batch-fixed when safe, then rechecked.
- The review result signal file contains one allowed result value.
- The context pack is non-empty and the findings file contains exactly one
  valid hash.
- No commit, push, branch creation, PR creation/update, or external reviewer
  request happened in this iteration.

When those criteria are met, stop. The outer `/dxreviewloop` owns the three
consecutive `CLEAN` gate.
