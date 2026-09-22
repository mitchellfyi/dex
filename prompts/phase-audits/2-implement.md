Before stopping, audit your implementation for completeness. Do NOT stop until every step below passes.

The dedicated Review phase (Phase 3) will handle adversarial code review. Your job here is to ensure the implementation is **functionally complete** — all tasks done, tests passing, no obvious gaps.

Read the plan's `## Coherence Contract` before writing code and follow it: mirror the canonical files, reuse the helpers it names, honor the rules it cites, and change the docs, configuration, and tests it lists together with the code. Where you deviate, say so and why — Phase 3's coherence lens and Phase 5's PR body both read those deviations.

Follow § Resource Discipline in `prompts/guardrails.md`: heavy work queues through `dx run-gate`; own what you start.

Apply `prompts/issue-hygiene.md` to material implementation discoveries.
Update the working issue and existing PR when their current descriptions are
stale, keep accepted related work in the same PR, and create a linked follow-up
for concrete distinct work after the duplicate search. End the phase summary
with the contract's exact `Issue/PR work:` line.

## Step 1: Task Completion Check

For each task in the approved plan:

1. **Implemented?** — Is the task fully implemented (not partially)?
2. **Tested?** — Does a test verify the implementation? (TDD: test should exist before or alongside the implementation)
3. **Passing?** — Run the tests that cover the changed files, their modules,
   and their direct consumers, within `DX_TEST_JOBS` workers. Do they pass?
   The whole suite is not an audit-pass ritual: Phase 4 runs the complete
   required pipeline once. Run it here only when you judge the change's reach
   makes it relevant, for example a shared module, a schema, a build or test
   configuration change, or a fix whose blast radius you cannot bound.

If any task is incomplete, implement it now. If any test is missing, write it now.

## Step 2: Basic Implementation Quality

Quick scan for obvious issues (the Review phase will do deep analysis):

- No TODO/FIXME/HACK left behind (unless intentionally deferred and documented)
- No console.log/print debugging statements left in production code
- No commented-out code blocks
- No comment that restates the code, API docs included
- Code compiles/transpiles without errors
- No obvious runtime errors (undefined variables, missing imports, broken references)

Fix anything found before proceeding.

## Step 2.5: Commit and Push Cadence

Review the implementation command history, `git status`, and the branch's
commits relative to the default branch:

- The history records small, coherent checkpoints as the work developed
  instead of collapsing several natural boundaries into one late commit.
- Checkpoints were not held back merely because the task, full test suite,
  phase, or final verification was incomplete. Focused checks were run when
  useful, and failed, pending, or unrun checks were reported honestly.
- Commits are logically understandable rather than arbitrary splits made only
  to increase the commit count.
- Every commit followed `prompts/commit-format.md`: specific-file staging,
  forbidden and sensitive file review, a conventional message, and Dex-only
  attribution.
- The newly created branch stayed local until its first branch-specific commit;
  no empty bootstrap commit was used to publish it.
- The first implementation commit established upstream tracking, and every
  later commit was pushed immediately after it was created.
- The working tree contains no completed implementation work waiting to be
  committed, and local HEAD matches `origin/<current-branch>`.

If approved work produced no branch-specific commit on a newly created local
branch, keep it unpushed and do not complete Phase 2. Ask the user whether to
stop the lifecycle as no-change or choose an explicit lifecycle control action;
do not advance into a PR flow that cannot complete.

## Step 2.6: The Complete Gate, When You Run It, Under Admission

The ladder: the tests covering the changed files while you work, the project's
fast gates on the changed set at each commit, and the complete gate once on the
final tree — in Phase 4, or here when the change's reach warrants it. When you
run the complete gate in Phase 2, run it as
`dx run-gate --name full-gate <the project's aggregate gate command>`: its
receipt is keyed by the checkout and working-tree fingerprints, so Phase 4
reuses it instead of running the same gate on the same tree twice, and a receipt
from an earlier tree is not evidence about this one. Review waves never run the
aggregate gate. Optionally publish the passing project-wide commands for Phase 3
with `dx_review_baseline_publish "$SESSION_ID" "$PWD" "<gate name>" "<exact
command>" "<measured seconds>"`, excluding anything focused, partial, failed,
estimated, or that changed the checkout.

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

## Step 6: UI Proof Decision

Run `/dxuicapture` before stopping and inspect the persisted decision with `dx ui-capture show`.

Accept any well-supported terminal decision:

- `READY`: the walkthrough is short, clear, no more than 90 seconds, and linked with its poster, editable storyboard, transcript, captions, browser logs, and manifest. Before/after parity is present when useful; a truthful after-only reason is valid when no baseline exists.
- `SKIPPED`: browser UI changed, but the agent explains why a produced walkthrough would not improve the review or would be unsafe or disproportionate.
- `N/A`: no browser-rendered behavior changed, with a reason.

`NEEDS_REVIEW` means the agent chose capture but the bundle still needs work. `MISSING` means no decision was recorded. Resolve those when practical; do not turn this advisory proof workflow into a claim that product functionality passed. Manual smoke testing remains a separate requirement.

All generated files must live under Dex's temporary artifact directory (`${DX_ARTIFACT_DIR:-~/.claude/.dex-artifacts}`) and must not be committed or staged.

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
- Choose `trivial` only for a documentation-only or test-only change, a rename
  with no behavior change, or a dependency bump whose full gate is green, using
  `localized-change,focused-verification,no-behavior-change`.
- Choose `small` only when every change is localized and mechanically direct,
  impact is narrow, focused verification is available, and no `complex`
  condition applies.
- Choose `normal` for everything else.

Use one or more comma-separated lowercase reason codes from this set:
`localized-change`, `focused-verification`, `no-behavior-change`,
`bounded-production-change`, `cross-module`, `public-contract`,
`security-sensitive`, `data-migration`, `concurrency`, `shell-hooks-ci`,
`deployment-packaging`, `declared-sensitive-path`, `broad-impact`, or
`uncertain-coverage`. Do not persist free-form rationale, paths, source text,
prompts, or secrets.

Follow the tier-specific reason combination rules in the assessment prompt. An
allowed code paired with a contradictory tier is invalid.

In a terminal `dx` lifecycle, record the selection for the current scope:

```bash
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh" || exit 1
SESSION_ID="${DEX_SESSION_ID:-$(dx_session_id)}"
REVIEW_TIER="<trivial|small|normal|complex>"
REVIEW_REASON_CODES="<comma-separated-reason-codes>"
dx_review_write_selection "$SESSION_ID" "$REVIEW_TIER" "lifecycle-agent" "$REVIEW_REASON_CODES" "$PWD"
```

The tier selects Dex's fixed global clean-wave policy: 1 for `trivial` and
`small`, 2 for `normal`, 3 for `complex`, with a soft wave budget of 2, 3, 6, or
9. Dex may raise the tier from the measured diff at wave time, never lower it.
The persisted selection is bound to the clean-wave policy. Candidate-branch
edits cannot lower the active gate, and `DEX_REVIEW_CLEAN_PASSES` can only
raise it. For an outlier, ask the human or record an attributed session decision
with `dx control override review.clean-passes <1-30> --source agent --reason
"<why>"`. A lower target still requires that many independent clean waves and
produces a waiver-bound receipt; it does not claim the trusted policy passed.
Use `dx control waive review.clean-passes` only when the decision is to skip
the remaining review gate entirely.

The selection is not a review pass and does not count toward the clean gate.
Because it is tied to the current scope fingerprint, rewrite it after any later
Phase 2 in-scope change.

## Completion Criteria

ALL of these must be true before you stop:
- Every task from the approved plan is implemented
- Every acceptance criterion has status MET in the evidence table (Step 3)
- The focused tests for every changed surface pass on the final checkout (rerun
  only the tests affected by later fixes), and the complete gate either has a
  passing `dx run-gate` receipt for this tree or is left to Phase 4
- No acceptance criterion or verification gate is deferred, skipped, blocked, or delegated to future CI
- Material implementation discoveries were handled under
  `prompts/issue-hygiene.md`, and the summary contains `Issue/PR work:`
- The change was exercised end-to-end locally and passed the manual smoke
  test, or manual verification is explicitly N/A with a reason
- No TODO/FIXME/debugging artifacts remain
- The implementation history contains the natural coherent checkpoints created
  during the work; every commit was pushed immediately after creation, local
  HEAD matches its upstream, and no empty bootstrap commit was used to publish
  the branch.
- A newly created local branch with no branch-specific commit remains unpushed
  and blocks the ordinary Phase 2 handoff pending user direction.
- No background processes or long-running verification commands started during Phase 2 are still in flight: every dev server, watcher, browser, and test runner this phase started has been stopped, and `dx ps` shows none of them
- Any needed `.dex/` updates are committed and pushed with the implementation
  increment that required them
- The UI proof decision is `READY`, `SKIPPED` with a reason, or `N/A` with a reason; a reasoned skip is valid and is not reported as a passed capture
- A deterministic `trivial`, `small`, `normal`, or `complex` Phase 3 risk
  selection is recorded for the final current scope and bound to the trusted
  clean-wave policy
- The review lenses ran over this diff in this session, what they found is
  fixed, and the findings ledger is seeded for Phase 3
- The Phase 1 review-criteria artifact still validates and includes every
  approved requirement, including any plan change the user approved in Phase 2

Before asking the Stop hook for the exact generation-bound completion command
in a terminal `dx` lifecycle, write the Phase 2 ready marker. Do this only after
every completion criterion above is true, including the current-scope
review-risk selection:

```bash
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh" || exit 1
touch "$(dx_phase_ready_file "${DEX_SESSION_ID:-$(dx_session_id)}" 2)"
```

When all criteria are met, stop. The Stop hook will verify your work and provide completion instructions. The next phase (Review) will perform deep adversarial code review.
