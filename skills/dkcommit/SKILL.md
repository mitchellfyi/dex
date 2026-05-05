---
name: "dkcommit"
description: "Stage, commit, and push changes following the repo's commit discipline after verification passes."
---

# Skill: dkcommit

Stage, commit, and push changes following the repo's commit discipline.

## When to Use

- After `/dkverify` passes all quality gates
- When ready to push changes to the remote branch

## Steps

### 1. Understand the Changes

```bash
git status
git diff --stat
```

Review what has changed. Identify logical groupings for atomic commits. If there are no changes to commit (clean working tree, nothing staged), **stop here** — inform the user and skip the remaining steps.

### 2. Stage and Commit

Read the commit format guide from the Doyaken prompts directory (`prompts/commit-format.md`) for the full format specification.

For each logical group:

1. **Stage specific files** — never use `git add -A` or `git add .`:
   ```bash
   git add path/to/file1 path/to/file2
   ```

2. **Check for forbidden and sensitive files** — verify none are staged:
   ```bash
   git diff --cached --name-only
   ```

3. **Write a conventional commit message** following the format in `prompts/commit-format.md`. Include a `Co-Authored-By` trailer:
   ```
   Co-Authored-By: Doyaken <noreply@doyaken.ai>
   ```

### 3. Push

```bash
git push
```

Verify the push succeeded. If it fails due to diverged history, investigate — do not force push without user approval.
