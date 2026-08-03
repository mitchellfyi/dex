---
name: "dxsync"
description: "Refresh Dex project context, rules, and repo memory by re-analyzing the codebase and promoting verified observations into reviewable `.dex/` context."
---

# Skill: dxsync

Refresh Dex's project context, repo memory, rules, guards, and candidate
workflow context.

## When to Use

- After `dx init` to build or refresh the first project-context and memory
  scaffold.
- When the user asks to sync, learn, refresh context, re-analyze the repo, or
  update repo memory.
- After repeated review comments, CI failures, or implementation lessons reveal
  a durable repo pattern.
- Before a background maintenance run that should use the latest repo context.

## Contract

Before starting the memory refresh, run the same conservative tooling bootstrap
as `dx sync` unless the user requested `--dry-run` or `--trace-retrieval`:

```bash
repo_root=$(git rev-parse --show-toplevel)
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh" || exit 1
dx_bootstrap_agent_tooling "$repo_root" "install"
```

For `--dry-run` or `--trace-retrieval`, use mode `"check"` instead and report
any drift without changing tooling.

Read and follow `prompts/sync-memory.md`. That prompt is the source of truth for:

- raw observations vs trusted memory
- promotion and rejection criteria
- `.dex/memory/domains/` entry shape
- baseline codebase re-analysis and `.dex/dex.md` drift handling
- retrieval tracing
- sync reports

Do not create `.dex/learnings.md`. Session observations stay outside trusted
repo memory until this skill promotes them through a reviewable `.dex/` diff.

## Arguments

Forward any user-provided arguments to the prompt contract:

- `--dry-run`
- `--state-dir <path>`
- `--since <ref|date>`
- `--no-pr`
- `--trace-retrieval <prompt-or-path>`
- `--phase <phase>`
- `--budget-minutes <n>`
- `--include-working-tree`

## Output

End with the DXSync report described in `prompts/sync-memory.md`. If files were
changed, list each changed path and why it changed.
