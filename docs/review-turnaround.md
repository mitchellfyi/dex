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
- Model sessions and check execution use separate host capacity pools. The
  checkout still has one review owner and one writer.
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
to run a check without reuse.

## Verification

Exercise cache hits and invalidation, failures, cancellation, concurrent
execution, malformed reports, criterion coverage, and session cleanup in
focused tests. Run the repository static checks and manifest suite. Manually
exercise the real command and report interfaces, then run a real review in an
isolated fixture repository to verify that the prompt follows the new flow.
