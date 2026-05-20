> **Note:** Phase 0 (Setup) runs in NORMAL mode (not plan mode). Its job is to
> bootstrap ticket state — tracker assignment, branch rename, branch push, and
> ticket status → In Progress — before Phase 1 (Plan) begins. This audit only
> runs after the Phase 0 ready marker has been written.

Before stopping, audit your ticket bootstrap. Each item below must be verifiable. If any item is unmet, finish it now instead of stopping.

## 1. Ticket Read

- The ticket was fetched from the configured tracker (see `.doyaken/doyaken.md` § Integrations).
- Title, description, acceptance criteria, and **all comments** were read.
- If no tracker is configured: this step is N/A.

Evidence: tracker tool invocation succeeded, or N/A.

## 2. Assignee

- If the tracker supports assignees: the ticket is assigned to the authenticated user.
- If the ticket was already assigned to someone else: you STOPPED and warned the user (do NOT silently reassign).
- If no tracker is configured: this step is N/A.

Evidence: tracker output shows the assignee, or N/A.

## 3. Branch Rename and Push

- The lifecycle branch was renamed to the tracker's git branch name (e.g. `feat/ENG-999-fix-login`). If no tracker, the lifecycle branch name was kept as-is.
- The renamed (or kept) branch was pushed to `origin` with upstream tracking (`git push -u origin <branch>`).
- A draft PR was **not** created (Phase 5 owns that — creating it now would force an empty bootstrap commit).
- The Doyaken meta sidecar reflects the rename: run

  ```bash
  source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"
  SID="${DOYAKEN_SESSION_ID:-$(dk_session_id)}"
  dk_meta_write "$SID" "tracker_key=<KEY-N>" "current_branch=$(git rev-parse --abbrev-ref HEAD)"
  ```

  using the tracker's key (e.g. `ENG-999`). This lets future `dk <N>` invocations resume the right worktree even after a rename.

Evidence: `git rev-parse --abbrev-ref HEAD` shows the new name; `git ls-remote --heads origin <branch>` confirms the push; `dk_meta_read` shows `tracker_key` and `current_branch`.

## 4. Ticket Status → In Progress

- If the tracker supports status: the ticket is now In Progress (or the equivalent active state).
- If no tracker is configured: this step is N/A.

Evidence: tracker output shows the new status, or N/A.

## 5. Description / Acceptance Criteria

- If the ticket description was empty, unclear, or missing acceptance criteria, you drafted them (2–3 sentences plus a checklist), presented them to the user, and updated the ticket after the user confirmed.
- If the description was already clear, this step is N/A.

Evidence: tracker comment or update record, or N/A.

## 6. Scope Boundaries Observed

You did **not**:
- call `EnterPlanMode` (that belongs to Phase 1)
- draft an implementation plan (that belongs to Phase 1)
- write source code (that belongs to Phase 2)
- commit or push source changes (Phase 4 owns commits)
- create or modify a pull request (Phase 5)

If you did any of those, treat them as out-of-scope work for Phase 0 and either revert or document in the Phase 0 summary so Phase 1 can pick up cleanly.

## 7. Ready Marker

- The Phase 0 ready marker has been written (`dk_phase_ready_file "$SESSION_ID" 0`).
- If you stop before the marker exists, the Stop hook will refuse the handoff and ask you to finish setup.

## Completion Criteria

ALL of these must be true before you stop:
- Every applicable item in §§1–6 is done or explicitly N/A.
- The ready marker (§7) is written.
- No Phase 0 background process is still running.

When all criteria are met, stop. The Stop hook will audit this phase and advance to Phase 1 (Plan) automatically.
