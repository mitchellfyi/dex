# Review checks

Write a command spec outside the checkout (for example in a `mktemp -d`
directory), then invoke it from the command's intended working directory:

```json
{
  "name": "focused regression tests",
  "argv": ["bash", "tests/example-test.sh"],
  "cache": "never",
  "inputs": [],
  "tools": []
}
```

```bash
bash "$DEX_DIR/bin/review-check.sh" /absolute/path/check.json
```

Use the repository's real command, not the example. `argv` is an argument
array, never shell-evaluated; for shell syntax use `["bash", "-c", "..."]` and
declare every tool it uses. Keep secrets out: a receipt stores only an input
hash and duration, and the private spec copy dies with the runner.

`cache: "snapshot"` asserts the check is deterministic for its inputs. With
`inputs: []` the runner binds the complete checkout, so any change invalidates
the receipt. Declaring `inputs` narrows that binding to exactly those paths:
name every path that can change the result (sources, fixtures, ignored
dependencies, external configuration); a fix elsewhere then leaves the receipt
valid. Under-declaring an input is how a stale pass gets reused: keep
`inputs: []`, or `never` when you cannot list them. Both bind the working
directory, arguments, environment, OS, executable bytes, criteria and policy,
and read real bytes even when Git index hints hide a change. Submodules run
without reuse. In `tools`, list executables and tool files beyond `argv[0]`,
interpreters and runtime libraries included; when impractical, use `never`.
Optional `autofix: true` declares a deterministic rewrite of the declared
inputs, and is what lets a wave report `MECHANICAL:N`.

Snapshot-cacheable checks do not receive wave/session control metadata such as
provider conversation IDs; `never` specs retain it. Every other environment
value affects reuse, including unknown `DEX_*` settings; the timeout process
token is reserved for cancellation. Use `never` for orchestration identity,
mutable services, network responses, wall clocks, randomness or uncaptured
inputs; for formatters and generators that write source, even if they restore
it; and for repro probes, so the verifier sees a fresh observation.

A pass is reusable only if its bound inputs — the whole checkout, or the
declared paths — still match after execution. A command that outruns the
execution budget (`DEX_REVIEW_CHECK_TIMEOUT`, 900s) keeps its real exit code
and duration, flagged `over-budget`, and is cached like any other; only a
failure or the hard ceiling publishes nothing. Missing or oversized inputs run
without caching. Record the pass or that validated reuse in the review notes.

All misses share a host FIFO check pool, separate from model waves. The default
is one active command; `DEX_REVIEW_MAX_ACTIVE_CHECKS=1..8` overrides it.
Respect `DEX_REVIEW_TEST_JOBS` inside each command. Waiting for the runner is
correct; running the same gate outside it is not — that duplicate load is what
the pool prevents, and its result is not reusable. Read, plan or write findings
while the heartbeat reports your queue position. A `queued` line and exit 75
mean a set `DEX_REVIEW_CHECK_QUEUE_TIMEOUT` was spent and nothing ran: do
lighter work and ask again. The outer wave deadline still applies. Do not nest
the runner inside a command holding the same check lease.

The wrapper supplies `DEX_REVIEW_CHECK_CACHE_SESSION` for reuse across fresh
waves. Do not open other sessions' caches or copy receipts. Phase 4 remains the
final verification pipeline: it reuses its own `dx run-gate` receipt for this
exact tree, never a wave's check cache.
