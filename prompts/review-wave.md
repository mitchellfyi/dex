# Review Wave

One `/dxreviewloop` iteration reviews the caller-supplied scope. This is usually
the full current change set; when no change set exists, it is the entire tracked
codebase. The outer loop maps its selected risk tier to review depth and a
consecutive `CLEAN` gate: `small` uses `light` and requires 3, `normal` uses
`standard` and requires 6, and `complex` uses `thorough` and requires 9.

## Rules

- Review the full caller-supplied scope every wave.
- Treat this as an independent review. Use only the current code, supplied
  scope, supplied acceptance criteria, and selected profile.
- Do not read or infer prior review reports, prior findings, findings
  fingerprints, clean-pass counts, telemetry, stale session prompts, previous
  turns, or unrelated ticket context.
- Build the context pack before broad exploration or domain-specific review.
- Run deterministic checks before semantic review.
- The review wave runs in one CLI session.
- Do not create or switch worktrees or branches. A review wave runs in the
  current checkout; only `dx <ticket-or-description>` owns lifecycle setup.
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
- `BLOCKED:reason-code` - required tooling, context, authority, or user judgment
  is missing.
- `CHURN:reason-code` - the wave cannot make reliable progress without
  repeating or oscillating.
- `ESCALATE:normal:reason-code` or `ESCALATE:complex:reason-code` - the current
  tier is too low for the observed risk.

Only `CLEAN` increments the outer clean counter. `FINDINGS_FIXED:N` and a valid
upward escalation reset the counter and continue in a fresh session.
`FINDINGS:N`, `BLOCKED:reason-code`, and `CHURN:reason-code` reset the counter
and pause the outer loop. Use short lowercase reason codes; never put source
text, file paths, prompts, credentials, or other free-form content in a result
suffix. `ESCALATE_THOROUGH:reason` is accepted only as a legacy alias for
`ESCALATE:complex:reason`.

## 1. Context Pack

Create or refresh the context pack in global Dex state:

```bash
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh" || exit 1
SESSION_ID="${DEX_SESSION_ID:-$(dx_session_id)}"
[[ -n "$SESSION_ID" ]] || { echo "ERROR: empty session id — refusing to write unkeyed state" >&2; exit 1; }
REVIEW_CONTEXT_FILE="$(dx_review_context_file "$SESSION_ID")"
mkdir -p "$(dirname "$REVIEW_CONTEXT_FILE")"
```

First write a non-empty skeleton with supplied diff/stat/name commands, changed
files, risk tier, profile, and acceptance criteria or `N/A`; then verify it:

```bash
test -s "$REVIEW_CONTEXT_FILE"
sed -n '1,80p' "$REVIEW_CONTEXT_FILE"
```

Use these exact top-level sections so the wrapper can reject placeholder
context packs:

- `## Scope`
- `## Deterministic Checks`
- `## Review Coverage`
- `## Verification`

Within them, record:

- file groups: production, tests, docs, generated, config, CI/devops, UI, API,
  data/schema, shell/hook, other
- per-file risk: high, medium, low
- relevant project context and scoped active memory entries
- discovered deterministic checks
- dependency impact: exports, schemas/contracts, direct consumers, recent fixes
- accepted debt/risk supplied by the current caller for this invocation

## 2. Deterministic Checks

Run available scoped checks first: format/check, lint, typecheck, targeted tests,
generated-code freshness, shell syntax/`shellcheck`, and CI/config validation
when relevant. Mechanical fixes make the wave non-`CLEAN`.

`CLEAN` and `FINDINGS_FIXED:N` require all applicable deterministic checks to
pass. If a required check fails, is only partially run, or cannot be run, use a
non-clean result that accurately describes the blocker. Never pair `CLEAN`
with failed, partial, or unavailable checks.

## 3. Repro Probe Plan

Before semantic review, decide whether the changed surface supports lightweight
repro tests. If the repo has runnable tests or scripts, create the smallest
temporary or committed-in-scope probe needed to prove suspected correctness,
contract, or regression findings. Prefer the repo's existing test framework; use
a short standalone script only when that is the local convention or faster for a
review-only reproduction.

For every high-confidence correctness finding, either:

- cite a failing targeted test/probe command and the observed failure, or
- explain why no executable repro is practical and cite the static trace that
  makes the issue mechanically verifiable.

Do not modify production code while creating probes. If a probe file belongs in
the final change set as a regression test, keep it and include it in the fix. If
it was review-only, remove it before the wave result and keep the command/output
in the context pack.

## 4. Issue Harvest

Collect all candidate issues before fixing anything.

- `light` (`small`): core domain sweep across correctness, security, contracts,
  tests, and architecture.
- `standard` (`normal`): core sweep plus targeted domain sweeps for concrete
  changed surfaces.
- `thorough` (`complex`): all domain sweeps across the full caller-supplied
  scope.

The wave orchestrator covers all requested domains in the current CLI session.
Construct breaking inputs, trace direct callers, and filter speculation.

Full domain roster in `thorough`: correctness, security, contracts, tests,
architecture, frontend, devops, performance, and observability.

Targeted domain sweeps in `standard`:

- trust boundary/secrets/auth -> security
- public API/schema/config/CLI contract -> contracts
- acceptance/regression coverage -> tests
- abstraction/module boundary -> architecture
- UI/browser/client state/routing/accessibility -> frontend
- CI/deploy/shell/hooks/package scripts/infra -> devops
- hot path/query/cache/large data/rendering -> performance
- logs/metrics/traces/health/audit trails -> observability

If the current session cannot review a required domain with enough confidence,
write `ESCALATE:normal:depth-gap` or `ESCALATE:complex:depth-gap` when a higher
tier resolves the gap. Write `BLOCKED:missing-tooling` when required local
tooling or context cannot be obtained. Never request a lower tier.

Candidate output must be `NO_FINDINGS`, `N/A`, a valid upward escalation, or
JSON lines:

```json
{"id":"domain-1","domain":"correctness","severity":"high|medium|low","confidence":95,"file":"path","line":123,"introduced_by_change":true,"evidence":"exact behavior checked","trigger":"specific input/state/request/command","suggested_fix":"concrete fix","verification":"command/check"}
```

Report only confidence >= 50, cite exact file/line unless cross-file evidence
requires multiple paths, and filter style-only nits unless project rules require
them.

## 5. Verification

Run an explicit verifier pass over the candidate inventory. Deduplicate by root
cause, re-read cited code, check project context and caller-supplied accepted
debt, reject weak/stale evidence, confirm change relevance, and normalize
severity.

Only verified findings may drive fixes. If a valid upward escalation survives
verification, write it instead of fixing.

## 6. Batch Fix

If verified findings exist:

1. Fix all verified findings in severity order.
2. Keep fixes scoped to this change set and directly impacted callers.
3. Re-run affected deterministic checks.
4. Re-run targeted review for changed surfaces and impacted callers.
5. Repeat once if new verified findings appear; then use
   `prompts/failure-recovery.md`.

Write `FINDINGS_FIXED:N` when all verified findings were fixed and rechecked.
Never write `CLEAN` after applying a fix in the same wave.

Do not stop after merely finding or reporting verified issues. `FINDINGS:N` is
allowed only when verified findings remain after a concrete local fix attempt is
blocked, unsafe, or requires user judgment; include the residual reason in the
context pack and final report.

If the fix/recheck cycle repeats the same failure or oscillates between two
states, write `CHURN:fix-cycle` and stop. The outer loop pauses rather than
counting the wave or retrying indefinitely.

## 7. Result Signal

```bash
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh" || exit 1
SESSION_ID="${DEX_SESSION_ID:-$(dx_session_id)}"
[[ -n "$SESSION_ID" ]] || { echo "ERROR: empty session id — refusing to write unkeyed state" >&2; exit 1; }
echo "<result>" > "$(dx_review_result_file "$SESSION_ID")"
FINDINGS_HASH=$(printf '%s\n' "<sorted verified finding descriptions or EMPTY>" | dx_review_hash_findings)
echo "$FINDINGS_HASH" > "$(dx_findings_file "$SESSION_ID")"
```

Write a versioned JSON evidence manifest to
`$(dx_review_evidence_file "$SESSION_ID")` with exactly these fields:

```json
{
  "version": 1,
  "scope_fingerprint": "<64 lowercase hex characters supplied by the wrapper>",
  "deterministic_checks": "pass",
  "coverage": ["correctness", "security", "contracts", "tests", "architecture"],
  "verifier": "pass",
  "verified_findings": 0,
  "fixes_applied": 0
}
```

Allowed check states are `pass`, `partial`, `fail`, and `unavailable`; allowed
verifier states are `pass`, `fail`, and `not-run`. Coverage values are
`correctness`, `security`, `contracts`, `tests`, `architecture`, `frontend`,
`devops`, `performance`, and `observability`. A thorough clean/fixed pass lists
all nine domains; light and standard clean/fixed passes list the five core
domains plus any targeted domains actually reviewed. Counts must agree with
the result. The wrapper rejects mismatched or incomplete evidence.

The wave is incomplete until the context pack contains substantive text and the
required sections, the evidence manifest validates, and the findings file
contains exactly one lowercase 16-character hash. Replace the findings file for
this pass; the outer loop appends validated hashes to its own history when
needed.
The hash is transient orchestration state. Do not print it, put it in the
context pack or telemetry, or expose it to a later review-wave agent.

Final output:

```markdown
## Review Wave Result

- Scope: full current change set | entire codebase
- Risk tier: small | normal | complex
- Profile: light | standard | thorough
- Context pack: <path>
- Review coverage: <profiles/domains/verifier pass run>
- Deterministic checks: PASS | FAIL | PARTIAL
- Verified findings: N
- Fixes applied this wave: N
- Result signal: CLEAN | FINDINGS_FIXED:N | FINDINGS:N | BLOCKED:reason-code | CHURN:reason-code | ESCALATE:normal:reason-code | ESCALATE:complex:reason-code
```
