---
name: "dkreview"
description: "Run one full-scope Doyaken review wave with deterministic checks, specialist reviewers, verifier triage, and batch fixes."
---

# Skill: dkreview

Run a single full-scope review wave. Direct user invocations still dispatch to
`/dkreviewloop`; the single-pass mode is for `/dkreviewloop` and Phase 3.

## Dispatch Mode

`/dkreview` without `--single-pass` or `--no-loop` must invoke the Skill tool
with skill: `dkreviewloop`, then stop.

Run the single-pass review-wave instructions only when one of these is true:

- the invocation includes `--single-pass` or `--no-loop`
- the caller explicitly says this is running from `/dkreviewloop`
- the caller explicitly says this is running by `/dkreviewloop`

If unsure, prefer the loop.

## Single-Pass Goal

One single-pass run performs **one full review wave** over the full current
change set:

1. Build or refresh the compact review context pack.
2. Run deterministic checks.
3. Spawn read-only specialist reviewers.
4. Verify, deduplicate, and rank findings.
5. Batch-fix verified findings.
6. Re-check affected surfaces.
7. Write the review result signal.

The outer loop still owns the guarantee of three consecutive full `CLEAN`
passes. A single pass that found and fixed anything is successful engineering
work, but it is **not** a clean pass.

## Review-Wave Contract

Read and follow `prompts/review-wave.md`. It is the source of truth for:

- context-pack contents and path handling
- specialist reviewer roster
- structured JSON-line finding schema
- verifier responsibilities
- result semantics
- stuck-loop findings hash

Use `prompts/review.md` as the criteria library behind each specialist review.
Do not paste the full criteria into every reviewer prompt; point reviewers at the
context pack and the relevant domain.

## Scope Detection

Review the full current change set, not just one category of changes:

- committed branch changes against `origin/<default>...HEAD` when available
- staged changes
- unstaged changes
- untracked files, represented with `git diff --no-index -- /dev/null <file>`

If the caller supplied explicit diff/stat/file-name commands, use those commands
instead of rediscovering scope. They are the authoritative full-scope commands
for the current loop iteration.

If no changes exist, stop with a clear message and do not write `CLEAN`.

## Context Pack

Create or refresh the context pack in global Doyaken loop state:

```bash
source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"
SESSION_ID="${DOYAKEN_SESSION_ID:-$(dk_session_id)}"
REVIEW_CONTEXT_FILE="$(dk_review_context_file "$SESSION_ID")"
mkdir -p "$(dirname "$REVIEW_CONTEXT_FILE")"
```

The pack is shared with specialist reviewers. It must be compact and current,
especially after the orchestrator applies fixes. Materialize it before broad
semantic exploration: write a non-empty skeleton with scope commands, changed
file names, and `Acceptance Criteria: N/A` unless criteria were explicitly
provided by the current caller; then run `test -s "$REVIEW_CONTEXT_FILE"` and
read back the first 80 lines before marking the context-pack step complete.

If `.doyaken/memory/index.md` exists, load only active memory entries whose scope
matches the changed files or review phase. Record loaded, skipped, and rejected
memory entries in the context pack. Treat memory as context to verify, not proof
of a finding.

Do not infer acceptance criteria from stale session prompt files, previous
conversation turns, session titles, AGENTS instructions, or unrelated ticket
context.

## Deterministic Checks

Run deterministic checks before semantic review whenever available and scoped:

- formatter/check mode
- linter/check mode
- typecheck
- targeted tests
- generated-code freshness
- `bash -n`, `zsh -n`, and `shellcheck` for shell changes when available
- CI/workflow/config validation when relevant and available

Fix mechanical failures before semantic review. If any fix is applied, the wave
cannot be `CLEAN`; final result should be `FINDINGS_FIXED:N` or another
non-CLEAN status.

## Specialist Review Wave

Spawn read-only specialist reviewers with the Agent tool. Run them in parallel
when the host supports parallel Agent calls.

If the Agent tool is unavailable, write `BLOCKED:agent-tool-unavailable`. Do not
simulate specialist review by reading all specialist prompts in the orchestrator
context.

Always run:

- `review-correctness`
- `review-security`
- `review-contracts`
- `review-tests`
- `review-architecture`

Run when relevant, allowing quick `N/A` responses:

- `review-frontend`
- `review-devops`
- `review-performance`
- `review-observability`

All specialist reviewers must return `NO_FINDINGS`, `N/A`, or JSON lines in the
schema from `prompts/review-wave.md`.

## Verification

Use `review-verifier` with the Agent tool. If the Agent tool is unavailable,
write `BLOCKED:agent-tool-unavailable`. Verification is mandatory before fixing.

The verifier must:

- deduplicate by root cause
- re-read cited code and context
- reject speculative or stale findings
- reject findings below confidence 50
- confirm the issue is introduced or made relevant by this change
- normalize severity

Only verified findings may drive fixes or reset the clean counter.

## Batch Fix And Recheck

If verified findings exist:

1. Fix them in severity order.
2. Re-run relevant deterministic checks.
3. Re-run targeted review on changed surfaces and impacted callers.
4. If new verified findings appear, fix once more.
5. After two unsuccessful fix cycles, read `prompts/failure-recovery.md`.

Do not mark the wave `CLEAN` after applying fixes. Write `FINDINGS_FIXED:N` when
all verified findings were fixed and rechecked, where N is the number of
verified findings found in the wave.

## Acceptance Criteria

If plan or ticket criteria are available, produce an evidence table:

```markdown
| # | Criterion | Implementation (`file:line`) | Test (`test:line`) | Status |
|---|-----------|------------------------------|--------------------|--------|
```

Any `NOT FOUND`, `NOT MET`, or unverified criterion is a verified finding unless
the criterion is explicitly out of scope or accepted as debt.

If no criteria are available, mark the section `N/A` and continue.

## Result Signal

When `DOYAKEN_SESSION_ID` is available, write exactly one result:

```bash
source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"
SESSION_ID="${DOYAKEN_SESSION_ID:-$(dk_session_id)}"
echo "<result>" > "$(dk_review_result_file "$SESSION_ID")"
```

Allowed results:

- `CLEAN`
- `FINDINGS_FIXED:N`
- `FINDINGS:N`
- `BLOCKED:reason`

Only `CLEAN` means the wave found zero verified findings and applied zero fixes.

Also append the findings hash described in `prompts/review-wave.md`.

## Final Report

End with:

```markdown
## Review Wave Result

- Scope: full current change set
- Context pack: <path>
- Specialist reviewers: <domains run>
- Deterministic checks: PASS | FAIL | PARTIAL
- Verified findings: N
- Fixes applied this wave: N
- Result signal: CLEAN | FINDINGS_FIXED:N | FINDINGS:N | BLOCKED:reason
```

## Notes

- This skill is for work-in-progress review before verify and PR creation.
- Do not commit, push, create PRs, update PRs, or request external reviewers.
- External PR feedback remains Phase 5/6 and `/dkprreview` work.
