Before stopping, run a thorough adversarial review of the implementation. Do NOT stop until every step below passes.

You are in the **Review phase** — your ONLY job is to find and fix issues. The implementation was written in a prior session. Review it as a critical, adversarial reviewer who did NOT write this code.

## Step 0: Codebase Context (mandatory)

Before reviewing, gather the project context needed to judge findings. Skipping this step is the primary source of false positives — patterns that look unusual in isolation are often the project's convention.

Read in this order — stop when you have enough:

1. `CLAUDE.md` (root and any nested), `AGENTS.md`, plus any `.doyaken/rules/*.md` they reference
2. `.doyaken/doyaken.md` — especially any `## Reviewers` or project-specific review-criteria sections
3. The plan file or ticket — what was the intended scope and out-of-scope list?
4. Recent fix history of touched files: `git log --oneline --since=3.months -- <file>` for each changed file
5. Similar features in the codebase — for any pattern the change introduces (`Grep` for existing instances). Established conventions filter out "doesn't match best practice" findings.
6. `prompts/guardrails.md` — implementation discipline that informs review passes
7. `prompts/review.md` — the canonical 12-pass criteria; treat its Phase 0 preamble as part of THIS phase
8. `prompts/failure-recovery.md` and any `.debt` ledger entries — debt items already accepted should not be re-raised

Every finding the review produces MUST cite which Phase 0 artefact backs it (e.g., "AGENTS.md:47 says hooks must use `set -euo pipefail`; this hook does not"). Findings without a Phase 0 anchor are filtered.

## Step 1: Self-Review via /dkreview --single-pass (find only — no fixes yet)

Run `/dkreview --single-pass` on the changes since the base branch (use `git diff --name-only` to scope). This phase is already managed by the shell review loop, so do not invoke `/dkreview` in its default looping mode.

Read the report carefully. Do NOT fix anything yet — record all findings for the inventory in Step 4.

## Step 2: Multi-Perspective Inventory

**CRITICAL: Do NOT fix anything during this step. Only find and record.**

Perform six manual review passes in addition to the `/dkreview --single-pass` findings. For each issue, record: `[INV-N] file:line | Pass | Severity | Description`

Reference `prompts/review.md` for the full criteria behind each pass.

### Pass A: Logic & Correctness

For each acceptance criterion, trace the implementing code end-to-end:
- Happy path, failure paths, edge cases (empty/null/zero/boundary)
- Try to BREAK each function — construct inputs that cause failure, states that cause inconsistency
- Off-by-one errors, null checks
- **Concurrency & races** — shared state without synchronisation, TOCTOU gaps, async ordering, reentrancy
- **Idempotency** — does a retry/duplicate invocation cause duplicate side effects?
- **State transitions** — atomic? Rollback path on partial failure? Exhaustive state machine?
- Missing error handling — swallowed errors, generic catch-alls, empty catch blocks
- Resource cleanup — opened resources closed on both success and failure paths
- Error propagation depth — does the error carry enough context to diagnose at the top of the stack?

### Pass B: Structure, Design & Documentation

- Workarounds, hacks, TODOs without linked tickets, hardcoded values
- Unnecessary complexity or abstraction (YAGNI)
- Unused imports, dead code, commented-out code, debug artifacts (`console.log`, `print`, etc.)
- N+1 queries, unbounded loops, performance anti-patterns
- Algorithm complexity appropriate (no O(n²) where O(n log n) is achievable at scale)
- Every new public function/method has a corresponding test
- Non-obvious logic has a "why" comment; complex regexes explained; magic numbers named
- New public APIs have doc comments with parameter/return descriptions
- Coupling — does new code reach across module boundaries / bypass project layering?
- Cohesion — single, clearly-named responsibility per module/function?

### Pass C: Security

OWASP Top 10 categories explicitly (reference `prompts/review.md` Pass C for full criteria):

- **A01 Access control** — every endpoint has authn AND authz (object-level, not just session-level)
- **A02 Cryptography** — no hardcoded secrets, no weak algorithms, secrets via env/secret-manager
- **A03 Injection** — parameterised SQL, no `shell=True`/`eval` on user input, template auto-escape, no `eval`/`exec` on untrusted input
- **A04 Insecure design** — secure defaults, defense in depth, threat-model new trust boundaries
- **A05 Misconfiguration** — security headers, narrow CORS, cookie flags, no leak of stack traces / internals to clients
- **A06 Vulnerable components** — new deps pinned, CVE-checked, maintained
- **A07 Auth failures** — random expiring rotating session tokens, slow KDF for passwords, MFA / rate-limit on login
- **A08 Integrity** — webhook signature verification, safe deserialization (no pickle on untrusted input), supply-chain integrity
- **A09 Logging gaps** — security-relevant events logged; no secrets/PII in logs
- **A10 SSRF** — outbound URLs validated against allowlist
- **CSRF** — state-changing requests require token / SameSite cookie
- **TOCTOU** — auth/permission checks atomic with the operation they guard
- **PII** — minimum necessary, retention documented, no PII in logs/metrics/traces

### Pass D: Performance

- N+1 queries (loop with query inside)
- Pagination on list operations; no unbounded data
- Indexes for new query patterns
- Timeouts on all external calls
- No unbounded loops over user-controlled data
- Bulk over row-by-row, caching where read-heavy, connection pooling
- Memory profile — buffering vs streaming, GC pressure in hot paths
- Lock contention — coarse locks across I/O, deadlock risk

### Pass E: Testing

- Tests cover behaviour, not implementation
- Real schemas/types imported, not redefined in tests
- Mocks at boundaries only (external services, time, randomness, FS)
- Edge cases / failure paths tested, not just happy path
- Tests can actually fail — no tautologies, no asserting on mocked data
- Each test independent; no shared mutable state
- Each acceptance criterion has at least one test
- Regression tests for any `fix:` introduced in the change

### Pass F: Observability (production code only)

- Logs at error/state-transition points; structured if the project is structured
- Metrics for new counters/histograms/gauges where the existing code uses them
- Tracing spans for new external calls (if project uses tracing)
- Health/readiness reflects new background jobs / external dependencies
- No secrets/PII in logs/metrics/traces

If the project has no observability tooling, downgrade these findings to suggestions in the PR description.

### Pass G: Backward Compatibility (when public contract touched)

For changes to HTTP API, CLI, library API, DB schema, event/wire format, config format:

- Breaking changes called out in PR description / CHANGELOG
- Migration path documented; deprecation cycle for additive-then-remove
- DB migrations split correctly (additive before required, drops gated/last)
- No silent wire-format changes (renamed fields without aliases, removed protobuf field numbers)
- Default-value changes verified safe for existing callers
- Risky changes wrapped in feature flags

If the change does NOT touch a public contract, mark Pass G as N/A.

### Pass H: Holistic Consistency & Dependencies

Run `git diff` against the base branch and review ALL changes together:

- Naming, error handling, logging, validation patterns consistent across all changed files
- Patterns established in one file followed in all files
- Code consistent with existing codebase conventions (`Grep` for nearby precedent)
- If a contract changed (type, API, schema), trace consumers up to 3 hops deep using `Grep` — all consumers updated?
- Architectural drift — does this change collectively shift the architecture?
- Boundary integrity — external concerns (HTTP/DB/FS types) at the edge, not in domain code

## Step 3: Independent Self-Reviewer Agent

Spawn the `self-reviewer` agent to get an independent review perspective. Provide:
- The acceptance criteria from the approved plan (copy verbatim)
- The current branch name and base branch (from `git rev-parse --abbrev-ref HEAD` and the default branch)
- Which areas of the codebase have changed files (from `git diff --name-only`)

The agent reviews independently and produces its own findings report. Do NOT fix anything based on the agent's findings yet — they feed into the merged inventory in Step 4.

## Step 4: Merged Inventory Output

Merge findings from all sources into a single inventory. Deduplicate by file:line. Print the complete inventory:

```
## Findings Inventory

| # | File:Line | Source | Pass | Severity | Description |
|---|-----------|--------|------|----------|-------------|
| INV-1 | ... | dkreview | A | high | ... |
| INV-2 | ... | manual | C | medium | ... |
| INV-3 | ... | agent | B | high | ... |

Total: N findings (X high, Y medium, Z low)
```

Source values: `dkreview`, `manual`, `agent`.

- If the inventory is **empty** → skip to Step 6.
- If **non-empty** → proceed to Step 5.

### Findings Hash (for stuck detection)

After building the inventory, compute and record a findings hash so the stop hook can detect stuck loops (same findings recurring across iterations):

```bash
source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"
FINDINGS_HASH=$(echo "<sorted list of INV-N descriptions>" | shasum -a 256 | cut -c1-16)
echo "$FINDINGS_HASH" >> "$(dk_findings_file "${DOYAKEN_SESSION_ID:-$(dk_session_id)}")"
```

Replace `<sorted list of INV-N descriptions>` with the actual finding descriptions from your inventory, sorted alphabetically, one per line. If the inventory is empty, use the string "EMPTY".

### Review Result Signal

After building the inventory, write the review result so the review loop can track clean passes:

```bash
source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"
SESSION_ID="${DOYAKEN_SESSION_ID:-$(dk_session_id)}"
if [[ <total findings> -eq 0 ]]; then
  echo "CLEAN" > "$(dk_review_result_file "$SESSION_ID")"
else
  echo "FINDINGS:<total findings>" > "$(dk_review_result_file "$SESSION_ID")"
fi
```

Replace `<total findings>` with the actual count from your inventory.

## Step 5: Batch Fix and Holistic Re-verification

1. Fix all inventory items in severity order (high → medium → low).
2. After ALL fixes are applied:
   - Re-run `/dkreview --single-pass` on the **full scope** (not just modified files).
   - Re-run your manual passes (Step 2) on the **entire change set** — fixes can regress untouched files.
   - Re-spawn the self-reviewer agent to verify fixes against the FULL change set. **Maximum 3 total agent spawns** (including the initial spawn in Step 3).
3. If new findings → add to inventory, fix, and re-verify. Maximum 3 cycles.
4. After each re-verification, update the review result signal file (Step 4).

## Step 5.5: Failure Recovery Check

If Step 5 has run 2+ cycles without reaching an empty inventory:

1. Read `prompts/failure-recovery.md` for recovery strategy guidance.
2. Identify findings that keep recurring across cycles.
3. For each recurring finding, run the failure analysis to choose a strategy.
4. If any findings are accepted as DEBT, record them in the debt ledger and remove them from the inventory before checking the completion gate.

Recurring findings accepted as debt do NOT block completion, but they MUST appear in the debt ledger and the PR description.

## Step 6: Evidence Table

For each acceptance criterion, fill in the evidence table:

```
## Evidence

| # | Criterion | Implementation (`file:line`) | Test (`test:line`) | Status |
|---|-----------|------------------------------|--------------------|---------
| 1 | ... | `file:line` | `test-file:line` | MET |
| 2 | ... | `file:line` | — | NOT MET |
```

**Rules:**
- Implementation evidence must be a specific `file:line` in production code.
- Test evidence must be a specific test name or `test-file:line`.
- Prose claims ("I verified this") are NOT evidence. Cite specific locations.
- Any NOT MET or NOT FOUND entry blocks completion — go back and implement/test it.

## Completion Criteria

ALL of these must be true before you stop:
- `/dkreview --single-pass` result is PASS — OR result is PASS WITH WARNINGS and all remaining warnings are tracked as DEBT in the debt ledger
- The findings inventory from your last re-verification (Step 5) is empty — OR all remaining findings are LOW/MEDIUM severity and tracked as DEBT
- Every acceptance criterion has status MET in the evidence table (Step 6) — OR criteria with status RELAXED have a corresponding DEBT entry
- The review result signal file contains "CLEAN" (written in Step 4)
- You have run `/dkreview --single-pass` AFTER your most recent code change

If any findings are tracked as debt, output a debt summary:

```
## Debt Summary
[List each debt item from the debt ledger file]
```

Do NOT stop if any HIGH severity findings remain unresolved, or any criterion is NOT MET without a DEBT entry. Fix first, then re-audit from Step 2.

When all criteria are met, stop. The Stop hook will verify your work and provide completion instructions after sufficient consecutive clean audit passes.
