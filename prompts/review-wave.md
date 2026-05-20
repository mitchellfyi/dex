# Review Wave

One `/dkreviewloop` iteration reviews the full current change set. The outer loop
sets the required consecutive `CLEAN` waves from the resolved profile: `light`,
`standard`, or `thorough`.

## Rules

- Review the full current change set every wave.
- Build the context pack before broad exploration or specialist/verifier calls.
- Run deterministic checks before semantic review.
- Specialist/verifier agents are read-only; only the wave orchestrator may edit.
- Do not commit, push, create branches, create or update PRs, or poll reviewers.
- Acceptance criteria come only from the current caller; otherwise use `N/A`.
- `CLEAN` means zero verified findings and zero fixes in this wave.

## Concise Style

Write for transfer, not narration. Prefer paths, symbols, command summaries,
file:line evidence, and JSON lines. Omit greetings, status prose, repeated rules,
passing logs, unchanged code, and duplicate findings. Keep command output in the
context pack summarized unless the exact text is evidence.

Tool output: prefer `rg`, `git diff --name-only`, `git diff --stat`, and
`git diff --numstat` for orientation. Use full file reads only when needed to
verify behavior; quote only the evidence lines in reports.

## Results

- `CLEAN` - no verified findings and no fixes.
- `FINDINGS_FIXED:N` - N verified findings fixed and rechecked.
- `FINDINGS:N` - N verified findings remain.
- `BLOCKED:reason` - required tooling, context, or user judgment is missing.
- `ESCALATE_THOROUGH:reason` - the current profile is too shallow.

Only `CLEAN` increments the outer clean counter. Every other result resets it.

## 1. Context Pack

Create or refresh the context pack in global Doyaken state:

```bash
source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"
SESSION_ID="${DOYAKEN_SESSION_ID:-$(dk_session_id)}"
REVIEW_CONTEXT_FILE="$(dk_review_context_file "$SESSION_ID")"
mkdir -p "$(dirname "$REVIEW_CONTEXT_FILE")"
```

First write a non-empty skeleton with supplied diff/stat/name commands, changed
files, profile, and acceptance criteria or `N/A`; then verify it:

```bash
test -s "$REVIEW_CONTEXT_FILE"
sed -n '1,80p' "$REVIEW_CONTEXT_FILE"
```

Add concise sections:

- file groups: production, tests, docs, generated, config, CI/devops, UI, API,
  data/schema, shell/hook, other
- per-file risk: high, medium, low
- relevant project context and scoped active memory entries
- discovered deterministic checks
- dependency impact: exports, schemas/contracts, direct consumers, recent fixes
- accepted debt/risk not to re-raise

## 2. Deterministic Checks

Run available scoped checks first: format/check, lint, typecheck, targeted tests,
generated-code freshness, shell syntax/`shellcheck`, and CI/config validation
when relevant. Mechanical fixes make the wave non-`CLEAN`.

## 3. Issue Harvest

Collect all candidate issues before fixing anything.

- `light`: orchestrator harvest; call `review-verifier` only for candidates or
  escalation risk.
- `standard`: orchestrator harvest; targeted specialists for concrete changed
  domains; then `review-verifier`.
- `thorough`: full specialist roster; then `review-verifier`.

The orchestrator harvest covers correctness, security, contracts, tests,
architecture, performance, and operations. Construct breaking inputs, trace
direct callers, and filter speculation.

Full roster in `thorough`: `review-correctness`, `review-security`,
`review-contracts`, `review-tests`, `review-architecture`, plus relevant
`review-frontend`, `review-devops`, `review-performance`, and
`review-observability`.

Targeted specialists in `standard`:

- trust boundary/secrets/auth -> `review-security`
- public API/schema/config/CLI contract -> `review-contracts`
- acceptance/regression coverage -> `review-tests`
- abstraction/module boundary -> `review-architecture`
- UI/browser/client state/routing/accessibility -> `review-frontend`
- CI/deploy/shell/hooks/package scripts/infra -> `review-devops`
- hot path/query/cache/large data/rendering -> `review-performance`
- logs/metrics/traces/health/audit trails -> `review-observability`

If a required specialist or verifier is unavailable, write
`BLOCKED:agent-tool-unavailable`.

Candidate output must be `NO_FINDINGS`, `N/A`, `ESCALATE_THOROUGH:reason`, or
JSON lines:

```json
{"id":"domain-1","domain":"correctness","severity":"high|medium|low","confidence":95,"file":"path","line":123,"introduced_by_change":true,"evidence":"exact behavior checked","trigger":"specific input/state/request/command","suggested_fix":"concrete fix","verification":"command/check"}
```

Report only confidence >= 50, cite exact file/line unless cross-file evidence
requires multiple paths, and filter style-only nits unless project rules require
them.

## 4. Verification

Run `review-verifier` after specialist reports, and in light mode only for
candidate findings or escalation risk. It dedupes by root cause, re-reads cited
code, checks project context and accepted debt, rejects weak/stale evidence,
confirms change relevance, and normalizes severity.

Only verified findings may drive fixes. If `ESCALATE_THOROUGH` survives
verification, write it instead of fixing.

## 5. Batch Fix

If verified findings exist:

1. Fix all verified findings in severity order.
2. Keep fixes scoped to this change set and directly impacted callers.
3. Re-run affected deterministic checks.
4. Re-run targeted review for changed surfaces and impacted callers.
5. Repeat once if new verified findings appear; then use
   `prompts/failure-recovery.md`.

Write `FINDINGS_FIXED:N` when all verified findings were fixed and rechecked.
Never write `CLEAN` after applying a fix in the same wave.

## 6. Result Signal

```bash
source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"
SESSION_ID="${DOYAKEN_SESSION_ID:-$(dk_session_id)}"
echo "<result>" > "$(dk_review_result_file "$SESSION_ID")"
FINDINGS_HASH=$(printf '%s\n' "<sorted verified finding descriptions or EMPTY>" | shasum -a 256 | cut -c1-16)
echo "$FINDINGS_HASH" >> "$(dk_findings_file "$SESSION_ID")"
```

Final output:

```markdown
## Review Wave Result

- Scope: full current change set
- Profile: light | standard | thorough
- Context pack: <path>
- Review coverage: <orchestrator/specialists/verifier run>
- Deterministic checks: PASS | FAIL | PARTIAL
- Verified findings: N
- Fixes applied this wave: N
- Result signal: CLEAN | FINDINGS_FIXED:N | FINDINGS:N | BLOCKED:reason | ESCALATE_THOROUGH:reason
```
