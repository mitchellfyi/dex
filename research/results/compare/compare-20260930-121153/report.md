# Dex vs bare Claude — compare-20260930-121153

Model `sonnet` at effort `low` for every arm; follow-up agent `sonnet` at `low`. Dex commit `0a54338` (23 uncommitted files under prompts/, skills/, hooks/, research/).
Resolved model: claude-sonnet-5-5.
Trials: 6 of 6 finished — valid 6. Invalid trials (no result, or an API error in the first turns) are excluded; censored trials (hit the time budget) are counted as they stand.

## Outcome quality

| Metric | bare | dex | Δ dex−bare | 95% CI |
|---|---|---|---|---|
| Hidden tests: spec | 100% | 100% | 0pp | 0pp … 0pp |
| Hidden tests: robust | 92% | 92% | 0pp | 0pp … 0pp |
| Hidden tests: preserve | 100% | 100% | 0pp | 0pp … 0pp |
| Own test suite passes | 100% | 100% | 0pp | 0pp … 0pp |
| Mutation score (own tests) | 86% | 90% | +4pp | +4pp … +4pp |
| Claimed passing, suite failed | 0% | 0% | 0pp | 0pp … 0pp |

## Size and scope

| Metric | bare | dex | Δ dex−bare | 95% CI |
|---|---|---|---|---|
| Source lines changed | 331 | 313 | -18 | -18 … -18 |
| Test lines changed | 4 | 78 | +74 | +74 … +74 |
| Files changed | 6 | 8 | +2 | +2 … +2 |
| Files outside scope | 0 | 0 | 0 | 0 … 0 |
| Forbidden files touched | 0 | 0 | 0 | 0 … 0 |

## Changeability (fixed follow-up agent)

| Metric | bare | dex | Δ dex−bare | 95% CI |
|---|---|---|---|---|
| Follow-up hidden tests | 100% | 100% | 0pp | 0pp … 0pp |
| Main hidden tests after follow-up | 98% | 98% | 0pp | 0pp … 0pp |
| Own suite passes after follow-up | 100% | 100% | 0pp | 0pp … 0pp |
| Follow-up cost ($) | 0.08 | 0.08 | -0.00 | -0.00 … -0.00 |
| Follow-up wall time (min) | 0.5 | 0.5 | +0.0 | +0.0 … +0.0 |
| Follow-up tokens | 111k | 87k | -24k | -24k … -24k |
| Follow-up source lines | 35 | 27 | -8 | -8 … -8 |

## Cost

| Metric | bare | dex | Δ dex−bare | 95% CI |
|---|---|---|---|---|
| Cost ($, API-equivalent) | 0.13 | 0.18 | +0.05 | +0.05 … +0.05 |
| Tokens (incl. cache) | 134k | 188k | +54k | +54k … +54k |
| Output tokens | 6k | 5k | -1k | -1k … -1k |
| Turns | 7.3 | 5.0 | -2.3 | -2.3 … -2.3 |
| Wall time (min) | 1.5 | 0.8 | -0.7 | -0.7 … -0.7 |

## Existing rubric (process-weighted; for continuity)

| Metric | bare | dex | Δ dex−bare | 95% CI |
|---|---|---|---|---|
| Rubric total | 92.0 | 92.3 | +0.3 | +0.3 … +0.3 |
| correctness | 100.0 | 100.0 | 0.0 | 0.0 … 0.0 |
| test_quality | 91.7 | 96.7 | +5.0 | +5.0 … +5.0 |
| robustness | 99.0 | 98.3 | -0.7 | -0.7 … -0.7 |
| verification | 100.0 | 100.0 | 0.0 | 0.0 … 0.0 |
| issue_detection | 100.0 | 95.0 | -5.0 | -5.0 … -5.0 |

Arm columns weight every scenario equally: the mean over scenarios of each scenario's mean over replicates.

## Per scenario

### cli-todo-app (bare n=1, dex n=1)

| Metric | bare | dex |
|---|---|---|
| Hidden tests: spec | 100% | 100% |
| Hidden tests: robust | 83% | 83% |
| Own test suite passes | 100% | 100% |
| Mutation score (own tests) | 95% | 100% |
| Claimed passing, suite failed | 0% | 0% |
| Source lines changed | 179 | 155 |
| Test lines changed | 0 | 215 |
| Files changed | 3 | 9 |
| Files outside scope | 0 | 0 |
| Forbidden files touched | 0 | 0 |
| Follow-up hidden tests | 100% | 100% |
| Main hidden tests after follow-up | 94% | 94% |
| Own suite passes after follow-up | 100% | 100% |
| Follow-up cost ($) | 0.07 | 0.07 |
| Follow-up wall time (min) | 0.5 | 0.5 |
| Follow-up tokens | 99k | 78k |
| Follow-up source lines | 52 | 32 |
| Cost ($, API-equivalent) | 0.09 | 0.19 |
| Tokens (incl. cache) | 83k | 149k |
| Output tokens | 4k | 7k |
| Turns | 8.0 | 4.0 |
| Wall time (min) | 0.7 | 1.0 |
| Rubric total | 89.0 | 90.0 |
| correctness | 100.0 | 100.0 |
| test_quality | 75.0 | 90.0 |
| robustness | 97.0 | 95.0 |
| verification | 100.0 | 100.0 |
| issue_detection | 100.0 | 85.0 |

### long-refactor-inheritance (bare n=1, dex n=1)

| Metric | bare | dex |
|---|---|---|
| Hidden tests: preserve | 100% | 100% |
| Own test suite passes | 100% | 100% |
| Claimed passing, suite failed | 0% | 0% |
| Source lines changed | 806 | 775 |
| Test lines changed | 0 | 0 |
| Files changed | 11 | 11 |
| Files outside scope | 0 | 0 |
| Forbidden files touched | 0 | 0 |
| Follow-up hidden tests | 100% | 100% |
| Main hidden tests after follow-up | 100% | 100% |
| Own suite passes after follow-up | 100% | 100% |
| Follow-up cost ($) | 0.09 | 0.08 |
| Follow-up wall time (min) | 0.5 | 0.5 |
| Follow-up tokens | 154k | 104k |
| Follow-up source lines | 34 | 36 |
| Cost ($, API-equivalent) | 0.23 | 0.22 |
| Tokens (incl. cache) | 198k | 246k |
| Output tokens | 11k | 7k |
| Turns | 7.0 | 6.0 |
| Wall time (min) | 3.3 | 0.9 |
| Rubric total | 90.0 | 90.0 |
| correctness | 100.0 | 100.0 |
| test_quality | 100.0 | 100.0 |
| robustness | 100.0 | 100.0 |
| verification | 100.0 | 100.0 |
| issue_detection | 100.0 | 100.0 |

### oss-bug-triage (bare n=1, dex n=1)

| Metric | bare | dex |
|---|---|---|
| Hidden tests: spec | 100% | 100% |
| Hidden tests: robust | 100% | 100% |
| Hidden tests: preserve | 100% | 100% |
| Own test suite passes | 100% | 100% |
| Mutation score (own tests) | 78% | 80% |
| Claimed passing, suite failed | 0% | 0% |
| Source lines changed | 9 | 9 |
| Test lines changed | 12 | 20 |
| Files changed | 3 | 3 |
| Files outside scope | 0 | 0 |
| Forbidden files touched | 0 | 0 |
| Follow-up hidden tests | 100% | 100% |
| Main hidden tests after follow-up | 100% | 100% |
| Own suite passes after follow-up | 100% | 100% |
| Follow-up cost ($) | 0.07 | 0.07 |
| Follow-up wall time (min) | 0.4 | 0.5 |
| Follow-up tokens | 80k | 80k |
| Follow-up source lines | 18 | 13 |
| Cost ($, API-equivalent) | 0.08 | 0.13 |
| Tokens (incl. cache) | 121k | 168k |
| Output tokens | 2k | 2k |
| Turns | 7.0 | 5.0 |
| Wall time (min) | 0.6 | 0.5 |
| Rubric total | 97.0 | 97.0 |
| correctness | 100.0 | 100.0 |
| test_quality | 100.0 | 100.0 |
| robustness | 100.0 | 100.0 |
| verification | 100.0 | 100.0 |
| issue_detection | 100.0 | 100.0 |

Per-scenario cells are the mean over replicates, ± the sample standard deviation for non-percentages.

