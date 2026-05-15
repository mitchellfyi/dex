# Implementation Review Criteria

Evaluate every changed file against the passes below. The `/dkreview` skill and
`prompts/review-wave.md` drive how these criteria are applied; this prompt
defines the criteria only. These criteria complement the implementation
discipline described in `prompts/guardrails.md`.

For each finding, report: `file:line | pass | severity | confidence | issue | suggested fix`.

Severity levels: **high** (correctness, security, data loss), **medium** (performance, missing tests, design), **low** (style, naming, minor conventions).

---

## Phase 0: Codebase Context (mandatory before any pass)

Before evaluating findings, gather the context needed to judge them. **Skipping this step produces false positives** — what looks like a bug in isolation is often an established pattern when read in context.

Read in this order — stop early when you have enough to judge the change:

1. **Project conventions** — `AGENTS.md`, `CLAUDE.md` compatibility pointers, and any `.doyaken/rules/*.md` referenced from them. These document language boundaries, naming, error-handling, and architecture rules specific to the repo. A finding that violates one of these has higher confidence; a finding that contradicts one is likely a false positive.
2. **Scoped repo memory** — if `.doyaken/memory/index.md` exists, read it and load only active memory entries whose scope matches the changed files or review phase. Memory is context, not proof; re-check current code before relying on it.
3. **Project-specific review criteria** — `.doyaken/doyaken.md` § Reviewers (or other review-criteria sections). Some projects extend or override the defaults below.
4. **The plan or ticket** — if a plan file or ticket context exists, read the acceptance criteria and the chosen approach. A "missing case" finding is invalid if the case was explicitly out of scope per the plan.
5. **Similar code in the repo** — for any pattern the change introduces (a new auth check, a new query, a new error type), `Grep` for existing instances. If the codebase already uses pattern X for this scenario in 3+ places, the change should follow X. If X is established and the change introduces Y → finding. If you flag the change as "doesn't match best practice Z" without confirming Z is the project's pattern, that's a false positive.
6. **Recent fix history of touched files** — `git log --oneline --since=3.months -- <file>` for each deep-review file. Recent `fix:` commits → fragile area; apply extra scrutiny.
7. **Failure-recovery and debt records** — `prompts/failure-recovery.md` (recovery strategies for stuck-loop scenarios) and any `.debt` ledger files in the loop dir. A finding that someone has already accepted as debt should not be re-raised.

For each pass below, an explicit "context check" step references back to the artefacts gathered here. Findings that don't pass the context check are downgraded or filtered.

---

### Confidence Scoring

Every finding MUST include a confidence score from 0-100:

| Score | Meaning | Action |
|-------|---------|--------|
| 90-100 | Certain — verifiable bug, missing guard, failing test | Always report |
| 75-89 | Highly confident — real issue with clear evidence | Always report |
| 50-74 | Moderately confident — likely issue but needs judgement | Report with caveat |
| 25-49 | Low confidence — might be intentional or context-dependent | Filter out |
| 0-24 | Noise — stylistic nitpick, pre-existing pattern, linter territory | Filter out |

**Threshold: 50.** Only report findings with confidence >= 50.

**Scoring guidelines — evidence determines confidence, not how certain you feel:**

**Tier 1 (90-100) — Mechanically verifiable:**
- You can write a test that reproduces the issue → 95-100
- The type checker / linter flags this → 90-95
- A required code path is missing and `Grep` confirms no alternative exists → 90-95

**Tier 2 (70-89) — Concrete example constructed:**
- You traced a specific input through the code to a wrong output → 80-89
- You found a consumer passing data inconsistent with the changed contract → 75-85
- You identified a missing check AND traced where unchecked data reaches a consumer → 70-80

**Tier 3 (50-69) — Pattern-matched with partial verification:**
- Code matches a known anti-pattern AND you verified preconditions apply here → 55-69
- You found the same bug elsewhere in this codebase (establishing precedent) → 50-65
- New code extends a pre-existing bad pattern → 50-60 (note the existing pattern)

**Below 50 — Reasoning without evidence (filtered out):**
- "This looks like it could be a problem" without a concrete trigger → 0
- "Best practice suggests..." without demonstrating the consequence → 0
- "Best practice suggests..." that contradicts a documented project convention → 0
- Pre-existing patterns not introduced in this change → 0
- Issues linters/formatters catch → 0
- Code that looks odd but follows a nearby pattern in this codebase → 0

---

### Observe-Verify-Conclude Protocol

Before reporting ANY finding, follow this sequence. Do not skip or reorder.

1. **LOCATE**: `Grep` or `Read` to find the exact file:line you will reference. If you cannot locate it, you do not have a finding.
2. **OBSERVE**: Read the surrounding code (minimum 3 lines of context). Record what the code DOES as a neutral statement ("Function X calls Y without checking the return value"), not what is WRONG with it.
3. **CHECK PROJECT CONTEXT**: Does Phase 0 context contradict the finding? Is there a project rule allowing this? Is this an established pattern with multiple occurrences? If yes, the finding is filtered.
4. **CHALLENGE**: Is this actually a problem? Check: Does the caller handle it instead? Does the type system guarantee safety? Does a nearby comment explain why?
5. **CONCLUDE**: Only now classify as a finding with severity and confidence (using the evidence tiers above).

If you feel certain about a finding before completing steps 1-4, treat that certainty as a signal to be MORE skeptical — pattern-recognition confidence without verification is the primary source of false positives.

---

## Pass A: Correctness & Logic

**Adversarial stance:** Your goal is to BREAK the code, not confirm it works. For each function, actively construct inputs that would cause failure, states that would produce wrong results, and timing that would create races. Only mark a code path as correct if you cannot construct a breaking scenario.

Trace the code path end-to-end:

- **Happy path** — does the expected input produce the expected output?
- **Failure paths** — what happens when a dependency is down, the API returns an error, the input is malformed?
- **Edge cases** — empty collections, null/nil/undefined, zero, negative numbers, MAX_INT, very long strings, Unicode (combining chars, surrogates), special characters, leap seconds/leap years, timezone boundaries, DST transitions, locale-dependent formatting
- **Concurrency & races** — shared state without synchronisation? Time-of-check-to-time-of-use (TOCTOU) gaps? Read-modify-write sequences without atomicity? Async ordering assumptions? Reentrancy via callbacks/hooks?
- **Idempotency & retries** — if this is invoked twice (network retry, queue redelivery, user double-click), does the second invocation cause duplicate side effects? Are retries safe?
- **State transitions** — are all state changes atomic? Can partial failures leave inconsistent state? Is there a rollback path? Is the state machine exhaustive — every state has a defined transition for every input?
- **Resource cleanup** — are all opened resources (connections, handles, subscriptions, timers, file descriptors, watchers, listeners) closed on both success and failure paths? Is cleanup ordering correct (e.g., flush before close)?
- **Return values** — are all branches returning the correct type? Any implicit undefined/null? Sentinel values that callers might mistake for valid data?
- **Boundary conditions** — off-by-one in loops/slices, empty vs. missing vs. null, first/last element handling, inclusive vs. exclusive bounds on ranges
- **Error propagation depth** — does the error carry enough context to diagnose at the top of the stack? Is the error type narrowed appropriately or do callers have to switch on a raw string?

**Context check before flagging:** Did Phase 0 surface a project convention that allows this? Does the same pattern appear elsewhere in the codebase as accepted? If yes, the finding is filtered or downgraded.

## Pass B: Design & Architecture

- Is this the simplest solution that meets the requirements?
- Would a new developer understand this in 5 minutes?
- Does it follow existing patterns in nearby files and the project's documented conventions?
- Are there unnecessary layers of abstraction or indirection? (YAGNI)
- Does it use existing utilities rather than creating new ones? (DRY of knowledge, not code that looks similar)
- Could a simpler data structure or algorithm achieve the same result?
- Are naming conventions consistent with surrounding code?
- **Coupling** — does the new code reach across module boundaries? Bypass the project's intended layering (e.g., a UI component talking directly to the database)? Create circular dependencies?
- **Cohesion** — does each module/function have a single, clearly-named responsibility, or is it doing 3 things?
- **Open/closed** — does adding a future variant require editing this code in N places, or extending it in 1?
- **Dependency direction** — do dependencies point toward stable abstractions (the project's core types) and away from volatile ones (specific frameworks, vendor SDKs)?
- **Boundaries** — are external concerns (HTTP, database, filesystem, env vars) isolated behind a thin adapter, or scattered through the business logic?

**Context check:** project-specific architecture rules in `.doyaken/rules/architecture.md` (or equivalent) supersede generic principles. If the project documents a different layering, follow it.

## Pass C: Security

Cover the OWASP Top 10 categories explicitly:

- **A01 Access control** — every endpoint/route has authentication AND authorization (authn != authz). Authz is checked at the right layer (not just in the UI). Object-level authz (the user owns the resource, not just is logged in).
- **A02 Cryptography** — no hardcoded secrets, credentials, API keys, or signing keys. No weak algorithms (MD5, SHA-1 for security, ECB mode, fixed IVs). Secrets pulled from a secret manager / env vars, not committed to the repo.
- **A03 Injection** — database queries use parameterized queries (no string interpolation). Shell commands pass user input as argv elements, never via `shell=True` / `eval`. Template engines auto-escape. No `eval`/`exec` on user input. LDAP, NoSQL, and command injection are all considered.
- **A04 Insecure design** — secure defaults (features off/restricted by default, not permissive). Defense in depth (no single control is the only protection). Threat-model the new flow if it introduces a new trust boundary.
- **A05 Security misconfiguration** — security headers (CSP, X-Frame-Options, HSTS, etc.) where applicable. CORS configured to a specific origin list, not `*`. Cookies have `Secure`, `HttpOnly`, `SameSite` flags. Verbose error messages don't leak stack traces, internal paths, or DB schema to clients.
- **A06 Vulnerable & outdated components** — new dependencies introduced? Pinned to a known-safe version? CVE-checked? Maintained?
- **A07 Identification & authentication failures** — session tokens are random, expire, rotate on privilege change. Passwords are hashed with a slow KDF (bcrypt/scrypt/argon2), never stored or logged. MFA / rate-limiting on login.
- **A08 Software & data integrity** — webhooks/callbacks verify signatures before trusting payload. Deserialization avoids unsafe formats (pickle, Java native serialization) on untrusted input. Supply-chain: lockfiles updated, integrity hashes match.
- **A09 Logging & monitoring failures** — security-relevant events (auth failures, authz denials, data exports) logged; logs don't contain secrets, PII, or full request bodies.
- **A10 SSRF** — if the code makes outbound HTTP, the destination URL/host is validated against an allowlist. No fetching arbitrary user-supplied URLs that could hit internal services.

Additional:
- **CSRF** — state-changing requests require a token / SameSite cookie / double-submit pattern.
- **Sensitive data in transit** — TLS for all external calls. Internal calls over plain HTTP only when explicitly inside a trust boundary.
- **PII handling** — minimum necessary data collected, retention period documented, deletion path exists, no PII in logs/metrics/traces.
- **Input validation at boundaries** — request handlers, queue consumers, file uploads, external API responses. Validate type, range, length, format. Reject early, log the rejection.
- **Concurrency security** — race conditions in authorization checks (TOCTOU), token reuse windows, double-spend in financial operations.

**Context check:** does the project have a `.doyaken/guards/` rule (or equivalent) that already blocks the pattern? Already-protected paths don't need re-flagging.

## Pass D: Performance

- **N+1 queries** — use joins, batch loading, or eager loading. The classic anti-pattern: looping over a list and querying inside the loop.
- **Pagination on list operations** — no unbounded queries returning unbounded data. Default page size, max page size enforced.
- **Indexes for new query patterns** — check migrations add appropriate indexes. New query without an index → full table scan at production scale.
- **Timeouts on external service calls** — every HTTP/DB/cache call has an explicit timeout. No relying on the OS default of "forever".
- **No unbounded loops over user-controlled data** — loop iteration count must be bounded by something the user can't make arbitrarily large.
- **Select only needed columns/fields** — `SELECT *` over wide tables, GraphQL queries that fetch fields and don't use them.
- **Caching considered** — for expensive read-heavy operations. Cache invalidation strategy documented (write-through, TTL, explicit invalidation).
- **Bulk operations preferred** — over row-by-row processing where applicable.
- **Algorithm complexity** — O(n²) or worse where O(n log n) or O(n) is achievable for the same scale; nested loops over collections that grow with input.
- **Connection pooling and resource reuse** — DB connections, HTTP clients, parsers — created once and reused, not per-request.
- **Memory profile** — buffering an entire response/file in memory when streaming would work, holding references after they're no longer needed (memory leaks via closures/event listeners).
- **GC pressure / allocation hot paths** — allocating in tight loops in GC'd languages, large temporary objects in inner loops.
- **Lock contention** — coarse locks held across long operations (I/O, network), nested locking with inconsistent ordering (deadlock risk).
- **Cold start / startup cost** — new code added to a hot startup path? Lazy-load if rarely used.

**Context check:** does the project have established perf budgets (in `AGENTS.md`, `CLAUDE.md`, or a perf doc)? Findings should reference them.

## Pass E: Testing

- Tests cover **behaviour** (inputs → outputs), not implementation details. Refactoring without changing behaviour should not break tests.
- Factory functions or fixtures for test data with sensible defaults — avoid hand-built objects with 30 fields in every test.
- Real schemas/types imported, not redefined in tests (otherwise tests pass on a parallel universe).
- Edge cases and failure paths tested — not just the happy path. Each branch in production code should have at least one test that exercises it.
- No mocking of internals — mock at boundaries only (external services, databases, time, randomness, filesystem). Mocking your own functions hides bugs.
- Test names describe the scenario and expected outcome (`describe what when then` style).
- Each test is independent — no shared mutable state between tests; tests pass when run in any order.
- **Tests can actually fail** — if the implementation were broken, the test would catch it. Not just asserting on mocked data, not tautologies (`assert x === x`), not asserting "no error thrown" without checking the result.
- Acceptance criteria from the ticket each have at least one corresponding test.
- **Regression tests for fixed bugs** — every `fix:` commit has a test that fails without the fix.
- **Boundary tests** — empty/zero/MAX/min boundaries explicitly covered, not just "typical" inputs.
- **Concurrency tests** for code with shared state — at minimum, run the operation in parallel and assert no inconsistency.
- **Coverage gaps that matter** — not coverage as a metric (gameable), but: if the change introduces error handling, is there a test that exercises the error path?

**Context check:** does the project have a documented testing style (`.doyaken/rules/testing.md` or equivalent)? Follow it.

## Pass F: Style & Conventions

Follow the project's established conventions (check AGENTS.md, CLAUDE.md, linter configs, and surrounding code):

- No dead code, debug logging, commented-out code, or debug artifacts (`console.log`, `print`, `dbg!`, `binding.pry`, `fmt.Println`, etc.)
- Type safety: avoid escape hatches (language-specific: `any`, `as`, `@ts-ignore`, `unsafe`, `# type: ignore`, `interface{}`/`any` in Go, etc.) without justification
- Comments explain "why", never "what" — no redundant comments. Doc comments on exported APIs are an exception (they explain "what" for callers).
- No TODO comments without a linked ticket
- DRY applied to _knowledge_, not just code that looks similar (two functions doing different things that happen to have similar shape should NOT be merged)
- YAGNI — no speculative features, no unused abstractions, no "we might need this later"
- File and module organisation — files at a sensible size (no 2000-line files mixing concerns), modules grouped by responsibility (not by type — avoid `controllers/`, `services/`, `models/` as the only structure if the project uses feature-folders)
- Public API surface — exports are intentional. New `pub`/`export` should be necessary, not accidental.
- Naming: identifiers describe the thing, not the type (`users` not `userArray`); booleans answer a yes/no question (`isExpired`, not `expired` ambiguity); functions name the action (`fetchUser` not `user`).

**Context check:** when in doubt, mirror nearby code. A finding that contradicts the dominant local style is a false positive.

## Pass G: Dependency Consistency

Cross-file contract adherence — verify changes propagate consistently:

When files that define contracts change (types, schemas, API definitions, database models, interfaces, GraphQL schemas, OpenAPI specs, protobuf), verify:
- All consumers/callers are updated to handle the new shape
- Serialization/deserialization code maps the new fields
- Tests reflect the updated contracts
- Generated code is refreshed if applicable
- Migrations run in a safe order (additive before required, drops last)

**How to check — multi-hop tracing:**

1. **Hop 1:** `Grep` for imports of the changed file → verify each direct consumer is consistent
2. **Hop 2:** For each direct consumer that re-exports or wraps the changed entity, `Grep` for ITS consumers → verify consistency
3. **Hop 3:** Continue one more level if hop 2 revealed re-exports, or stop at leaf consumers

Track the chain: `[Changed] X → [Hop 1] Y ✓ → [Hop 2] Z ✓`. Stop at 3 hops or leaf consumers (non-exported code), whichever comes first.

For inter-service contracts (HTTP/RPC/event schemas), the trace extends across services — check the consuming service's repo if accessible, or note in the PR description.

## Pass H: Acceptance Criteria

If ticket context is available (plan file, task list, or ticket tracker):

For each acceptance criterion:
1. **Implementation**: trace to a specific `file:line` in production code that implements it
2. **Test**: trace to a specific test case that validates it

| Criterion | Implemented | Tested |
|-----------|------------|--------|
| _criterion text_ | `file:line` or **NOT FOUND** | `test-file:line` or **NOT FOUND** |

Flag **NOT FOUND** entries as high-severity findings.

Reject prose-only criteria ("works correctly", "is performant") — they should have been rewritten as testable assertions in `/dkplan` Step 2.5. If they slipped through, flag the criterion as un-verifiable.

## Pass I: Documentation Quality

Code should be self-documenting, but non-obvious logic needs explanation:

- Functions/methods with complex control flow (nested conditionals, state machines, multi-step transformations) must have a comment explaining **why**, not what
- New public APIs (exported functions, HTTP endpoints, CLI commands) need doc comments with parameter/return descriptions and at least one example
- Complex regular expressions must have a comment explaining what they match and why that pattern was chosen
- Magic numbers and magic strings must be extracted to named constants, or have an inline comment explaining the value (with a source if it's a spec value, e.g., `// max length per RFC 5321 §4.5.3.1.6`)
- Non-trivial algorithms should cite the algorithm name or link to the source/reference (e.g., "// Fisher-Yates shuffle" or "// See RFC 5322 §3.4")
- If a code block implements a workaround for a known issue, it must link to the issue/ticket
- **Architectural decisions of substance** should be captured in an ADR or similar (`docs/adr/`, `decisions/`) — flag if the change introduces a new abstraction without recording why
- **Changelog/release notes** — user-facing changes should land in the project's changelog file if one exists
- **README/getting-started updates** — new commands, new env vars, or new setup steps should be reflected in the project's quickstart docs

## Pass J: Holistic Consistency

Review ALL changed files together as a set (not individually). Check for cross-file consistency:

- **Naming** — are the same concepts named the same way across all changed files? (e.g., not `userId` in one file and `user_id` in another, not `getUser` in one and `fetchUser` in another)
- **Error handling** — does every file follow the same error handling pattern? (e.g., if one function returns errors, all similar functions should too; if one uses try/catch, don't mix with error codes)
- **Logging** — are log levels, formats, and structured fields consistent across all changed files?
- **Patterns** — if a pattern is established in one changed file (e.g., input validation style, response formatting), it must be followed in all changed files
- **Imports** — are utility/helper imports consistent? (e.g., not importing the same function from different paths)
- **Architectural drift** — does the change collectively shift the architecture (e.g., the first instance of a UI component reaching directly into the data layer)? If so, the change should either follow the existing layering or be paired with a documented architecture revision (Pass I).
- **Boundary integrity** — does the change keep external concerns (HTTP, DB, FS) at the edge? A leak — a database type appearing in a web handler, an HTTP request type in a domain service — is a structural finding.

## Pass K: Observability

For production code (not tests, not docs):

- **Logs** — every error path and every significant state transition logs a message at an appropriate level (`debug`/`info`/`warn`/`error`). Logs include a request/correlation ID so events can be tied together. Logs are structured (JSON) if the rest of the project is structured.
- **Log content** — descriptive enough to diagnose without re-running. Avoid logs that are just `"error"` with no context. No secrets, no PII, no full request bodies.
- **Metrics** — counters for important events (requests, errors, retries). Histograms for latency. Gauges for queue depth / connection counts. New code paths add the metrics needed to alert on regressions.
- **Tracing** — if the project uses distributed tracing (OpenTelemetry, etc.), new external calls are wrapped in a span. Spans carry the request ID.
- **Health/readiness** — new background jobs / queues / external dependencies are reflected in health checks if the project has them.
- **Alerts** — if this code path failing would matter, is there an alert (or a runbook entry) covering it? Not all code needs alerts — flag only when an obvious gap exists.

**Context check:** if the project doesn't have observability tooling, downgrade these findings to suggestions in the PR description, not blockers.

## Pass L: Backward Compatibility & Migrations

For changes that modify a public contract (HTTP API, CLI, library API, DB schema, event schema, config format):

- **Breaking changes identified explicitly** — does the PR description or a CHANGELOG entry name this as a breaking change?
- **Migration path documented** — for each break, is there a migration step the consumer runs? Is it automated or manual?
- **Deprecation period** — for changes that could be additive-then-remove, is there a deprecation cycle (release N adds new, marks old deprecated; release N+1 removes old)?
- **Database migrations** — additive migrations (new column, new table) before code that requires them. Destructive migrations (drop column, drop table) gated behind a feature flag or run after the code is deployed everywhere. No `DROP COLUMN` in the same migration as code that read the column.
- **Wire format changes** — protobuf field numbers reused? JSON field renamed without an alias? GraphQL field removed? These break clients silently.
- **Default values changed** — has the new default been verified to be safe for all existing callers? A flipped default is a breaking change for anyone relying on the old default.
- **Config schema changes** — required fields added without defaults? Renamed fields without an alias? These break existing deployments.
- **Feature flags** — risky changes wrapped in a flag with a documented rollout plan?

**Context check:** the project's `AGENTS.md` may document a breaking-change policy (e.g., semver, calendar versioning, "breaking changes only on major releases"). Apply that policy.

---

## Output

For each finding:
```
| file:line | Pass | Severity | Confidence | Issue | Suggested fix |
```

Only include findings with confidence >= 50. If all passes are clean or all findings are below threshold: **"No issues found."**

For passes that don't apply to the changed files (e.g., Pass K on a docs-only change), explicitly note "N/A — <reason>" in the report so the omission is visible.
