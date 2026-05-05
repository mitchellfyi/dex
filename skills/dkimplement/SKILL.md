---
name: "dkimplement"
description: "Execute the approved implementation plan with TDD discipline and completeness verification."
---

# Skill: dkimplement

Execute the approved plan, working through tasks with TDD discipline.

## When to Use

- After the user has approved the plan from `/dkplan`
- When resuming implementation work on a ticket

## Steps

### 1. Work Through Tasks

Before starting, read the implementation guardrails from `prompts/guardrails.md`. Apply them throughout.

If `.doyaken/learnings.md` exists, read it — it contains conventions, failure patterns, and interface details discovered during earlier tasks in this session that may save you time.

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

### 2. Keep `.doyaken/` in Sync

After completing each task, check if your changes require updating project documentation in `.doyaken/`:

- **New dependencies added** (package.json, go.mod, etc.) → update `.doyaken/doyaken.md` § Tech Stack or Quality Gates
- **New code patterns established** (new conventions, architectural patterns) → add or update the relevant `.doyaken/rules/*.md` file
- **Security boundaries changed** (new auth, sensitive file paths, restricted APIs) → add a guard in `.doyaken/guards/`
- **Integration added/changed** (new MCP, new CI step) → update `.doyaken/doyaken.md` § Integrations

Only update when the change is meaningful and lasting — don't document one-off implementation details.

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

When stopping for scope changes, do NOT output a completion promise (e.g., `PHASE_2_COMPLETE`). Simply halt and wait for user input. The phase audit loop will detect that the completion signal file was not written and keep the session alive. Once the user provides direction, resume implementation from where you left off.

Update the ticket via the configured tracker (see doyaken.md § Integrations) with the scope change details. If no tracker is configured, inform the user in conversation.

### 4. Self-Review Loop (Merged-Inventory Approach)

After all tasks are completed, run a two-perspective review to catch issues you may have missed:

**Step 1 — Your own inventory (find only, no fixes):**
Walk through all changed files and build a numbered findings list. For each file, check: correctness (try to break it), design (workarounds, complexity), documentation (non-obvious logic explained?), and consistency (patterns match across files). Record each issue as `[INV-N] file:line | description`. Do NOT fix anything yet.

**Step 2 — Independent review via self-reviewer agent:**
Spawn the `self-reviewer` agent with:
- The acceptance criteria from the approved plan (copy verbatim)
- The base branch and current branch name
- Which areas of the codebase have changed files

The agent reviews independently and produces its own findings report.

**Step 3 — Merge inventories:**
Combine your findings (Step 1) with the agent's findings (Step 2). Deduplicate by file:line. The union is the master inventory.

**Step 4 — Batch fix:**
Fix all items from the merged inventory in severity order (high first).

**Step 5 — Re-verify:**
Re-spawn the self-reviewer agent to verify fixes against the FULL change set (not just fixed files). If new findings emerge, fix and re-spawn. Maximum 3 total agent spawns.

**Step 6 — Evidence table:**
Before declaring PASS, produce an acceptance criteria evidence table:

| # | Criterion | Implementation (`file:line`) | Test (`test:line`) | Status |
|---|-----------|------------------------------|--------------------|---------|

Every criterion must have status MET with specific file:line evidence. Any NOT FOUND blocks completion.

If the final agent result is PASS and the evidence table has zero NOT FOUND entries: implementation is complete. When run via the `dk` wrapper, the next phase (Verify & Commit) follows automatically after you signal completion.

### 5. Chain to /dkreview

After the self-review loop passes (Step 4 produces PASS with zero NOT FOUND entries), invoke `/dkreview` using the Skill tool as a final independent gate. The phase audit loop checks that `/dkreview` was run after the last code change.

If `/dkreview` returns NEEDS ATTENTION, fix the findings and re-invoke `/dkreview`. Maximum 3 review cycles.

## Scope Boundaries

During implementation (Phase 2), you MUST NOT:
- Run `git commit` or `git push` (that is Phase 4: Verify & Commit)
- Create or modify pull requests via `gh pr` (that is Phase 5: PR)
- Mark tickets as done or in-review (that is Phase 6: Complete)
- Create new branches (the worktree branch was created by `dk`)

You SHOULD:
- Implement all planned tasks with TDD
- Run quality checks on changed files after each task (format, lint, typecheck)
- Run the self-review loop (Step 4) and chain to `/dkreview` (Step 5)
- Update `.doyaken/` project docs if your changes require it

## Notes

- Stay in scope. Only implement what's in the plan.
- If you think of improvements outside the plan, note them but don't implement them.
- Keep the user informed at natural milestones (e.g., "3 of 5 tasks complete").
