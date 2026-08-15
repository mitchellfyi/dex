---
name: state-in-repo
enabled: true
event: file
match: path
pattern: \.dex/(?!worktrees/|guards/|rules/|dex\.md|CLAUDE\.md|\.gitignore).*\.(state|phase|times|complete|active|prompt)$
action: warn
---

Ephemeral state files must NOT be written inside the repo. State belongs in `~/.claude/.dex-phases/` or `~/.claude/.dex-loops/`, keyed by session ID.
