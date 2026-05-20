Before stopping, audit your implementation for completeness. Do NOT stop until every step below passes.

The dedicated Review phase (Phase 3) will handle adversarial code review. Your job here is to ensure the implementation is **functionally complete** — all tasks done, tests passing, no obvious gaps.

## Step 1: Task Completion Check

For each task in the approved plan:

1. **Implemented?** — Is the task fully implemented (not partially)?
2. **Tested?** — Does a test verify the implementation? (TDD: test should exist before or alongside the implementation)
3. **Passing?** — Run the test suite. Do all tests pass?

If any task is incomplete, implement it now. If any test is missing, write it now.

## Step 2: Basic Implementation Quality

Quick scan for obvious issues (the Review phase will do deep analysis):

- No TODO/FIXME/HACK left behind (unless intentionally deferred and documented)
- No console.log/print debugging statements left in production code
- No commented-out code blocks
- Code compiles/transpiles without errors
- No obvious runtime errors (undefined variables, missing imports, broken references)

Fix anything found before proceeding.

## Step 3: Evidence Table

For each acceptance criterion from the plan, fill in the evidence table:

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
- Every acceptance criterion and verification gate must be exactly `MET`.
- Any `NOT MET`, `NOT FOUND`, `DEFERRED`, `SKIPPED`, `BLOCKED`, `N/A`, "CI will cover it", "port busy", "tool unavailable", or equivalent entry blocks completion unless the user explicitly approved a plan change.
- If a local port is busy or a service is unavailable, resolve it locally (for example, use another port or start the missing service) and rerun the required verification. Do not substitute future CI for a required Phase 2 check.
- Use a plain GitHub Markdown table or short bullets. Do not use Unicode box-drawing tables; they wrap poorly in Claude Code transcripts.

## Step 4: `.doyaken/` Freshness

Check if your implementation introduced any of these:
- New dependencies or tooling changes → `.doyaken/doyaken.md` § Tech Stack / Quality Gates updated?
- New code patterns or conventions → relevant `.doyaken/rules/*.md` updated?
- New security boundaries or sensitive paths → `.doyaken/guards/` updated?

If updates are needed but missing, make them now.

## Step 5: Memory Candidate Check

If you discovered conventions, repeated failure patterns, review expectations,
or interface details that would help future tasks, decide where they belong:

- Clear, current project rule that future agents should follow now -> update the
  relevant `.doyaken/rules/*.md` file.
- Enforceable safety pattern with a narrow detector -> add or update a
  `.doyaken/guards/*.md` rule.
- Durable lesson that needs evidence, recurrence, or review before becoming
  trusted -> run `/dksync --dry-run` or include it in the Phase 2 summary as a
  candidate observation for `dk sync`.

Do not create `.doyaken/learnings.md`. Raw observations are not trusted memory.
Durable memory belongs in `.doyaken/memory/domains/` only after `/dksync` or
`dk sync` promotes it through a reviewable diff.

## Step 6: UI Capture Evidence

If the implementation affects browser UI, run `/dkuicapture` before stopping.

Required evidence for UI-affecting changes:

- Before screenshot/trace for each changed representative route/view captured before UI edits, or an explicit reason the baseline is unavailable
- Desktop screenshot for each changed representative route/view
- Mobile screenshot when layout, responsive behavior, shared components, or CSS changed
- Playwright trace for captured routes/views
- Video for interactive flows (clicks, forms, navigation, modals, menus, drag/drop, auth, checkout, onboarding, uploads)
- Console, page, network, and HTTP error logs checked
- `visual-evidence.md` manifest under Doyaken's artifact directory, with before and after links grouped for PR upload
- Absolute links to all screenshots/videos/traces/logs included in the evidence table or final Phase 2 summary

Artifacts must live under Doyaken's artifact directory (`${DK_ARTIFACT_DIR:-~/.claude/.doyaken-artifacts}`) and must not be committed or staged.
If `DK_ARTIFACT_DIR` points inside the repo, verify the artifact path is gitignored before writing captures.

If the implementation does not affect browser UI, include:

```text
UI capture: N/A — no UI-affecting files changed
```

## Completion Criteria

ALL of these must be true before you stop:
- Every task from the approved plan is implemented
- Every acceptance criterion has status MET in the evidence table (Step 3)
- All tests pass (run the test suite one final time to confirm)
- No acceptance criterion or verification gate is deferred, skipped, blocked, or delegated to future CI
- No TODO/FIXME/debugging artifacts remain
- No background agents or long-running verification commands started during Phase 2 are still in flight
- Any needed `.doyaken/` updates are staged
- UI capture evidence is linked for UI-affecting changes, including before/after evidence or a before-unavailable reason, or UI capture is explicitly N/A

Before writing the completion signal in a terminal `dk` lifecycle, write the Phase 2 ready marker. Do this only after every completion criterion above is true:

```bash
source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"
touch "$(dk_phase_ready_file "${DOYAKEN_SESSION_ID:-$(dk_session_id)}" 2)"
```

When all criteria are met, stop. The Stop hook will verify your work and provide completion instructions. The next phase (Review) will perform deep adversarial code review.
