---
name: "dkpr"
description: "Generate a PR description, create a draft pull request, and attach request-type reviewers."
---

# Skill: dkpr

Generate a PR description, create a draft pull request, and attach `request`-type reviewers. Stays in draft — Phase 6 (`dkcomplete`) marks it ready and posts `@mention` comments.

## When to Use

- After `/dkcommit` has pushed all changes
- When the implementation is complete and verified

## Steps

### 1. Gather Context

Detect the default branch using the shared library function (see `lib/git.sh`):

```bash
source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"
DEFAULT_BRANCH=$(dk_default_branch)
git log origin/$DEFAULT_BRANCH..HEAD --oneline
git diff origin/$DEFAULT_BRANCH...HEAD --stat
```

Understand the full scope of changes across all commits. Note any `.doyaken/` file changes — these should be called out in the PR description.

### 2. Generate PR Description

**Debt ledger check**: Before generating the description, check if a debt ledger exists for this session:

```bash
source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"
DEBT_FILE=$(dk_debt_file "${DOYAKEN_SESSION_ID:-$(dk_session_id)}")
[[ -f "$DEBT_FILE" ]] && cat "$DEBT_FILE"
```

If the file exists and has content, include a "Technical Debt" section in the PR description with the ledger contents. This makes debt visible to reviewers.

Check if the project has a PR description template or prompt (referenced in CLAUDE.md or `.doyaken/doyaken.md`). If so, follow that template.

Otherwise, read the PR description template from the Doyaken prompts directory (`prompts/pr-description.md`) and follow its structure. Fill in every section with specifics from the implementation.

### 3. Create or Update the PR (always as draft)

Read the commit format prompt (`prompts/commit-format.md`) for title format guidance.

If a PR doesn't yet exist for the current branch, create one as a **draft**:

```bash
PR_NUM=$(gh pr view --json number -q .number 2>/dev/null)
if [[ -z "$PR_NUM" ]]; then
  gh pr create --draft --title "<title>" --body "$(cat <<'EOF'
<generated description>
EOF
)"
  PR_NUM=$(gh pr view --json number -q .number)
fi
```

If a PR already exists, update its title and body. Do NOT mark it ready — Phase 6 does that.

```bash
gh pr edit "$PR_NUM" --title "<title>" --body "$(cat <<'EOF'
<generated description>
EOF
)"
```

### 4. Attach Request-Type Reviewers

Read the `## Reviewers` section of `.doyaken/doyaken.md`. For every row whose Type column is `request`, attach the reviewer to the draft PR:

```bash
gh pr edit "$PR_NUM" --add-reviewer "<handle-without-leading-@>"
```

Notes:
- `gh pr edit --add-reviewer` is idempotent — re-running on a PR that already has the reviewer is a no-op.
- GitHub does NOT send notifications for review requests on a **draft** PR. The notifications fire when Phase 6 marks the PR ready. Attaching reviewers now is purely so they're already in place when the PR goes ready.
- Skip rows whose Type is `mention` — those are posted as PR comments by Phase 6, not added as review requests.
- Skip the placeholder row (`_none_` handle) — it means the user has chosen not to assign anyone.
- Strip a leading `@` from the handle if present (e.g., `@octocat` → `octocat`). `gh` rejects the `@` prefix.

If the `## Reviewers` section is missing or empty, skip this step entirely.

### 5. Update Ticket (if tracker configured)

Add an implementation summary to the ticket via the configured tracker (see doyaken.md § Integrations) — what was implemented, key decisions, deviations from plan. If no tracker is configured, skip — the PR description covers this.

### 6. Hand Off to Phase 6

Print a summary of the draft PR for the user:
- PR link
- PR description preview (title + summary section)
- List of `request` reviewers attached
- Implementation summary

Then output:

```
Phase 5 complete. The PR is in DRAFT state with reviewers pre-attached.
Phase 6 (Complete) will mark it ready, request reviews, post @mention comments,
monitor CI/reviews, address comments, and close the ticket.
```

Do NOT call `gh pr ready`. Do NOT post `@mention` comments. Do NOT launch `/loop` monitoring. Those belong to Phase 6.

## Notes

- Keep the PR description factual and specific — no filler or marketing language.
- If a ticket link is available, include it in the PR body for auto-linking.
- The PR is created as a DRAFT in Phase 5 so reviewers are not notified prematurely. Phase 6 flips it to ready and triggers the notifications by re-requesting the same reviewers.
