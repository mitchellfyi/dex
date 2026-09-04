# Review Quality

Durable lessons about adversarial review waves, specialist reviewers, and the
evidence standards Dex reviews depend on.

## M-001: Review specialists are read-only and must not enable project memory

Domain: review-quality
Status: active
Scope: prompts/review-wave.md, prompts/review.md, skills/dxreview*/SKILL.md
Applies to phases: review (Phase 3), prompt-loop
Applies to paths: prompts/review-wave.md, prompts/review.md, skills/dxreview*/SKILL.md
Last verified: 2026-09-03
Recheck when: a new specialist reviewer is added, agent frontmatter schema changes, or `.claude/agent-memory/` semantics change

Lesson:
Specialist reviewers in a Dex review wave must be strictly read-only. They
may use Read, Glob, Grep, and Bash for inspection only — never Edit, Write, or
NotebookEdit. They must not enable project memory; review waves must not leave
`.claude/agent-memory/` artifacts as a side effect of running.

Evidence:
- The standalone `agents/*.md` specialist files this entry originally cited no
  longer exist; review specialists now live in `prompts/review-wave.md` and the
  `skills/dxreview*/` skills. The read-only rule survived the move.
- `hooks/guards/review-assessment-no-bash.md` and
  `hooks/guards/review-assessment-no-file-edits.md` surface violations for the
  risk assessor as advisory warnings while `DEX_REVIEW_ASSESSMENT_ACTIVE=1`.
- `.dex/review-rules.md` codifies the rule for review-wave prompts and skills.
- Commit `4742c3f feat(review): add specialist review wave loop` body lists a
  smoke-test fix for "read-only specialist memory behavior", confirming this
  rule was already violated once and required a guardrail.

Future agent behavior:
- When adding or editing a review specialist, keep `tools:` limited to read-only
  tools and keep the explicit "You are read-only" line in the agent body.
- Do not add a `memory: project` frontmatter field to a review specialist.
- After running a review wave, confirm no `.claude/agent-memory/` files were
  created. If they appear, treat it as a defect, not a feature.
- Findings must include explicit evidence, a concrete trigger, and confidence
  >= 50 — review-rules.md is the authoritative format.

## M-007: Review waves must isolate scope and run deterministic checks before semantic review

Domain: review-quality
Status: active
Scope: lib/review.sh, lib/review-loop.sh, prompts/review-risk-assessment.md, prompts/review-wave.md, prompts/phase-audits/2-implement.md, prompts/phase-audits/3-review-loop.md, prompts/phase-audits/3-review.md, skills/dximplement/SKILL.md, skills/dxreviewloop/SKILL.md, skills/dxreview/SKILL.md
Applies to phases: review (Phase 3), prompt-loop
Applies to paths: lib/review*.sh, prompts/review-risk-assessment.md, prompts/review-wave.md, prompts/phase-audits/2-implement.md, prompts/phase-audits/3-review*.md, skills/dximplement/SKILL.md, skills/dxreview*/SKILL.md
Last verified: 2026-09-04
Recheck when: review wave architecture changes, the context-pack file path or session-id derivation changes, the CLEAN/FINDINGS_FIXED result semantics change, or the dxreviewloop tier/gate/budget/churn policy changes

Lesson:
Dex review waves preserve six interlocking rules. First, each wave gets a fresh
agent session and a new compact context pack in global Dex state via
`dx_review_context_file`, never inside the repo. Second, deterministic checks
run before semantic review. Third, acceptance criteria come only from the
current caller's plan or ticket; stale prompts, previous conversation turns,
AGENTS instructions, and unrelated tickets are not sources of acceptance
criteria. Fourth, later reviewers never receive prior reports, findings,
fingerprints, clean counts, or telemetry. Fifth, only a wave that found zero
verified findings and applied zero fixes writes `CLEAN`; any fix forces
`FINDINGS_FIXED:N` and resets the outer clean-pass counter. Sixth, the Phase 2
implementation agent selects `small`, `normal`, or `complex` review risk for the
final scope, requiring 1, 2, or 3 consecutive clean waves and supplying a soft
outer-wave budget of 3, 6, or 9 waves. The budget is operational rather than an
assurance gate: spending it pauses review and preserves valid clean credit.

Evidence:
- Commit `4742c3f feat(review): add specialist review wave loop` body lists
  smoke-test fixes for context-pack timing, stale prompt isolation, review-pass
  completion gating, and read-only specialist memory behavior.
- `prompts/review-wave.md` Step 1 requires context pack first; Step 2 requires
  deterministic checks before semantic review; Step 7 defines `CLEAN` result
  semantics.
- `lib/review.sh` owns tier normalization, 1/2/3 gates, scope-bound selection,
  resumable state, success receipts, result validation, deterministic churn
  detection, and typed telemetry payload construction.
- `prompts/review-risk-assessment.md` owns the ordered deterministic tier rubric;
  `prompts/phase-audits/2-implement.md` requires the implementation agent to
  apply it and persist a selection after the final in-scope change.
- `prompts/phase-audits/3-review-loop.md` requires the selected consecutive
  `CLEAN` gate and a current-scope receipt. It pauses on `FINDINGS:N`,
  `BLOCKED:reason-code`, `CHURN:reason-code`, invalid results, provider failure,
  or repeated/alternating findings fingerprints.
- `.dex/review-rules.md` § `prompts/phase-audits/` records that the outer
  review loop owns the selected clean-pass gate.
- Commit `b577f92 fix(dxreviewloop): review full current change set` confirms
  the review wave must cover the full diff, not a subset.
- Commit `d868c38 fix: pause phase three while reviews run` confirms review
  waves must not race the calling phase.
- Commit `e920421 fix(review): align tests with the v2 clean-pass policy and
  name the busy session` updates the remaining runtime, harness, and test
  consumers from the old 1/3/6 contract to the fixed 1/2/3 policy.
- Commit `17700b8 feat(lifecycle): bound reviews and resume Codex sessions`
  adds the 3/6/9 tier budgets, the attributed `review.max-waves` override, and
  pause-without-completion behavior when the budget is spent.

Future agent behavior:
- When editing `prompts/review-wave.md` or
  `prompts/phase-audits/3-review*.md`, preserve context-pack-first ordering,
  deterministic-before-semantic ordering, stale-prompt isolation, and the
  `CLEAN` vs `FINDINGS_FIXED:N` distinction.
- When editing review specialist prompts, do not infer acceptance criteria from
  session state.
- Never pass prior review conclusions, reports, findings, fingerprints, clean
  counts, or telemetry into a fresh wave.
- When a wave applies any fix, write `FINDINGS_FIXED:N`; never write `CLEAN`
  after applying a fix.
- Select the highest matching risk tier after the final Phase 2 in-scope change:
  `small` requires 1 clean wave, `normal` 2, and `complex` 3. Risk may escalate
  but never downgrade.
- Keep Phase 2 selection mandatory in the normal lifecycle. A legacy or resumed
  lifecycle with no valid current-scope selection may recover through a fresh
  read-only lifecycle assessor before the first wave.
- When a review wave changes the scope, retain or raise the tier, bind the
  selection to the updated fingerprint, reset clean progress, and review the
  full updated scope in a fresh session.
- Keep review state checkout-scoped and single-owner. A second loop must stop
  before it can change selection, progress, receipts, or Phase 3 busy markers.
- Enforce pass timeouts around the provider process tree, then clear busy state
  and record a normalized pause. A timeout setting that is only displayed or
  polled by the Stop hook is not enough.
- Keep the tier's soft outer-wave budget separate from clean-pass assurance.
  Re-read an attributed `review.max-waves` override between waves; spending the
  budget pauses without issuing a completion receipt, weakening the clean gate,
  or discarding valid clean credit. Do not reintroduce the removed
  `DEX_REVIEW_MAX_ITERATIONS` ceiling.
- When invoking review outside the lifecycle, still build the context pack
  before broad semantic exploration. Without an explicit tier/profile override,
  run the read-only risk assessor before the first wave.
- Treat `FINDINGS_FIXED:N` as a valid single-wave completion result; the outer
  `/dxreviewloop` owns the selected clean-pass gate and current-scope receipt.
