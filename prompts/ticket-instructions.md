IMPORTANT: These steps run in Phase 0 (Setup) of the `dk` lifecycle. Phase 0 runs in NORMAL mode (no plan mode), so you can write to git and the tracker before Phase 1 begins. Use the ticket tracker configured in doyaken.md § Integrations. If no tracker is configured, skip tracker steps. Do NOT call `EnterPlanMode` during this phase.

1. Gather ticket context from the configured ticket tracker:

   - Read ticket {{TICKET_NUM}} — title, description, acceptance criteria, and relations.
   - Read all comments on the ticket (for Linear: use `list_comments` with the issue ID). Comments often contain clarifications, decisions, and context not captured in the description.
   - If the tracker supports assignees: check the assignee. If assigned to someone else, STOP and warn. If unassigned, assign to the current user (for Linear: use `save_issue` with `assignee: "me"`).
   - If no tracker is configured: use the branch name `{{BRANCH}}` and the local filesystem for context. Ask the user what they want to work on.

2. Rename and push the branch — **do NOT create the draft PR yet**. The PR is created later by `/dkpr` (Phase 5) once the implementation has been committed. Creating it upfront on an empty branch fails with "No commits between main and …" and forces an empty bootstrap commit; deferring avoids that whole dance.

   **If ticket context was found**:
   - Rename to match the ticket's git branch name (returned by the tracker — e.g., Linear's `branchName` field from `get_issue`):
     ```
     git branch -m {{BRANCH}} <suggested-branch-name>
     git push -u origin <suggested-branch-name>
     ```

   **If no ticket context**:
   - Keep the current branch name `{{BRANCH}}`.
   - Push the branch so the remote tracks it:
     ```
     git push -u origin {{BRANCH}}
     ```

   - After renaming, update the per-session meta sidecar so `dk <N>` can find this worktree later even though the branch no longer matches `worktree-ticket-*`:
     ```bash
     source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"
     SID="${DOYAKEN_SESSION_ID:-$(dk_session_id)}"
     dk_meta_write "$SID" "tracker_key=<KEY-N>" "current_branch=$(git rev-parse --abbrev-ref HEAD)"
     ```
     Use the tracker's key (e.g. `ENG-999`). If no tracker is configured, only the `current_branch` field is required.

3. Set the ticket status to "In Progress" via the configured tracker. If no tracker, skip.

4. Check the ticket description (if a ticket was found):
   - If the description is empty, unclear, or missing acceptance criteria:
     a. Read related issues, comments, and explore the relevant code.
     b. Draft a short description (2-3 sentences) and acceptance criteria checklist.
     c. Present to the user for review.
     d. Once confirmed, update the ticket via the configured tracker.
   - If clear, skip to step 5.

5. Read the relevant AGENTS.md or README.md for the areas of code involved. Explore the codebase only enough to validate the bootstrap (e.g., confirm the branch name format matches existing conventions). Deep exploration is Phase 1's job.

6. Once setup steps 1–5 are complete, write the Phase 0 ready marker so the Stop hook can audit and advance:

   ```bash
   source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"
   touch "$(dk_phase_ready_file "${DOYAKEN_SESSION_ID:-$(dk_session_id)}" 0)"
   ```

   Then print a brief one-line summary of what was set up (branch, ticket status, assignee) and stop once. Do NOT call `EnterPlanMode`, do NOT invoke `/dkplan`, and do NOT wait for a "ready to start?" prompt — the Stop hook will inject Phase 1 instructions automatically. The user can interrupt at any time if they want to redirect.
