# Review Quality

Durable lessons about adversarial review waves, specialist reviewers, and the
evidence standards Doyaken reviews depend on.

## M-001: Review specialists are read-only and must not enable project memory

Domain: review-quality
Status: active
Scope: agents/review-*.md, agents/self-reviewer.md, agents/review-verifier.md, prompts/review-wave.md, prompts/review.md, skills/dkreview*/SKILL.md
Applies to phases: review (Phase 3), prompt-loop
Applies to paths: agents/review-*.md, agents/self-reviewer.md, agents/review-verifier.md, prompts/review-wave.md, prompts/review.md
Last verified: 2026-05-15
Recheck when: a new specialist reviewer is added, agent frontmatter schema changes, or `.claude/agent-memory/` semantics change

Lesson:
Specialist reviewers in a Doyaken review wave must be strictly read-only. They
may use Read, Glob, Grep, and Bash for inspection only — never Edit, Write, or
NotebookEdit. They must not enable project memory; review waves must not leave
`.claude/agent-memory/` artifacts as a side effect of running.

Evidence:
- All ten specialist agent files (`agents/review-architecture.md`,
  `review-contracts.md`, `review-correctness.md`, `review-devops.md`,
  `review-frontend.md`, `review-observability.md`, `review-performance.md`,
  `review-security.md`, `review-tests.md`, `review-verifier.md`) declare
  `tools: Read, Glob, Grep, Bash` and explicitly state "You are read-only".
- `.doyaken/review-rules.md` codifies the rule for both `agents/*.md` and
  review-wave skill files.
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
Scope: prompts/review-wave.md, prompts/phase-audits/3-review-loop.md, prompts/phase-audits/3-review.md, skills/dkreviewloop/SKILL.md, skills/dkreview/SKILL.md, agents/review-*.md, agents/review-verifier.md
Applies to phases: review (Phase 3), prompt-loop
Applies to paths: prompts/review-wave.md, prompts/phase-audits/3-review*.md, skills/dkreview*/SKILL.md, agents/review-*.md, agents/review-verifier.md
Last verified: 2026-05-15
Recheck when: review wave architecture changes, the context-pack file path or session-id derivation changes, the CLEAN/FINDINGS_FIXED result semantics change, or the outer dkreviewloop three-consecutive-clean gate changes

Lesson:
Doyaken review waves preserve four interlocking rules. First, the wave's first
substantive action builds or refreshes a compact context pack in Doyaken global
state via `dk_review_context_file`, never inside the repo. Second,
deterministic checks run before semantic review. Third, acceptance criteria come
only from the current caller's plan or ticket; stale prompts, previous
conversation turns, AGENTS instructions, and unrelated tickets are not sources
of acceptance criteria. Fourth, only a wave that found zero verified findings
and applied zero fixes writes `CLEAN`; any fix forces `FINDINGS_FIXED:N`, which
resets the outer clean-pass counter.

Evidence:
- Commit `4742c3f feat(review): add specialist review wave loop` body lists
  smoke-test fixes for context-pack timing, stale prompt isolation, review-pass
  completion gating, and read-only specialist memory behavior.
- `prompts/review-wave.md` Step 1 requires context pack first; Step 2 requires
  deterministic checks before semantic review; Step 7 defines `CLEAN` result
  semantics.
- `prompts/phase-audits/3-review-loop.md` requires three consecutive `CLEAN`
  reports and excludes `FINDINGS_FIXED:N`, `FINDINGS:N`, and `BLOCKED:reason`
  from incrementing the counter.
- `.doyaken/review-rules.md` § `prompts/phase-audits/` records that the outer
  review loop owns the gate.
- Commit `b577f92 fix(dkreviewloop): review full current change set` confirms
  the review wave must cover the full diff, not a subset.
- Commit `d868c38 fix: pause phase three while reviews run` confirms review
  waves must not race the calling phase.

Future agent behavior:
- When editing `prompts/review-wave.md` or
  `prompts/phase-audits/3-review*.md`, preserve context-pack-first ordering,
  deterministic-before-semantic ordering, stale-prompt isolation, and the
  `CLEAN` vs `FINDINGS_FIXED:N` distinction.
- When editing review specialist prompts, do not infer acceptance criteria from
  session state.
- When a wave applies any fix, write `FINDINGS_FIXED:N`; never write `CLEAN`
  after applying a fix.
- When invoking review outside the lifecycle, still build the context pack
  before broad semantic exploration.
- Treat `FINDINGS_FIXED:N` as a valid single-wave completion result; the outer
  `/dkreviewloop` owns the three-clean-pass gate.
