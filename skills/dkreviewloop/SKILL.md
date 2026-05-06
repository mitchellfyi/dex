---
name: "dkreviewloop"
description: "Run dkreview repeatedly in fresh independent sessions until three clean reports in a row."
---

# Skill: dkreviewloop

Run `/dkreview --single-pass` repeatedly in fresh, independent sessions until **3 clean reports in a row** (max 10 iterations). Lighter-weight standalone alternative to the full dk Phase 3 review.

## When to Use

- When the user invokes `/dkreviewloop`
- Before committing or pushing significant work, when you want strong confidence the code is clean
- As an in-session counterpart to the `dkreviewloop` shell function (which spawns full Claude CLI sessions). The shell function is preferred when you can drop to the terminal; this skill is for when you're already inside a Claude Code session and want the same guarantee without exiting.

## Why "Fresh Sessions"

A single review pass can convince itself the code is clean — motivated reasoning kicks in right after fixing ("I just fixed it, so it must be fine"). Three **independent** passes, each starting from a blank context, agreeing that the code is clean, is a much stronger signal than one pass that says CLEAN.

## Steps

### 1. Detect the Diff Scope

Use this priority order to determine what to review. Stop at the first match:

1. **Staged changes** — `git diff --cached --quiet` exits non-zero → use `git diff --cached`
2. **Unstaged changes** — `git diff --quiet` exits non-zero → use `git diff`
3. **Unpushed commits** — `git log @{u}..HEAD --oneline` is non-empty → use `git diff @{u}...HEAD`
4. **PR diff vs default** — commits ahead of `origin/<default>` → use `git diff origin/<default>...HEAD`

If none of these find changes, stop and tell the user there is nothing to review.

Print the chosen scope (name + diff command + file count) before spawning the first subagent.

### 2. Spawn Fresh Review Sessions

For each iteration (up to **10**), spawn a fresh subagent via the **Agent tool** with `subagent_type: "general-purpose"`. Each Agent invocation is a fresh context window — that is the independence the user wants.

The subagent's prompt must include:

- The diff command from Step 1 (so the subagent reviews the right scope, not the default `origin/<default>...HEAD`)
- An instruction to invoke `/dkreview --single-pass` via the Skill tool
- A request to report back with: (a) the final result line — `CLEAN`, `PASS WITH WARNINGS`, or `NEEDS ATTENTION` — and (b) any remaining findings that the subagent did not auto-fix
- A reminder that the subagent should NOT commit, push, or create PRs

If no plan / acceptance criteria are available, tell the subagent to mark plan-dependent steps (Phase 5 / acceptance criteria, Phase 6 / evidence table from `prompts/phase-audits/3-review.md`) as **N/A** and proceed without them.

### 3. Track Consecutive Clean Passes

After each subagent returns, classify its result:

- **CLEAN** — no findings, or all remaining items are tracked as accepted debt → `clean_count += 1`
- **PASS WITH WARNINGS** — non-trivial findings remain → `clean_count = 0`
- **NEEDS ATTENTION** — high-severity findings remain → `clean_count = 0`

If the result is non-CLEAN: **fix the findings yourself in this orchestrator session** before spawning the next subagent. The subagent only reviews; the orchestrator owns the fixes so the next subagent sees the corrected state.

### 4. Exit Conditions

- **Success** — `clean_count >= 3` consecutive clean passes → done.
- **Safety net** — 10 iterations reached without 3 clean in a row → stop and report partial result. Do not loop forever.
- **User interrupt** — if the user redirects, halt and surface the current count.

### 5. Report

Print a final summary:

```
## dkreviewloop Result

- Scope:                 {staged | unstaged | unpushed | PR diff}
- Iterations:            N / 10
- Consecutive clean:     M / 3
- Result:                {SUCCESS | SAFETY-NET-EXIT}
- Findings fixed this run: K
```

If SAFETY-NET-EXIT, list the residual findings the subagents kept reporting so the user can decide whether to accept them as debt or escalate.

## Notes

- **Fresh sessions matter.** Do not "carry state" across iterations beyond `clean_count` and the diff scope. The orchestrator persists; each review pass must not.
- **Fixes belong to the orchestrator, reviews belong to subagents.** Subagents that fix things they review make the independence claim weaker. Keep the split clean.
- For the full dk Phase 3 experience (git checkpoints, audit-prompt enforcement via the Stop hook, `--fork-session` isolation between iterations), prefer the `dkreviewloop` shell function or `dk <ticket>` Phase 3. This skill is the in-session, lighter-weight variant.
- Do NOT commit, push, or create PRs from this skill. Review and fix only.
