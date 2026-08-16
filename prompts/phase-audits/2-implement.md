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

## Step 4: `.dex/` Freshness

Check if your implementation introduced any of these:
- New dependencies or tooling changes → `.dex/dex.md` § Tech Stack / Quality Gates updated?
- New code patterns or conventions → relevant `.dex/rules/*.md` updated?
- New security boundaries or sensitive paths → `.dex/guards/` updated?

If updates are needed but missing, make them now.

## Step 5: Memory Candidate Check

If you discovered conventions, repeated failure patterns, review expectations,
or interface details that would help future tasks, decide where they belong:

- Clear, current project rule that future agents should follow now -> update the
  relevant `.dex/rules/*.md` file.
- Enforceable safety pattern with a narrow detector -> add or update a
  `.dex/guards/*.md` rule.
- Durable lesson that needs evidence, recurrence, or review before becoming
  trusted -> run `/dxsync --dry-run` or include it in the Phase 2 summary as a
  candidate observation for `dx sync`.

Do not create `.dex/learnings.md`. Raw observations are not trusted memory.
Durable memory belongs in `.dex/memory/domains/` only after `/dxsync` or
`dx sync` promotes it through a reviewable diff.

## Step 6: UI Capture Evidence

If the implementation affects browser UI, run `/dxuicapture` before stopping.

Required evidence for UI-affecting changes:

- Before screenshot/trace for each changed representative route/view captured before UI edits, or an explicit reason the baseline is unavailable
- Desktop screenshot for each changed representative route/view
- Mobile screenshot when layout, responsive behavior, shared components, or CSS changed
- Playwright trace for captured routes/views
- Video for interactive flows (clicks, forms, navigation, modals, menus, drag/drop, auth, checkout, onboarding, uploads)
- Console, page, network, and HTTP error logs checked
- `visual-evidence.md` manifest under Dex's artifact directory, with before and after links grouped for PR upload
- Absolute links to all screenshots/videos/traces/logs included in the evidence table or final Phase 2 summary

Artifacts must live under Dex's artifact directory (`${DX_ARTIFACT_DIR:-~/.claude/.dex-artifacts}`) and must not be committed or staged.
If `DX_ARTIFACT_DIR` points inside the repo, verify the artifact path is gitignored before writing captures.

If the implementation does not affect browser UI, include:

```text
UI capture: N/A — no UI-affecting files changed
```

## Step 7: Select Phase 3 Review Risk

After the final in-scope change and verification run, use
`prompts/review-risk-assessment.md` as the source of truth. Its first matching
rule wins:

- Choose `complex` when the scope touches a trust boundary; authentication,
  authorization, permissions, secrets, payments, or destructive behavior;
  persistence, schemas, or migrations; public API, CLI, configuration, or
  compatibility contracts; concurrency or process lifecycle; hooks, guards,
  CI, deployment, or packaging; broad cross-module behavior; or a concrete gap
  in the supplied scope or verification that leaves material behavior
  unbounded.
- Choose `small` only when every change is localized and mechanically direct,
  impact is narrow, focused verification is available, and no `complex`
  condition applies.
- Choose `normal` for everything else.

Use one or more comma-separated lowercase reason codes from this set:
`localized-change`, `focused-verification`, `bounded-production-change`,
`cross-module`, `public-contract`, `security-sensitive`, `data-migration`,
`concurrency`, `shell-hooks-ci`, `deployment-packaging`, `broad-impact`, or
`uncertain-coverage`. Do not persist free-form rationale, paths, source text,
prompts, or secrets.

Follow the tier-specific reason combination rules in the assessment prompt. An
allowed code paired with a contradictory tier is invalid.

In a terminal `dx` lifecycle, record the selection for the current scope:

```bash
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh" || exit 1
SESSION_ID="${DEX_SESSION_ID:-$(dx_session_id)}"
REVIEW_TIER="<small|normal|complex>"
REVIEW_REASON_CODES="<comma-separated-reason-codes>"
dx_review_write_selection "$SESSION_ID" "$REVIEW_TIER" "lifecycle-agent" "$REVIEW_REASON_CODES" "$PWD"
```

The tier selects the trusted clean-wave policy from the committed default
branch. The defaults are 3 for `small`, 6 for `normal`, and 9 for `complex`;
repositories may configure monotonic values from 1 through 30 in `.dex/dex.md`
`## Review Policy`. The persisted selection is bound to that resolved policy.
Candidate-branch edits cannot lower the active gate, and
`DEX_REVIEW_CLEAN_PASSES` can only raise it.

The selection is not a review pass and does not count toward the clean gate.
Because it is tied to the current scope fingerprint, rewrite it after any later
Phase 2 in-scope change.

## Completion Criteria

ALL of these must be true before you stop:
- Every task from the approved plan is implemented
- Every acceptance criterion has status MET in the evidence table (Step 3)
- All tests pass (run the test suite one final time to confirm)
- No acceptance criterion or verification gate is deferred, skipped, blocked, or delegated to future CI
- The change was exercised end-to-end locally and passed the manual smoke
  test, or manual verification is explicitly N/A with a reason
- No TODO/FIXME/debugging artifacts remain
- No background processes or long-running verification commands started during Phase 2 are still in flight
- Any needed `.dex/` updates are staged
- UI capture evidence is linked for UI-affecting changes, including before/after evidence or a before-unavailable reason, or UI capture is explicitly N/A
- A deterministic `small`, `normal`, or `complex` Phase 3 risk selection is
  recorded for the final current scope and bound to the trusted clean-wave
  policy
- The Phase 1 review-criteria artifact still validates and includes every
  approved requirement, including any plan change the user approved in Phase 2

Before writing the completion signal in a terminal `dx` lifecycle, write the
Phase 2 ready marker. Do this only after every completion criterion above is
true, including the current-scope review-risk selection:

```bash
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh" || exit 1
touch "$(dx_phase_ready_file "${DEX_SESSION_ID:-$(dx_session_id)}" 2)"
```

When all criteria are met, stop. The Stop hook will verify your work and provide completion instructions. The next phase (Review) will perform deep adversarial code review.
