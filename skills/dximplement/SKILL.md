---
name: "dximplement"
description: "Execute the approved implementation plan with TDD discipline and completeness verification."
---

# Skill: dximplement

Execute the approved plan, working through tasks with TDD discipline.

## When to Use

- After the user has approved the plan from `/dxplan`
- When resuming implementation work on a ticket

## Steps

### 1. Work Through Tasks

Before starting, read the implementation guardrails from `prompts/guardrails.md`. Apply them throughout.

If `.dex/memory/index.md` exists, read it and load only the memory entries
whose scope matches the approved plan, changed files, or current phase. Treat
memory as useful context, not proof: re-check current code before relying on an
old lesson.

Before editing UI-affecting files, decide whether the approved plan changes browser UI, visual layout, styles, routes, or user flows. If it does, invoke `dxuicapture` immediately for before evidence and add the generated `visual-evidence.md` manifest path to your working notes. Capture the representative routes/flows you expect to change. If UI files have already been modified before the baseline can be captured, do not synthesize a before state; record `Before capture: unavailable — UI was already modified before capture` in the manifest and final evidence.

For each task in the approved plan:

1. `TaskUpdate(task_id, "in_progress")`
2. Implement the task:
   - Follow the patterns and conventions established in the codebase (check AGENTS.md, README.md, and existing code in the area you're modifying).
   - If the project has code generation (API clients, DB types, OpenAPI specs), run the generator after schema or API changes.
3. Follow **Red-Green-Refactor** (TDD) where the project has a test suite:
   - Write a failing test first.
   - Write the minimum code to make it pass.
   - Refactor while keeping tests green.
4. After completing the task, run deterministic quality checks (format, lint, typecheck) on changed files only. Fix issues before moving to the next task — this prevents error accumulation across tasks. Run the language's type checker and static analysis tool. If tests use libraries that extend the assertion framework, verify the type checker also recognizes those extensions. These checks must pass — do not defer them to the end.
5. Codebase stewardship: if you encounter dead code, stale comments, or outdated references in files you are modifying, clean them up — but do not expand scope to files outside the plan.
6. `TaskUpdate(task_id, "completed")`

### 2. Keep `.dex/` in Sync

After completing each task, check if your changes require updating project documentation in `.dex/`:

- **New dependencies added** (package.json, go.mod, etc.) → update `.dex/dex.md` § Tech Stack or Quality Gates
- **New code patterns established** (new conventions, architectural patterns) → add or update the relevant `.dex/rules/*.md` file
- **Security boundaries changed** (new auth, sensitive file paths, restricted APIs) → add a guard in `.dex/guards/`
- **Integration added/changed** (new MCP, new CI step) → update `.dex/dex.md` § Integrations
- **Durable repo lesson discovered** (repeated failure, review pattern, or workflow rule) → run `/dxsync --dry-run` or record the candidate in the implementation summary so `dx sync` can promote it through a reviewable `.dex/memory/domains/` diff

Only update when the change is meaningful and lasting — don't document one-off implementation details.
Do not create `.dex/learnings.md`; raw observations are not trusted memory.

### 3. Handle Scope Changes

If during implementation you discover:
- **A requirement is ambiguous**: STOP. Present 2-3 options with trade-offs. Ask the user to choose.
- **The plan needs to change**: STOP. Explain the change and its impact. Ask for approval.
- **A dependency is blocked**: STOP. Document the blocker. Ask how to proceed.

**When running non-interactively** (no user to respond — e.g., `-p` mode, automated harness, or if the user is unavailable): do NOT stop on ambiguity. Instead, choose the **most comprehensive reasonable interpretation** and document your assumptions in a README. Specifically:
- For algorithmic or strategic choices: implement **at least two approaches** (e.g., fixed-window + sliding-window + token-bucket for rate limiting, multiple sort algorithms, etc.) and let the caller choose via a factory or configuration parameter.
- For data modeling: default to **per-client/per-key isolation** and **configurable limits** with sensible defaults.
- For scope: when the prompt is vague, build a complete library with a clean exported API, comprehensive tests covering edge cases, and a README explaining design decisions and usage.
- For REST APIs: always include the production API defaults from guardrails.md (pagination, search/filter, PATCH, timestamps, uniqueness constraints, health check, request logging) even when not explicitly requested. These are expected in any production API.
- For stateful systems (caches, rate limiters, session stores): implement automatic memory cleanup of expired entries and export a destroy/close method for resource cleanup.
- For HTTP middleware: if building a library that could be used as middleware, export a middleware adapter alongside the core API.
- For ALL projects: write tests even if the prompt does not ask for them. Aim for **>20 test cases** spread across **at least three test files** covering: every public function/command with valid input, every public function/command with invalid/edge input (empty, null, boundary, unicode), error paths, and at least one concurrency or stress test. Use the language's idiomatic test organization (named subtests, describe/it blocks, table-driven tests, etc.).
- For CLI tools: test every command for both success and error cases. Test with empty input, non-existent IDs, corrupted data files, and missing arguments. Organize tests into **at least three files**: (1) unit tests for individual modules/functions, (2) integration tests for end-to-end command flows, (3) edge case and error recovery tests (corrupted data, boundary values, concurrent access).

**Non-interactive mistakes to avoid** (these cause the most quality failures):
- Don't declare "done" without running the test suite and seeing all tests pass. If tests fail, read the error output and fix the root cause. "Tests should pass" is not the same as "tests pass."
- Don't install a library that extends the test framework or type system without configuring the type checker to recognize it. If tests run fine but the type checker reports errors on assertion matchers, you have a type registration problem — fix it.
- Don't write 20 tests for one function and zero for another. Spread test coverage evenly across all public APIs, commands, or functions.
- Don't create multiple interacting modules without an integration test. If Module A calls Module B, write a test that exercises A→B together, not just each in isolation.
- Don't assume the first API design you choose is stable. After implementing, run the tests — if the tests import your module and call your functions, the API is real. If you change function signatures after writing tests, update the tests too.
- Don't save the README or other required documentation for the final task on library/module work. Draft it in the first half of the task list once the public API is stable enough to describe; an unexpected retry or wall-clock limit should not leave the deliverable undocumented.
- Don't postpone creating the primary deliverable. When the prompt names a specific output (file path, package layout, document), create a minimal but runnable version at the exact named path as the first concrete artifact, before extensive scaffolding, planning, or test setup. A time-bounded or interrupted run that never produces the named output scores zero on correctness no matter how good the surrounding work is.
- Don't write tests against a deliverable that does not yet exist at its target path. Establish the implementation module or file at the path the prompt named first (even as a thin working skeleton), then layer tests against it. Tests importing a path that was never created run nothing.

When stopping for scope changes, do NOT output a completion promise (e.g., `PHASE_2_COMPLETE`). Simply halt and wait for user input. The phase audit loop will detect that the completion signal file was not written and keep the session alive. Once the user provides direction, resume implementation from where you left off.

Update the ticket via the configured tracker (see dex.md § Integrations) with the scope change details. If no tracker is configured, inform the user in conversation.

### 4. Implementation Inventory

After all tasks are completed, run a focused implementation inventory to catch
issues before the dedicated Phase 3 review loop takes over.

**Step 1 — Build the inventory (find only, no fixes):**
Walk through all changed files and build a numbered findings list. For each file, check: correctness (try to break it), design (workarounds, complexity), documentation (non-obvious logic explained?), and consistency (patterns match across files). Record each issue as `[INV-N] file:line | description`. Do NOT fix anything yet.

**Step 2 — Batch fix:**
Fix all items from the inventory in severity order (high first).

**Step 3 — Re-verify:**
Re-run the inventory against the FULL change set (not just fixed files). If new
findings emerge, fix them and re-run the inventory.

**Step 4 — Evidence table:**
Before declaring PASS, produce an acceptance criteria evidence table:

| # | Criterion | Implementation (`file:line`) | Test (`test:line`) | Status |
|---|-----------|------------------------------|--------------------|---------|

Every criterion must have status MET with specific file:line evidence. Any NOT FOUND blocks completion.

Use a plain GitHub Markdown table or short bullets. Do not use Unicode box-drawing tables; they wrap poorly in Claude Code transcripts.

Completion is blocked unless every acceptance criterion and verification gate is exactly `MET`. Treat `NOT MET`, `NOT FOUND`, `DEFERRED`, `SKIPPED`, `BLOCKED`, `N/A`, "CI will cover it", "port busy", "tool unavailable", or equivalent as a blocker unless the user explicitly approved a plan change. If a local port is busy, use another port or stop the conflicting process and rerun the required check; do not defer required Phase 2 verification to future CI.

Before declaring PASS, confirm that no implementation helper, UI capture, test
runner, dev server, or other Phase 2 background process is still in flight.

If the final inventory is empty and the evidence table has zero NOT FOUND
entries: implementation is complete. When run via `dx`, the next phase (Review)
follows automatically after the Stop hook audits this phase.

### 5. Final Implementation Checks

After the implementation inventory passes and the evidence table has zero NOT
FOUND entries, run the project's relevant deterministic checks one more time and
update the evidence table with final pass/fail status. Do not invoke `/dxreview`
from Phase 2; the dedicated Phase 3 `/dxreviewloop` handles adversarial review
after implementation is complete.

### 6. UI Capture Evidence

If the change affects browser UI, invoke the `dxuicapture` skill before Phase 2 completes. Ensure the evidence includes:

- before screenshots/traces captured before UI edits, or an explicit before-unavailable reason
- after desktop/mobile screenshots for the same representative routes/views
- Playwright traces and browser logs for captured routes/views
- video for interactive flows
- the `visual-evidence.md` manifest path under Dex's artifact directory

Artifacts must stay in Dex's artifact directory and must not be committed. Add absolute links to the manifest, screenshots, videos, traces, and logs to the implementation evidence.

If no browser UI changed, add `UI capture: N/A — no UI-affecting files changed` to the evidence.

### 7. Mark Phase 2 Ready

When running inside a terminal `dx` lifecycle (`DEX_SESSION_ID` is present), write the Phase 2 ready marker only after all of these are true:

- Every planned task is complete.
- Every acceptance criterion and verification gate is exactly `MET`.
- No evidence entry is deferred, skipped, blocked, missing, or delegated to future CI unless the user approved a plan change.
- Final deterministic checks passed locally.
- Required UI capture evidence is linked, including before/after evidence or a before-unavailable reason, or UI capture is explicitly N/A.
- No Phase 2 background processes or long-running commands are still in flight.

```bash
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"
touch "$(dx_phase_ready_file "${DEX_SESSION_ID:-$(dx_session_id)}" 2)"
```

Do not write this marker early. The Stop hook ignores `PHASE_2_COMPLETE` without it.

## Scope Boundaries

During implementation (Phase 2), you MUST NOT:
- Run `git commit` or `git push` (that is Phase 4: Verify & Commit)
- Create or modify pull requests via `gh pr` (that is Phase 5: PR)
- Mark tickets as done or in-review (that is Phase 6: Complete)
- Rename the lifecycle branch or move ticket status — Phase 0 (Setup) already handled that. If you notice it wasn't done, surface that to the user rather than fixing it ad-hoc.
- Create new branches (the worktree branch was created by `dx`)

You SHOULD:
- Implement all planned tasks with TDD
- Run quality checks on changed files after each task (format, lint, typecheck)
- Run the self-review loop (Step 4) and final implementation checks (Step 5)
- Run `/dxuicapture` for UI-affecting changes before UI edits and after implementation, then link the artifacts
- Update `.dex/` project docs if your changes require it

## Notes

- Stay in scope. Only implement what's in the plan.
- If you think of improvements outside the plan, note them but don't implement them.
- Keep the user informed at natural milestones (e.g., "3 of 5 tasks complete").
