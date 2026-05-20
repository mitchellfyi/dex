# Implementation Guardrails

Reference document for doyaken skills. Read when referenced by `/dkplan`, `/dkimplement`, or `/dkloop`.

## HARD STOPS — Override All Other Priorities

These override code completion momentum, pattern consistency, and time pressure. Violating any is a blocking defect:

1. **Verification failures block progress.** If the type checker, linter, or test runner fails → stop and fix. Do not move on, declare done, or commit.
2. **Parameterized queries only.** No string interpolation in database queries. No exceptions.
3. **No hardcoded secrets.** Not in production code, not in tests, not "temporarily."
4. **Tests must run before done.** "It should work" is not verification.
5. **No silent error swallowing.** Every catch block logs with context or re-throws.

These rules exist because they compete with the momentum of code completion. If you find yourself about to skip one because "it's simpler" or "just for now" — that impulse is exactly what the rule guards against.

## AI Discipline

### Verify, Don't Assume

- Before claiming something works: run the test, read the output, check the file.
- Before claiming something exists: grep for it, read it. Don't rely on memory.
- Before using a function or API: read the source or official docs to confirm the signature and behavior.
- If you are uncertain about behavior, a schema, or a business rule: write a small test or read the code. Do not fill gaps with plausible guesses.

### Tool Output Hygiene

- Prefer scoped `rg`, `git diff --name-only`, `git diff --stat`, and targeted file reads before broad output.
- Summarize passing logs; keep exact failing lines, file:line evidence, and commands needed to verify the claim.
- Do not paste full files, full diffs, or full logs when a short summary plus path is enough.

### Research Before Implementing

- Before writing code that uses an unfamiliar API or library: read the official docs or source.
- Before choosing an approach for a non-trivial problem: search the codebase for prior art and similar patterns.
- Before implementing a non-trivial algorithm or integration: search for known pitfalls, common mistakes, and edge cases others have documented.
- Prefer solutions that are widely adopted and battle-tested over novel or clever ones.

### Understanding Verification

Before writing any implementation code, answer these five questions (briefly, to yourself):

1. What is the exact input and output of this change?
2. What existing code will this interact with?
3. What are the failure modes?
4. What is explicitly out of scope?
5. What would a reviewer challenge about this approach?

If you cannot answer all five confidently, gather more context first.

## Implementation Principles

### Common Mistakes to Avoid

These are recurring mistakes observed across many implementations. Check against this list before declaring done:

- **Don't skip verification steps.** If the type checker, linter, or test runner fails, STOP and fix it immediately. Do not move to the next task, do not declare done, do not commit. Broken verification is the #1 source of quality failures.
- **Don't mix module systems.** Pick one module system per project and use it everywhere. Mixing module conventions in the same project causes subtle runtime errors that are hard to debug.
- **Don't put all production code in a single file.** Separate the entry point (CLI parsing, route handling, UI rendering) from core logic (business rules, data operations), and separate I/O or storage from pure computation. Even small projects benefit from at least three source files — a monolithic approach prevents isolated testing and makes the codebase harder to navigate.
- **Don't write tests that only cover happy paths.** For every success test, write at least one error/edge test. A test suite with 20 happy-path tests and zero error tests is worse than 10 tests with proper error coverage — it creates false confidence.
- **Don't assume your code works without running it.** After writing implementation code, run the tests. After writing tests, run them. After fixing a bug, run the tests again. "It should work" is not verification.
- **Don't ignore test failures.** If most tests fail, the implementation has a fundamental problem — don't declare done. Read the error output, identify the root cause, and fix it. Common root causes: missing type definitions in config, wrong import paths, missing dependencies.
- **Don't use string interpolation for database queries.** Always use parameterized queries (placeholders or bindings). String interpolation in queries is a SQL/NoSQL injection vulnerability. The only exception is for table/column names that come from your own code (never user input).
- **Don't hardcode locale-specific formats.** Phone numbers, dates, currency, and addresses vary by country. Unless the spec explicitly says one locale only, support international formats. Validate structure, not specific country patterns.
- **Don't create multi-file projects without testing cross-file integration.** If Module A calls Module B, write a test that exercises the full A→B flow. Modules that work in isolation but break when composed are a common failure mode.
- **Don't install libraries without configuring them for the type system.** If you add a library that extends test matchers, assertion APIs, or global types, update the project's test-runner and type-checker configuration so those extensions load at the correct lifecycle point. Type errors from missing type registrations are a common verification failure.
- **Don't rely on environment-specific focus simulation without validating it.** Headless DOM and browser simulators vary in how they emit focus, blur, and keyboard navigation events. If a focus-management test is flaky or unsupported in the chosen environment, use the framework's documented lower-level focus/blur helpers or run the interaction in a real browser test.
- **Don't use platform-specific APIs without platform type declarations.** If you use runtime-specific APIs (timers, filesystem, HTTP, process signals) in a typed language, ensure the platform's type declarations are included. Without them, the code runs fine but the type checker reports errors on platform-provided methods and modules.
- **Don't concatenate strings in a loop.** Use the language's efficient string builder (StringBuilder, strings.Builder, StringIO, etc.) instead of repeated concatenation, which allocates a new string on every iteration.

### Fail Fast, Fail Loud

- Validate preconditions at function entry. Return early or throw on invalid state.
- Include context in error messages: what was expected, what was received, what the caller should do.
- Never swallow errors silently. If you catch an exception, log it with context or re-throw with added information.
- Set timeouts on all external calls — network, database, file system. No unbounded waits.

### Recovery Over Retry

When a fix attempt fails:

- Do NOT retry the identical approach. The same input produces the same output.
- Before your second attempt, analyze WHY the first attempt failed.
- If two different approaches both fail, the problem may be in your understanding of the requirement, not in the code. Re-read the acceptance criteria and the error message together.
- Refer to `prompts/failure-recovery.md` for the full recovery decision framework when you hit 2+ failures on the same check or finding.

### Type Safety at Boundaries

- Validate all data entering the system: API inputs, file reads, environment variables, database results, third-party responses.
- Do not trust data shape from external sources. Parse and validate before using.
- Use the language's type system to enforce contracts internally (generics, branded types, sum types, enums).

### Production API Defaults

When building HTTP APIs (REST, GraphQL, RPC), always include these unless explicitly scoped out:

- **CORS**: Enable cross-origin requests via middleware or manual response headers.
- **Request size limits**: Set explicit body size limits to prevent abuse.
- **UUIDs for resource IDs**: Use random UUIDs — never sequential integers (they leak information and are guessable).
- **Graceful shutdown**: Handle termination signals to close the server and release resources cleanly.
- **Module structure**: Separate route definitions from the app/server setup. Each resource gets its own route file, imported by the main app.
- **PATCH for partial updates**: If the API supports PUT (full replacement), also implement PATCH (partial update) on the same resource. PATCH merges provided fields with the existing record, preserving unmentioned fields.
- **JSON error bodies**: Every error response must be structured (JSON or equivalent) with a descriptive message field. Never return raw strings or stack traces.
- **Status code discipline**: Use the correct code for each outcome — `201` for creation, `204` for deletion, `400` for validation failure, `404` for missing resources, `409` for conflicts.
- **Pagination**: Every list endpoint must support pagination via query parameters. Return items plus metadata (`total`, `page`, `limit`), not a bare array. Default to sensible values when parameters are omitted.
- **Search and filtering**: List endpoints must support filtering by key fields via query parameters. Filter on at least the most important field for the resource.
- **Timestamps**: Auto-populate `createdAt` and `updatedAt` fields on every resource. Use ISO 8601 format.
- **Uniqueness constraints**: If a resource has a naturally unique field (ISBN, email, SKU), enforce uniqueness on creation and return `409 Conflict` on duplicates.
- **Request logging**: Log method, path, status, and duration for every request.
- **Health check**: Add a `GET /health` endpoint that returns `200 OK` with a status indicator. Standard for deployment readiness checks.

These are implied requirements for any production-quality API, even when the spec does not list them.

**API anti-patterns to avoid:**
- Don't return bare arrays from list endpoints. Always wrap in an object with metadata (items, total, page, limit). Bare arrays break pagination and make the API impossible to extend.
- Don't return plain text error messages. Always return structured error responses with a descriptive message field.
- Don't implement PUT without also implementing PATCH. Clients that only need to update one field shouldn't have to send the entire resource.
- Don't store passwords in plain text, even in demo projects. Use bcrypt/argon2/scrypt for hashing. This is a non-negotiable security baseline.

### Module & Library Deliverables

When creating a standalone library, package, or module:

- **Standard importability**: The module must be loadable via the language's standard mechanism without requiring the consumer to run a separate build step. If using a compiled language or transpiler, configure the build so installation triggers compilation automatically.
- **README.md**: Always include a README documenting what the library does, usage with code examples, and the rationale behind non-obvious design decisions.
- **Conventional naming**: Export the primary API using the most natural name for the domain. Avoid abbreviations in public exports.
- **Doc comments on all exports**: Every exported function, type, and constant must have a documentation comment following the language's convention.

### String and Character Handling

When manipulating strings at the character level:

- **Unicode-aware operations**: Use the language's proper character/grapheme abstraction (runes, code points, grapheme clusters) — not raw byte indexing. `"café"[3]` gives a byte in many languages, not the character `é`.
- Don't index strings by byte position when working with characters. Always convert to the appropriate character sequence type first.
- Don't build strings by repeated concatenation in loops. Use the language's efficient string builder (StringBuilder, Buffer, StringIO, etc.).

### Component and UI Library Defaults

When building a UI component library:

- **Strict typing**: Use the language's type system in strict mode. Define a typed props/config interface for every component.
- **Accessibility (a11y)**: Form inputs must set appropriate ARIA attributes for invalid states and error descriptions. Labels must be programmatically associated with inputs.
- **Ref forwarding**: Wrap input components with the framework's ref forwarding mechanism so consumers can attach refs.
- **Prop spreading**: Accept and forward remaining props to the root DOM element so consumers can pass classes, data attributes, and ARIA attributes.
- **Test assertion library setup**: When using test assertion libraries that extend the test framework's matchers, configure them in both the test setup file AND the type checker config. If the test runner recognizes custom matchers but the type checker doesn't, you have missing type registrations — fix them before proceeding.
- **Barrel exports**: Create an index file that re-exports all components by name.

**UI component anti-patterns to avoid:**
- Don't use custom test matchers without registering their types with the type checker. Tests may run fine while the type checker reports errors on every custom assertion — this is a configuration problem, not a code problem.
- Don't test implementation details (internal state, CSS classes). Test what the user perceives: accessible roles, labels, visible text. If a refactor breaks your tests but not the behavior, the tests are wrong.
- Don't skip accessibility testing. Every form input needs a test verifying the label-input association. Every error state needs a test verifying ARIA attributes are set. These are functional requirements.
- Don't create components without testing error/validation states. If a component accepts an error prop, test that the error renders and ARIA attributes update.
- Don't forget to test interaction callbacks. Verify that event handlers fire with the correct arguments when the user interacts.
- Don't write tests that rely on simulated Tab key navigation in DOM-only test environments — focus/blur events from keyboard simulation are unreliable. Use direct focus/blur event triggers instead.

### Data Validation Defaults

When building validation or data-checking functions:

- **Consistent return shape**: Every validator must return the same structure. Never mix return types across validators in the same library.
- **Graceful null/empty handling**: Every validator must handle null, empty, and whitespace-only inputs without throwing. Return a clear validation failure instead.
- **Internationalization**: Support international formats for phone numbers (prefixes, country-specific formats), and strip formatting characters (spaces, dashes, parentheses) before validation. Don't validate against a single country's format unless the spec explicitly requires it.
- **Formatting tolerance**: For structured inputs (credit cards, phone numbers, postal codes), accept inputs with spaces, dashes, or no separators. Normalize before applying format-specific checks.
- **Boundary and unusual inputs**: Test with very long inputs (>1000 chars), all-whitespace, unicode characters, and inputs that are technically valid but uncommon.

**Validation anti-patterns to avoid:**
- Don't write complex format validation from scratch with a naive regex. Email, URL, and phone RFCs are complex — use well-tested patterns or established libraries.
- Don't validate against a single country format. `^\d{10}$` rejects every international phone number. Strip formatting first, then check length and prefix patterns for multiple regions.
- Don't assume structured inputs arrive as clean strings. Strip non-digit characters before applying checksums or length validation.
- Don't return different shapes from different validators. If one returns `{valid, message}` and another returns `{isValid, errors}`, consumers can't use them generically. Define one return type and use it everywhere.
- Don't accept obviously invalid sentinel values. For credit cards, reject all-zeros (`0000000000000000`) and all-same-digit sequences even if they pass Luhn — no real card has this pattern. Add explicit checks for known-invalid patterns after the checksum.
- Don't confuse "before" with "strictly before" in date ranges. A same-day range (start == end) is valid — it represents a single day. Only reject when start is strictly after end.
- Don't implement phone validation that only works for one country without clearly documenting that limitation. If the spec says "phone numbers" without specifying a country, implement validation for at least US (+1), UK (+44), and generic international format (E.164).

### Resource Cleanup

- Close what you open: database connections, file handles, HTTP clients, sockets.
- Clear what you start: intervals, timeouts, event listeners, subscriptions, temporary files.
- Use the language's cleanup idiom: try-finally, defer, using/with, RAII, useEffect cleanup.
- Verify cleanup happens in error paths too — errors during processing must not leak resources acquired before the error.
- **Memory-bounded state**: For any in-memory store keyed by client/user/key (rate limiters, caches, session stores), implement automatic cleanup of expired entries via a periodic sweep. Export a destroy/close method to stop the cleanup. Without this, the store grows unboundedly under production load.

### Rate Limiter & Throttle Defaults

When building a rate limiter, throttle, or quota system:

- **Rich response metadata**: Return not just allow/deny, but also `remaining` (requests left in window), `retryAfter` (seconds until next allowed request), and `resetAt` (timestamp when the window resets). Export these in a response object, not just a boolean.
- **Multiple algorithms**: Implement at least two strategies (e.g., fixed-window + sliding-window, or token-bucket) selectable via a factory function or configuration parameter.
- **Typed API**: Type the config object and response shape explicitly using the language's type system or documentation comments.

### WebSocket & Real-Time Defaults

When building WebSocket servers, chat systems, or real-time features:

- **Validate incoming message structure** before processing. Don't assume clients send the exact shape you expect — check for required fields and reject malformed messages with an error response, not a crash.
- **Handle disconnections gracefully.** Clean up user state, room memberships, and event listeners when a client disconnects. Leaked listeners cause memory growth and ghost participants.
- **Support reconnection.** Clients disconnect frequently (network changes, sleep). Design for it: track message history so reconnecting clients can catch up, and don't treat disconnect as "user left."
- Don't hardcode a single message format key. If your protocol uses `type`, `action`, or `event`, document it clearly and validate it. Better yet, accept multiple conventions during parsing.
- Don't broadcast to disconnected sockets. Check connection state before sending, or use try/catch to handle already-closed connections.
- **Heartbeat/ping-pong**: Implement periodic health checks (ping/pong or custom heartbeat) to detect dead connections. Mark connections as alive on pong receipt, and terminate connections that miss heartbeats. Without this, half-open TCP connections accumulate silently.
- **Connection and message limits**: Set `maxPayload` (or equivalent) to reject oversized messages. Consider connection-per-IP limits or rate limiting on message frequency to prevent abuse. These are production-essential even when not specified.
- **Use structured logging, not console.log**: For servers, use a logging library or at minimum a structured log function with timestamps and levels. Raw `console.log` output is not parseable in production and mixes with other output.

### Database Defaults

When building APIs backed by databases:

- **Always use parameterized queries.** Use placeholder syntax for all user-provided values — never string interpolation. This is non-negotiable.
- **Test the full relationship lifecycle.** If one resource belongs to another: test create parent → create child with reference → get child (verify parent data included) → delete parent (verify cascade or constraint behavior).
- **Close connections in tests.** Unclosed database connections cause test hangs, file locks, and port exhaustion.
- Don't use `SELECT *` in production code. List the columns you need explicitly. `SELECT *` breaks when columns are added and pulls unnecessary data.
- Don't forget indexes on foreign key columns and frequently-filtered columns. A query on an unindexed column is a full table scan.
- Don't return raw database errors to clients. Catch constraint violations and return meaningful HTTP errors (409 for uniqueness, 400 for invalid references, 404 for missing records).

### Backward Compatibility

- Classify every change: additive (safe), modification (potentially breaking), removal (breaking).
- For breaking changes: document the migration path in the PR description.
- For API or schema changes: consider versioning or deprecation periods before removal.
- For database migrations: ensure they are reversible and test rollback.

### Codebase Stewardship

When modifying a file for your task, also:

- Remove dead code, unused imports, and unreachable branches you encounter.
- Fix stale comments that no longer match the code.
- Replace magic numbers with named constants.
- Delete commented-out code — version control is the history.

Do not expand scope to files outside the plan. Stewardship improvements in your working files should be in separate commits from feature work.

### Test Integrity

- After writing a test, verify it can fail: temporarily break the code under test and confirm the test catches it.
- If a test passes with the implementation removed or broken, the test is not testing anything — rewrite it.
- Test behavior, not implementation details. Tests should survive refactoring.
- Error-case tests are mandatory, not optional. For every happy-path test, write at least one error-case test.
- Name tests to describe the SPECIFIC behavior they verify. For bug fixes, include the symptom and fix in the name (e.g., "should reject negative prices", "removeItem should filter items not reassign array"). Test names must be grep-searchable for the behavior they guard.
- **Test isolation**: Each test must create its own fresh state. Use setup/teardown hooks (or the language equivalent) to reset state between tests. Never rely on execution order.
- **Minimum test count**: Aim for **>15 focused test cases** for any non-trivial project. For APIs, test every endpoint for both success and error cases, plus edge cases. For libraries, test every public function with at least 3 inputs each (valid, invalid, boundary).
- **Test file organization**: Distribute tests across **at least three files** by concern — unit tests for individual functions or modules, integration tests for cross-module and end-to-end flows, and edge case or error recovery tests. Don't put all tests in one or two files; dedicated edge-case and error-recovery test files ensure those areas get proper attention rather than being an afterthought in happy-path test files.
- **Use the idiomatic test HTTP client** for the framework (the one that manages server lifecycle and provides assertion helpers) rather than making raw HTTP calls in tests.
- **Structured tests**: Organize tests using named subtests or describe/it blocks. Each test case should have a clear name so failures are immediately identifiable. Table-driven or parameterized tests are preferred when testing the same function with many inputs.

**Testing anti-patterns to avoid:**
- Don't write tests that pass when the implementation is broken. After writing a test, mentally (or actually) delete the implementation and ask: would this test still pass? If yes, it's testing nothing.
- Don't test only creation without testing retrieval, update, and deletion. A test suite that only creates resources proves nothing about the system's usefulness.
- Don't test data-linked code without testing relationships. If one resource references another, test the full lifecycle including creating, linking, retrieving with the association, and cascading behavior on delete.
- Don't write 20 tests for one function and zero for another. Distribute test coverage across all public functions/endpoints. A balanced 15 tests beats a lopsided 30.
- Don't rely on test execution order. If test B depends on state from test A, test B will break when tests run in parallel or random order. Each test must set up its own state.

### Edge Case Coverage

For any non-trivial feature, systematically test these categories (where applicable):

- **Concurrency / parallel access**: Multiple simultaneous callers sharing state. Use concurrent execution primitives to test parallel requests. Use keywords like `concurrent`, `parallel`, `simultaneous` in test names so intent is searchable.
- **State expiry / reset**: Time-based state (windows, TTLs, caches) must have tests that verify cleanup, expiry, and window boundaries. Use fake/mock timers to test time-dependent behavior without real waits.
- **Multi-tenant / client isolation**: If state is keyed per client, user, or tenant, test that one key's state does not affect another.
- **Burst / stress**: Rapid successive calls beyond normal limits — verify the system degrades correctly, not silently.
- **Boundary values**: Zero, one, max, max+1, empty, null, undefined for every input.

Aim for **>15 focused test cases** per feature. Prefer many small tests over few large ones.

### Refactoring Quality

When extracting shared utilities or reducing duplication:

- **Declarative over imperative**: Prefer validation schemas/rule objects over chains of if-else. The shared module should express *what* to validate, not *how* to walk through fields.
- **Parameterize**: Shared helpers must accept configuration (max lengths, required fields, patterns) — not hardcode values from one caller.
- **Clean exports**: Use named exports, not default exports of anonymous objects.
- **Modern idioms**: Use immutable-by-default declarations. Remove debug output from production code — use a proper logger or remove it entirely.
- **Minimal callers**: After extraction, caller files should be thin — handlers should delegate to the shared utility and be short.
- **Verify adoption**: After creating a shared utility, search every caller file to confirm it actually imports and uses the shared module. Dead shared code is worse than duplication — the extraction only counts if callers use it.
