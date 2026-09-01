> **Note:** Phase 0 (Setup) runs in NORMAL mode (not plan mode). Its job is to
> bootstrap ticket state — tracker assignment, local branch resolution, and
> ticket status → In Progress — before Phase 1 (Plan) begins. This audit only
> runs after the Phase 0 ready marker has been written.

Before stopping, audit your ticket bootstrap. Each item below must be verifiable. If any item is unmet, finish it now instead of stopping.

Read and apply `prompts/issue-hygiene.md`. Phase 0 owns the full duplicate and
relationship search, reconciliation of accepted decisions into the working
issue, and reconciliation of any existing open PR. End the phase summary with
the exact `Issue/PR work:` line required by that contract.

## 1. Ticket Read

- The ticket was fetched from the configured tracker (see `.dex/dex.md` § Integrations).
- Title, description, acceptance criteria, and **all comments** were read.
- If no tracker is configured: this step is N/A.

Evidence: tracker tool invocation succeeded, or N/A.

## 2. Assignee

- If the tracker supports assignees: the ticket is assigned to the authenticated user.
- If the ticket was already assigned to someone else: you paused and warned the user by default. Do not silently reassign. A reasoned `setup.ticket-ownership` waiver may continue without claiming the assignee changed.
- If no tracker is configured: this step is N/A.

Evidence: tracker output shows the assignee, or N/A.

## 3. Local Branch Resolution

- The lifecycle branch was prepared with `dx_ticket_branch_prepare` using the
  tracker's git branch name (for example, `feat/ENG-999-fix-login`). If no
  tracker was configured, the lifecycle branch name was kept as-is.
- When the tracker supplied a branch name, session metadata records
  `ticket_branch_source` as `remote`, `local`, or `new`. A `remote` result also
  records `ticket_branch_pr_kind` as `OPEN` or `NONE`, plus the fetched commit
  as `ticket_branch_remote_oid`. If no tracker was configured, these fields are
  N/A.
- For a remote result, the current branch tracks
  `origin/<tracker-branch>`, the recorded remote commit is reachable from local
  `HEAD`, and the work started from the fetched branch rather than the default
  branch. A network or GitHub lookup failure was not treated as a missing
  branch.
- A remote branch with only closed or merged PRs was not adopted. Setup paused
  for explicit direction instead of silently reviving completed or abandoned
  work.
- A newly created branch with no branch-specific commits was not pushed merely
  to establish upstream tracking. No empty bootstrap commit was created. Phase
  2 will push the branch immediately after its first implementation commit.
- Draft PR creation was left for Phase 5 by default. If the user requested a PR
  during setup but the branch had no branch-specific commits, the setup summary
  records that publication is deferred until the first implementation commit.
- The Dex meta sidecar reflects the resolved branch: run

  ```bash
  source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh" || exit 1
  SID="${DEX_SESSION_ID:-$(dx_session_id)}"
  dx_meta_write "$SID" "tracker_key=<KEY-N>" "current_branch=$(git rev-parse --abbrev-ref HEAD)"
  ```

  using the tracker's key (e.g. `ENG-999`). This lets future `dx <N>` invocations resume the right worktree even after a rename.

Evidence: `git rev-parse --abbrev-ref HEAD` shows the resolved name;
`git rev-parse --abbrev-ref --symbolic-full-name '@{u}'` and
`git merge-base --is-ancestor '@{u}' HEAD` pass for a remote result; the setup
command history contains no empty commit or first push for a new branch; and
`dx_meta_read` shows `tracker_key`, `current_branch`, `ticket_branch_source`,
and the applicable remote metadata.

## 4. Ticket Status → In Progress

- If the tracker supports status: the ticket is now In Progress (or the equivalent active state).
- If no tracker is configured: this step is N/A.

Evidence: tracker output shows the new status, or N/A.

## 5. Description / Acceptance Criteria

- If the ticket description was empty, unclear, or missing acceptance criteria, you drafted them (2–3 sentences plus a checklist), presented them to the user, and updated the ticket after the user confirmed.
- If the description was already clear, this step is N/A.

Evidence: tracker comment or update record, or N/A.

## 6. Phase Focus Recorded

- Setup stayed focused on tracker, branch, and ticket bootstrap.
- Planning and source work normally remain with Phases 1 and 2.
- Phase 2 records implementation checkpoints, Phase 3 records accepted review
  fixes, and Phase 4 runs final verification while recording any repair
  checkpoints. Phase 5 remains the default owner of pull-request setup.
- Any commit, push, or pull-request action requested during Phase 0 is recorded in the setup summary so later phases continue from the actual repository and PR state.

## 7. Ready Marker

- The Phase 0 ready marker has been written (`dx_phase_ready_file "$SESSION_ID" 0`).
- If you stop before the marker exists, the Stop hook will refuse the handoff and ask you to finish setup.

## Completion Criteria

ALL of these must be true before you stop:
- Every applicable item in §§1–6 is done or explicitly N/A.
- Issue and PR hygiene is complete, and the summary contains `Issue/PR work:`.
- The ready marker (§7) is written.
- No Phase 0 background process is still running.

When all criteria are met, stop. The Stop hook will audit this phase and advance to Phase 1 (Plan) automatically.
