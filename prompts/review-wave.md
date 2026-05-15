# Review Wave

A review wave is one full-scope pass inside `/dkreviewloop`. The outer loop still
requires the configured number of consecutive full clean passes, normally three.
This prompt defines how one pass should spend its time efficiently.

## Non-Negotiables

- Review the full current change set for every wave.
- Specialist reviewers are read-only.
- Only the wave orchestrator may edit files.
- A wave that finds and fixes any verified issue is not clean. It must write a
  non-CLEAN result so the outer clean counter resets.
- Do not commit, push, create branches, create PRs, or update PRs.
- Do not treat draft PR review or external reviewer polling as part of Phase 3.

## Result Semantics

- `CLEAN` - no verified findings were found and no fixes were applied during this
  wave.
- `FINDINGS_FIXED:N` - N verified findings were found and all were fixed, with
  deterministic checks and targeted re-review passing afterward.
- `FINDINGS:N` - N verified findings remain unresolved.
- `BLOCKED:reason` - the wave could not complete because required context,
  tooling, or user judgment is missing.

Only `CLEAN` increments the outer clean-pass counter. Every other result resets
the counter.

## Step 1: Build Or Refresh The Context Pack

Create or refresh a compact context pack in Doyaken's global loop state, never in
the repository. This must be the first substantive action in the wave: do not do
broad `Read`, `Glob`, `Grep`, or specialist-agent prompt loading before a
non-empty context pack exists.

```bash
source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"
SESSION_ID="${DOYAKEN_SESSION_ID:-$(dk_session_id)}"
REVIEW_CONTEXT_FILE="$(dk_review_context_file "$SESSION_ID")"
mkdir -p "$(dirname "$REVIEW_CONTEXT_FILE")"
```

First write a small skeleton with the caller-supplied scope commands, changed
file names, and `Acceptance Criteria: N/A` unless explicit criteria were supplied
by the current caller. Then prove it exists:

```bash
test -s "$REVIEW_CONTEXT_FILE"
sed -n '1,80p' "$REVIEW_CONTEXT_FILE"
```

Do not infer acceptance criteria from stale session prompt files, previous
conversation turns, session titles, AGENTS instructions, or unrelated ticket
context. If this review invocation did not explicitly provide a plan, ticket, or
criteria, the acceptance section is `N/A`.

After the skeleton exists, enrich it with concise sections:

- Scope commands supplied by the caller: diff, stat, and file names.
- Changed files grouped as production, test, docs, generated, config, CI/devops,
  frontend/UI, backend/API, data/schema, shell/hook, and other.
- Risk classification per file: high, medium, or low.
- Relevant project context: `AGENTS.md`, `CLAUDE.md`, `.doyaken/doyaken.md`,
  `.doyaken/rules/*.md`, `.doyaken/review-rules.md`, and scoped active
  `.doyaken/memory/domains/*.md` entries referenced by
  `.doyaken/memory/index.md` if present.
- Plan or ticket acceptance criteria, or `N/A` if none are available.
- Deterministic checks discovered for affected packages.
- Dependency impact notes: touched exports, changed schemas/contracts, direct
  consumers found by grep, and recent fix history for deep-review files.
- Debt or accepted-risk entries that should not be re-raised.
- Memory load notes: which memory entries were loaded, skipped, or rejected for
  this review scope, with a one-line reason for each.

Keep the pack short. Prefer bullet summaries and command outputs over pasted
full files. If the pack already exists, refresh any sections invalidated by new
edits.

## Step 2: Deterministic Foundation

Run deterministic checks before semantic review, scoped to affected packages or
changed files when possible:

- format/check mode
- lint/check mode
- typecheck
- targeted tests
- generated-code freshness when relevant
- shell syntax and `shellcheck` for shell changes when available
- workflow/config validation for CI or infrastructure changes when available

Record deterministic failures as findings. Fix mechanical failures before
spending model time on semantic findings, then continue the wave. A deterministic
failure fixed during the wave still makes the wave non-CLEAN.

## Step 3: Specialist Reviewers

Spawn the applicable read-only specialist reviewers with the Agent tool. Use
parallel Agent calls when the host environment supports them. If the Agent tool is
unavailable, write `BLOCKED:agent-tool-unavailable`; do not simulate specialist
review by reading every specialist prompt in the orchestrator context.

Always include:

- `review-correctness`
- `review-security`
- `review-contracts`
- `review-tests`
- `review-architecture`

Include these when relevant, and let them return `N/A` quickly when not relevant:

- `review-frontend` for browser UI, client state, routing, accessibility,
  responsive layout, or design-system changes.
- `review-devops` for CI, deployment, shell hooks, package scripts, infrastructure
  config, secrets handling, generated artifacts, or release process changes.
- `review-performance` for hot paths, database queries, large data processing,
  caching, concurrency, or expensive frontend rendering.
- `review-observability` for logging, metrics, traces, health checks, alerting,
  audit trails, or operational diagnostics.

Give every reviewer:

- the review context pack path
- the full-scope diff/stat/file-name commands
- the current branch and base branch
- acceptance criteria or `N/A`
- the instruction to be read-only
- the structured finding schema below

Do not mark this step complete until every applicable Agent report has returned
and every non-applicable domain is explicitly recorded as `N/A`.

## Step 4: Structured Findings

Every reviewer must end with either `NO_FINDINGS`, `N/A`, or JSON lines using
this schema:

```json
{"id":"domain-1","domain":"correctness","severity":"high|medium|low","confidence":95,"file":"path/to/file","line":123,"introduced_by_change":true,"evidence":"exact code behavior and context checked","trigger":"specific input, state, request, or command that exposes the issue","suggested_fix":"concrete fix","verification":"command or check that would prove the fix"}
```

Rules:

- Confidence must be 50 or higher.
- Findings below 50 confidence are filtered by the reviewer.
- Findings must cite an exact file and line unless the issue is cross-file or
  missing-file evidence, in which case the reviewer must cite all relevant paths.
- Findings must explain why the issue is introduced or made relevant by this
  change. Pre-existing unrelated debt is filtered.
- Style-only nits are filtered unless the project has an explicit rule.

## Step 5: Verification And Triage

Run `review-verifier` with the Agent tool after all specialist reports return. If
the Agent tool is unavailable, write `BLOCKED:agent-tool-unavailable`; do not
replace verifier triage with unlabelled orchestrator reasoning. The verifier:

1. Deduplicates by root cause, not just by file line.
2. Re-reads the cited code before accepting a finding.
3. Checks project rules and nearby precedent.
4. Rejects findings with missing evidence, missing trigger, stale context, or
   confidence below 50.
5. Promotes severity only for mechanically verifiable correctness, security,
   data loss, contract breakage, or release-blocking CI/devops issues.
6. Produces the final verified inventory.

Only verified findings may drive fixes or reset the clean counter.

## Step 6: Batch Fix

If the verified inventory is non-empty:

1. Fix all verified findings in severity order.
2. Keep fixes scoped to the current change set and directly impacted callers.
3. Re-run deterministic checks affected by the fixes.
4. Re-run targeted specialist review only for changed surfaces and impacted
   callers to confirm the fixes.
5. If new verified findings appear, repeat once more. After two unsuccessful fix
   cycles, read `prompts/failure-recovery.md` and choose a recovery strategy.

If all verified findings are fixed, write `FINDINGS_FIXED:N`, not `CLEAN`.

## Step 7: Clean Wave

If the wave reaches zero verified findings without applying any fix during this
wave, write `CLEAN`.

Write the result signal when `DOYAKEN_SESSION_ID` is available:

```bash
source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"
SESSION_ID="${DOYAKEN_SESSION_ID:-$(dk_session_id)}"
echo "<CLEAN|FINDINGS_FIXED:N|FINDINGS:N|BLOCKED:reason>" > "$(dk_review_result_file "$SESSION_ID")"
```

Also append a findings hash for stuck-loop detection:

```bash
FINDINGS_HASH=$(printf '%s\n' "<sorted verified finding descriptions or EMPTY>" | shasum -a 256 | cut -c1-16)
echo "$FINDINGS_HASH" >> "$(dk_findings_file "$SESSION_ID")"
```

## Final Report

End each wave with:

```markdown
## Review Wave Result

- Scope: full current change set
- Context pack: <path>
- Specialist reviewers: correctness, security, contracts, tests, architecture, ...
- Deterministic checks: PASS | FAIL | PARTIAL
- Verified findings: N
- Fixes applied this wave: N
- Result signal: CLEAN | FINDINGS_FIXED:N | FINDINGS:N | BLOCKED:reason
```
