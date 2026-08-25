# Failure Recovery

Use this process after the same check or review finding fails twice. Stop
repeating the current attempt before it turns into a loop.

## Diagnose the failure

Classify what is blocking progress:

- `REPEATING_ERROR` — the same failure survived more than one fix.
- `NEW_ERROR_FROM_FIX` — the last fix caused a different failure.
- `CRITERIA_MISMATCH` — the approved requirement cannot be met by the current design.
- `TOOLCHAIN_ISSUE` — the build, test, or local environment is failing.
- `SCOPE_EXCEEDED` — a safe fix needs work beyond the approved plan.

Record the evidence, the approaches already tried, and what the next approach
will change. Do not count another identical retry as a new strategy.

## Recover within the approved contract

Try no more than three concrete attempts for one strategy, then switch to a
materially different strategy. Useful choices include:

- Re-read the exact failure and compare it with a working pattern in the repo.
- Reduce the reproduction and test the smallest failing boundary.
- Replace the implementation approach while preserving the same requirements.
- Repair or isolate the local toolchain, then rerun the required check.
- Ask for human direction when the safe fix changes scope, architecture, or an
  approved requirement.

The approved acceptance criteria and verification gates do not change because
an agent is stuck. Do not relax, split, defer, mark N/A, or accept a criterion
as debt unless the user explicitly changes the plan. A debt note may preserve
useful context, but it never satisfies a completion gate.

## Escalate without claiming completion

After two materially different strategies fail, use the exact escalation
command supplied by the Dex hook. That command is bound to this launch's
completion generation. Never look up a newer generation and never write a
completion, readiness, or human-control marker yourself.

Escalation pauses and detaches the current automation, revokes its completion
authorization, and preserves workspace edits for the user. It does not signal
completion or weaken any approved criterion. In the final response, report:

- the failing requirement or check;
- the evidence and commands used;
- each strategy attempted and why it failed; and
- the smallest decision or external action needed from the user.

Use this format while deciding:

```text
## Recovery Decision
- Failure type: <classification>
- Attempt: <number>
- Strategy: <materially different approach or escalation>
- Evidence: <specific output and file locations>
- Why this differs: <one sentence>
```
