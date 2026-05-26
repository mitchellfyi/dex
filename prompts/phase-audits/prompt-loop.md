Before stopping, audit your work against the original prompt. Do NOT stop until every step below passes.

If you haven't already, read the implementation guardrails from `prompts/guardrails.md` — they inform what to look for in the review passes below.

## Step 1: Acceptance Criteria Extraction

Your original task prompt is reprinted above (under "Original Task Prompt"). If it is not visible, read it from the file path in your system prompt using the Read tool, or check `~/.claude/.dex-loops/` for a `.prompt` file matching your session.

List every distinct acceptance criterion as a numbered list — this list is your contract for all subsequent steps.

For each criterion, classify it:
- **Functional** — what the code must do
- **Non-functional** — error handling, edge cases, performance, security
- **Implied** — criteria not stated explicitly but necessary for correctness (e.g., input validation, cleanup on failure)
- **Contextual** — specific files, APIs, patterns, or conventions mentioned or referenced

If the prompt references external context (a ticket, a URL, a document), ensure you have incorporated it into the acceptance criteria.

Verify your understanding against the guardrails:
- Can you answer the five understanding-check questions from `prompts/guardrails.md`?
- Have you identified the failure modes and resource cleanup needs?

**Session classification:** Run `git diff --name-only` and `git status --porcelain`. If any production code files were created or modified (not just docs/config), this is a **code-change session**. Otherwise it is a **non-code session**. This classification determines whether the `/dxreview --single-pass` review wave runs in subsequent steps.

## Step 2: Self-Review via /dxreview --single-pass (code-change sessions only)

**Skip this step if this is a non-code session.**

Run `/dxreview --single-pass` on your changes (if you haven't already since your last code change). This audit loop already owns repetition, so do not invoke `/dxreview` in its default looping mode here. The single-pass review wave handles deterministic checks, issue harvest, verifier triage, batch fixes, and targeted recheck.

Read the report carefully. If the review wave applied fixes, restart this audit from Step 1 so the acceptance criteria and current diff are fresh. If findings remain, record them for the inventory in Step 5.

## Step 3: Multi-Perspective Inventory

**CRITICAL: Do NOT fix anything during this step. Only find and record.**

Perform four manual review passes over ALL your changes, in addition to any `/dxreview --single-pass` findings from Step 2. For each issue, record: `[INV-N] file:line | Pass | Severity | Description`

Reference `prompts/review.md` for the full criteria behind each pass.

### Pass A: Logic & Correctness

For each acceptance criterion from Step 1, trace the implementing code end-to-end:
- Happy path, failure paths, edge cases (empty/null/zero/boundary)
- Try to BREAK each function — construct inputs that cause failure, states that cause inconsistency
- Off-by-one errors, null checks, race conditions
- Missing error handling — swallowed errors, generic catch-alls, empty catch blocks
- Resource cleanup — are opened resources closed on both success and failure paths?

### Pass B: Structure, Design & Documentation

- Workarounds, hacks, TODOs, or hardcoded values?
- Unnecessary complexity or abstraction?
- Unused imports, dead code, commented-out code?
- N+1 queries, unbounded loops, performance anti-patterns?
- Does every new public function/method have a corresponding test?
- Non-obvious logic has a "why" comment? Complex regexes explained? Magic numbers named?
- New public APIs have doc comments?

### Pass C: Security

Review all changes for security gaps (reference `prompts/review.md` Pass C for full criteria):
- New endpoints/routes have appropriate authentication and authorization?
- No hardcoded secrets, credentials, or API keys?
- No sensitive data in logs, error messages, or API responses?
- Input validated at system boundaries?
- Database queries use parameterized queries — no string interpolation?
- Secure defaults — features restricted by default, not permissive?

### Pass D: Holistic Consistency & Dependencies

Run `git diff` against the base branch and review ALL changes together:
- Naming, error handling, and logging consistent across all changed files?
- Patterns established in one file followed in all files?
- Code consistent with existing codebase conventions?
- If you changed a contract (type, API, schema), trace consumers up to 3 hops deep using `Grep` — are all consumers updated?

## Step 4: Merged Inventory Output

Merge findings from all sources into a single inventory. Deduplicate by file:line. Print the complete inventory:

```
## Findings Inventory

| # | File:Line | Source | Pass | Severity | Description |
|---|-----------|--------|------|----------|-------------|
| INV-1 | ... | dxreview | A | high | ... |
| INV-2 | ... | manual | C | medium | ... |

Total: N findings (X high, Y medium, Z low)
```

Source values: `dxreview`, `manual`.
If `/dxreview --single-pass` did not run (non-code session), omit that source.

- If the inventory is **empty** → skip to Step 6.
- If **non-empty** → proceed to Step 5.

### Findings Hash (for stuck detection)

After building the inventory, compute and record a findings hash so the stop hook can detect stuck loops:

```bash
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"
FINDINGS_HASH=$(echo "<sorted list of INV-N descriptions>" | shasum -a 256 | cut -c1-16)
echo "$FINDINGS_HASH" >> "$(dx_findings_file "${DEX_SESSION_ID:-$(dx_session_id)}")"
```

Replace `<sorted list of INV-N descriptions>` with the actual finding descriptions from your inventory, sorted alphabetically, one per line. If the inventory is empty, use the string "EMPTY".

## Step 5: Batch Fix and Holistic Re-verification

1. Fix all inventory items in severity order (high → medium → low).
2. After ALL fixes are applied:
   - **Code-change sessions:** re-run `/dxreview --single-pass` on the **full scope** (not just modified files).
   - Re-run your manual passes (Step 3) on the **entire change set** — fixes can regress untouched files.
3. If new findings → add to inventory, fix, and re-verify. **Maximum 3 cycles.**
4. Do NOT proceed with known findings. If findings persist after 3 cycles, continue fixing — the iteration limit in the stop hook is the only safety valve, not this step.

## Step 6: /dxverify Quality Pipeline (code-change sessions only)

**Skip this step if this is a non-code session.**

Run /dxverify to execute the full quality verification pipeline:
1. Format — auto-fix formatting issues
2. Lint — auto-fix where possible, manual fix where not
3. Type-check — fix type errors
4. Code generation — if applicable, run generators and check for uncommitted changes
5. Test — run the full test suite

If any check fails, fix and re-run (max 3 retries per check type). After 3 failures on the same check, escalate to the user.

All checks must pass before proceeding to Step 7.

## Step 7: Evidence Table

Before filling the table, list every concrete output the prompt explicitly named — file paths, directory structures, required artifacts — and confirm each exists at the exact path specified. Use `git status`, `git ls-files`, and directory listings rather than recalling from memory. A required output that is missing, empty, or located at a different path is a blocking defect: return to implementation and produce the artifact before continuing. Do not paper over the gap with a note in the table.

For each acceptance criterion from Step 1, fill in the evidence table:

```
## Evidence

| # | Criterion | Implementation (`file:line`) | Test (`test:line`) | Status |
|---|-----------|------------------------------|--------------------|---------|
| 1 | ... | `file:line` | `test-file:line` | MET |
| 2 | ... | `file:line` | — | NOT MET |
```

**Rules:**
- Implementation evidence must be a specific `file:line` in production code.
- Test evidence must be a specific test name or `test-file:line`. For non-code acceptance criteria (research, analysis, documentation), write `N/A` with a brief justification.
- Prose claims ("I verified this") are NOT evidence. Cite specific locations.
- Any NOT MET entry blocks completion — go back and implement/test it.

## Step 8: `.dex/` Freshness (if applicable)

If the project has a `.dex/` directory, check whether your changes introduced:
- New dependencies or tooling changes → `.dex/dex.md` updated?
- New code patterns or conventions → relevant `.dex/rules/*.md` updated?
- New security boundaries or sensitive paths → `.dex/guards/` updated?
- Durable repo lessons that should help future agents → `/dxsync --dry-run`
  run, or candidate observations recorded in the final summary for `dx sync`

If updates are needed but missing, make them now.
Do not create `.dex/learnings.md`; raw observations must be promoted through
`/dxsync` or `dx sync` before they become trusted memory.

## Completion Gate

ALL of these must be true before you stop:
- Every acceptance criterion from Step 1 has status MET in the evidence table (Step 7)
- The findings inventory from your last re-verification (Step 5) is empty
- **Code-change sessions:** `/dxreview --single-pass` result is `CLEAN`, AND you have run `/dxreview --single-pass` AFTER your most recent code change
- **Code-change sessions:** /dxverify passes — format, lint, typecheck, tests all green (Step 6)
- Any needed `.dex/` updates are applied (Step 8)
- You have re-verified AFTER your most recent change of any kind

Do NOT stop if any acceptance criterion is NOT MET, any findings remain, `/dxreview --single-pass` is not `CLEAN` (for code changes), or /dxverify has failures (for code changes). Fix first, then re-audit from Step 3.

When all criteria are met, stop. The Stop hook will verify your work and provide completion instructions after sufficient consecutive clean audit passes.
