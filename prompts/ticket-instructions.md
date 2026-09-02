IMPORTANT: These steps run in Phase 0 (Setup) of the `dx` lifecycle. Phase 0 runs in NORMAL mode (no plan mode), so you can write to git and the tracker before Phase 1 begins. Use the ticket tracker configured in dex.md § Integrations. If no tracker is configured, skip tracker steps. Do NOT call `EnterPlanMode` during this phase.

1. Gather ticket context from the configured ticket tracker:

   - Read ticket {{TICKET_NUM}} — title, description, acceptance criteria, and relations.
   - Read all comments on the ticket (for Linear: use `list_comments` with the issue ID). Comments often contain clarifications, decisions, and context not captured in the description.
   - Read and apply `prompts/issue-hygiene.md`: search open and closed tracker
     items with several semantic queries, read strong duplicate and related
     candidates, and inspect the current branch's existing open PR when one
     exists. Reconcile accepted comment decisions into the issue and stale PR
     body. Do not create a new PR, mark one ready, request reviewers, or post
     review notifications during this setup step.
   - If the tracker supports assignees: check the assignee. If assigned to someone else, pause and warn by default; do not silently reassign. A reasoned `setup.ticket-ownership` waiver may continue without claiming ownership changed. If unassigned, assign to the current user (for Linear: use `save_issue` with `assignee: "me"`).
   - If no tracker is configured: use the branch name `{{BRANCH}}` and the local filesystem for context. Ask the user what they want to work on.

2. Prepare the tracker's branch locally, but do not publish a new branch during
   setup. Use the shared helper so an existing remote branch is never mistaken
   for a new one. The helper checks `origin` directly, fetches the exact branch,
   verifies that it has an open PR or no PR, adopts its current tip, establishes
   upstream tracking, and updates the saved lifecycle branch. It stops without
   changing the local branch when the checkout is dirty, the remote is
   unavailable, branch histories conflict, or the remote branch has only closed
   or merged PRs.

   A genuinely new lifecycle branch should stay local until it contains its
   first real implementation commit. Do not create an empty bootstrap commit
   just to make the branch pushable. Phase 2 establishes upstream tracking after
   that first commit, then pushes every later commit as it is created. The
   default workflow leaves PR creation and readiness to `/dxpr` in Phase 5. If the user
   asks for a PR during setup and the new branch has no branch-specific commits,
   report that it will be created after the first implementation commit.

   **If ticket context was found**:
   - Prepare the ticket's git branch name returned by the tracker (for example,
     Linear's `branchName` field from `get_issue`):
     ```
     source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh" || exit 1
     BRANCH_SOURCE=$(dx_ticket_branch_prepare "<suggested-branch-name>" "$(pwd)") || exit 1
     ```
     `BRANCH_SOURCE` is `remote`, `local`, or `new`. Include it in the setup
     summary. Do not reproduce the fetch, PR-state, reset, switch, or tracking
     logic by hand.

   **If no ticket context**:
   - Keep the current branch name `{{BRANCH}}`.

   **For both cases**:
   - Update the per-session meta sidecar so `dx <N>` can find this worktree
     later even when the branch no longer matches `worktree-ticket-*`:
     ```bash
     source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh" || exit 1
     SID="${DEX_SESSION_ID:-$(dx_session_id)}"
     dx_meta_write "$SID" "tracker_key=<KEY-N>" "current_branch=$(git rev-parse --abbrev-ref HEAD)"
     ```
     Use the tracker's key (e.g. `ENG-999`). If no tracker is configured, only the `current_branch` field is required.

3. Set the ticket status to "In Progress" via the configured tracker. If no tracker, skip.

4. Check the ticket description (if a ticket was found):
   - If the description is empty, unclear, or missing acceptance criteria:
     a. Read related issues, comments, and explore the relevant code.
     b. Draft a short description (2-3 sentences) and acceptance criteria checklist.
     c. Invoke the `humanizer` skill on the draft. Preserve factual requirements, ticket IDs, checkboxes, commands, and acceptance criteria exactly.
     d. Present to the user for review.
     e. Once confirmed, update the ticket via the configured tracker.
   - If clear, skip to step 5.

5. Read the relevant AGENTS.md or README.md for the areas of code involved. Explore the codebase only enough to validate the bootstrap (e.g., confirm the branch name format matches existing conventions). Deep exploration is Phase 1's job.

6. Once setup steps 1–5 are complete, write the Phase 0 ready marker so the Stop hook can audit and advance:

   ```bash
   source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh" || exit 1
   touch "$(dx_phase_ready_file "${DEX_SESSION_ID:-$(dx_session_id)}" 0)"
   ```

   Then print a brief setup summary covering the branch, ticket status,
   assignee, duplicate and related searches, any issue or existing-PR updates,
   and any linked issues created. End with the exact `Issue/PR work:` line from
   `prompts/issue-hygiene.md`. Do NOT call `EnterPlanMode`, do NOT invoke
   `/dxplan`, and do NOT wait for a "ready to start?" prompt — the Stop hook
   will inject Phase 1 instructions automatically. The user can interrupt at
   any time if they want to redirect.
