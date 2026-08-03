# Failure Recovery Analysis

When you have failed the same check or encountered the same review finding 2+ times, STOP retrying and run this analysis before your next attempt.

## Step 1: Classify the Failure

What type of failure is this?

- **REPEATING_ERROR** — same error message or finding appears across attempts
- **NEW_ERROR_FROM_FIX** — fix introduced a different error (whack-a-mole)
- **CRITERIA_MISMATCH** — acceptance criteria cannot be met with current approach
- **TOOLCHAIN_ISSUE** — build/test infrastructure problem, not code logic
- **SCOPE_EXCEEDED** — the fix requires changes outside the planned scope

## Step 2: Choose a Recovery Strategy

Based on the classification, choose ONE strategy:

### RETRY_WITH_GUIDANCE (for TOOLCHAIN_ISSUE or first NEW_ERROR_FROM_FIX)

- Re-read the error output carefully, word by word
- Search the codebase for similar patterns that work
- Search documentation for the specific API/tool causing the error
- Write down what you will do differently this time BEFORE making changes
- Proceed with the fix

### CHANGE_APPROACH (for REPEATING_ERROR after 2 retries, or 2nd NEW_ERROR_FROM_FIX)

- The current approach is fundamentally wrong. Do NOT retry it.
- List 2-3 alternative approaches to solve the same problem
- Pick the one that avoids the root cause of the current failure
- Revert the failing changes, then implement the alternative from scratch

### RELAX_CRITERIA (for CRITERIA_MISMATCH)

- Identify which specific criterion is causing the blockage
- Determine if the criterion is overly strict for the situation
- If relaxing is reasonable: document what was relaxed and why, record as debt
- If relaxing is not reasonable: use SPLIT_TASK or ESCALATE instead

### SPLIT_TASK (for SCOPE_EXCEEDED or complex REPEATING_ERROR)

- The task is too large or entangled to fix in one pass
- Identify the minimal subset that CAN pass all checks
- Implement that subset and track the remainder as debt
- Debt items become warnings for downstream tasks

### ACCEPT_WITH_DEBT (for issues that are real but non-blocking)

- Only for severity LOW or MEDIUM findings
- HIGH severity findings CANNOT be accepted as debt — fix them or escalate
- Record each debt item (see Debt Tracking below)
- Proceed with completion

### ESCALATE (last resort — after 2+ strategies have failed)

- Write the completion signal file to exit the loop
- In your final output, clearly describe:
  - What was attempted (strategies tried)
  - Why each approach failed
  - What information or action the user needs to provide

## Step 3: Record Your Decision

Before proceeding, output:

```
## Recovery Decision
- Failure type: <classification>
- Attempt number: <N>
- Strategy: <chosen strategy>
- Rationale: <1-2 sentences>
- Previous attempts: <what was tried and why it failed>
```

## Anti-Loop Guard

If you have already run this analysis in a previous iteration and chose a strategy that ALSO failed:

- You MUST choose a DIFFERENT strategy this time
- If you have exhausted RETRY_WITH_GUIDANCE and CHANGE_APPROACH, move to SPLIT_TASK or ACCEPT_WITH_DEBT
- Never choose the same strategy more than twice
- **Budget: 2 strategies x 3 retries each = 6 total attempts.** After 6 attempts, you must ACCEPT_WITH_DEBT or ESCALATE.

---

## Debt Tracking

When accepting findings as debt (via ACCEPT_WITH_DEBT, SPLIT_TASK, or RELAX_CRITERIA), record each item in the debt ledger:

```bash
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh" || exit 1
cat >> "$(dx_debt_file "${DEX_SESSION_ID:-$(dx_session_id)}")" <<'DEBT'
- **[TYPE]** | Severity: [low|medium] | [description]
  - File: [file:line if applicable]
  - Reason deferred: [why this was not fixed]
  - Impact: [what downstream tasks should know]
DEBT
```

### Debt Types

| Type | When to use |
|------|-------------|
| `INCOMPLETE_IMPL` | Feature partially implemented, remaining work tracked |
| `KNOWN_BUG` | Bug identified but not fixed (low severity only) |
| `MISSING_TEST` | Test coverage gap accepted |
| `DESIGN_SHORTCUT` | Temporary implementation that should be refactored |
| `RELAXED_CRITERIA` | Acceptance criterion intentionally relaxed |

### Rules

- HIGH severity findings CANNOT be debt. Fix them or escalate.
- Every debt item must have a reason and impact description.
- Debt items propagate as warnings to downstream tasks and appear in the PR description.
