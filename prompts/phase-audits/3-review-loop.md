Before stopping, verify the same-session Review phase completed the full review
loop. Do NOT stop until every step below passes.

This lifecycle advances phases in the same Claude session. Phase 3 gets
independent review coverage by running `/dkreviewloop`, which spawns fresh
full-scope review waves and requires the resolved profile's clean-pass gate.

## Completion Criteria

All of these must be true before you stop:

- `/dkreviewloop` ran on the full current change set.
- The `/dkreviewloop` result is `SUCCESS`.
- The final result shows the required consecutive clean reports for its resolved
  profile or explicit environment override.
- Each clean report came from a full review wave that found zero verified
  findings and applied zero fixes. Waves that wrote `FINDINGS_FIXED:N`,
  `FINDINGS:N`, `BLOCKED:reason`, or `ESCALATE_THOROUGH:reason` reset the
  counter and do not count as clean.
- Any findings discovered by the loop were fixed.
- The review was re-run after the most recent code change.
- No new commits, pushes, PR creation, or PR updates are performed from this audit point forward. If one already happened earlier in Phase 3, report it as an ordering warning and continue only after `/dkreviewloop` reaches `SUCCESS`; do not deadlock on an irreversible past action.

If any criterion is not met, run `/dkreviewloop` or fix the remaining findings
now, then stop again for this audit.
