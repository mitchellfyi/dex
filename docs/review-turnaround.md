# Review turnaround

Review still requires 1, 2, or 3 independent clean waves for small, normal,
or complex changes. Each wave reviews the full current scope. Findings are
verified before the active wave applies a batch of fixes; any fix resets the
clean streak. Phase 4 remains the final quality gate.

The turnaround changes remove repeated mechanical work:

- A command runner reuses explicitly deterministic checks only when the
  checkout, command, environment, tools, declared external inputs, criteria,
  and review policy still match. Failed, interrupted, and source-mutating
  commands never publish reusable evidence. Checks with unbounded inputs run
  every time.
- Model sessions and check execution use separate host capacity pools. Existing
  model admission defaults remain unchanged; the default check budget is one
  command. The checkout still has one review owner and one writer.
- The wrapper prepares factual scope input for each reviewer. Reviewers still
  produce independent coverage and findings; previous conclusions are never
  reused as context.
- A report publisher derives hashes, bindings, and evidence references from
  one structured report, validates it through the existing gates, then writes
  the completion receipt last. It does not invent passing checks or satisfied
  acceptance criteria.

## Design decisions

Whole-wave concurrency is excluded from this change. The existing waves also
launch scouts, so running three full waves concurrently multiplies resource
use before there is evidence that the code is ready for confirmation. It also
requires a new all-results acceptance transaction to prevent an early clean
result from hiding a later finding. Sequential independent waves retain the
existing receipt and recovery semantics while the reusable work and host
queue bottlenecks are addressed.

Automatic model concurrency also stays unchanged. Raising it lowers the
default scout parallelism even when only one review is active, which can
increase that review's turnaround time. The separate check pool lets operators
tune model admission without multiplying test suites, but defaults should
change only after measuring that tradeoff.

Caching is conservative: a source change invalidates the whole check entry.
Inferring that a changed file cannot affect a check requires a complete
dependency model, which Dex cannot assume in an arbitrary repository.
Toolchain and ignored dependency inputs must be declared when they are not
already covered by the executable and checkout fingerprints. Network state,
clocks, randomness, mutable services, and unbounded external inputs are reasons
to run a check without reuse. Reuse does not replace independent semantic
review, and these same-UID receipts detect drift rather than forgery.

## Interfaces

Review agents use [the check spec](../prompts/review-checks.md) and
`bash "$DEX_DIR/bin/review-check.sh" <check-spec.json>`. Reuse is opt-in per
command. The runner reports whether it executed or reused the check, along
with its duration and queue wait. Cache entries stay in private global Dex
state under the parent review session and are removed by session cleanup.

Reviewers supply [one structured report](../prompts/review-report.md) to
`bash "$DEX_DIR/bin/review-result.sh" <report.json> <authorized-generation>`.
The report contains conclusions and evidence; code derives the bookkeeping.
Existing version-3 artifacts and generation-bound receipt validation are
unchanged. The legacy baseline interface remains accepted, but new review
instructions use the environment- and tool-bound runner instead.

`DEX_REVIEW_MAX_ACTIVE_WAVES=1..8` and `DEX_REVIEW_MAX_ACTIVE_CHECKS=1..8`
override the separate host budgets. `DEX_REVIEW_CHECK_TIMEOUT` defaults to 900
seconds for queue waiting and, separately, execution. It does not extend the
outer wave deadline. Existing scout and test-job limits still apply.

## Verification

Verification on 2026-09-08:

- `bash tests/check.sh`: all static checks passed.
- `bash tests/run-all.sh`: 102 passed, 0 failed on macOS.
- Final focused rerun of check caching/execution, reports, capacity, timeouts,
  session forgetting, and the session catalog: 7 passed, 0 failed.
- Both changed skills passed the skill validator.

| Criterion | Implementation (`file:line`) | Test (`file:line`) | Status |
|---|---|---|---|
| Reuse requires matching bounded inputs | `scripts/review_checks.py:153` | `tests/review-check-cache-test.py:32`; `tests/review-check-runner-test.sh:127` | MET |
| Failures and cancellation preserve their result without reusable success | `bin/review-check.sh:80`; `lib/session.sh:2061` | `tests/review-check-runner-test.sh:69` | MET |
| Check admission is separate from model admission | `lib/review-capacity.sh:78` | `tests/review-check-runner-test.sh:110` | MET |
| Prepared scope facts do not count as reviewed evidence | `lib/review.sh:1806` | `tests/review-report-test.sh:104` | MET |
| Report automation retains criterion, receipt, and clean-wave gates | `bin/review-result.sh:24`; `prompts/review-wave.md:10` | `tests/review-report-test.sh:62`; `tests/review-loop-test.sh:1696` | MET |
| Session cleanup removes new state; vendored runtimes contain the helpers | `lib/session.sh:2675` | `tests/session-forget-test.sh:178`; `tests/review-evaluation-harness-test.sh:235` | MET |

Manual checks used an isolated Python fixture repository:

- A real reviewer followed the updated skill, ran seven tests and independent
  boundary probes, and published a clean report on its first attempt. The
  existing evidence, completion-receipt, and metrics validators accepted it.
- The public `dxreviewloop` command launched the installed Codex CLI and
  completed a small-tier review with one independent clean wave and a valid
  final receipt. No provider or review result was mocked in this run.
- A snapshot-cacheable syntax check executed once, reused its result after
  changing the provider conversation and wave IDs, then executed again after a
  declared input changed.
- Ten repeated public-runner timeout checks each returned 124. This exposed
  and verified a fix for macOS Bash 3.2 cleanup replacing a timeout result with
  exit 1 when an interrupted process left a temporary snapshot behind.

These checks establish behavior, not a production speedup percentage. A
before/after benchmark of a six-hour review was not run.
