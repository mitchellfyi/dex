#!/usr/bin/env bash
set -euo pipefail

# The prompts that carry the verification ladder, the Coherence Contract, and
# the one-reviewer wave.
#
# These are cross-file contracts: the plan writes a section the Phase 1 audit
# requires, the Phase 2 agent reads, the wave's coherence lens checks and the
# PR body lists; the ladder says which rung runs where. Each of those is a
# different file, and the failure mode is silent — a renamed heading or a
# dropped sentence leaves every other file pointing at nothing. Text
# assertions are the only mechanical check available, so this file holds them.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/tests/helpers.sh"

CONTRACT_HEADING='## Coherence Contract'

# ─── Item 11: the Coherence Contract, end to end ────────────────────────────

PLAN="$ROOT/prompts/workflows/dxplan.md"
assert_contains "$CONTRACT_HEADING" "$PLAN"
assert_contains "canonical files this change must" "$PLAN"
assert_contains "extension points to reuse" "$PLAN"
assert_contains "must change" "$PLAN"
assert_contains "Keep it under a screen" "$PLAN"
# The prior-art and holistic-fit steps are where the contract comes from.
assert_contains "Find codebase prior art" "$PLAN"
assert_contains "Check holistic fit" "$PLAN"

# Phase 1 requires it; Phase 2 reads it; Phase 5 lists the deviations.
for consumer in \
  prompts/phase-audits/1-plan.md \
  prompts/phase-audits/2-implement.md \
  prompts/review-wave.md \
  prompts/workflows/dxpr.md; do
  assert_contains "$CONTRACT_HEADING" "$ROOT/$consumer"
done
assert_contains "or the ticket is recorded as trivial" "$ROOT/prompts/phase-audits/1-plan.md"
assert_contains "Where you deviate" "$ROOT/prompts/phase-audits/2-implement.md"
assert_contains "list every deviation from it" "$ROOT/prompts/workflows/dxpr.md"

# ─── Item 3: the ladder, rung by rung ───────────────────────────────────────

WAVE="$ROOT/prompts/review-wave.md"
# Rungs 1 and 2 in the wave, scoped to what the wave touched.
assert_contains "each limited to the paths this wave touched" "$WAVE"
# Rung 3 is Phase 4's, and the wave may not reach for the project's own
# aggregate gate.
assert_contains "aggregate gate is not a check a wave may choose" "$WAVE"
assert_contains "Phase 4 owns the complete pipeline" "$WAVE"
# Input-scoped invalidation replaces the whole-checkout rule for a check that
# declares its inputs.
assert_contains "a fix invalidates the receipts whose" "$WAVE"
assert_contains "no declared inputs is invalidated by" "$WAVE"
assert_not_contains "A fix invalidates reuse for the entire checkout" "$WAVE"

CHECKS="$ROOT/prompts/review-checks.md"
assert_contains "Declaring \`inputs\` narrows that" "$CHECKS"
assert_contains "Under-declaring an input" "$CHECKS"

# Phase 2 runs the full gate through the admission path, once, and Phase 4
# reuses the receipt instead of running it again.
IMPLEMENT="$ROOT/prompts/phase-audits/2-implement.md"
assert_contains "dx run-gate" "$IMPLEMENT"
assert_contains "Review waves never run the" "$IMPLEMENT"
assert_contains "passing \`dx run-gate\` receipt for this tree" "$IMPLEMENT"

VERIFY="$ROOT/prompts/phase-audits/4-verify.md"
assert_contains "bin/gate-receipt.sh" "$VERIFY"
assert_contains "0 reuse, 1 run it, 3 it failed here" "$VERIFY"
assert_contains "dx run-gate" "$VERIFY"
assert_contains "full_gate: ci" "$VERIFY"
assert_contains "changed the gates, CI, or test infrastructure" "$VERIFY"
assert_contains "passing result for this tree" "$VERIFY"

# Rung 4: CI is the final arbiter, and Phase 6 owns it under full_gate: ci.
COMPLETE="$ROOT/prompts/phase-audits/6-complete.md"
assert_contains "full_gate: ci" "$COMPLETE"
assert_contains "CI is the final arbiter" "$COMPLETE"

# The verify skill means "a passing receipt on the final tree", not "ran it".
VERIFY_SKILL="$ROOT/skills/dxverify/SKILL.md"
assert_contains "passing result for the" "$VERIFY_SKILL"
assert_contains "bin/gate-receipt.sh" "$VERIFY_SKILL"
assert_contains "full_gate: ci" "$VERIFY_SKILL"
# The removed environment variable must not come back: full_gate is a contract
# field, and two switches for one decision is how they disagree.
for prompt_file in "$ROOT"/prompts/*.md "$ROOT"/prompts/*/*.md "$ROOT"/skills/*/SKILL.md; do
  assert_not_contains "DEX_VERIFY_FULL_SUITE" "$prompt_file"
done

LOOP_PROMPT="$ROOT/prompts/phase-audits/prompt-loop.md"
assert_contains "gate-receipt.sh" "$LOOP_PROMPT"

# ─── Item 9: one reviewer, sequential lenses, a ledger ──────────────────────

assert_contains "## 4. Sequential Lenses" "$WAVE"
assert_contains "sweeps the scope once per lens" "$WAVE"
assert_contains "4. coherence, required in every tier" "$WAVE"
assert_contains "**Coherence lens.**" "$WAVE"
assert_contains "reuse an existing helper, service, or pattern" "$WAVE"
assert_contains "must change together" "$WAVE"
assert_contains "callers and dependents of changed" "$WAVE"
assert_contains "**Delta review with a ledger.**" "$WAVE"
assert_contains "wave_found" "$WAVE"
assert_contains "DEX_REVIEW_CONFIRMATION=1" "$WAVE"
assert_contains "independent read-only tool calls" "$WAVE"
# Scouts are conditional on the wrapper's value, never the default.
assert_contains "only while the wrapper's" "$WAVE"

# The scope rule is stated once and the same way everywhere: full scope on the
# first pass and on a would-be-clean pass, ledger plus delta in between. The
# old unconditional "every wave" reading contradicted the wrapper.
assert_not_contains "Review the full caller-supplied scope every wave" "$WAVE"
assert_contains "on a loop's first pass and on any pass" "$WAVE"
assert_contains "the passes between those reviewed the ledger and the delta" \
  "$ROOT/prompts/phase-audits/3-review-loop.md"
assert_contains "on any pass that would be clean" "$ROOT/skills/dxreview/SKILL.md"
assert_contains "the ledger plus the named delta otherwise" \
  "$ROOT/prompts/phase-audits/3-review.md"

# The independence rule and the ledger have to agree, in all four places that
# state it, or a wave is told both to read the ledger and never to read it.
for independence_file in \
  skills/dxreviewloop/SKILL.md \
  skills/dxreview/SKILL.md \
  prompts/phase-audits/3-review.md \
  prompts/phase-audits/3-review-loop.md; do
  assert_contains "ledger" "$ROOT/$independence_file"
  assert_not_contains "no prior review reports, findings," "$ROOT/$independence_file"
done
assert_contains "ledger is the one exception it passes" "$ROOT/skills/dxreviewloop/SKILL.md"
assert_contains "not an earlier reviewer's conclusion" "$ROOT/prompts/phase-audits/3-review.md"

# Coherence is never handed to a scout, in either mode.
assert_contains "coherence, required in every tier" "$WAVE"
assert_contains "the coherence lens is never" "$ROOT/lib/review-loop.sh"
assert_contains "__dx_review_lens_count" "$ROOT/lib/review-loop.sh"

# ─── Item 12: the finding bar, notes, churn, and the trivial tier ───────────

assert_contains "**The finding bar.**" "$WAVE"
assert_contains "verified by a probe or a named project rule" "$WAVE"
assert_contains "NOTES:N" "$WAVE"
assert_contains "CHURN:no-convergence" "$WAVE"
# A deterministic autofix is reportable only under the subset test.
assert_contains "MECHANICAL:N" "$WAVE"
assert_contains '"autofix": true' "$WAVE"
assert_contains "inside that check's declared \`inputs\`" "$WAVE"
assert_contains "Either way the clean streak restarts" "$WAVE"
for mechanical_file in \
  prompts/phase-audits/3-review.md \
  prompts/phase-audits/3-review-loop.md \
  prompts/review-report.md \
  skills/dxreview/SKILL.md \
  skills/dxreviewloop/SKILL.md \
  docs/autonomous-mode.md \
  AGENTS.md; do
  assert_contains "MECHANICAL:N" "$ROOT/$mechanical_file"
done
# The ledger's lens and file columns are what make the post-fix pass cheap;
# per-lens clean status is deliberately absent.
assert_contains "which lenses a fix invalidated" "$WAVE"
assert_contains "Per-lens clean status deliberately does not exist" "$ROOT/AGENTS.md"

# A mechanical wave is a fix in every way that protects the attestation chain,
# and cheap only in what it costs the budget and the next wave.
LOOP="$ROOT/lib/review-loop.sh"
assert_contains "findings_fixed|mechanical)" "$LOOP"
assert_contains 'result_kind" != "mechanical"' "$LOOP"
assert_contains "budget_mechanical_used" "$LOOP"
assert_contains "one such wave per loop is free of the wave budget" "$WAVE"
assert_contains "one mechanical" "$ROOT/AGENTS.md"
assert_contains "wave per loop does not spend the wave budget" "$ROOT/AGENTS.md"
assert_contains "one mechanical wave per loop does not spend" "$ROOT/docs/autonomous-mode.md"
# Every result token is the same on both providers and in the hook's snippet.
for token in "NOTES:N" "MECHANICAL:N"; do
  assert_contains "$token" "$LOOP"
  assert_contains "$token" "$ROOT/hooks/phase-loop.sh"
done
# The gate sentences and the validator have to agree about MECHANICAL.
assert_contains '`CLEAN`, `NOTES:N`, `MECHANICAL:N` and `FINDINGS_FIXED:N` all require' "$WAVE"
assert_contains '`CLEAN`, `NOTES:N`, `MECHANICAL:N` and `FINDINGS_FIXED:N` still require' "$WAVE"
assert_contains 'result.startswith(("NOTES:", "MECHANICAL:"))' "$ROOT/lib/review.sh"
# Every delta branch ends at the same place: the clean pass reviews it all.
assert_eq "3" "$(grep -c 'whole ticket diff under the coherence lens before declaring a clean result' "$LOOP")" \
  "the mechanical, post-fix and confirmation branches all end with the whole diff"
# A lens name a wave wrote is bounded to the roster before it is interpolated.
assert_contains "LENSES = {" "$ROOT/lib/review.sh"
assert_contains "the wrapper's authority" "$ROOT/lib/review.sh"
assert_contains "1 wave for \`trivial\` and \`small\`" "$WAVE"

RISK="$ROOT/prompts/review-risk-assessment.md"
assert_contains "Choose \`trivial\`" "$RISK"
assert_contains "no-behavior-change" "$RISK"
assert_contains "declared-sensitive-path" "$RISK"
assert_contains "review_sensitive_paths" "$RISK"
assert_contains "2, 3, 6, or 9" "$RISK"

REVIEW_LOOP_AUDIT="$ROOT/prompts/phase-audits/3-review-loop.md"
assert_contains "1 for" "$REVIEW_LOOP_AUDIT"
assert_contains "\`trivial\`" "$REVIEW_LOOP_AUDIT"
assert_contains "NOTES:N" "$REVIEW_LOOP_AUDIT"
assert_contains "CHURN:no-convergence" "$REVIEW_LOOP_AUDIT"
assert_contains "dx review stats" "$REVIEW_LOOP_AUDIT"
assert_contains "Confirmation passes" "$REVIEW_LOOP_AUDIT"

WAVE_AUDIT="$ROOT/prompts/phase-audits/3-review.md"
assert_contains "NOTES:N" "$WAVE_AUDIT"
assert_contains "coherence lens is required in every tier" "$WAVE_AUDIT"

# The implementer reviews its own diff and seeds the ledger before handoff.
IMPLEMENT_WORKFLOW="$ROOT/prompts/workflows/dximplement.md"
assert_contains "Review Your Own Diff" "$IMPLEMENT_WORKFLOW"
assert_contains "dx_review_findings_ledger_seed" "$IMPLEMENT_WORKFLOW"
assert_contains "no subagent" "$IMPLEMENT_WORKFLOW"
assert_contains "Choose \`trivial\`" "$IMPLEMENT_WORKFLOW"
assert_contains "findings ledger is seeded for Phase 3" "$IMPLEMENT"

# Both review skills teach the same wave.
REVIEW_SKILL="$ROOT/skills/dxreview/SKILL.md"
assert_contains "one lens at a time" "$REVIEW_SKILL"
assert_contains "findings ledger" "$REVIEW_SKILL"
assert_contains "NOTES:N" "$REVIEW_SKILL"
assert_contains "zero by default" "$REVIEW_SKILL"

LOOP_SKILL="$ROOT/skills/dxreviewloop/SKILL.md"
assert_contains "\`trivial\` | \`light\` | 1 | 2 |" "$LOOP_SKILL"
assert_contains "NOTES:N" "$LOOP_SKILL"
assert_contains "CHURN:no-convergence" "$LOOP_SKILL"
assert_contains "dx review stats" "$LOOP_SKILL"

# The project contract names every key the code reads, so a repository can
# actually declare them.
for key in full_gate review_sensitive_paths review_trivial_max_files \
  review_trivial_max_lines review_broad_impact_files review_scout_min_files; do
  assert_contains "$key" "$ROOT/prompts/init-analysis.md"
  assert_contains "$key" "$ROOT/docs/host-budget.md"
done

printf 'review ladder and coherence contract tests passed\n'
