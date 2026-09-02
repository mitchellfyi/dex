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

Commits and pushes record the work as it happens: Phase 2 records implementation
checkpoints, the active Phase 3 wave records accepted review fixes while the
lifecycle parent remains quiescent, and Phase 4 records any final verification
repairs. Verification is the PR gate, not a commit prerequisite. Phase 5 owns
PR setup, and Phase 6 owns external review follow-through.

Read `prompts/issue-hygiene.md` for the lifecycle-wide issue and PR contract.
Phase 0 performs the full duplicate, relationship, and existing-PR search.
Later phases apply the contract when material new context appears. Every phase
handoff and completed-phase summary must include its exact `Issue/PR work:`
line, including when all fields are unchanged or N/A.

### Phase 0: Setup

1. Runs in NORMAL mode (no plan mode) so the agent can write to git and the tracker before any planning starts.
2. Follow `prompts/ticket-instructions.md` end to end:
   - Read the ticket from the configured tracker (including all comments).
   - If unassigned, assign the ticket to the authenticated user. If assigned to someone else, pause and ask by default. A justified `setup.ticket-ownership` waiver may continue without claiming ownership changed.
   - Run `dx_ticket_branch_prepare` with the tracker's git branch name. It
     adopts an existing origin branch only when its PR is open or it has no PR,
     and otherwise prepares a new local branch. Do not push a new branch with
     no branch-specific commits or create an empty bootstrap commit. Phase 2
     publishes it after the first implementation commit. Draft PR creation
     normally stays with Phase 5.
   - Set ticket status to **In Progress**.
   - Apply `prompts/issue-hygiene.md`: search for duplicates and related work,
     reconcile accepted comment decisions into the issue, and read and update
     the existing open PR when its title or body is stale.
   - If the description is empty or unclear, draft 2-3 sentences plus an acceptance-criteria checklist, present to the user, and update the ticket once confirmed.
   - Update the per-session meta sidecar with `tracker_key` and `current_branch` so future `dx <N>` invocations can find the worktree even after the branch rename.
3. **SCOPE**: keep the phase focused on ticket bootstrap. Planning and source
   work normally begin in later phases; routine commits and pushes begin in
   Phase 2, and PR work normally begins in Phase 5.
4. When setup is complete, write the Phase 0 ready marker (`dx_phase_ready_file ... 0`) and stop once so the Stop hook can audit and advance to Phase 1 automatically.

### Phase 1: Plan

1. Phase 0 already handled ticket setup; do not redo it unless something is clearly missing (status still Backlog/Todo, no assignee, or branch unresolved). An adopted remote branch already tracks origin. For a genuinely new local branch, the absence of a remote before the first implementation commit is expected.
2. Run `/dxplan` — gather any remaining context, draft the implementation plan, create tasks.
3. Present the plan and wait for approval by default. If an outlier justifies proceeding in the current session, record a named `plan.approval` waiver; do not represent it as human approval.
4. If the user requests changes, revise and re-present.
5. When running under the terminal `dx` lifecycle, stop once immediately after approval so the Stop hook can audit the plan and inject Phase 2 in the same session. Do not tell the user to run `/dximplement`.
6. When running `/dex` interactively without the wrapper, output `PHASE_1_COMPLETE` when the user approves.

### Phase 2: Implement

1. Invoke the Skill tool with `skill: "dximplement"` — work through tasks with TDD discipline. The plan approval was the go-ahead; do not pause to ask for permission.
2. Commit early and often. Whenever the current changes form a small, coherent
   checkpoint, create an atomic conventional commit and push it immediately.
   Run focused checks when useful, but do not wait for them to pass, for the
   task to finish, or for final verification. Report failing or unrun checks
   honestly, continue toward a verified branch, and use natural history
   boundaries rather than arbitrary splits. For a new local branch with no
   upstream, the first real branch-specific commit establishes tracking; every
   later commit is pushed as it is created. Never publish the new branch before
   that commit.
3. Ask by default if ambiguous requirements, scope changes, or blocked dependencies arise. The active agent may use the attributed override/waiver contract when proceeding is justified.
4. Invoke `/dxuicapture` early to decide whether visual proof would help. The agent may capture a concise walkthrough, record `SKIPPED` with a reason for a visible but disproportionate case, or record `N/A` when there is no browser impact. When capture is chosen, prefer a matched before/after flow, keep it under 90 seconds, and surface the temporary bundle after baseline and production.
5. End Phase 2 with a manual local smoke test: run the change end-to-end locally and confirm it works, driving browser-facing flows with the Claude-in-Chrome browser tools (Playwright fallback), seeding and then cleaning up local data as needed.
6. The audit loop verifies all tasks are complete with tests passing, the evidence table filled, implementation commits pushed, the manual smoke test passed or explicitly N/A, and an honest UI proof decision recorded. A reasoned `SKIPPED` decision is valid; it is not reported as a successful capture.
7. **SCOPE**: focus on implementation, testing, incremental commits and pushes,
   and the UI proof decision. Ticket setup belongs to Phase 0, so only re-run it
   here if Phase 0 left it incomplete. Phase 3 records accepted review fixes,
   Phase 4 owns the final PR verification gate, and Phase 5 normally owns the
   PR description.
8. After the final in-scope change, select and persist the Phase 3 risk
   tier for the current scope: `small`, `normal`, or `complex`, with a
   deterministic set of reason codes. The tier selects Dex's fixed global
   clean-wave policy: 1 for `small`, 2 for `normal`, and 3 for `complex`.
9. Output `PHASE_2_COMPLETE` when all tasks are implemented, the evidence table
   shows all criteria MET, implementation commits are pushed, and the
   review-risk selection matches the final scope fingerprint and trusted
   policy. If approved work produced no branch-specific commit on a newly
   created local branch, keep it unpushed and pause for user direction instead
   of advancing toward Phase 5. The user may stop the lifecycle as no-change or
   choose an explicit lifecycle control action.
10. Reconcile material implementation discoveries under
    `prompts/issue-hygiene.md` before the phase handoff.

### Phase 3: Review

1. Invoke `/dxreviewloop` to run the independent adversarial review loop using
   the risk tier recorded by the Phase 2 implementation agent. A legacy or
   resumed lifecycle with no valid current-scope selection may use the wrapper's
   fresh read-only lifecycle assessor as a recovery path before the first wave.
2. Each `/dxreviewloop` iteration runs one full review wave in a fresh CLI
   session: compact context pack, deterministic checks, issue harvest, verifier
   triage when needed, batch fixes, and targeted recheck.
3. Waves that find and fix issues commit and push coherent accepted-fix
   checkpoints as they work, complete the required rechecks, write
   `FINDINGS_FIXED:N`, reset the clean counter, and force the next iteration to
   re-review the full change set.
4. The loop uses the selected tier's global clean-wave requirement: 1 for
   `small`, 2 for `normal`, and 3 for `complex`. A candidate branch cannot
   lower the active gate, and the loop has no outer iteration
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
   If an interrupt leaves `.phase-3.busy` behind and the Stop hook reports that
   its recorded owner PID is dead, do not remove state files or wait for the
   ordinary timeout. Run exactly:
   `bash "$DEX_DIR/bin/control.sh" recover review --source agent --reason "<why the review owner stopped>"`.
   Use this only for the dead-owner diagnosis. The command refuses live or
   malformed state and leaves Phase 3 paused; then follow the user's direction
   to `/dxresume` or `/dxskip`.
8. **SCOPE**: focus on review and fixes. An active review wave owns its accepted
   fixes: commit and push coherent checkpoints as they form, then complete the
   required rechecks before reporting `FINDINGS_FIXED:N`. Do not switch branches
   or create or update a PR. Phase 5 owns PR setup.
9. Output `PHASE_3_COMPLETE` only when the current scope has a valid review
   receipt binding the approved criteria, trusted policy, attested clean
   ledger, and any lower-target override. Report whether the trusted target
   passed or the attributed lower target was waived.
10. Review children report tracker candidates only. The lifecycle owner applies
    `prompts/issue-hygiene.md` once for accepted findings so waves cannot create
    duplicate follow-up issues.

### Phase 4: Verify

1. Run `/dxverify` — format, lint, typecheck, generate, test.
2. Fix any failures. Re-run until all green, using the current retry defaults from `dx_failure_attempts_per_strategy` and `dx_failure_max_strategies` as described in `prompts/failure-recovery.md`.
3. Treat this as the final PR gate, not the first opportunity to commit. As
   verification repairs reach coherent checkpoints, run `/dxcommit` and push
   each one immediately even while later checks are still pending or failing.
   After the complete pipeline passes, confirm the branch is clean and its HEAD
   is on origin.
4. Output `PHASE_4_COMPLETE` when all checks pass and every branch-specific
   commit is pushed. A newly created local branch with no branch-specific
   commits cannot use the ordinary Phase 4 completion path; return to Phase 2's
   user-direction path instead of publishing it.
5. Apply `prompts/issue-hygiene.md` to material verification discoveries before
   the phase handoff.

### Phase 5: PR

1. Run `/dxpr` — generate the PR description, refresh any UI after-capture handoff, create or update the PR, attach `request`-type reviewers from `dex.md § Reviewers`, mark the PR ready for review, and update the tracker if available.
2. Reconcile the working issue, related issues, and PR under
   `prompts/issue-hygiene.md` before finalizing its copy.
3. Phase 5 must leave the PR ready for review. Phase 6 verifies readiness and normally owns the `@mention` comments.
4. Output `PHASE_5_COMPLETE` only when the PR is current, ready for review, and reviewers are attached.

### Phase 6: Complete (autonomous)

1. Read `## Reviewers` from `dex.md`. On the first cycle: verify the PR is ready and use `gh pr ready` if recovery is needed, re-sync `request` reviewers (idempotent), and post one `@mention` comment listing all `mention` reviewers.
2. Set up monitoring: `/loop 5m /dxwatchpr`. The PR watcher handles both CI failures and review feedback.
3. Re-read `dx_complete_wait_minutes` (default 5) each cycle. The Stop hook re-injects the audit and only authorizes outcome evaluation once the current window has elapsed.
4. Escalate by default when a loop reaches `dx_complete_ci_fix_attempts`, or encounters architectural review comments, a secrets scan failure, or a scope conflict. Ask for or record a justified waiver when an exception is appropriate.
5. After each push: re-request `request` reviewers and post a fresh mention comment so reviewers know there's something new.
6. After the current `dx_complete_max_cycles` value (default 3) is reached with no progress, escalate to the user.
7. When CI green AND all successfully requested `request` reviewers have approved, run `/dxcomplete`'s final verification — update tracker to Done, print summary.
8. Apply `prompts/issue-hygiene.md` once to accepted CI or review discoveries;
   scheduled watcher cycles must not create duplicate follow-ups.
9. Output `DEX_TICKET_COMPLETE` once verification passes.

## Resuming

If the session is interrupted, `dx 999` or `dx --resume` picks up from the saved phase. Phase tracking is handled by the `dx` shell lifecycle (see `dx.sh` `__dx_run_phases_inline`), which persists the current phase number in `~/.claude/.dex-phases/<session_id>.phase`. The Stop hook is responsible for advancing phases in-session by updating phase state and injecting the next phase message and audit prompt.

An interrupted Phase 3 review may need fence recovery before resume. Trust the
Stop hook's PID diagnosis, not the marker's age: recover only when it says the
owner is dead, never while it says review is still running. Recovery is
maintenance, not evidence that review passed.

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
