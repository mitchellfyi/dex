---
name: "dxpr"
description: "Generate or update a PR description, create or update the pull request, attach request-type reviewers, and mark the PR ready for review."
---

# Skill: dxpr

Read and follow `prompts/workflows/dxpr.md` from the installed Dex directory
before PR work. Use `$DEX_DIR`; if unset, resolve this skill directory's symlink
and use its grandparent. Do not substitute a file from the target project.

The full workflow owns verification evidence, attachments, reviewer selection,
attribution and marking the PR ready. Preserve every requirement. After
compaction, reload it only while PR preparation is the active task.
