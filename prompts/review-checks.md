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
array, never shell-evaluated. If shell syntax is necessary, explicitly use
`["bash", "-c", "..."]`; declare every tool that script uses. Don't put secrets
in arguments or the spec. A passing receipt stores only an input hash and
duration, not logs, arguments, or environment values. The private command-spec
copy is removed when the runner exits.

`cache: "snapshot"` is an explicit assertion that the check is deterministic
for its inputs. The runner binds the complete checkout, working directory,
arguments, environment, OS, executable bytes, criteria, and policy. In `inputs`,
list any ignored dependencies, external configuration, or other files/directories
the check reads. Source bytes are checked even when Git index hints suppress
status changes. Submodule checkouts currently run without reuse. In `tools`,
list additional executables or tool files beyond
`argv[0]`. Runtime libraries and interpreter packages also need coverage. When
that inventory is impractical, use `never`.

Snapshot-cacheable checks do not receive wave/session control metadata, including
provider conversation IDs. Uncached checks retain that environment. All other
environment values affect reuse, including unknown `DEX_*` settings. The
timeout process token is reserved for cancellation, not application input.
Use `never` for checks that require orchestration identity, mutable services,
network responses, wall clocks, randomness, or uncaptured inputs. Formatters
and generators that write source also use `never`, even if they restore it.
Repro probes
run with `never` so the verifier sees a fresh observation.

A pass is reusable only if the checkout and declared inputs still match after
execution. Failures and timeouts preserve the command's nonzero result and
publish nothing. Missing or oversized reusable inputs fall back to execution
without caching. A cache hit reports the duration of the avoided command.
Record either the actual pass or that validated reuse in the review notes.

All misses share a host FIFO check pool, separate from model waves. The default
is one active command; `DEX_REVIEW_MAX_ACTIVE_CHECKS=1..8` overrides it. Respect
`DEX_REVIEW_TEST_JOBS` inside each command. `DEX_REVIEW_CHECK_TIMEOUT` bounds
queue waiting and, separately, execution (900 seconds each by default); set it
to the project's known check budget when needed. The outer wave deadline still
applies. Do not nest the runner inside a command holding the same check lease.

The wrapper supplies `DEX_REVIEW_CHECK_CACHE_SESSION` for reuse across fresh
waves. Do not open other sessions' caches or copy receipts. Phase 4 remains the
final verification pipeline, not a cache-only gate.
