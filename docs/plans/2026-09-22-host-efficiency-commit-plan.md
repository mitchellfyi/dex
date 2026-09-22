# Suggested commit plan for the unstaged Dex change (HEAD 6ab0575)

Nothing below has been staged or committed. These are coherent groupings in the plan's
build order, each independently revertible, with subjects in Dex's existing
`type(scope): imperative` style. Adjust to taste; the file lists are the authoritative
"what belongs together", not the wording.

## 1. feat(session): own every process a lifecycle phase starts
`lib/session.sh` (ownership token on fd 8, scan by /proc, libproc, lsof; reaper; telemetry block),
`lib/events.sh`, `bin/ps.sh`, `bin/control.sh`, `bin/session-runtime-owner.sh`,
`hooks/session-end.sh`, `hooks/guards/detached-processes.md`, `hooks/guard-handler.py`
(detached-process detector), `dx.sh` (phase-exit reap, `dx ps` wiring),
`tests/session-process-ownership-test.sh`, `tests/session-ps-test.sh`,
`tests/session-telemetry-test.sh`, `tests/session-runtime-owner-test.sh` (new cases),
`docs/events.md` (ownership + telemetry rows), `docs/reference.md`, `docs/guards.md`.
Body: token per provider session (one phase); reap at session-end, phase-exit, watchdog-kill,
control-cancel, launcher-stopped, ps --reap-orphans; dry-run `dx ps`; session.summary per phase.

## 2. feat(host): admit heavy work through one lease and `dx run-gate`
`lib/host-budget.sh` (facts + fallbacks, heavy limit, priority wrappers, receipts),
`lib/review-capacity.sh` (named pools, host-derived waves limit, `live_count` kind arg),
`bin/run-gate.sh`, `bin/gate-receipt.sh`, `scripts/project-contract.py`, `lib/project-state.sh`,
`lib/provider.sh` (snapshot export, minimal MCP for phases 4/5/6), `hooks/phase-loop.sh`
(handoff line, vocabulary), `lib/common.sh`, `.dex/dex.md` (`## Resources`),
`prompts/init-analysis.md` (`## Resources` template), `tests/run-gate-test.sh`,
`tests/gate-receipt-test.sh`, `tests/host-budget-test.sh`, `tests/review-capacity-test.sh`,
`docs/host-budget.md`, `docs/reference.md`.

## 3. feat(review): scoped waves, one reviewer, ledger, tiers from change facts
`lib/review.sh`, `lib/review-loop.sh`, `lib/review-policy.sh`, `lib/review-controller.sh`,
`scripts/review_checks.py` (input-scoped invalidation, `autofix`), `scripts/review_stats.py`,
`bin/review.sh` (`dx review stats`), `bin/review-check.sh` + `prompts/review-checks.md`
(queue/execution budgets, over-budget, heartbeat), `prompts/review-wave.md`,
`prompts/review-report.md`, `prompts/review-risk-assessment.md`, `skills/dxreview/SKILL.md`,
`skills/dxreviewloop/SKILL.md`, `skills/dex/SKILL.md`, `prompts/phase-audits/3-review.md`,
`prompts/phase-audits/3-review-loop.md`, `tests/review-tier-derivation-test.sh`,
`tests/review-stats-test.sh`, `tests/review-ladder-contract-test.sh`,
`tests/review-controller-test.sh`, `tests/review-check-budget-test.sh`,
`tests/review-check-runner-test.sh`, `tests/review-check-cache-test.py`,
`tests/review-loop-contract-test.sh`, `docs/autonomous-mode.md`, `docs/review-turnaround.md`,
`docs/events.md` (review rows).
Body: waves never run the aggregate gate; full-gate receipts reused in Phase 4; `full_gate`
contract field; scouts default 0, sequential lenses + coherence lens; findings ledger;
`trivial` tier; NOTES:N and MECHANICAL:N (streak resets, one mechanical wave budget-exempt);
convergence guard; `dx review stats` over the events journal.

## 4. feat(plan): Coherence Contract and the verification ladder in every phase
`prompts/workflows/dxplan.md`, `prompts/phase-audits/1-plan.md`, `prompts/workflows/dxpr.md`,
`prompts/phase-audits/2-implement.md`, `prompts/phase-audits/4-verify.md`,
`prompts/phase-audits/6-complete.md`, `prompts/phase-audits/prompt-loop.md`,
`skills/dxverify/SKILL.md`, `prompts/workflows/dximplement.md`.

## 5. feat(worktree): project lifecycle hooks and `dx worktree audit`
`lib/worktree.sh`, `bin/worktree.sh`, `bin/maintain.sh`, `dx.sh` (create/remove call sites,
`worktree` dispatcher), `prompts/ui-proof.md` (baseline helpers), `prompts/init-analysis.md`
(`## Worktree Hooks` template), `docs/worktree-hooks.md`, `tests/worktree-hooks-test.sh`,
`README.md`.

## 6. feat(mcp): per-phase browser profiles and minimal MCP where no browser is needed
`scripts/browser-mcp.cjs`, `lib/ui-capture.sh`, `lib/agent-tools.sh`, `bin/ui-capture.sh`,
`tests/phase-mcp-test.sh`, `docs/ui-capture.md`.
Body: profiles under the per-phase `DX_SESSION_TMP`; `--strict-mcp-config` for phases 4/5/6
(and 1 outside inline handoff); install scope stays `user` by default with `--project`/`--local`.

## 7. docs(prompts): host etiquette in Resource Discipline and every phase audit
`prompts/guardrails.md`, `prompts/phase-audits/0-setup.md`, `prompts/phase-audits/5-pr.md`
(plus the small edits already in groups 3 and 4), `hooks/guards/detached-processes.md`
(heavy-command nudge), `hooks/guard-handler.py` (contract-backed nudge, mtime cache),
`tests/host-etiquette-test.sh`, `docs/guards.md`.

## 8. feat(clean): `dxclean --apply` and `dx doctor`
`dx.sh` (dxclean report/apply), `bin/doctor.sh`, `tests/host-cleanup-test.sh`,
`docs/host-budget.md` (final section), `README.md`, `AGENTS.md`.

## 9. chore(tests): register the new suites
`tests/manifest.tsv` (sorted, 127 rows). Fold into whichever group lands last, or keep separate.

## Not ours
`scripts/ui-capture.cjs` carries your own earlier uncommitted change (23+/6−); leave it out of
these groups. `docs/plans/2026-09-21-host-efficiency-and-process-ownership.md` is the plan.

## Before merging
Run in CI, not on the shared laptop: `review-loop-contract-test.sh` (changed, never run
locally), `review-loop-test.sh`, `standalone-provider-test.sh`, `maintenance-test.sh`.
Known pre-existing failures on main: `provider-command-test.sh`, `lifecycle-control-hook-test.sh`
under the runner. Ticket to file: behavioural tests for "no wave runs the aggregate gate" and
"the full gate runs once per session"; the evaluation harness's recursive re-run of the suite.
