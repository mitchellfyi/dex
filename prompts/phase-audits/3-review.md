Before stopping, complete exactly one full Doyaken review wave for the current
`/dkreviewloop` iteration.

You are in the **Review phase**. Your job in this iteration is to review the
full current change set, fix verified findings when possible, write the review
result signal, and then stop so the outer loop can decide whether the clean-pass
counter advances or resets.

## Required Workflow

1. Invoke the Skill tool with skill: `dkreview` and `--single-pass`.
2. Follow `prompts/review-wave.md` as the source of truth.
3. Use the full-scope diff/stat/file-name commands supplied by the caller. If any
   other prompt suggests only `origin/<default>...HEAD`, override it with the
   supplied full-scope commands.
4. Build or refresh the review context pack in global Doyaken state using
   `dk_review_context_file`. This is the first substantive action: write a
   non-empty skeleton pack, `test -s` it, and read back the first 80 lines before
   broad semantic exploration or specialist spawning.
5. Run deterministic checks first.
6. Harvest candidate issues according to the current review profile:
   - `light`: orchestrator harvest; verifier only if candidates/escalation risk
   - `standard`: orchestrator harvest plus targeted specialists for concrete
     changed domains
   - `thorough`: full specialist roster
7. Run `review-verifier` with the Agent tool.
8. Batch-fix verified findings in severity order.
9. Re-run deterministic checks and targeted review for changed surfaces.
10. Write the review result signal.

## Result Signal Rules

Write exactly one of these values to `$(dk_review_result_file "$SESSION_ID")`:

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

If verified findings remain, write `FINDINGS:N`. If required tooling/context is
missing and cannot be resolved locally, write `BLOCKED:reason`.

If the current review profile is too shallow for the observed risk, write
`ESCALATE_THOROUGH:reason` so the outer loop restarts with thorough review.

If the Agent tool is unavailable for specialist review or verifier triage, write
`BLOCKED:agent-tool-unavailable`; do not simulate the specialist wave inside the
orchestrator context.

Do not infer acceptance criteria from stale session prompt files, previous
conversation turns, session titles, AGENTS instructions, or unrelated ticket
context. If the caller did not explicitly supply criteria for this review
iteration, mark plan-dependent sections `N/A`.

Also append the findings hash described in `prompts/review-wave.md` for stuck
loop detection.

## Completion Criteria For This Iteration

All of these must be true before you stop:

- The full current change set was reviewed.
- The context pack was created or refreshed.
- Deterministic checks were run or explicitly marked unavailable.
- Candidate issues were harvested for the current profile, with non-applicable
  specialist domains marked `N/A`.
- Findings were verified before any fix was applied.
- Verified findings were batch-fixed when safe, then rechecked.
- The review result signal file contains one allowed result value.
- No commit, push, branch creation, PR creation/update, or external reviewer
  request happened in this iteration.

When those criteria are met, stop. The outer `/dkreviewloop` owns the three
consecutive `CLEAN` gate.
