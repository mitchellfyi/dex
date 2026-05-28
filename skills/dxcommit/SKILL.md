---
name: "dxcommit"
description: "Stage, commit, and push changes following the repo's commit discipline after verification passes."
---

# Skill: dxcommit

Stage, commit, and push changes following the repo's commit discipline.

## When to Use

- After `/dxverify` passes all quality gates
- When ready to push changes to the remote branch

## Steps

### 1. Understand the Changes

```bash
git status
git diff --stat
```

Review what has changed. Identify logical groupings for atomic commits. If there are no changes to commit (clean working tree, nothing staged), **stop here** — inform the user and skip the remaining steps.

### 2. Stage and Commit

Read the commit format guide from the Dex prompts directory (`prompts/commit-format.md`) for the full format specification.

For each logical group:

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

### 3. Push

```bash
current_branch=$(git branch --show-current)
upstream=$(git rev-parse --abbrev-ref --symbolic-full-name @{u} 2>/dev/null || true)
if [[ -z "$upstream" || "$upstream" != "origin/${current_branch}" ]]; then
  git push -u origin HEAD
else
  git push
fi
```

Verify the push succeeded. This handles newly created Dex lifecycle branches whose first checkout was based on the default branch's upstream or remote-tracking ref, but whose push target must be their own branch. If push fails due to diverged history, investigate — do not force push without user approval.
