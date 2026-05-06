IMPORTANT: Follow these steps in order. Use the ticket tracker configured in doyaken.md § Integrations. If no tracker is configured, skip tracker steps.

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

3. Set the ticket status to "In Progress" via the configured tracker. If no tracker, skip.

4. Check the ticket description (if a ticket was found):
   - If the description is empty, unclear, or missing acceptance criteria:
     a. Read related issues, comments, and explore the relevant code.
     b. Draft a short description (2-3 sentences) and acceptance criteria checklist.
     c. Present to the user for review.
     d. Once confirmed, update the ticket via the configured tracker.
   - If clear, skip to step 5.

5. Read the relevant AGENTS.md or README.md for the areas of code involved. Explore the codebase to understand scope and context.

6. Once setup steps 1–5 are complete, continue directly with the active workflow (e.g., `/doyaken`, `/dkplan`, `/dkimplement`, or whatever the user invoked). Do NOT pause to ask for go-ahead — running setup is part of carrying out the user's already-authorised request, and a separate "ready to start?" prompt is unnecessary friction. Print a brief one-line summary of what was set up (branch, ticket status) and then proceed. If the active workflow is `dk` Phase 1 planning, then after the user approves `ExitPlanMode`, stop once so the Stop hook can audit the plan and inject Phase 2 in the same session; do not tell the user to run `/dkimplement`. The user can interrupt at any time if they want to redirect.
