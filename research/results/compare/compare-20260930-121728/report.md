# Dex vs bare Claude — compare-20260930-121728

Model `opus` at effort `xhigh` for every arm; follow-up agent `sonnet` at `high`. Dex commit `0a54338` (23 uncommitted files under prompts/, skills/, hooks/, research/).
Resolved model: claude-opus-5-5.
Trials: 24 of 24 finished — valid 24. Invalid trials (no result, or an API error in the first turns) are excluded; censored trials (hit the time budget) are counted as they stand.

## Outcome quality

| Metric | bare | dex | Δ dex−bare | 95% CI |
|---|---|---|---|---|
| Hidden tests: spec | 100% | 100% | 0pp | 0pp … 0pp |
| Hidden tests: robust | 98% | 98% | 0pp | -4pp … +4pp |
| Hidden tests: preserve | 100% | 100% | 0pp | 0pp … 0pp |
| Own test suite passes | 100% | 100% | 0pp | 0pp … 0pp |
| Mutation score (own tests) | 91% | 88% | -3pp | -5pp … -1pp |
| Claimed passing, suite failed | 0% | 0% | 0pp | 0pp … 0pp |

## Size and scope

| Metric | bare | dex | Δ dex−bare | 95% CI |
|---|---|---|---|---|
| Source lines changed | 259 | 503 | +244 | +195 … +298 |
| Test lines changed | 207 | 525 | +318 | +262 … +386 |
| Files changed | 6 | 12 | +7 | +6 … +8 |
| Files outside scope | 0 | 0 | 0 | 0 … 0 |
| Forbidden files touched | 0 | 0 | 0 | 0 … 0 |

## Changeability (fixed follow-up agent)

| Metric | bare | dex | Δ dex−bare | 95% CI |
|---|---|---|---|---|
| Follow-up hidden tests | 100% | 100% | 0pp | 0pp … 0pp |
| Main hidden tests after follow-up | 100% | 100% | 0pp | -1pp … +1pp |
| Own suite passes after follow-up | 100% | 100% | 0pp | 0pp … 0pp |
| Follow-up cost ($) | 0.10 | 0.14 | +0.04 | +0.03 … +0.04 |
| Follow-up wall time (min) | 0.7 | 0.9 | +0.2 | +0.2 … +0.3 |
| Follow-up tokens | 95k | 161k | +66k | +51k … +80k |
| Follow-up source lines | 32 | 38 | +7 | +2 … +11 |

## Cost

| Metric | bare | dex | Δ dex−bare | 95% CI |
|---|---|---|---|---|
| Cost ($, API-equivalent) | 0.64 | 2.43 | +1.79 | +1.30 … +2.45 |
| Tokens (incl. cache) | 384k | 2816k | +2433k | +1763k … +3383k |
| Output tokens | 20k | 66k | +46k | +33k … +64k |
| Turns | 13.8 | 33.8 | +20.0 | +12.8 … +25.5 |
| Wall time (min) | 3.8 | 12.6 | +8.8 | +6.6 … +11.7 |

## Runtime behaviour (reference solution = 1.00x)

| Metric | bare | dex | Δ dex−bare | 95% CI |
|---|---|---|---|---|
| Time vs reference (geomean) | 1.31x | 1.49x | +0.19x | -0.05x … +0.44x |
| Worst timing noise (CV) | 44% | 50% | +6pp | -11pp … +21pp |
| Fuzz sequences agreeing with reference | 100% | 95% | -5pp | -5pp … -5pp |

## Code health

| Metric | bare | dex | Δ dex−bare | 95% CI |
|---|---|---|---|---|
| eslint findings per KLOC (source) | 2.8 | 2.8 | 0.0 | -0.0 … +0.0 |
| Cyclomatic complexity (mean) | 2.9 | 2.7 | -0.2 | -0.4 … -0.1 |
| Cyclomatic complexity (max) | 10 | 8 | -2 | -3 … -1 |
| Longest function (lines) | 40 | 33 | -7 | -13 … -2 |
| Deepest nesting | 2 | 2 | +0 | -0 … +0 |
| Duplicated source lines (%) | 0.2 | 0.0 | -0.2 | -0.6 … 0.0 |
| Dependencies declared | 0 | 2 | +2 | +2 … +2 |
| Packages installed | 0 | 40 | +40 | +40 … +40 |
| npm audit findings | – | 0 | – | – |

## Test-suite health

| Metric | bare | dex | Δ dex−bare | 95% CI |
|---|---|---|---|---|
| Suite passes (of 5 runs) | 100% | 100% | 0pp | 0pp … 0pp |
| Flaky suite | 0% | 0% | 0pp | 0pp … 0pp |
| Suite runtime (s, median) | 1.7 | 1.3 | -0.4 | -1.1 … +0.6 |
| Files left behind by tests | 1 | 1 | 0 | 0 … 0 |

## Conventions and docs

| Metric | bare | dex | Δ dex−bare | 95% CI |
|---|---|---|---|---|
| CLI conventions met | 100% | 100% | 0pp | 0pp … 0pp |
| Has a README | 17% | 50% | +33pp | +25pp … +50pp |
| README samples that run | 100% | 76% | -7pp | -20pp … 0pp |
| Closing report accuracy (judge) | 100% | 100% | 0pp | 0pp … 0pp |

## Existing rubric (process-weighted; for continuity)

| Metric | bare | dex | Δ dex−bare | 95% CI |
|---|---|---|---|---|
| Rubric total | 91.0 | 90.6 | -0.4 | -1.4 … +0.6 |
| correctness | 98.0 | 96.8 | -1.2 | -4.5 … +2.0 |
| test_quality | 91.8 | 97.5 | +5.8 | +5.8 … +5.8 |
| robustness | 97.2 | 90.4 | -6.8 | -8.4 … -5.1 |
| verification | 100.0 | 100.0 | 0.0 | 0.0 … 0.0 |
| issue_detection | 97.5 | 90.0 | -7.5 | -10.0 … -6.2 |

Arm columns weight every scenario equally: the mean over scenarios of each scenario's mean over replicates.

Timing caution: repeat runs of the same code varied by up to 122% (CV). Treat perf ratios within about ±25% of 1.00x as equal.

## Blind pairwise review

Judge: `claude` `opus` (same model family as the arms). 12 pairs, each judged in both orders; a criterion counts for an arm only when both orders agree. The overall pick was the same in both orders for 11 of 12 pairs.

### dex vs bare

| Criterion | All pairs | buggy-code-fix | cli-todo-app | long-refactor-inheritance | oss-bug-triage |
|---|---|---|---|---|---|
| overall | dex 2 · tie 1 · bare 9 | dex 0 · tie 0 · bare 3 | dex 0 · tie 0 · bare 3 | dex 0 · tie 1 · bare 2 | dex 2 · tie 0 · bare 1 |
| correctness | dex 2 · tie 8 · bare 2 | dex 0 · tie 3 · bare 0 | dex 0 · tie 3 · bare 0 | dex 1 · tie 1 · bare 1 | dex 1 · tie 1 · bare 1 |
| readability | dex 0 · tie 4 · bare 8 | dex 0 · tie 0 · bare 3 | dex 0 · tie 0 · bare 3 | dex 0 · tie 1 · bare 2 | dex 0 · tie 3 · bare 0 |
| maintainability | dex 3 · tie 3 · bare 6 | dex 0 · tie 1 · bare 2 | dex 0 · tie 0 · bare 3 | dex 1 · tie 2 · bare 0 | dex 2 · tie 0 · bare 1 |
| tests | dex 2 · tie 9 · bare 1 | dex 0 · tie 3 · bare 0 | dex 0 · tie 3 · bare 0 | dex 0 · tie 3 · bare 0 | dex 2 · tie 0 · bare 1 |
| scope | dex 1 · tie 1 · bare 10 | dex 0 · tie 0 · bare 3 | dex 0 · tie 0 · bare 3 | dex 0 · tie 0 · bare 3 | dex 1 · tie 1 · bare 1 |

## Per scenario

### buggy-code-fix (bare n=3, dex n=3)

| Metric | bare | dex |
|---|---|---|
| Hidden tests: spec | 100% | 100% |
| Hidden tests: robust | 100% | 100% |
| Hidden tests: preserve | 100% | 100% |
| Own test suite passes | 100% | 100% |
| Mutation score (own tests) | 100% | 99% |
| Claimed passing, suite failed | 0% | 0% |
| Source lines changed | 52 ±7 | 224 ±27 |
| Test lines changed | 277 ±22 | 694 ±91 |
| Files changed | 3 ±0 | 10 ±0 |
| Files outside scope | 0 ±0 | 0 ±0 |
| Forbidden files touched | 0 ±0 | 0 ±0 |
| Follow-up hidden tests | 100% | 100% |
| Main hidden tests after follow-up | 100% | 100% |
| Own suite passes after follow-up | 100% | 100% |
| Follow-up cost ($) | 0.08 ±0.01 | 0.11 ±0.01 |
| Follow-up wall time (min) | 0.5 ±0.0 | 0.8 ±0.1 |
| Follow-up tokens | 90k ±14k | 140k ±30k |
| Follow-up source lines | 18 ±4 | 37 ±13 |
| Cost ($, API-equivalent) | 0.38 ±0.02 | 1.80 ±0.38 |
| Tokens (incl. cache) | 272k ±10k | 1905k ±402k |
| Output tokens | 11k ±1k | 50k ±12k |
| Turns | 12.3 ±0.6 | 37.3 ±4.2 |
| Wall time (min) | 2.3 ±0.1 | 9.9 ±2.1 |
| Time vs reference (geomean) | 1.74x ±0.30x | 1.29x ±0.23x |
| Worst timing noise (CV) | 62% | 46% |
| Fuzz sequences agreeing with reference | 100% | 100% |
| eslint findings per KLOC (source) | 0.0 ±0.0 | 0.0 ±0.0 |
| Cyclomatic complexity (mean) | 2.3 ±0.3 | 2.4 ±0.4 |
| Cyclomatic complexity (max) | 7 ±2 | 7 ±3 |
| Longest function (lines) | 16 ±3 | 14 ±3 |
| Deepest nesting | 1 ±0 | 1 ±1 |
| Duplicated source lines (%) | 0.0 ±0.0 | 0.0 ±0.0 |
| Dependencies declared | 0 ±0 | 3 ±0 |
| Packages installed | 0 ±0 | 79 ±0 |
| npm audit findings | – | 0 ±0 |
| Suite passes (of 5 runs) | 100% | 100% |
| Flaky suite | 0% | 0% |
| Suite runtime (s, median) | 0.4 ±0.1 | 0.8 ±0.2 |
| Files left behind by tests | 1 ±0 | 1 ±0 |
| Has a README | 0% | 100% |
| README samples that run | – | 58% |
| Closing report accuracy (judge) | 100% | 100% |
| Rubric total | 90.7 ±1.2 | 94.3 ±1.2 |
| correctness | 100.0 ±0.0 | 100.0 ±0.0 |
| test_quality | 87.0 ±0.0 | 100.0 ±0.0 |
| robustness | 100.0 ±0.0 | 96.7 ±5.8 |
| verification | 100.0 ±0.0 | 100.0 ±0.0 |
| issue_detection | 90.0 ±8.7 | 100.0 ±0.0 |

### cli-todo-app (bare n=3, dex n=3)

| Metric | bare | dex |
|---|---|---|
| Hidden tests: spec | 100% | 100% |
| Hidden tests: robust | 94% | 94% |
| Own test suite passes | 100% | 100% |
| Mutation score (own tests) | 95% | 88% |
| Claimed passing, suite failed | 0% | 0% |
| Source lines changed | 225 ±29 | 777 ±195 |
| Test lines changed | 529 ±33 | 1366 ±266 |
| Files changed | 6 ±1 | 20 ±3 |
| Files outside scope | 0 ±0 | 0 ±0 |
| Forbidden files touched | 0 ±0 | 0 ±0 |
| Follow-up hidden tests | 100% | 100% |
| Main hidden tests after follow-up | 98% | 98% |
| Own suite passes after follow-up | 100% | 100% |
| Follow-up cost ($) | 0.12 ±0.00 | 0.22 ±0.01 |
| Follow-up wall time (min) | 0.9 ±0.1 | 1.4 ±0.2 |
| Follow-up tokens | 96k ±1k | 296k ±50k |
| Follow-up source lines | 45 ±12 | 56 ±5 |
| Cost ($, API-equivalent) | 0.67 ±0.14 | 4.69 ±2.51 |
| Tokens (incl. cache) | 368k ±104k | 6369k ±3579k |
| Output tokens | 22k ±5k | 126k ±66k |
| Turns | 16.0 ±4.6 | 51.0 ±28.8 |
| Wall time (min) | 4.0 ±0.9 | 24.0 ±10.3 |
| Time vs reference (geomean) | 1.04x ±0.17x | 1.62x ±0.36x |
| Worst timing noise (CV) | 47% | 41% |
| Fuzz sequences agreeing with reference | 100% | 80% |
| eslint findings per KLOC (source) | 0.0 ±0.0 | 0.0 ±0.0 |
| Cyclomatic complexity (mean) | 3.1 ±0.1 | 2.5 ±0.2 |
| Cyclomatic complexity (max) | 16 ±2 | 9 ±1 |
| Longest function (lines) | 49 ±18 | 28 ±4 |
| Deepest nesting | 3 ±1 | 3 ±0 |
| Duplicated source lines (%) | 0.0 ±0.0 | 0.0 ±0.0 |
| Dependencies declared | 0 ±0 | 3 ±0 |
| Packages installed | 0 ±0 | 79 ±0 |
| npm audit findings | – | 0 ±0 |
| Suite passes (of 5 runs) | 100% | 100% |
| Flaky suite | 0% | 0% |
| Suite runtime (s, median) | 5.5 ±3.6 | 3.3 ±0.8 |
| Files left behind by tests | 1 ±0 | 1 ±0 |
| CLI conventions met | 100% | 100% |
| Has a README | 67% | 100% |
| README samples that run | 100% | 93% |
| Closing report accuracy (judge) | 100% | 100% |
| Rubric total | 87.0 ±1.7 | 89.3 ±2.3 |
| correctness | 92.0 ±6.9 | 92.0 ±6.9 |
| test_quality | 80.0 ±0.0 | 90.0 ±0.0 |
| robustness | 92.0 ±0.0 | 95.0 ±0.0 |
| verification | 100.0 ±0.0 | 100.0 ±0.0 |
| issue_detection | 100.0 ±0.0 | 100.0 ±0.0 |

### long-refactor-inheritance (bare n=3, dex n=3)

| Metric | bare | dex |
|---|---|---|
| Hidden tests: preserve | 100% | 100% |
| Own test suite passes | 100% | 100% |
| Claimed passing, suite failed | 0% | 0% |
| Source lines changed | 751 ±89 | 1005 ±57 |
| Test lines changed | 0 ±0 | 0 ±0 |
| Files changed | 10 ±2 | 16 ±1 |
| Files outside scope | 0 ±0 | 0 ±0 |
| Forbidden files touched | 0 ±0 | 0 ±0 |
| Follow-up hidden tests | 100% | 100% |
| Main hidden tests after follow-up | 100% | 100% |
| Own suite passes after follow-up | 100% | 100% |
| Follow-up cost ($) | 0.10 ±0.00 | 0.13 ±0.01 |
| Follow-up wall time (min) | 0.6 ±0.0 | 0.7 ±0.0 |
| Follow-up tokens | 108k ±15k | 121k ±16k |
| Follow-up source lines | 43 ±4 | 40 ±7 |
| Cost ($, API-equivalent) | 1.29 ±0.16 | 2.78 ±0.57 |
| Tokens (incl. cache) | 731k ±67k | 2648k ±785k |
| Output tokens | 42k ±7k | 80k ±15k |
| Turns | 18.3 ±1.2 | 36.3 ±5.8 |
| Wall time (min) | 7.5 ±0.9 | 14.5 ±3.8 |
| Time vs reference (geomean) | 1.40x ±0.30x | 2.20x ±0.89x |
| Worst timing noise (CV) | 34% | 61% |
| Fuzz sequences agreeing with reference | 100% | 100% |
| eslint findings per KLOC (source) | 0.0 ±0.0 | 0.0 ±0.0 |
| Cyclomatic complexity (mean) | 2.7 ±0.0 | 2.4 ±0.2 |
| Cyclomatic complexity (max) | 9 ±2 | 8 ±2 |
| Longest function (lines) | 79 ±11 | 72 ±10 |
| Deepest nesting | 2 ±1 | 2 ±1 |
| Duplicated source lines (%) | 0.8 ±1.4 | 0.0 ±0.0 |
| Dependencies declared | 0 ±0 | 0 ±0 |
| Packages installed | 0 ±0 | 0 ±0 |
| Suite passes (of 5 runs) | 100% | 100% |
| Flaky suite | 0% | 0% |
| Suite runtime (s, median) | 0.4 ±0.1 | 0.5 ±0.0 |
| Files left behind by tests | 1 ±0 | 1 ±0 |
| Has a README | 0% | 0% |
| Closing report accuracy (judge) | 100% | 100% |
| Rubric total | 89.3 ±1.2 | 81.7 ±2.3 |
| correctness | 100.0 ±0.0 | 95.0 ±8.7 |
| test_quality | 100.0 ±0.0 | 100.0 ±0.0 |
| robustness | 96.7 ±5.8 | 70.0 ±0.0 |
| verification | 100.0 ±0.0 | 100.0 ±0.0 |
| issue_detection | 100.0 ±0.0 | 60.0 ±0.0 |

### oss-bug-triage (bare n=3, dex n=3)

| Metric | bare | dex |
|---|---|---|
| Hidden tests: spec | 100% | 100% |
| Hidden tests: robust | 100% | 100% |
| Hidden tests: preserve | 100% | 100% |
| Own test suite passes | 100% | 100% |
| Mutation score (own tests) | 77% | 78% |
| Claimed passing, suite failed | 0% | 0% |
| Source lines changed | 6 ±3 | 6 ±3 |
| Test lines changed | 21 ±7 | 39 ±14 |
| Files changed | 3 ±0 | 3 ±0 |
| Files outside scope | 0 ±0 | 0 ±0 |
| Forbidden files touched | 0 ±0 | 0 ±0 |
| Follow-up hidden tests | 100% | 100% |
| Main hidden tests after follow-up | 100% | 100% |
| Own suite passes after follow-up | 100% | 100% |
| Follow-up cost ($) | 0.09 ±0.00 | 0.09 ±0.00 |
| Follow-up wall time (min) | 0.6 ±0.0 | 0.6 ±0.0 |
| Follow-up tokens | 86k ±1k | 85k ±2k |
| Follow-up source lines | 22 ±3 | 19 ±5 |
| Cost ($, API-equivalent) | 0.21 ±0.01 | 0.44 ±0.05 |
| Tokens (incl. cache) | 162k ±1k | 343k ±59k |
| Output tokens | 4k ±0k | 8k ±1k |
| Turns | 8.3 ±0.6 | 10.3 ±1.2 |
| Wall time (min) | 1.3 ±0.2 | 1.9 ±0.2 |
| Time vs reference (geomean) | 1.06x ±0.06x | 0.86x ±0.15x |
| Worst timing noise (CV) | 33% | 51% |
| Fuzz sequences agreeing with reference | 100% | 100% |
| eslint findings per KLOC (source) | 11.2 ±0.1 | 11.2 ±0.1 |
| Cyclomatic complexity (mean) | 3.5 ±0.1 | 3.5 ±0.1 |
| Cyclomatic complexity (max) | 7 ±0 | 7 ±0 |
| Longest function (lines) | 17 ±0 | 17 ±0 |
| Deepest nesting | 3 ±0 | 3 ±0 |
| Duplicated source lines (%) | 0.0 ±0.0 | 0.0 ±0.0 |
| Dependencies declared | 0 ±0 | 0 ±0 |
| Packages installed | 0 ±0 | 0 ±0 |
| Suite passes (of 5 runs) | 100% | 100% |
| Flaky suite | 0% | 0% |
| Suite runtime (s, median) | 0.3 ±0.1 | 0.5 ±0.0 |
| Files left behind by tests | 1 ±0 | 1 ±0 |
| Has a README | 0% | 0% |
| Closing report accuracy (judge) | 100% | 100% |
| Rubric total | 97.0 ±0.0 | 97.0 ±0.0 |
| correctness | 100.0 ±0.0 | 100.0 ±0.0 |
| test_quality | 100.0 ±0.0 | 100.0 ±0.0 |
| robustness | 100.0 ±0.0 | 100.0 ±0.0 |
| verification | 100.0 ±0.0 | 100.0 ±0.0 |
| issue_detection | 100.0 ±0.0 | 100.0 ±0.0 |

Per-scenario cells are the mean over replicates, ± the sample standard deviation for non-percentages.

