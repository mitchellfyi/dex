Before stopping, verify that the same-session Review phase completed the full
review loop. Do not stop until every criterion below passes.

This lifecycle advances phases in the same agent session. Phase 3 gets
independent review coverage from `/dxreviewloop`, which spawns fresh full-scope
review-wave sessions. Review runs in the current checkout. It must not run Phase
0 setup, create or switch worktrees, create or rename branches, or call
`dx <ticket-or-task>`.

## Completion Criteria

All of these must be true:

- In the normal flow, Phase 2 recorded a valid risk selection for the current
  scope before Phase 3 began. For a legacy or resumed lifecycle whose selection
  was missing or stale, a fresh read-only lifecycle assessor recorded a valid
  current-scope recovery selection before the first wave. The selected tier is
  `small`, `normal`, or `complex`, with a deterministic set of reason codes.
- `/dxreviewloop` reviewed the full caller-supplied scope: the current change
  set, or the entire tracked codebase when no change set exists.
- The `/dxreviewloop` result is `SUCCESS`.
- The loop reached the selected consecutive clean gate: 3 for `small`, 6 for
  `normal`, or 9 for `complex`. An explicit `DEX_REVIEW_CLEAN_PASSES` override
  may raise that count but cannot lower the tier's canonical floor.
- Every counted clean result came from a fresh pass-scoped agent session that
  saw the current code and scope but no prior review reports, findings,
  fingerprints, clean-pass counts, telemetry, or stale conversation context.
- Every counted wave wrote `CLEAN` after finding zero verified findings and
  applying zero fixes.
- Any `FINDINGS_FIXED:N` result reset the clean counter, and review restarted
  against the updated full scope in another fresh session.
- Any escalation raised the tier, reset the clean counter, and restarted review
  at the higher depth. The tier was never downgraded.
- No `FINDINGS:N`, `BLOCKED:reason-code`, `CHURN:reason-code`, missing or
  malformed result, provider failure, repeated-fingerprint churn, or
  alternating-fingerprint churn remains. Each of these pauses rather than
  completing the loop.
- The loop wrote a valid machine-readable review receipt tied to the current
  scope fingerprint. A prose `SUCCESS` claim without that receipt does not
  satisfy Phase 3.
- Review ran again after the most recent in-scope change. After review fixes,
  the loop retained or raised the tier, rebound its selection to the updated
  fingerprint, and reset progress. Any out-of-band scope change invalidated
  selection, progress, and receipts before counting resumed.
- Phase 3 stays focused on review by default. If a commit, push, or PR action
  occurs during the phase, record the resulting state. Re-run `/dxreviewloop`
  after any code change; publishing does not replace the clean-pass requirement.

The outer review loop has no iteration maximum. It continues until the clean
gate succeeds or a deterministic pause condition occurs.

If completion evidence is missing and no deterministic pause condition is
recorded, run `/dxreviewloop` or resolve the remaining in-scope issue, then stop
again for this audit. If review paused, report the normalized pause reason and
the exact intervention needed; do not rerun the loop or write the Phase 3
completion signal.
