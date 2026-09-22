Before stopping, audit the final PR gate and commit quality. This phase does
not reserve commits until verification is green: while repairing a failing
gate, commit and push each coherent checkpoint as it forms, then continue the
pipeline. The complete required pipeline must pass before Phase 5.

Follow § Resource Discipline in `prompts/guardrails.md`: heavy work queues through `dx run-gate`; own what you start.

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

Every required gate needs a passing result for *this* tree, and this is the
phase that runs the complete suite. Before running it, ask
`bash "$DEX_DIR/bin/gate-receipt.sh" full-gate` (0 reuse, 1 run it, 3 it failed here):
a `full-gate` receipt Phase 2 wrote on this exact checkout and working tree is
the evidence, so reuse it and say so; a receipt for any other gate is not.
Otherwise run `dx run-gate --name full-gate <project aggregate gate>` now, which
records the receipt; one that failed on this tree is a gate to fix, not to
re-run. When `.dex/dex.md` § Resources declares `full_gate: ci`, run the fast
gates and focused tests here, leave the complete suite to CI, keep the PR a
draft, and let Phase 6 treat CI as the final gate — unless this ticket
changed the gates, CI, or test infrastructure, which runs locally regardless.

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
implementation or review required. If final verification added more, commit them
as a coherent checkpoint, ideally `docs(.dex): sync project config`. Do not move
an implementation-owned `.dex/` update into Phase 4 because it was left staged.

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
affected checks; do not wait for the rest of the pipeline before recording one.

If you pushed and got errors (e.g., remote rejection, hook failures), fix the issues and push again.

If a newly created local branch has no branch-specific commits, keep it
unpushed. It cannot satisfy the ordinary Phase 4 completion gate or continue to
Phase 5; return to Phase 2's user-direction path instead. The user may stop the
lifecycle as no-change or choose an explicit lifecycle control action. Do not
create an empty commit.

## Completion criteria

ALL of these must be true before you stop:
- Every required gate has a passing result for this tree: a reused `dx run-gate`
  receipt with a matching fingerprint, a fresh run, or CI under `full_gate: ci`
- No session-owned background process in flight, per `dx ps`
- Commits are clean and atomic with conventional messages
- No unwanted files in the diff
- Any `.dex/` changes are committed cleanly
- Every branch-specific commit is pushed to origin successfully
- A newly created local branch with no branch-specific commits did not enter
  the ordinary Phase 4 flow
- Material verification findings were handled under
  `prompts/issue-hygiene.md`, and the summary contains `Issue/PR work:`

When all criteria are met, stop. The Stop hook will verify your work and provide completion instructions.
