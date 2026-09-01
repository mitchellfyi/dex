---
name: "dxcommit"
description: "Stage, commit, and push a coherent checkpoint whenever work reaches a useful history boundary."
---

# Skill: dxcommit

Stage, commit, and push coherent checkpoints following the repo's commit
discipline.

## When to Use

- Throughout implementation, review, and verification whenever the current
  changes form a small, coherent checkpoint
- After a focused check, even when broader or final verification is still
  pending or currently failing
- When a local commit exists but has not reached the remote branch

## Steps

### 1. Understand the Changes

```bash
git status
git diff --stat
```

Review what has changed and identify logical groupings for atomic commits. If
the working tree is clean, check whether the current branch has an unpushed
branch-specific commit from an earlier failed push. Continue to the push check
when it does. Otherwise stop: do not publish a newly created branch merely to
establish upstream tracking, and do not create an empty commit.

Do not run or wait for the full verification pipeline merely to make the
changes committable. Run a useful focused check when practical, preserve its
actual result in the status report, and commit the coherent checkpoint whether
that check passed, failed, or remains pending. Final verification gates PR
handoff, not the existence of working-history commits.

### 2. Stage, Commit, and Push Each Group

Read the commit format guide from the Dex prompts directory (`prompts/commit-format.md`) for the full format specification.

For each logical group, finish all four steps before starting the next group:

1. **Stage specific files** — never use `git add -A` or `git add .`:
   ```bash
   git add path/to/file1 path/to/file2
   ```

2. **Check for forbidden and sensitive files** — verify none are staged:
   ```bash
   git diff --cached --name-only
   ```

3. **Write a conventional commit message** following the format in `prompts/commit-format.md`. Include the Dex `Co-Authored-By` trailer and no Claude attribution:
   ```
   Co-Authored-By: Dex <noreply@dexcode.ai>
   ```
   Do not include `Generated with Claude Code`, `Co-Authored-By: Claude ...`, or any similar Claude Code footer.

4. **Push immediately.** The first real commit on a new local branch establishes
   its upstream; every later commit pushes to that upstream before another
   commit is created:

   ```bash
   current_branch=$(git branch --show-current)
   upstream=$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true)
   if [[ -z "$upstream" || "$upstream" != "origin/${current_branch}" ]]; then
     git push -u origin HEAD
   else
     git push
   fi
   ```

   Verify the push succeeded before staging the next logical group. If it fails
   because the remote diverged, investigate; do not force-push without user
   approval.

### 3. Final Sync Check

Confirm the working tree is clean, the current branch contains at least one
branch-specific commit, and local HEAD matches `origin/<current-branch>`. A
newly created branch with no branch-specific commits stays local.

Do not confuse this sync check with final verification. It proves that the
checkpoint was recorded and pushed, not that the branch is ready for a PR.
