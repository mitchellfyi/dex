Before stopping, verify the same-session Review phase completed the full review
loop. Do NOT stop until every step below passes.

This lifecycle advances phases in the same Claude session. Phase 3 gets independent review coverage by
running `/dkreviewloop`, which spawns fresh review subagents and requires three
clean reports in a row.

## Completion Criteria

All of these must be true before you stop:

- `/dkreviewloop` ran on the full current change set.
- The `/dkreviewloop` result is `SUCCESS`.
- The final result shows at least 3 consecutive clean reports.
- Any findings discovered by the loop were fixed.
- The review was re-run after the most recent code change.
- No commits, pushes, PR creation, or PR updates were performed in this phase.

If any criterion is not met, run `/dkreviewloop` or fix the remaining findings
now, then stop again for this audit.
