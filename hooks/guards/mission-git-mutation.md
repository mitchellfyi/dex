---
name: mission-git-mutation
enabled: true
event: bash
detector: mission-git-mutation
action: warn
env_var: DX_MISSION_ACTIVE
env_value: "1"
---

A mission helper is about to run a git command that changes the tree, the
index or a branch (`commit`, `checkout`, `switch`, `reset`, `stash`, `clean`,
`rebase`, `merge`, `push`, `worktree`, `cherry-pick`, `am`). Only the lead
does that in a mission; helpers leave their changes in the working tree and
report what they changed in their `dx-result` block. A helper that commits,
stages everyone's changes or switches branch can take another helper's
unfinished work with it, and the lead can no longer tell whose change is
whose.

Read-only git (`status`, `diff`, `log`, `show`, `blame`, `rev-parse`) is fine.

This guard advises and records the attempt; it does not stop the command.
