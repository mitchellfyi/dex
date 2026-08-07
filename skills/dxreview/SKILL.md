---
name: "dxreview"
description: "Run one independent full-scope Dex review wave at the selected risk depth."
---

# Skill: dxreview

Run one full-scope review wave. Direct `/dxreview` invocations dispatch to
`/dxreviewloop`; single-pass mode is reserved for `/dxreviewloop` and Phase 3.

## Dispatch

If invoked without `--single-pass` or `--no-loop`, invoke `dxreviewloop` and
stop.

Run the single-pass workflow only when the invocation includes
`--single-pass`, `--no-loop`, or explicitly states that it came from
`/dxreviewloop`. If unsure, use the loop.

## Single-Pass Workflow

Follow `prompts/review-wave.md` as the source of truth. In one wave:

1. Review the caller-supplied full current change set. When no change set
   exists, review the supplied whole-codebase inventory.
2. Build a new compact context pack before broad exploration.
3. Run deterministic checks before semantic review.
4. Create lightweight repro probes for suspected correctness, contract, or
   regression findings when the repo has runnable tests or scripts.
5. Harvest candidate issues at the supplied profile:
   - `light` (`small` risk): core domain sweep
   - `standard` (`normal` risk): core sweep plus targeted domain sweeps for
     concrete changed surfaces
   - `thorough` (`complex` risk): all domain sweeps across the full scope
6. Verify, deduplicate, and rank candidates before changing code.
7. Batch-fix all verified findings that are safe and in scope, then rerun
   affected checks and targeted review once.
8. Write the review result signal and findings fingerprint.

Run in the current checkout. Do not run `dx <ticket-or-description>`, Phase 0
setup, or any branch/worktree setup from this skill. Do not create, switch,
rename, or delete branches or worktrees.

This wave must remain independent. Use only the current code, caller-supplied
scope, supplied acceptance criteria, and current profile. Do not read or infer
prior review reports, prior findings, findings fingerprints, clean-pass counts,
telemetry, stale session prompts, previous turns, or unrelated ticket context.

Collect all candidate issues before fixing anything. This fresh review-wave CLI
session is the independent reviewer. The point is one aggressive inventory
followed by one verified batch fix.

Do not stop after only reporting findings. Fix safe verified findings in scope,
rerun affected checks, and write `FINDINGS_FIXED:N`. Write `FINDINGS:N` only
when verified findings remain after a concrete local fix attempt is blocked,
unsafe, or requires user judgment.

If no plan or ticket criteria are supplied by the current caller, mark
criteria-dependent evidence as `N/A`. Do not reconstruct criteria from other
state.

## Result Signal

When `DEX_SESSION_ID` is available, write exactly one result:

```bash
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh" || exit 1
SESSION_ID="${DEX_SESSION_ID:-$(dx_session_id)}"
[[ -n "$SESSION_ID" ]] || { echo "ERROR: empty session id — refusing to write unkeyed state" >&2; exit 1; }
echo "<result>" > "$(dx_review_result_file "$SESSION_ID")"
```

Allowed results:

- `CLEAN`
- `FINDINGS_FIXED:N`
- `FINDINGS:N`
- `BLOCKED:reason-code`
- `CHURN:reason-code`
- `ESCALATE:normal:reason-code`
- `ESCALATE:complex:reason-code`

Only `CLEAN` means the wave found zero verified findings and applied zero fixes.
Any fix writes `FINDINGS_FIXED:N`. If the supplied tier is too low for the
observed risk, request the next adequate tier. Never request a downgrade.

Use short, lowercase reason codes. Do not put source text, file paths, prompts,
credentials, or other free-form content in result suffixes. The legacy
`ESCALATE_THOROUGH:reason` form is accepted but should not be emitted by new
waves.

Also write the single findings hash described in `prompts/review-wave.md`.
The outer wrapper uses it only for deterministic churn detection; subsequent
reviewers must never receive it.

## Final Report

End with the `Review Wave Result` block from `prompts/review-wave.md`. Do not
commit, push, create or update PRs, or request external reviewers.
