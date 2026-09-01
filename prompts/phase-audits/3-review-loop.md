Before stopping, verify that the same-session Review phase completed the full
review loop. Do not stop until every criterion below passes.

This lifecycle advances phases in the same agent session. Phase 3 gets
independent review coverage from `/dxreviewloop`, which spawns fresh full-scope
review-wave sessions. Review runs in the current checkout. It must not run Phase
0 setup, create or switch worktrees, create or rename branches, or call
`dx <ticket-or-task>`.

Apply `prompts/issue-hygiene.md` after the lifecycle owner accepts review
findings. Fresh review children report out-of-scope issue candidates but never
write to the tracker; the owner performs one duplicate search and one external
write. End the phase summary with the contract's exact `Issue/PR work:` line.

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
- The loop reached the selected tier's global consecutive clean gate: 1 for
  `small`, 2 for `normal`, and 3 for `complex`.
  `DEX_REVIEW_CLEAN_PASSES` may raise the launch requirement but cannot lower
  it. Candidate-branch policy edits do not change the active gate. An
  attributed `review.clean-passes` session override may lower the effective
  target while still requiring that many independent `CLEAN` waves. Its
  receipt remains bound to the global policy and override decision, and the
  phase outcome is `waived`. A full `dx control waive review.clean-passes`
  advances without a clean-review receipt.
- Every counted clean result came from a fresh pass-scoped agent session that
  saw the current code and scope but no prior review reports, findings,
  fingerprints, clean-pass counts, telemetry, or stale conversation context.
- Every counted wave wrote `CLEAN` after finding zero verified findings and
  applying zero fixes.
- Every counted wave supplied valid evidence version 3. For every approved
  objective, acceptance criterion, and verification requirement, the manifest
  recorded the exact ordered item hash, a `met` outcome, and substantive
  references to that pass's context pack. Its policy and pass bindings matched
  the wrapper's immutable inputs.
- Before granting clean credit, the wrapper attested the evidence manifest,
  context pack, result, profile, and findings fingerprint together. Each clean
  ledger row contains the unique pass identity, its bindings, and that
  attestation. Private, read-only proof copies remain available so receipt
  validation can revalidate each pass and recompute every attestation.
- Any `FINDINGS_FIXED:N` result reset the clean counter, and review restarted
  against the updated full scope in another fresh session.
- Any escalation raised the tier, reset the clean counter, and restarted review
  at the higher depth. The tier was never downgraded.
- No `FINDINGS:N`, `BLOCKED:reason-code`, `CHURN:reason-code`, missing or
  malformed result, provider failure, repeated-fingerprint churn, or
  alternating-fingerprint churn remains. Each of these pauses rather than
  completing the loop.
- The loop wrote a valid machine-readable review receipt tied to the current
  scope fingerprint, approved criteria, trusted policy, attested clean ledger,
  and any lower-target override. A prose `SUCCESS` claim without that receipt
  does not satisfy Phase 3.
- Review ran again after the most recent in-scope change. After review fixes,
  the loop retained or raised the tier, rebound its selection to the updated
  fingerprint, and reset progress. Any out-of-band scope change invalidated
  selection, progress, and receipts before counting resumed.
- Any criteria or trusted-policy binding change invalidated prior selection,
  progress, clean credit, and receipts before review resumed.
- Phase 3 stays focused on review and fixes. Do not commit, push, or create a PR
  during this phase. Phase 4 commits and publishes accepted review fixes after
  final verification. Re-run `/dxreviewloop` after any code change.
- Accepted review findings were reconciled under
  `prompts/issue-hygiene.md`, and the summary contains `Issue/PR work:`.

The outer review loop has no iteration maximum. It continues until the clean
gate succeeds or a deterministic pause condition occurs.

If the Stop hook reports that an interrupt left a stale review fence whose
owner PID is dead, do not delete the marker or wait for its timeout. Run the
exact standalone `bin/control.sh recover review --source agent --reason ...`
command printed by the hook. Use it only for that dead-owner diagnosis; it
refuses live or malformed state and leaves Phase 3 paused with no clean credit.
Then use `/dxresume` to retry or `/dxskip` only when the user intends to bypass
review.

If completion evidence is missing and no deterministic pause condition is
recorded, run `/dxreviewloop` or resolve the remaining in-scope issue, then stop
again for this audit. If review paused, report the normalized pause reason and
the exact intervention needed; do not rerun the loop or write the Phase 3
completion receipt. The Stop hook supplies the only valid generation-bound
completion command once the audit threshold is reached. Run that literal
command only when the clean-pass gate and every Phase 3 requirement are met,
then stop again so Dex can commit the transition.
