---
name: "dksync"
description: "Refresh Doyaken repo memory and rules by promoting verified observations into reviewable `.doyaken/` context."
---

# Skill: dksync

Refresh Doyaken's repo memory, rules, guards, and candidate workflow context.

## When to Use

- After `dk init` to build or refresh the first memory scaffold.
- When the user asks to sync, learn, refresh context, or update repo memory.
- After repeated review comments, CI failures, or implementation lessons reveal
  a durable repo pattern.
- Before a background maintenance run that should use the latest repo context.

## Contract

Read and follow `prompts/sync-memory.md`. That prompt is the source of truth for:

- raw observations vs trusted memory
- promotion and rejection criteria
- `.doyaken/memory/domains/` entry shape
- retrieval tracing
- sync reports

Do not create `.doyaken/learnings.md`. Session observations stay outside trusted
repo memory until this skill promotes them through a reviewable `.doyaken/` diff.

## Arguments

Forward any user-provided arguments to the prompt contract:

- `--dry-run`
- `--state-dir <path>`
- `--since <ref|date>`
- `--no-pr`
- `--trace-retrieval <prompt-or-path>`
- `--phase <phase>`

## Output

End with the DKSync report described in `prompts/sync-memory.md`. If files were
changed, list each changed path and why it changed.
