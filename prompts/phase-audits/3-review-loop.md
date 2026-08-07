Before stopping, verify the same-session Review phase completed the full review
loop. Do NOT stop until every step below passes.

This lifecycle advances phases in the same Claude session. Phase 3 gets
independent review coverage by running `/dxreviewloop`, which spawns fresh
full-scope review waves and requires the resolved profile's clean-pass gate.
Fresh review waves run in the current checkout. They must not run Phase 0 setup,
create worktrees, switch branches, rename branches, or call `dx <ticket-or-task>`.

## Completion Criteria

All of these must be true before you stop:

- `/dxreviewloop` ran on the full caller-supplied scope: the current change set,
  or the entire tracked codebase when no change set exists.
- The `/dxreviewloop` result is `SUCCESS`.
- The final result shows the required consecutive clean reports for its resolved
  profile or explicit environment override.
- Each clean report came from a full review wave that found zero verified
  findings and applied zero fixes. Waves that wrote `FINDINGS_FIXED:N`,
  `FINDINGS:N`, or `ESCALATE_THOROUGH:reason` reset the counter and do not count
  as clean. `BLOCKED:reason` stops the loop immediately.
- Any findings discovered by the loop were fixed.
- The review was re-run after the most recent code change.
- The loop did not stop after a pass that merely found or reported issues; those
  issues were fixed when safe, then the loop continued until the clean-pass gate
  succeeded or a true blocker remained.
- No new commits, pushes, PR creation, or PR updates are performed from this audit point forward. If one already happened earlier in Phase 3, report it as an ordering warning and continue only after `/dxreviewloop` reaches `SUCCESS`; do not deadlock on an irreversible past action.

If any criterion is not met, run `/dxreviewloop` or fix the remaining findings
now, then stop again for this audit.
