# Dex vs bare Claude — compare-20260930-135556

Model `sonnet` at effort `low` for every arm; follow-up agent `sonnet` at `low`. Dex commit `0a54338` (26 uncommitted files under prompts/, skills/, hooks/, research/).
Resolved model: claude-sonnet-5-5.
Trials: 8 of 8 finished — valid 8. Invalid trials (no result, or an API error in the first turns) are excluded; censored trials (hit the time budget) are counted as they stand.

## Outcome quality

| Metric | bare | dex@HEAD | dex | dex-loop | Δ dex@HEAD−bare | 95% CI | Δ dex−bare | 95% CI | Δ dex-loop−bare | 95% CI |
|---|---|---|---|---|---|---|---|---|---|---|
| Hidden tests: spec | 100% | 100% | 100% | 100% | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp |
| Hidden tests: robust | 95% | 95% | 100% | 100% | 0pp | 0pp … 0pp | +5pp | +5pp … +5pp | +5pp | +5pp … +5pp |
| Hidden tests: preserve | 100% | 100% | 100% | 100% | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp |
| Own test suite passes | 100% | 100% | 100% | 100% | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp |
| Mutation score (own tests) | 80% | 82% | 78% | 82% | +2pp | +2pp … +2pp | -3pp | -3pp … -3pp | +1pp | +1pp … +1pp |
| Claimed passing, suite failed | 0% | 0% | 0% | 0% | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp |

## Size and scope

| Metric | bare | dex@HEAD | dex | dex-loop | Δ dex@HEAD−bare | 95% CI | Δ dex−bare | 95% CI | Δ dex-loop−bare | 95% CI |
|---|---|---|---|---|---|---|---|---|---|---|
| Source lines changed | 138 | 138 | 188 | 114 | -0 | -0 … -0 | +49 | +49 … +49 | -24 | -24 … -24 |
| Test lines changed | 68 | 78 | 88 | 76 | +10 | +10 … +10 | +20 | +20 … +20 | +8 | +8 … +8 |
| Files changed | 2 | 4 | 2 | 2 | +1 | +1 … +1 | 0 | 0 … 0 | 0 | 0 … 0 |
| Files outside scope | 0 | 0 | 0 | 0 | 0 | 0 … 0 | 0 | 0 … 0 | 0 | 0 … 0 |
| Forbidden files touched | 0 | 0 | 0 | 0 | 0 | 0 … 0 | 0 | 0 … 0 | 0 | 0 … 0 |

## Changeability (fixed follow-up agent)

| Metric | bare | dex@HEAD | dex | dex-loop | Δ dex@HEAD−bare | 95% CI | Δ dex−bare | 95% CI | Δ dex-loop−bare | 95% CI |
|---|---|---|---|---|---|---|---|---|---|---|
| Follow-up hidden tests | 100% | 100% | 100% | 100% | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp |
| Main hidden tests after follow-up | 98% | 98% | 100% | 100% | 0pp | 0pp … 0pp | +2pp | +2pp … +2pp | +2pp | +2pp … +2pp |
| Own suite passes after follow-up | 100% | 100% | 100% | 100% | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp |
| Follow-up cost ($) | 0.10 | 0.10 | 0.08 | 0.09 | +0.00 | +0.00 … +0.00 | -0.01 | -0.01 … -0.01 | -0.01 | -0.01 … -0.01 |
| Follow-up wall time (min) | 0.8 | 0.8 | 0.6 | 0.7 | -0.0 | -0.0 … -0.0 | -0.1 | -0.1 … -0.1 | -0.0 | -0.0 … -0.0 |
| Follow-up tokens | 131k | 139k | 97k | 108k | +8k | +8k … +8k | -35k | -35k … -35k | -23k | -23k … -23k |
| Follow-up source lines | 31 | 26 | 24 | 29 | -6 | -6 … -6 | -8 | -8 … -8 | -2 | -2 … -2 |

## Cost

| Metric | bare | dex@HEAD | dex | dex-loop | Δ dex@HEAD−bare | 95% CI | Δ dex−bare | 95% CI | Δ dex-loop−bare | 95% CI |
|---|---|---|---|---|---|---|---|---|---|---|
| Cost ($, API-equivalent) | 0.11 | 0.20 | 0.21 | 0.33 | +0.09 | +0.09 … +0.09 | +0.11 | +0.11 … +0.11 | +0.22 | +0.22 … +0.22 |
| Tokens (incl. cache) | 91k | 213k | 183k | 482k | +122k | +122k … +122k | +92k | +92k … +92k | +391k | +391k … +391k |
| Output tokens | 5k | 6k | 7k | 7k | +1k | +1k … +1k | +2k | +2k … +2k | +2k | +2k … +2k |
| Turns | 4.0 | 5.5 | 6.0 | 10.0 | +1.5 | +1.5 … +1.5 | +2.0 | +2.0 … +2.0 | +6.0 | +6.0 … +6.0 |
| Wall time (min) | 0.8 | 1.0 | 1.1 | 1.5 | +0.2 | +0.2 … +0.2 | +0.3 | +0.3 … +0.3 | +0.7 | +0.7 … +0.7 |

## Audit loop (dex-loop arms)

| Metric | bare | dex@HEAD | dex | dex-loop | Δ dex@HEAD−bare | 95% CI | Δ dex−bare | 95% CI | Δ dex-loop−bare | 95% CI |
|---|---|---|---|---|---|---|---|---|---|---|
| Audit iterations the Stop hook ran | – | – | – | 1.5 | – | – | – | – | – | – |
| Loop finished with a receipt | – | – | – | 100% | – | – | – | – | – | – |

## Runtime behaviour (reference solution = 1.00x)

| Metric | bare | dex@HEAD | dex | dex-loop | Δ dex@HEAD−bare | 95% CI | Δ dex−bare | 95% CI | Δ dex-loop−bare | 95% CI |
|---|---|---|---|---|---|---|---|---|---|---|
| Time vs reference (geomean) | 0.67x | 0.82x | 0.60x | 0.91x | +0.14x | +0.14x … +0.14x | -0.07x | -0.07x … -0.07x | +0.23x | +0.23x … +0.23x |
| Worst timing noise (CV) | 35% | 27% | 54% | 52% | -8pp | -8pp … -8pp | +20pp | +20pp … +20pp | +17pp | +17pp … +17pp |
| Fuzz sequences agreeing with reference | 90% | 96% | 96% | 96% | +6pp | +6pp … +6pp | +6pp | +6pp … +6pp | +6pp | +6pp … +6pp |

## Code health

| Metric | bare | dex@HEAD | dex | dex-loop | Δ dex@HEAD−bare | 95% CI | Δ dex−bare | 95% CI | Δ dex-loop−bare | 95% CI |
|---|---|---|---|---|---|---|---|---|---|---|
| eslint findings per KLOC (source) | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 … 0.0 | 0.0 | 0.0 … 0.0 | 0.0 | 0.0 … 0.0 |
| Cyclomatic complexity (mean) | 4.5 | 4.6 | 3.6 | 3.4 | +0.1 | +0.1 … +0.1 | -0.9 | -0.9 … -0.9 | -1.1 | -1.1 … -1.1 |
| Cyclomatic complexity (max) | 20 | 20 | 18 | 18 | +0 | +0 … +0 | -2 | -2 … -2 | -2 | -2 … -2 |
| Longest function (lines) | 62 | 59 | 72 | 60 | -2 | -2 … -2 | +11 | +11 … +11 | -1 | -1 … -1 |
| Deepest nesting | 4 | 4 | 4 | 4 | +0 | +0 … +0 | +1 | +1 … +1 | +0 | +0 … +0 |
| Duplicated source lines (%) | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 | 0.0 … 0.0 | 0.0 | 0.0 … 0.0 | 0.0 | 0.0 … 0.0 |
| Dependencies declared | 0 | 0 | 0 | 0 | 0 | 0 … 0 | 0 | 0 … 0 | 0 | 0 … 0 |
| Packages installed | 0 | 0 | 0 | 0 | 0 | 0 … 0 | 0 | 0 … 0 | 0 | 0 … 0 |

## Test-suite health

| Metric | bare | dex@HEAD | dex | dex-loop | Δ dex@HEAD−bare | 95% CI | Δ dex−bare | 95% CI | Δ dex-loop−bare | 95% CI |
|---|---|---|---|---|---|---|---|---|---|---|
| Suite passes (of 5 runs) | 100% | 100% | 100% | 100% | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp |
| Flaky suite | 0% | 0% | 0% | 0% | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp |
| Suite runtime (s, median) | 0.3 | 0.3 | 0.4 | 0.4 | -0.0 | -0.0 … -0.0 | +0.0 | +0.0 … +0.0 | +0.0 | +0.0 … +0.0 |
| Files left behind by tests | 1 | 1 | 1 | 1 | 0 | 0 … 0 | 0 | 0 … 0 | 0 | 0 … 0 |

## Conventions and docs

| Metric | bare | dex@HEAD | dex | dex-loop | Δ dex@HEAD−bare | 95% CI | Δ dex−bare | 95% CI | Δ dex-loop−bare | 95% CI |
|---|---|---|---|---|---|---|---|---|---|---|
| Has a README | 0% | 0% | 0% | 0% | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp |

## Existing rubric (process-weighted; for continuity)

| Metric | bare | dex@HEAD | dex | dex-loop | Δ dex@HEAD−bare | 95% CI | Δ dex−bare | 95% CI | Δ dex-loop−bare | 95% CI |
|---|---|---|---|---|---|---|---|---|---|---|
| Rubric total | 90.5 | 90.5 | 91.0 | 91.0 | 0.0 | 0.0 … 0.0 | +0.5 | +0.5 … +0.5 | +0.5 | +0.5 … +0.5 |
| correctness | 100.0 | 100.0 | 100.0 | 100.0 | 0.0 | 0.0 … 0.0 | 0.0 | 0.0 … 0.0 | 0.0 | 0.0 … 0.0 |
| test_quality | 90.0 | 91.5 | 89.0 | 90.5 | +1.5 | +1.5 … +1.5 | -1.0 | -1.0 … -1.0 | +0.5 | +0.5 … +0.5 |
| robustness | 95.0 | 95.0 | 100.0 | 100.0 | 0.0 | 0.0 … 0.0 | +5.0 | +5.0 … +5.0 | +5.0 | +5.0 … +5.0 |
| verification | 100.0 | 100.0 | 100.0 | 100.0 | 0.0 | 0.0 … 0.0 | 0.0 | 0.0 … 0.0 | 0.0 | 0.0 … 0.0 |
| issue_detection | 85.0 | 85.0 | 85.0 | 85.0 | 0.0 | 0.0 … 0.0 | 0.0 | 0.0 … 0.0 | 0.0 | 0.0 … 0.0 |

Arm columns weight every scenario equally: the mean over scenarios of each scenario's mean over replicates.

Timing caution: repeat runs of the same code varied by up to 75% (CV). Treat perf ratios within about ±25% of 1.00x as equal.

## Per scenario

### csv-rfc4180 (bare n=1, dex@HEAD n=1, dex n=1, dex-loop n=1)

| Metric | bare | dex@HEAD | dex | dex-loop |
|---|---|---|---|---|
| Hidden tests: spec | 100% | 100% | 100% | 100% |
| Hidden tests: robust | 90% | 90% | 100% | 100% |
| Own test suite passes | 100% | 100% | 100% | 100% |
| Mutation score (own tests) | 82% | 88% | 88% | 85% |
| Claimed passing, suite failed | 0% | 0% | 0% | 0% |
| Source lines changed | 169 | 161 | 191 | 176 |
| Test lines changed | 59 | 85 | 88 | 82 |
| Files changed | 3 | 5 | 3 | 3 |
| Files outside scope | 0 | 0 | 0 | 0 |
| Forbidden files touched | 0 | 0 | 0 | 0 |
| Follow-up hidden tests | 100% | 100% | 100% | 100% |
| Main hidden tests after follow-up | 97% | 97% | 100% | 100% |
| Own suite passes after follow-up | 100% | 100% | 100% | 100% |
| Follow-up cost ($) | 0.10 | 0.13 | 0.09 | 0.08 |
| Follow-up wall time (min) | 0.9 | 1.0 | 0.8 | 0.6 |
| Follow-up tokens | 133k | 196k | 110k | 62k |
| Follow-up source lines | 35 | 27 | 23 | 31 |
| Cost ($, API-equivalent) | 0.11 | 0.21 | 0.21 | 0.41 |
| Tokens (incl. cache) | 68k | 197k | 164k | 596k |
| Output tokens | 6k | 7k | 7k | 9k |
| Turns | 3.0 | 5.0 | 7.0 | 11.0 |
| Wall time (min) | 0.9 | 1.1 | 1.1 | 1.9 |
| Audit iterations the Stop hook ran | – | – | – | 2.0 |
| Loop finished with a receipt | – | – | – | 100% |
| Time vs reference (geomean) | 0.53x | 0.80x | 0.72x | 0.78x |
| Worst timing noise (CV) | 21% | 20% | 34% | 53% |
| Fuzz sequences agreeing with reference | 80% | 92% | 92% | 92% |
| eslint findings per KLOC (source) | 0.0 | 0.0 | 0.0 | 0.0 |
| Cyclomatic complexity (mean) | 7.2 | 7.5 | 5.4 | 5.1 |
| Cyclomatic complexity (max) | 33 | 34 | 28 | 28 |
| Longest function (lines) | 92 | 87 | 113 | 92 |
| Deepest nesting | 5 | 6 | 6 | 6 |
| Duplicated source lines (%) | 0.0 | 0.0 | 0.0 | 0.0 |
| Dependencies declared | 0 | 0 | 0 | 0 |
| Packages installed | 0 | 0 | 0 | 0 |
| Suite passes (of 5 runs) | 100% | 100% | 100% | 100% |
| Flaky suite | 0% | 0% | 0% | 0% |
| Suite runtime (s, median) | 0.4 | 0.3 | 0.3 | 0.4 |
| Files left behind by tests | 1 | 1 | 1 | 1 |
| Has a README | 0% | 0% | 0% | 0% |
| Rubric total | 90.0 | 90.0 | 92.0 | 91.0 |
| correctness | 100.0 | 100.0 | 100.0 | 100.0 |
| test_quality | 91.0 | 94.0 | 94.0 | 92.0 |
| robustness | 90.0 | 90.0 | 100.0 | 100.0 |
| verification | 100.0 | 100.0 | 100.0 | 100.0 |
| issue_detection | 85.0 | 85.0 | 85.0 | 85.0 |

### inventory-race (bare n=1, dex@HEAD n=1, dex n=1, dex-loop n=1)

| Metric | bare | dex@HEAD | dex | dex-loop |
|---|---|---|---|---|
| Hidden tests: spec | 100% | 100% | 100% | 100% |
| Hidden tests: robust | 100% | 100% | 100% | 100% |
| Hidden tests: preserve | 100% | 100% | 100% | 100% |
| Own test suite passes | 100% | 100% | 100% | 100% |
| Mutation score (own tests) | 78% | 77% | 68% | 78% |
| Claimed passing, suite failed | 0% | 0% | 0% | 0% |
| Source lines changed | 108 | 115 | 184 | 52 |
| Test lines changed | 77 | 71 | 87 | 70 |
| Files changed | 2 | 2 | 2 | 2 |
| Files outside scope | 0 | 0 | 0 | 0 |
| Forbidden files touched | 0 | 0 | 0 | 0 |
| Follow-up hidden tests | 100% | 100% | 100% | 100% |
| Main hidden tests after follow-up | 100% | 100% | 100% | 100% |
| Own suite passes after follow-up | 100% | 100% | 100% | 100% |
| Follow-up cost ($) | 0.09 | 0.07 | 0.07 | 0.10 |
| Follow-up wall time (min) | 0.6 | 0.5 | 0.5 | 0.8 |
| Follow-up tokens | 130k | 82k | 84k | 153k |
| Follow-up source lines | 27 | 24 | 24 | 27 |
| Cost ($, API-equivalent) | 0.10 | 0.19 | 0.22 | 0.24 |
| Tokens (incl. cache) | 113k | 229k | 201k | 368k |
| Output tokens | 4k | 5k | 7k | 5k |
| Turns | 5.0 | 6.0 | 5.0 | 9.0 |
| Wall time (min) | 0.8 | 0.8 | 1.1 | 1.2 |
| Audit iterations the Stop hook ran | – | – | – | 1.0 |
| Loop finished with a receipt | – | – | – | 100% |
| Time vs reference (geomean) | 0.82x | 0.84x | 0.49x | 1.03x |
| Worst timing noise (CV) | 49% | 34% | 75% | 50% |
| Fuzz sequences agreeing with reference | 100% | 100% | 100% | 100% |
| eslint findings per KLOC (source) | 0.0 | 0.0 | 0.0 | 0.0 |
| Cyclomatic complexity (mean) | 1.8 | 1.7 | 1.8 | 1.8 |
| Cyclomatic complexity (max) | 7 | 7 | 8 | 7 |
| Longest function (lines) | 31 | 31 | 32 | 29 |
| Deepest nesting | 2 | 2 | 3 | 2 |
| Duplicated source lines (%) | 0.0 | 0.0 | 0.0 | 0.0 |
| Dependencies declared | 0 | 0 | 0 | 0 |
| Packages installed | 0 | 0 | 0 | 0 |
| Suite passes (of 5 runs) | 100% | 100% | 100% | 100% |
| Flaky suite | 0% | 0% | 0% | 0% |
| Suite runtime (s, median) | 0.3 | 0.3 | 0.4 | 0.3 |
| Files left behind by tests | 1 | 1 | 1 | 1 |
| Has a README | 0% | 0% | 0% | 0% |
| Rubric total | 91.0 | 91.0 | 90.0 | 91.0 |
| correctness | 100.0 | 100.0 | 100.0 | 100.0 |
| test_quality | 89.0 | 89.0 | 84.0 | 89.0 |
| robustness | 100.0 | 100.0 | 100.0 | 100.0 |
| verification | 100.0 | 100.0 | 100.0 | 100.0 |
| issue_detection | 85.0 | 85.0 | 85.0 | 85.0 |

Per-scenario cells are the mean over replicates, ± the sample standard deviation for non-percentages.

