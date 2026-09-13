# Free-form workflow intake

Use this during Phase 0 when the user chose the full workflow for a prompt.
The mode choice authorizes the lifecycle; ask before creating its tracker
issue. Session-only launches do not run this intake.

1. Read the original request, `.dex/dex.md` integrations, and relevant project
   context. Explore enough code to establish scope, testable acceptance
   criteria, a rough estimate, and any dependencies. Ask about consequential
   gaps. Keep implementation planning for Phase 1.
2. Apply `prompts/issue-hygiene.md` to search open and closed issues and related
   PRs. Read strong matches. Reuse an existing issue that covers the request;
   ask which issue to use when the matches are ambiguous. Do not reopen closed
   work or expand another issue's scope without approval.
3. If a new issue is needed, draft its title, scope, acceptance criteria, and
   estimate using project conventions. Apply `humanizer`, show the draft, and
   ask whether to create it. If the work needs several issues, propose that
   split and ask which issue this workflow should implement. Create only the
   approved issues, after a final duplicate check. Record their returned URLs.
4. If the user declines creation, offer to continue this workflow without an
   issue or stop. Do not treat silence as approval. If no tracker is configured,
   retain the scoped request in the conversation and continue without an issue.
   A headless run follows its run spec: do not ask interactive questions or
   create issues unless the spec authorizes creation. Failed tracker access is
   a blocker to report, not evidence that an issue does not exist.
5. Record the outcome in the session metadata with `dx_meta_write`:

   ```bash
   source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh" || exit 1
   SID="${DEX_SESSION_ID:-$(dx_session_id)}"
   dx_meta_write "$SID" "intake_decision=<existing|created|declined|unavailable>"
   ```

   Use `existing` or `created` only after reading the selected issue, and also
   save `tracker_key=<KEY-OR-URL>` and `ticket_number=<NUMBER-IF-GITHUB>`.
   Use `declined` only when the user chose to continue without an issue;
   `unavailable` means no configured tracker or a headless spec without issue
   creation authorization. Explain the decision in the setup summary.
6. Continue `prompts/ticket-instructions.md` with the selected issue: assignment,
   branch preparation through `dx_ticket_branch_prepare`, status, and the
   Phase 0 ready marker. If continuing without an issue, keep the task branch
   and mark ticket-specific steps N/A. Then let the normal phase handoff start
   planning. Do not launch a second nested lifecycle or implement during intake.

On resume, read the recorded decision and selected issue first. Honor the
user's decision without repeating issue creation or its approval question.
Phase 1 may refine the plan and update the selected issue within the approved
scope; changes to that scope still need the user's decision.
