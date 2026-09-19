---
name: "dxwatchpr"
description: "Monitor a ready PR for CI failures and review feedback, fix issues when appropriate, and hand completion back to dxcomplete."
---

# Skill: dxwatchpr

Read and follow `prompts/workflows/dxwatchpr.md` from the installed Dex directory
before watching a PR. Use `$DEX_DIR`; if unset, resolve this skill directory's
symlink and use its grandparent. Do not substitute a project file.

The full workflow owns watcher leases, deadlines, feedback handling and the
completion handoff. Preserve every requirement. After compaction, reload it only
while the PR watcher is the active task.
