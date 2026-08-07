---
name: "dxreviewloop"
description: "Run independent full-scope Dex review waves until the selected risk tier's consecutive clean-pass gate succeeds."
---

# Skill: dxreviewloop

Run `/dxreview --single-pass` in fresh review-wave sessions until the selected
risk tier reaches its consecutive `CLEAN` gate. This is the default Review
phase used by `dx`.

## Workspace Boundary

`/dxreviewloop` is a one-off review command unless it is invoked from an active
`dx` lifecycle. Run it in the current checkout exactly as found.

Do not run `dx <ticket-or-description>`, `dx --no-worktree`, Phase 0 setup, or
any branch/worktree setup from this skill. Do not create, switch, rename, or
delete branches or worktrees. A fresh review-wave session is a fresh agent
context for the same checkout, not a fresh git workspace.

## Risk Selection

Resolve one risk tier before the first review wave. The tier controls both the
review depth and the number of consecutive clean waves required:

| Risk tier | Review profile | Required consecutive `CLEAN` waves |
|-----------|----------------|-------------------------------------|
| `small` | `light` | 3 |
| `normal` | `standard` | 6 |
| `complex` | `thorough` | 9 |

Use `prompts/review-risk-assessment.md` as the source of truth. Its first
matching rule wins:

- Choose `complex` when the scope touches a trust boundary; authentication,
  authorization, permissions, secrets, payments, or destructive behavior;
  persistence, schemas, or migrations; public API, CLI, configuration, or
  compatibility contracts; concurrency or process lifecycle; hooks, guards,
  CI, deployment, or packaging; broad cross-module behavior; or material
  uncertainty about impact or verification.
- Choose `small` only when every change is localized and mechanically direct,
  impact is narrow, focused verification is available, and no `complex`
  condition applies.
- Choose `normal` for everything else.

The choice must be deterministic. Use one or more of these comma-separated
reason codes: `localized-change`, `focused-verification`,
`bounded-production-change`, `cross-module`, `public-contract`,
`security-sensitive`, `data-migration`, `concurrency`, `shell-hooks-ci`,
`deployment-packaging`, `broad-impact`, or `uncertain-coverage`. Do not put
free-form prose, paths, source excerpts, prompts, or secrets in the persisted
reason field.

The reason codes must satisfy the tier-specific combination rules in
`prompts/review-risk-assessment.md`; an allowed code with a contradictory tier
is still invalid.

The wrapper reserves the reason codes `operator-override` for an explicit
environment override and `wave-escalation` for a verified upward promotion.
Selection sources are `environment`, `lifecycle-agent`, `lifecycle-assessor`,
`standalone-assessor`, or `wave-escalation`. These are structured orchestration
values, not alternatives the risk assessor may invent.

In the normal lifecycle flow, the implementation agent must record this
selection before Phase 2 hands off to Phase 3. When a legacy or resumed
lifecycle has no valid current-scope selection, the wrapper may recover by
launching a fresh read-only assessor before the first wave and recording
`lifecycle-assessor` as the source. This recovery path is not a substitute for
normal Phase 2 selection.

A standalone `dxreviewloop` invocation without an explicit tier/profile
override launches the same read-only assessment in a fresh session and records
`standalone-assessor` as the source. An assessment is not a clean pass and must
not edit the checkout.

`DEX_REVIEW_TIER=small|normal|complex` is the canonical explicit override and
takes precedence. `DEX_REVIEW_PROFILE=light|standard|thorough` remains a legacy
alias. A `DEX_REVIEW_CLEAN_PASSES` override may raise the gate but cannot
lower the selected tier's canonical floor. Review may escalate to a higher tier,
but it never downgrades.

There is no outer iteration limit. The loop continues until the clean-pass gate
succeeds or a deterministic pause condition requires intervention.

## Scope

Review the full current change set when one exists:

- committed branch changes, preferably `git diff origin/<default>...HEAD`
- staged changes via `git diff --cached`
- unstaged changes via `git diff`
- untracked files represented with `git diff --no-index -- /dev/null <file>`

If no changes or comparable branch diff exist, review the entire tracked
codebase. Do not stop only because `git diff` is empty; use the caller-supplied
file inventory commands as the authoritative scope.

## Independent Per-Pass Contract

Each iteration launches exactly one fresh review-wave CLI session with a
pass-scoped session ID. The wave receives only the current code, current scope,
current acceptance criteria when supplied by this invocation, the selected
review profile, and a new context-pack path.

Do not give a wave prior review reports, prior findings, findings fingerprints,
clean-pass counts, telemetry, or previous conversation context. The outer
wrapper owns that history. This prevents a later wave from anchoring on an
earlier reviewer's conclusion.

Every wave must:

1. Build a non-empty compact context pack in its pass-scoped global Dex state.
2. Run deterministic checks before semantic review.
3. Harvest candidates across the full supplied scope at the selected depth.
4. Verify and deduplicate candidates before fixing.
5. Batch-fix verified findings that are safe and in scope.
6. Re-run affected checks and targeted review.
7. Write one result signal, exactly one lowercase 16-character findings hash,
   and the pass completion marker, then stop.

Waves run with `DEX_REVIEW_PASS_ACTIVE=1`, a pass-scoped `DEX_SESSION_ID`, and
an empty `DEX_PHASE_HANDOFF`. They must never receive or write the lifecycle
completion path.

If fresh review-wave CLI sessions are unavailable, pause with
`BLOCKED:review-session-unavailable`; do not simulate independent passes in the
orchestrator's existing context.

The wrapper accepts a wave only when its result is valid, its context pack is
non-empty, its findings hash is valid, and its completion marker exists. It
harvests validated non-clean hashes for churn detection before deleting all
pass-scoped state.

## Result Signals

- `CLEAN`: zero verified findings and zero fixes; increment the consecutive
  clean count.
- `FINDINGS_FIXED:N`: N verified findings were fixed and rechecked; reset the
  clean count and start another fresh wave.
- `ESCALATE:normal:reason-code` or `ESCALATE:complex:reason-code`: raise the
  tier, reset the clean count, and continue with a fresh wave.
- `FINDINGS:N`: verified findings remain after a concrete safe fix attempt;
  reset the count and pause for intervention.
- `BLOCKED:reason-code`: required tooling, context, authority, or user judgment
  is unavailable; reset the count and pause.
- `CHURN:reason-code`: the pass cannot make reliable progress; reset the count
  and pause.

`ESCALATE_THOROUGH:reason` remains accepted for backward compatibility and maps
to `ESCALATE:complex:reason`. New waves should use the tiered form.

Only `CLEAN` increments the gate. Any in-scope change invalidates prior clean
credit. After a wave applies fixes, retain or raise the selected tier, bind it
to the updated scope fingerprint, reset progress to zero, and start another
fresh wave. The outer wrapper also pauses on missing or malformed results,
provider failures, three repeated findings fingerprints, or an alternating
two-fingerprint cycle across four non-clean waves. Findings fingerprints stay
in transient Dex state and are never included in later wave prompts or
telemetry.

## Persistence and Receipt

The wrapper persists the selected tier, required clean count, iteration, clean
count, and current-scope fingerprint outside the repository. Resume that state
only while the scope fingerprint still matches. An out-of-band scope change
invalidates selection, progress, and success receipts; resolve the tier again
before counting another wave.

After the gate succeeds, write a machine-readable review receipt tied to the
current scope fingerprint. Lifecycle Phase 3 advances only when that receipt is
valid; a prose success claim is not sufficient.

## Telemetry

Record review state changes in the run journal with these event types:

- `review.tier.selected`
- `review.pass.started`
- `review.pass.finished`
- `review.tier.escalated`
- `review.completed`
- `review.paused`

Payloads use normalized tiers, reason codes, result kinds, counts, durations,
exit reasons, and churn categories. Never record raw result suffixes, findings,
fingerprints, file paths, branch names, prompts, diffs, context packs, or
free-form agent rationale. Telemetry is observational and must never determine
whether a pass counts as clean.

## Report

Print:

```markdown
## dxreviewloop Result

- Scope: full current change set | entire codebase
- Risk tier: small | normal | complex
- Review profile: light | standard | thorough
- Iterations: N
- Consecutive clean: M / required
- Findings fixed this run: K
- Result: SUCCESS | PAUSED
- Exit reason: clean_gate_reached | <normalized pause reason>
```

On success, include the valid receipt path. On pause, include only the
normalized reason and the intervention needed.
