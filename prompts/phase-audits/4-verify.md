Before stopping, audit the final PR gate and commit quality. This phase does
not reserve commits until verification is green: while repairing a failing
gate, commit and push each coherent checkpoint as it forms, then continue the
pipeline. The complete required pipeline must pass before Phase 5.

Apply `prompts/issue-hygiene.md` when verification exposes material new
requirements, a distinct defect, or stale issue/PR context. Do not create an
issue for a transient test failure that was fixed as part of the accepted
scope. End the phase summary with the contract's exact `Issue/PR work:` line.

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

Earlier phases should already have committed and pushed any `.dex/` updates
required by implementation or review. If final verification added further
`.dex/` changes, commit them as a coherent checkpoint, ideally as a separate
`docs(.dex): sync project config` commit. Do not move an implementation-owned
`.dex/` update into Phase 4 merely because it was left staged.

## Step 3: Diff review

Run `git diff --stat origin/<default-branch>` and review:
- Does the overall diff look clean and focused?
- Are there any unexpected files in the diff?
- Is the total scope of changes proportional to the task?

## Step 4: Push

Earlier phases should already have pushed their implementation and review-fix
checkpoints. Confirm local HEAD matches `origin/<current-branch>`. If final
verification still left changes, split them only at natural logical boundaries,
commit and push each coherent repair checkpoint immediately, and rerun the
affected checks. Do not wait for the rest of the pipeline to pass before
recording a checkpoint.

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
- Material verification findings were handled under
  `prompts/issue-hygiene.md`, and the summary contains `Issue/PR work:`

When all criteria are met, stop. The Stop hook will verify your work and provide completion instructions.
