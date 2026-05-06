---
name: "dkreview"
description: "Run an adversarial implementation review using tooling, semantic analysis, dependency tracing, and acceptance criteria verification."
---

# Skill: dkreview

Agentic implementation review that combines deterministic tooling with semantic analysis, dependency tracing, and acceptance criteria verification.

## When to Use

- After completing implementation, before running `/dkverify`
- When you want to catch issues in your own code before pushing

## Dispatch Mode

`/dkreview` is the user-facing review command. When invoked directly by a user
without `--single-pass` or `--no-loop`, immediately invoke the Skill tool with
skill: `dkreviewloop`, then stop. This gives users the 3-clean-pass review loop
without requiring them to remember a separate command.

Run the single-pass review instructions below only when one of these is true:

- The invocation includes `--single-pass` or `--no-loop`
- The caller explicitly says this review is being run from `/dkreviewloop`
- The caller explicitly says this review is being run by Doyaken Phase 3's
  shell-managed review loop

If you are unsure whether this is a direct user invocation or an internal loop
iteration, prefer the loop and invoke `dkreviewloop`.

## Overview

Four phases, executed sequentially. Phase 0 (Codebase Context) is a sub-step of Phase 0 — it runs FIRST so all subsequent passes have the context they need.

0. **Deterministic Foundation** — codebase context + machine checks establish a clean baseline
1. **Review Plan** — assign review depth and applicable passes per file
2. **Semantic Review** — full-file context, dependency tracing, convention checks (12 passes A-L)
3. **Fix and Re-Review Loop** — fix findings, re-check, repeat (max 3 iterations)

---

## Phase 0: Deterministic Foundation

Run machine checks first. Don't waste semantic review effort on issues linters catch.

### 0.0 — Codebase Context (mandatory)

Before scope analysis, gather the context you need to judge findings. **Skipping this is the primary source of false positives** — what looks like a bug in isolation is often an established pattern when read in context.

Read in this order — stop early when you have enough to judge the change:

1. `CLAUDE.md` (root and any nested), `AGENTS.md` — language boundaries, naming, error-handling, architecture rules
2. `.doyaken/rules/*.md` files referenced from CLAUDE.md / AGENTS.md
3. `.doyaken/doyaken.md § Reviewers` and any project-specific review-criteria sections — some projects extend or override the defaults
4. The plan file, ticket, or commit messages — what was the intended scope? What was explicitly out of scope?
5. Recent fix history of the touched files — `git log --oneline --since=3.months -- <file>` for each deep-review file. Recent `fix:` commits = fragile area, apply extra scrutiny.
6. Similar code in the repo — for any pattern the change introduces, `Grep` for existing instances. If pattern X is established (3+ occurrences) and the change introduces Y instead, that's a finding. If the change uses an "unusual" pattern that turns out to match an established convention, the finding is filtered.
7. `prompts/failure-recovery.md` and any `.debt` ledger files — debt items already accepted should not be re-raised

When you flag a finding, the report MUST cite which Phase 0 artefact you checked (e.g., "AGENTS.md says all hooks must use `set -euo pipefail`; this hook does not"). Findings without a Phase 0 anchor are downgraded.

### 0.1 — Scope Analysis

Detect the default branch using the shared library function (see `lib/git.sh`):

```bash
source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"
DEFAULT_BRANCH=$(dk_default_branch)
git diff origin/$DEFAULT_BRANCH...HEAD --stat
git diff origin/$DEFAULT_BRANCH...HEAD --name-only
git log origin/$DEFAULT_BRANCH..HEAD --oneline
```

Classify every changed file by its role in the project (e.g., business logic, test, config, migration, documentation, generated code). Use the project's directory structure and naming conventions to determine categories.

Count files and lines changed per category. This drives review depth in Phase 1.

### 0.1a — Auto-Skip Check

If the change is trivial, skip the full semantic review (Phases 1-2) and go straight to Phase 0.2 deterministic checks only:

**Skip semantic review when ALL of these are true:**
- Total lines changed < 20
- Only config, docs, or non-logic categories (no business logic)
- No new files created
- No security-sensitive files touched — specifically: any file whose path matches `*auth*`, `*permission*`, `*policy*`, `*secret*`, `*token*`, `*credential*`, `*session*`, `*middleware*`, `*guard*`, `*rls*`, `*acl*`, `*.env*`; any migration file; any file under directories like `security/`, `access/`, `iam/`

**Examples that skip:** README typo fix, package version bump, config value change, `.gitignore` update.

**Examples that DON'T skip:** New endpoint (even if small), migration, test changes, any file matching the security-sensitive patterns above, any new middleware or policy file.

### 0.2 — Targeted Deterministic Checks

Discover the project's quality tools (same approach as `/dkverify`) and run checks **only for packages with changed files** (not the entire repo).

For each tool discovered (formatter, linter, type checker, test runner), run it scoped to the affected area. Record failures as findings.

### 0.3 — Generated Code Freshness

If the project uses code generation (detectable from Makefile targets, package.json scripts, or generator config files), and any source files that feed the generator changed, run the generator and check for uncommitted changes. Stage any changes and record as a finding.

---

## Phase 1: Review Plan Generation

For each changed file, assign review depth and applicable passes. This is internal — don't present to the user.

### Review Depth

**Deep** (full-file read + dependency trace + git history):
- Business logic (services, use cases, core modules)
- Database queries (repositories, migrations, queries)
- Security code (auth, access control, middleware)
- New files (no prior context to lean on)

**Shallow** (diff-only scan):
- Config changes (package manifests, tool configs, environment examples) — still apply **Pass C (Security)** to dependency changes that could introduce vulnerabilities
- Import reordering or formatting-only changes
- Documentation files
- Generated code

### Pass Assignment

Select which review passes apply per file. If the plan includes **task risk levels** (from `/dkplan`), use them to adjust review depth:

**Risk-proportional pass selection** (when task risk metadata is available):

| Risk | Passes | Notes |
|------|--------|-------|
| **LOW** | A, F, H | Correctness, Style, Acceptance Criteria only |
| **MEDIUM** | A, B, C, E, F, G, H, J | Skip D (Performance), I (Documentation), K (Observability), L (BC) unless they apply to the touched files |
| **HIGH** | All 12 passes | Full dependency trace + git history context |

If no risk metadata is available, fall back to the file-based assignment below.

**File-based pass assignment** (default):

| Pass | Applies when |
|------|-------------|
| **A: Correctness & Logic** | Business logic, services, data access, anything with branching or async |
| **B: Design & Architecture** | New files, refactored code, complex changes, new boundaries |
| **C: Security** | Auth, access control, external APIs, data access, file uploads, deserialization |
| **D: Performance** | Database queries, list endpoints, loops, external calls, hot paths |
| **E: Testing** | Test files, plus any production code with new branches |
| **F: Style & Conventions** | All files |
| **G: Dependency Consistency** | Types, schemas, API contracts, migrations, anything imported from elsewhere |
| **H: Acceptance Criteria** | All production code (if ticket context available) |
| **I: Documentation Quality** | All files with non-obvious logic; new public APIs |
| **J: Holistic Consistency** | All changed files (cross-file pass) |
| **K: Observability** | Production code paths (not docs/tests); new error paths or background jobs |
| **L: Backward Compatibility** | Public APIs, CLI, DB schema, event/wire formats, config formats, defaults |

---

## Phase 2: Semantic Review

Read the review criteria from `prompts/review.md` for the 12-pass criteria (A-L), the Phase 0 codebase-context preamble, the Observe-Verify-Conclude protocol, and confidence scoring guidelines. Project-specific extensions live in `CLAUDE.md`, `AGENTS.md`, and `.doyaken/doyaken.md`.

### 2.0 — Cross-File Overview Scan

Before reviewing individual files, scan ALL changed files at the diff level to build a mental model of the full change:

- What is the overall shape of this change? (new feature, refactor, bug fix, etc.)
- What contracts or interfaces cross file boundaries?
- What assumptions does File A make about File B?
- Are there cross-file patterns that should be consistent?
- Does the change introduce a new pattern or follow an existing one? (`Grep` for similar features)

Record cross-file assumptions — these will be verified in Phase 2.2-2.3 and 2.8.

### 2.1 — Full-File Read

For every changed file, `Read` the **entire file** — not just the diff. Evaluate the change within its full context. The diff tells you _what_ changed; the full file tells you whether the change _fits_.

### 2.1a — Observation Before Conclusion

For each file under deep review, record observations before forming conclusions:

1. **Observe** — Read the file and note what the code does. Write neutral statements, not judgments. "Function X calls Y without null check" not "Bug: missing null check."
2. **Challenge** — For each observation, ask: is this intentional? Does the caller handle it? Does the type system prevent it? Is there a project convention that allows it?
3. **Conclude** — Only classify surviving observations as findings.

This sequence exists because code review is susceptible to motivated reasoning — forming a conclusion ("this is a bug") then constructing justification backward. Observations first, conclusions second.

### 2.2 — Dependency Tracing (multi-hop)

For each changed function, class, type, or export, trace consumers up to 3 hops deep:

1. **Hop 1:** `Grep` for imports referencing the changed file → verify each direct consumer is consistent
2. **Hop 2:** For each direct consumer that re-exports or wraps the changed entity, `Grep` for ITS consumers → verify consistency
3. **Hop 3:** Continue one more level if hop 2 revealed re-exports, or stop at leaf consumers (non-exported code)

Track the chain: `[Changed] X → [Hop 1] Y ✓ → [Hop 2] Z ✓`

Answer: **"Are all consumers of this changed API updated consistently, including transitive consumers?"**

If a function signature changed but callers weren't updated → finding.
If a type added a field but serializers don't map it → finding.
If a type narrowed but consumers still pass the old shape → finding.
If a transitive consumer depends on the old behavior → finding.

### 2.3 — Cross-Reference Consistency

When files that define contracts (types, schemas, API definitions, database models) change, verify that all dependent code is consistent. Use `Grep` to find imports of the changed file, then verify each consumer handles the change.

### 2.4 — Git History Context

For deep-review files only:

```bash
git log --oneline -10 -- <file>
```

If recent `fix:` commits exist → flag as **fragile area**. Apply extra scrutiny on correctness (Pass A).

### 2.5 — Acceptance Criteria Verification

If ticket context is available (from `/dkplan` or `/doyaken` — check task list or plan file):

For each acceptance criterion:
1. Verify production code implements it (trace to specific file:line)
2. Verify a test validates it (trace to specific test case)

Flag unmet criteria as **severity: high** findings.

### 2.6 — Convention Checks

Semantic layer on top of linting — catches what machines miss:

- **Architecture violations** — bypassing abstraction layers, cross-module coupling that breaks the project's boundaries
- **Missing error handling** — unhandled exceptions in new code paths, missing error propagation
- **Performance anti-patterns** — unbounded queries, N+1 patterns in loops, missing pagination on list operations
- **Security gaps** — unprotected endpoints, sensitive data in logs or error messages, missing input validation at system boundaries
- **Test quality** — mocking internals instead of testing behaviour, missing edge case coverage, hardcoded test data

### 2.7 — Documentation Quality

Execute Pass I from `prompts/review.md` on all files with non-obvious logic:

- Functions with complex control flow need "why" comments
- New public APIs need doc comments
- Complex regexes, magic numbers, and non-trivial algorithms need explanation
- Architectural decisions of substance captured in ADR / decisions log
- User-facing changes reflected in CHANGELOG / README

### 2.8 — Observability

Execute Pass K from `prompts/review.md` on production code paths:

- Logs at error/state-transition points, structured if the project is structured
- Metrics for new counters/histograms/gauges where the existing code has them
- Tracing spans for new external calls (if the project uses tracing)
- Health/readiness reflects new background jobs and external dependencies
- No secrets/PII in logs/metrics/traces

If the project has no observability tooling, downgrade these findings to suggestions.

### 2.9 — Backward Compatibility

Execute Pass L from `prompts/review.md` if the change touches a public contract (HTTP API, CLI, library API, DB schema, event/wire format, config format):

- Breaking changes called out in PR description / CHANGELOG
- Migration path documented
- DB migrations split correctly (additive before required, drops gated/last)
- No silent wire-format changes (renamed fields without aliases, removed protobuf field numbers, etc.)
- Default-value changes verified safe for existing callers
- Risky changes wrapped in feature flags

### 2.10 — Holistic Consistency

Execute Pass J from `prompts/review.md` across ALL changed files as a set:

- Review the cross-file assumptions recorded in Phase 2.0
- Check naming, error handling, logging, and pattern consistency across all changed files
- Detect architectural drift — does this change collectively shift the architecture in a way no individual file makes obvious?
- Boundary integrity — external concerns (HTTP/DB/FS types) stay at the edge, not in domain code
- This pass catches issues invisible when reviewing files individually

---

## Phase 3: Fix and Re-Review Loop

**Maximum 3 iterations.** After each fix round:

1. Fix all findings — auto-fixable immediately, judgment-required with best attempt
2. Re-run deterministic checks on affected files (not the full suite)
3. Re-run semantic review on **ALL changed files from Phase 0.1 scope** — not just files modified by the fix. Fixes can introduce regressions in files that were not directly modified. Specifically check for:
   - Type mismatches introduced by fix-side signature changes
   - Behavioral changes visible to callers that were not updated
   - Test assertions that no longer match fixed behavior
   - Broken cross-file consistency (naming, patterns, error handling)
4. New findings → add to list, continue loop
5. No new findings → exit loop

**On 2nd iteration with recurring findings:** Read `prompts/failure-recovery.md` and run the failure analysis on each finding that appeared in the previous iteration. Log your recovery decision before proceeding. If findings are accepted as debt, record them in the debt ledger and remove them from the active findings list.

After 3 iterations, report remaining findings and proceed to `/dkverify`.

---

## Output

Print a structured report at the end:

```
## Self-Review Report

### Scope
- Files changed: X (by category breakdown)
- Review depth: X deep, Y shallow

### Deterministic Checks
- Format: PASS | Lint: PASS | Typecheck: PASS | Tests: PASS

### Findings (confidence >= 50 only)
| # | Severity | Confidence | File:Line | Pass | Issue | Fix Applied |
|---|----------|------------|-----------|------|-------|-------------|

### Filtered Out
- X finding(s) below confidence threshold (< 50)

### Dependency Trace
- [Changed] foo.ts → [Checked] bar.ts ✓, baz.ts ✓

### Acceptance Criteria
- [x] Criterion 1: implemented + tested
- [ ] Criterion 2: NOT FOUND

### Iterations: N/3
### Result: PASS | PASS WITH WARNINGS | NEEDS ATTENTION
```

**Result meanings:**
- **PASS** — no findings remain, all acceptance criteria met
- **PASS WITH WARNINGS** — minor findings remain (style, naming) but no correctness/security/performance issues
- **NEEDS ATTENTION** — findings remain after 3 iterations, or acceptance criteria unmet. Proceed to `/dkverify` but flag to the user.

## Notes

- This skill is for reviewing your own work-in-progress, not for reviewing PRs or others' code.
- Focus on issues you can actually fix — don't flag existing patterns in the codebase.
- Be honest about your own code. The goal is to ship high-quality work, not to rubber-stamp it.
- Deterministic checks run here AND in `/dkverify`. Self-review fixes issues; verify confirms they're fixed. The duplication is intentional.
