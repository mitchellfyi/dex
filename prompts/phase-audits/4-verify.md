Before stopping, audit the verification results and commit quality.

## Step 1: Verification checks

Confirm every quality gate passed:
- Format: PASS? If not, run the formatter and re-check.
- Lint: PASS? If not, fix lint errors (don't disable rules).
- Typecheck: PASS? If not, fix type errors.
- Tests: ALL passing? No skipped tests, no flaky failures? If any test was skipped or failed intermittently, investigate and fix the root cause.

Run /dxverify if you haven't already, or if you've made changes since the last run.

## Step 2: Commit quality

Review your commit history (`git log --oneline origin/<default-branch>..HEAD`):
- Are commits atomic? Each commit should contain one logical change.
- Do commit messages follow conventional format? (`type(scope): description`)
- Are there any commits that should be split or combined?
- Are there any files that should NOT have been committed?
  - Generated files that should be in .gitignore
  - Debug logs or temporary files
  - Files containing secrets or credentials

## Step 2.5: `.dex/` in commits

Phase 2 should already have committed and pushed any `.dex/` updates required
by implementation. If review or final verification added further `.dex/`
changes, commit them now, ideally as a separate
`docs(.dex): sync project config` commit. Do not move an implementation-owned
`.dex/` update into Phase 4 merely because it was left staged.

## Step 3: Diff review

Run `git diff --stat origin/<default-branch>` and review:
- Does the overall diff look clean and focused?
- Are there any unexpected files in the diff?
- Is the total scope of changes proportional to the task?

## Step 4: Push

Phase 2 should already have pushed each implementation commit. Confirm local
HEAD matches `origin/<current-branch>`. If Phase 3 review fixes or final
verification left changes, commit them atomically and push immediately.

If you pushed and got errors (e.g., remote rejection, hook failures), fix the issues and push again.

If a newly created local branch has no branch-specific commits, keep it
unpushed. It cannot satisfy the ordinary Phase 4 completion gate or continue to
Phase 5; return to Phase 2's user-direction path instead. The user may stop the
lifecycle as no-change or choose an explicit lifecycle control action. Do not
create an empty commit.

## Completion criteria

ALL of these must be true before you stop:
- All quality checks pass (format, lint, typecheck, tests)
- Commits are clean and atomic with conventional messages
- No unwanted files in the diff
- Any `.dex/` changes are committed cleanly
- Every branch-specific commit is pushed to origin successfully
- A newly created local branch with no branch-specific commits did not enter
  the ordinary Phase 4 flow

When all criteria are met, stop. The Stop hook will verify your work and provide completion instructions.
