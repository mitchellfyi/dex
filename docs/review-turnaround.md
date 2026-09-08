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
- Model sessions and check execution use separate host capacity pools. Hosts
  with at least 8 CPUs and 16 GiB RAM admit two model waves, smaller hosts one.
  The default check budget is one command. The checkout still has one review
  owner and one writer.
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

Exercise cache hits and invalidation, failures, cancellation, concurrent
execution, malformed reports, criterion coverage, and session cleanup in
focused tests. Run the repository static checks and manifest suite. Manually
exercise the real command and report interfaces, then run a real review in an
isolated fixture repository to verify that the prompt follows the new flow.
