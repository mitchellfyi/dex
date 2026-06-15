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

### Phase 0: Setup

1. Runs in NORMAL mode (no plan mode) so the agent can write to git and the tracker before any planning starts.
2. Follow `prompts/ticket-instructions.md` end to end:
   - Read the ticket from the configured tracker (including all comments).
   - If unassigned, assign the ticket to the authenticated user. If assigned to someone else, **[STOP]** and warn.
   - Rename the lifecycle branch to the tracker's git branch name and push it with upstream tracking. Do NOT create a draft PR — Phase 5 owns that step.
   - Set ticket status to **In Progress**.
   - If the description is empty or unclear, draft 2-3 sentences plus an acceptance-criteria checklist, present to the user, and update the ticket once confirmed.
   - Update the per-session meta sidecar with `tracker_key` and `current_branch` so future `dx <N>` invocations can find the worktree even after the branch rename.
3. **SCOPE**: ticket bootstrap only. Do NOT call `EnterPlanMode`, do NOT draft a plan, do NOT write source code, do NOT commit, do NOT open a PR.
4. When setup is complete, write the Phase 0 ready marker (`dx_phase_ready_file ... 0`) and stop once so the Stop hook can audit and advance to Phase 1 automatically.

### Phase 1: Plan

1. Phase 0 already handled ticket setup; do not redo it unless something is clearly missing (status still Backlog/Todo, no assignee, branch not renamed/pushed).
2. Run `/dxplan` — gather any remaining context, draft the implementation plan, create tasks.
3. **[STOP]** Present the plan to the user. Wait for approval.
4. If the user requests changes, revise and re-present.
5. When running under the terminal `dx` lifecycle, stop once immediately after approval so the Stop hook can audit the plan and inject Phase 2 in the same session. Do not tell the user to run `/dximplement`.
6. When running `/dex` interactively without the wrapper, output `PHASE_1_COMPLETE` when the user approves.

### Phase 2: Implement

1. Invoke the Skill tool with `skill: "dximplement"` — work through tasks with TDD discipline. The plan approval was the go-ahead; do not pause to ask for permission.
2. **[STOP]** if ambiguous requirements, scope changes, or blocked dependencies arise.
3. For UI-affecting changes, invoke `/dxuicapture` before UI edits for baseline evidence, then again after implementation. Capture screenshots/traces, record video for interactive flows, and link the `visual-evidence.md` manifest from Dex's artifact directory.
4. End Phase 2 with a manual local smoke test: run the change end-to-end locally and confirm it works, driving browser-facing flows with the Claude-in-Chrome browser tools (Playwright fallback), seeding and then cleaning up local data as needed.
5. The audit loop verifies all tasks are complete with tests passing, the evidence table filled, the manual smoke test passed or explicitly N/A, and UI capture evidence present or explicitly N/A.
6. **SCOPE**: implementation, testing, and UI capture evidence ONLY. Ticket setup belongs to Phase 0 — only re-run it here if Phase 0 left it incomplete. Do NOT commit or push implementation code (Phase 4 owns that), and do NOT update the PR description (Phase 5 owns that).
7. Output `PHASE_2_COMPLETE` when all tasks are implemented and the evidence table shows all criteria MET.

### Phase 3: Review

1. Invoke `/dxreviewloop` to run the adaptive adversarial review loop.
2. Each `/dxreviewloop` iteration runs one full review wave in a fresh CLI
   session: compact context pack, deterministic checks, issue harvest, verifier
   triage when needed, batch fixes, and targeted recheck.
3. Waves that find and fix issues write `FINDINGS_FIXED:N`, reset the clean
   counter, and force the next iteration to re-review the full change set.
4. The loop requires the resolved profile's consecutive `CLEAN` gate to advance.
5. **SCOPE**: review and fix ONLY. Do NOT commit, push, or create PRs.
6. Output `PHASE_3_COMPLETE` when review is clean.

### Phase 4: Verify & Commit

1. Run `/dxverify` — format, lint, typecheck, generate, test.
2. Fix any failures. Re-run until all green (max 3 retries per check).
3. Run `/dxcommit` — atomic conventional commits, push to origin.
4. Output `PHASE_4_COMPLETE` when all checks pass and code is pushed.

### Phase 5: PR

1. Run `/dxpr` — generate PR description, refresh any UI after-capture handoff, create draft PR, attach `request`-type reviewers from `dex.md § Reviewers`, update tracker if available.
2. SCOPE: Do NOT mark the PR ready for review or post `@mention` comments — Phase 6 owns those steps so reviewers are notified at exactly the right moment.
3. Output `PHASE_5_COMPLETE` when the draft PR is created and reviewers are attached.

### Phase 6: Complete (autonomous)

1. Read `## Reviewers` from `dex.md`. On the first cycle: `gh pr ready`, re-sync `request` reviewers (idempotent), post one `@mention` comment listing all `mention` reviewers.
2. Set up monitoring: `/loop 5m /dxwatchpr`. The PR watcher handles both CI failures and review feedback.
3. Wait at least `DEX_COMPLETE_WAIT_MINUTES` minutes (default 5) per cycle. The Stop hook re-injects the audit and only authorizes outcome evaluation once the window has elapsed.
4. **[STOP]** if a loop escalates (CI failures after 3 attempts, architectural review comments, secrets scan, scope conflict).
5. After each push: re-request `request` reviewers and post a fresh mention comment so reviewers know there's something new.
6. After `DEX_COMPLETE_MAX_CYCLES` (default 3) idle cycles with no progress, escalate to the user.
7. When CI green AND all successfully requested `request` reviewers have approved, run `/dxcomplete`'s final verification — update tracker to Done, print summary.
8. Output `DEX_TICKET_COMPLETE` once verification passes.

## Resuming

If the session is interrupted, `dx 999` or `dx --resume` picks up from the saved phase. Phase tracking is handled by the `dx` shell lifecycle (see `dx.sh` `__dx_run_phases`), which persists the current phase number in `~/.claude/.dex-phases/<session_id>.phase`. The Stop hook is responsible for advancing phases in-session by updating phase state and injecting the next phase message and audit prompt.

As a fallback (e.g., when running `/dex` interactively without the wrapper), the agent can infer the correct phase by checking current state:

1. **Check for existing PR**: `gh pr view --json state,isDraft,statusCheckRollup`
   - No PR + branch still on `worktree-ticket-*` or `worktree-task-*` and ticket status is not yet In Progress → Phase 0 (Setup)
   - No PR + bootstrap done (branch renamed, status In Progress) → Phase 1 (Plan)
   - Draft PR, no commits → Phase 1 (Plan)
   - Draft PR with implementation commits → Phase 4 (Verify & Commit)
   - Ready PR with failing CI → Phase 6 (Complete — monitor and fix)
   - Ready PR with all checks green → Phase 6 (Complete — finalize)

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
| 2-5 | Normal phase completion | Stop once; the Stop hook injects the next phase automatically |
| 5 | Draft PR created | Stop; Phase 6 takes over automatically |
| 6 | CI secrets scan failure | Cancel all loops, alert immediately |
| 6 | 3 failed CI fix attempts | Cancel loops, escalate with details |
| 6 | Architectural review comment | Cancel loops, escalate to user |
| 6 | Max cycles reached idle | Escalate to user (no progress) |

## Autonomous Mode (Phase Audit Loops)

When the session is started by `dx`, a Stop hook prevents premature exit and injects a phase-specific audit prompt. Activation is signaled via an `.active` file in `~/.claude/.dex-loops/` (and optionally the `DEX_LOOP_ACTIVE=1` env var as a belt-and-suspenders mechanism). Each phase has its own quality criteria — the loop continues until the audit is satisfied. This enables quality-gated autonomous execution:

- If `/dxverify` fails → fix and retry automatically
- If `/dxreviewloop` finds issues → fix and re-review automatically
- If CI fails → fix and re-push automatically
- If reviews have comments → address and re-push automatically

The loop continues until:
1. **Completion promise**: Output `DEX_TICKET_COMPLETE` when ALL of these are true:
   - All tasks completed
   - PR approved with all checks green
   - All review comments addressed
   - Ticket updated to Done (if tracker configured)
2. **Max iterations reached** (default: 30) — safety net to prevent runaway costs
3. **User interrupts** — the user can always take over

### When to output the completion promise

Only output `DEX_TICKET_COMPLETE` when you have verified:
- `gh pr view --json state,statusCheckRollup` shows the PR is open/ready and all checks passed
- No unresolved review threads
- Ticket state is "Done" or "Closed" (if tracker configured)

### Escalation in autonomous mode

Even in autonomous mode, STOP and escalate to the user for:
- Secrets scan failures (never auto-fix)
- Architectural review comments (need human judgement)
- 3+ failed attempts at the same fix
- Scope changes that affect other tickets

## Notes

- The user can interrupt at any point and the agent should gracefully stop.
- Each phase naturally flows into the next — no manual invocation needed after `/dex`.
- The agent should provide brief status updates at phase transitions, but must not wait for the user except at the decision points above.
- Keep the configured ticket tracker updated throughout (see dex.md § Integrations). If no tracker is configured, the conversation and PR serve as the record.
