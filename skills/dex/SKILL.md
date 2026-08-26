---
name: "dex"
description: "Orchestrate the full Dex ticket lifecycle from planning through PR completion."
---

# Skill: Dex

Orchestrate the full ticket lifecycle from planning through completion.

## When to Use

- After the SessionStart hook has loaded context and confirmed readiness
- When the user says "dex", "start", "go", "begin work", or invokes `/dex`

## Lifecycle

The terminal `dx` lifecycle runs phases in the same Claude Code session. Each phase has an audit loop that critically reviews the work before allowing completion; when the phase passes, the Stop hook injects the next phase instructions directly into the current session.

Commits, pushes, and pull-request actions remain available in every phase.
Phase assignments describe their default focus and owner. When a direct human
instruction or the active workflow calls for one of those actions, record the
resulting state and continue using the current phase's completion criteria.

### Phase 0: Setup

1. Runs in NORMAL mode (no plan mode) so the agent can write to git and the tracker before any planning starts.
2. Follow `prompts/ticket-instructions.md` end to end:
   - Read the ticket from the configured tracker (including all comments).
   - If unassigned, assign the ticket to the authenticated user. If assigned to someone else, pause and ask by default. A justified `setup.ticket-ownership` waiver may continue without claiming ownership changed.
   - Rename the lifecycle branch to the tracker's git branch name and push it with upstream tracking. Draft PR creation normally stays with Phase 5 unless the user asks for it earlier.
   - Set ticket status to **In Progress**.
   - If the description is empty or unclear, draft 2-3 sentences plus an acceptance-criteria checklist, present to the user, and update the ticket once confirmed.
   - Update the per-session meta sidecar with `tracker_key` and `current_branch` so future `dx <N>` invocations can find the worktree even after the branch rename.
3. **SCOPE**: keep the phase focused on ticket bootstrap. Planning and source work normally begin in later phases; commits and PR work retain their existing phase owners unless the user directs otherwise.
4. When setup is complete, write the Phase 0 ready marker (`dx_phase_ready_file ... 0`) and stop once so the Stop hook can audit and advance to Phase 1 automatically.

### Phase 1: Plan

1. Phase 0 already handled ticket setup; do not redo it unless something is clearly missing (status still Backlog/Todo, no assignee, branch not renamed/pushed).
2. Run `/dxplan` — gather any remaining context, draft the implementation plan, create tasks.
3. Present the plan and wait for approval by default. If an outlier justifies proceeding in the current session, record a named `plan.approval` waiver; do not represent it as human approval.
4. If the user requests changes, revise and re-present.
5. When running under the terminal `dx` lifecycle, stop once immediately after approval so the Stop hook can audit the plan and inject Phase 2 in the same session. Do not tell the user to run `/dximplement`.
6. When running `/dex` interactively without the wrapper, output `PHASE_1_COMPLETE` when the user approves.

### Phase 2: Implement

1. Invoke the Skill tool with `skill: "dximplement"` — work through tasks with TDD discipline. The plan approval was the go-ahead; do not pause to ask for permission.
2. Ask by default if ambiguous requirements, scope changes, or blocked dependencies arise. The active agent may use the attributed override/waiver contract when proceeding is justified.
3. Invoke `/dxuicapture` early to decide whether visual proof would help. The agent may capture a concise walkthrough, record `SKIPPED` with a reason for a visible but disproportionate case, or record `N/A` when there is no browser impact. When capture is chosen, prefer a matched before/after flow, keep it under 90 seconds, and surface the temporary bundle after baseline and production.
4. End Phase 2 with a manual local smoke test: run the change end-to-end locally and confirm it works, driving browser-facing flows with the Claude-in-Chrome browser tools (Playwright fallback), seeding and then cleaning up local data as needed.
5. The audit loop verifies all tasks are complete with tests passing, the evidence table filled, the manual smoke test passed or explicitly N/A, and an honest UI proof decision recorded. A reasoned `SKIPPED` decision is valid; it is not reported as a successful capture.
6. **SCOPE**: focus on implementation, testing, and the UI proof decision. Ticket setup belongs to Phase 0, so only re-run it here if Phase 0 left it incomplete. Phase 4 normally owns verification and publishing, while Phase 5 normally owns the PR description; direct human instructions can change that order.
7. After the final in-scope change, select and persist the Phase 3 risk
   tier for the current scope: `small`, `normal`, or `complex`, with a
   deterministic set of reason codes. The tier selects the trusted clean-wave
   policy from the committed default branch. Its defaults are 1, 3, and 6;
   `.dex/dex.md` may configure monotonic values from 1 through 30.
8. Output `PHASE_2_COMPLETE` when all tasks are implemented, the evidence table
   shows all criteria MET, and the review-risk selection matches the final
   scope fingerprint and trusted policy.

### Phase 3: Review

1. Invoke `/dxreviewloop` to run the independent adversarial review loop using
   the risk tier recorded by the Phase 2 implementation agent. A legacy or
   resumed lifecycle with no valid current-scope selection may use the wrapper's
   fresh read-only lifecycle assessor as a recovery path before the first wave.
2. Each `/dxreviewloop` iteration runs one full review wave in a fresh CLI
   session: compact context pack, deterministic checks, issue harvest, verifier
   triage when needed, batch fixes, and targeted recheck.
3. Waves that find and fix issues write `FINDINGS_FIXED:N`, reset the clean
   counter, and force the next iteration to re-review the full change set.
4. The loop uses the selected tier's trusted clean-wave requirement. The
   defaults are 1 for `small`, 3 for `normal`, and 6 for `complex`. A candidate
   branch cannot lower the active gate, and the loop has no outer iteration
   maximum. For an outlier, `dx control override review.clean-passes <1-30>`
   keeps independent review while changing the target. A lower target is bound
   to the attributed decision and records Phase 3 as waived. Use
   `dx control waive review.clean-passes` only to skip the remaining waves.
5. Prior review conclusions, findings, fingerprints, clean counts, and telemetry
   are never passed to a later reviewer.
6. Each accepted wave supplies evidence version 3 with exact ordered criterion
   hashes, outcomes, substantive context references, and policy and pass
   bindings. Dex attests the evidence, context, result, profile, and findings
   fingerprint before granting clean credit, retains private proof copies, and
   recomputes every attestation when it validates the receipt.
7. `FINDINGS:N`, `BLOCKED:reason-code`, `CHURN:reason-code`, invalid results,
   provider failures, and deterministic fingerprint churn pause the loop.
8. **SCOPE**: focus on review and fixes. Phase 4 and Phase 5 remain the default
   owners of publishing and PR setup, but those actions are available here.
9. Output `PHASE_3_COMPLETE` only when the current scope has a valid review
   receipt binding the approved criteria, trusted policy, attested clean
   ledger, and any lower-target override. Report whether the trusted target
   passed or the attributed lower target was waived.

### Phase 4: Verify & Commit

1. Run `/dxverify` — format, lint, typecheck, generate, test.
2. Fix any failures. Re-run until all green, using the current retry defaults from `dx_failure_attempts_per_strategy` and `dx_failure_max_strategies` as described in `prompts/failure-recovery.md`.
3. Run `/dxcommit` — atomic conventional commits, push to origin.
4. Output `PHASE_4_COMPLETE` when all checks pass and code is pushed.

### Phase 5: PR

1. Run `/dxpr` — generate the PR description, refresh any UI after-capture handoff, create or update the PR, attach `request`-type reviewers from `dex.md § Reviewers`, and update the tracker if available. New PRs default to draft.
2. Phase 6 normally owns marking the PR ready and posting `@mention` comments so reviewer notifications happen together. If the user directs either action in Phase 5, carry it out and record the updated PR state for Phase 6.
3. Output `PHASE_5_COMPLETE` when the PR is current, its actual draft or ready state is recorded, and reviewers are attached.

### Phase 6: Complete (autonomous)

1. Read `## Reviewers` from `dex.md`. On the first cycle: `gh pr ready`, re-sync `request` reviewers (idempotent), post one `@mention` comment listing all `mention` reviewers.
2. Set up monitoring: `/loop 5m /dxwatchpr`. The PR watcher handles both CI failures and review feedback.
3. Re-read `dx_complete_wait_minutes` (default 5) each cycle. The Stop hook re-injects the audit and only authorizes outcome evaluation once the current window has elapsed.
4. Escalate by default when a loop reaches `dx_complete_ci_fix_attempts`, or encounters architectural review comments, a secrets scan failure, or a scope conflict. Ask for or record a justified waiver when an exception is appropriate.
5. After each push: re-request `request` reviewers and post a fresh mention comment so reviewers know there's something new.
6. After the current `dx_complete_max_cycles` value (default 3) is reached with no progress, escalate to the user.
7. When CI green AND all successfully requested `request` reviewers have approved, run `/dxcomplete`'s final verification — update tracker to Done, print summary.
8. Output `DEX_TICKET_COMPLETE` once verification passes.

## Resuming

If the session is interrupted, `dx 999` or `dx --resume` picks up from the saved phase. Phase tracking is handled by the `dx` shell lifecycle (see `dx.sh` `__dx_run_phases_inline`), which persists the current phase number in `~/.claude/.dex-phases/<session_id>.phase`. The Stop hook is responsible for advancing phases in-session by updating phase state and injecting the next phase message and audit prompt.

As a fallback (for example, `/dex` without the wrapper), use repository and PR
state to orient the next action. External state is a hint, not proof that an
unrecorded Review or Verify phase passed. Prefer persisted Dex phase outcomes
when they exist. Ask for a waiver or jump before bypassing an unresolved gate
when the consequence is material; the active agent may also apply a reasoned
session override when the safe choice is clear.

1. **Check for existing PR**: `gh pr view --json state,isDraft,statusCheckRollup`
   - No PR + branch still on `worktree-ticket-*` or `worktree-task-*` and ticket status is not yet In Progress → Phase 0 (Setup)
   - No PR + bootstrap done (branch renamed, status In Progress) → Phase 1 (Plan)
   - Existing draft or ready PR → record the PR state and resume the persisted
     Dex phase; do not infer Review or Verify completion from the PR alone
   - Merged PR with Dex already at Phase 5 or later → reconcile Phase 5 as
     externally complete and continue Phase 6 cleanup
   - Merged PR while Dex is still before Phase 5 → surface the mismatch, then
     ask for a waiver or apply a reasoned agent waiver when waiting would not
     improve the decision

2. **Check task list**: If tasks exist from a prior `/dxplan`, offer to resume from the first incomplete task rather than re-planning.

3. **Check ticket state** (if tracker configured):
   - In progress → work underway (Phase 1 or later)
   - In review → monitor
   - Done/closed → nothing to do
   - Backlog/Todo + branch still on the canonical `worktree-*` name → Phase 0 (Setup) still pending
   - If no tracker: infer from PR and git state above.

## Decision Points Summary

| Phase | Trigger | Action |
|-------|---------|--------|
| 1 | Plan ready | Present plan, wait for approval |
| 2 | Ambiguous requirement | Present options, ask user to choose |
| 2 | Scope change needed | Explain impact, ask approval |
| 3 | Findings, blocker, churn, invalid result, or provider failure | Pause with the normalized reason and required intervention |
| 2-5 | Normal phase completion | Stop once; the Stop hook injects the next phase automatically |
| 5 | PR created or updated | Stop; Phase 6 takes over automatically |
| 6 | CI secrets scan failure | Cancel all loops, alert immediately |
| 6 | 3 failed CI fix attempts | Cancel loops, escalate with details |
| 6 | Architectural review comment | Cancel loops, escalate to user |
| 6 | Max cycles reached idle | Escalate to user (no progress) |

## Autonomous Mode (Phase Audit Loops)

When the session is started by `dx`, a Stop hook prevents premature exit and injects a phase-specific audit prompt. Activation is signaled via an `.active` file in `~/.claude/.dex-loops/` (and optionally the `DEX_LOOP_ACTIVE=1` env var as a belt-and-suspenders mechanism). Each phase has its own quality criteria — the loop continues until the audit is satisfied. This enables quality-gated autonomous execution:

- If `/dxverify` fails → fix and retry automatically
- If a wave fixes safe in-scope issues (`FINDINGS_FIXED:N`) → reset the clean
  streak and run a fresh full-scope wave
- If review returns residual `FINDINGS:N`, `BLOCKED:*`, or `CHURN:*` → pause
  for intervention
- If CI fails → fix and re-push automatically
- If reviews have comments → address and re-push automatically

The phase audit loop continues until:
1. **Completion promise**: Output `DEX_TICKET_COMPLETE` when ALL of these are true:
   - All tasks completed
   - PR approved with all checks green
   - All review comments addressed
   - Ticket updated to Done (if tracker configured)
2. **Max audit iterations reached** (default: 30) — safety net for the phase
   Stop-hook audit, separate from `/dxreviewloop`'s clean-pass loop
3. **User interrupts** — the user can always take over

The outer `/dxreviewloop` has no iteration maximum. It stops only after its
clean gate succeeds or it reaches a blocker, residual finding, churn condition,
provider failure, invalid result, user interruption, or direct intervention.

### When to output the completion promise

Only output `DEX_TICKET_COMPLETE` when you have verified:
- `gh pr view --json state,statusCheckRollup` shows the PR is open/ready and all checks passed
- No unresolved review threads
- Ticket state is "Done" or "Closed" (if tracker configured)

### Escalation in autonomous mode

Even in autonomous mode, escalate to the user by default for:
- Secrets scan failures (never auto-fix)
- Architectural review comments (need human judgement)
- The current `dx_failure_attempts_per_strategy` budget at the same fix
- Scope changes that affect other tickets

When a launch or Stop audit supplies an exact generation-bound escalation
command, use that literal command after the current
`dx_failure_max_strategies` default is reached. It pauses and detaches the current generation and revokes its
completion authorization. It does not create a human control receipt or a
completion receipt. Never substitute a raw pause marker, a generic human
control command, or relaxed completion criteria.

These are soft escalation defaults. If an outlier makes one counterproductive,
the agent may ask the user or record a specific, reasoned override itself. It
must preserve any unmet assurance item as waived, skipped, or unresolved.

## Notes

- The user can interrupt at any point and the agent should gracefully stop.
- Each phase naturally flows into the next — no manual invocation needed after `/dex`.
- The agent should provide brief status updates at phase transitions, but must not wait for the user except at the decision points above.
- Keep the configured ticket tracker updated throughout (see dex.md § Integrations). If no tracker is configured, the conversation and PR serve as the record.
