# Dex vs bare Claude — compare-20260930-142637

Model `opus` at effort `xhigh` for every arm; follow-up agent `sonnet` at `high`. Dex commit `0a54338` (26 uncommitted files under prompts/, skills/, hooks/, research/).
Resolved model: claude-opus-5-5.
Trials: 24 of 24 finished — censored 1, valid 23. Invalid trials (no result, or an API error in the first turns) are excluded; censored trials (hit the time budget) are counted as they stand.

## Outcome quality

| Metric | bare | dex@HEAD | dex | dex-loop | Δ dex@HEAD−bare | 95% CI | Δ dex−bare | 95% CI | Δ dex-loop−bare | 95% CI |
|---|---|---|---|---|---|---|---|---|---|---|
| Hidden tests: spec | 100% | 100% | 100% | 100% | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp |
| Hidden tests: robust | 100% | 100% | 100% | 97% | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp | -3pp | -8pp … 0pp |
| Hidden tests: preserve | 100% | 100% | 100% | 100% | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp |
| Own test suite passes | 100% | 100% | 100% | 100% | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp |
| Mutation score (own tests) | 89% | 93% | 87% | 91% | +4pp | +3pp … +6pp | -1pp | -6pp … +2pp | +3pp | +0pp … +5pp |
| Claimed passing, suite failed | 0% | 0% | 0% | 0% | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp |

## Size and scope

| Metric | bare | dex@HEAD | dex | dex-loop | Δ dex@HEAD−bare | 95% CI | Δ dex−bare | 95% CI | Δ dex-loop−bare | 95% CI |
|---|---|---|---|---|---|---|---|---|---|---|
| Source lines changed | 296 | 473 | 346 | 331 | +178 | +156 … +197 | +51 | +27 … +70 | +35 | -3 … +69 |
| Test lines changed | 544 | 1122 | 606 | 686 | +578 | +472 … +719 | +62 | +15 … +116 | +142 | +82 … +207 |
| Files changed | 4 | 11 | 6 | 6 | +7 | +6 … +8 | +2 | +1 … +3 | +2 | +1 … +4 |
| Files outside scope | 0 | 1 | 0 | 0 | +1 | +0 … +1 | 0 | 0 … 0 | +0 | 0 … +0 |
| Forbidden files touched | 0 | 0 | 0 | 0 | 0 | 0 … 0 | 0 | 0 … 0 | 0 | 0 … 0 |

## Changeability (fixed follow-up agent)

| Metric | bare | dex@HEAD | dex | dex-loop | Δ dex@HEAD−bare | 95% CI | Δ dex−bare | 95% CI | Δ dex-loop−bare | 95% CI |
|---|---|---|---|---|---|---|---|---|---|---|
| Follow-up hidden tests | 100% | 100% | 100% | 100% | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp |
| Main hidden tests after follow-up | 100% | 100% | 100% | 99% | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp | -1pp | -3pp … 0pp |
| Own suite passes after follow-up | 100% | 100% | 100% | 100% | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp |
| Follow-up cost ($) | 0.23 | 0.25 | 0.21 | 0.24 | +0.03 | +0.00 … +0.05 | -0.02 | -0.04 … +0.02 | +0.01 | -0.03 … +0.07 |
| Follow-up wall time (min) | 1.5 | 2.0 | 1.4 | 1.6 | +0.6 | +0.1 … +1.3 | -0.1 | -0.2 … +0.1 | +0.1 | -0.2 … +0.4 |
| Follow-up tokens | 266k | 282k | 238k | 262k | +16k | -45k … +81k | -28k | -110k … +79k | -4k | -71k … +77k |
| Follow-up source lines | 68 | 74 | 67 | 72 | +6 | +2 … +11 | -1 | -7 … +5 | +4 | -3 … +11 |

## Cost

| Metric | bare | dex@HEAD | dex | dex-loop | Δ dex@HEAD−bare | 95% CI | Δ dex−bare | 95% CI | Δ dex-loop−bare | 95% CI |
|---|---|---|---|---|---|---|---|---|---|---|
| Cost ($, API-equivalent) | 1.42 | 3.62 | 2.31 | 3.78 | +2.20 | +1.45 … +3.15 | +0.89 | +0.63 … +1.19 | +2.36 | +2.14 … +2.61 |
| Tokens (incl. cache) | 772k | 3789k | 2309k | 7864k | +3016k | +2229k … +3902k | +1537k | +1078k … +1966k | +7091k | +5054k … +10219k |
| Output tokens | 48k | 96k | 65k | 73k | +49k | +33k … +66k | +17k | +9k … +26k | +25k | +2k … +43k |
| Turns | 14.8 | 34.0 | 28.7 | 59.8 | +19.2 | +9.5 … +28.7 | +13.8 | +8.7 … +18.5 | +44.9 | +36.9 … +52.6 |
| Wall time (min) | 8.4 | 19.7 | 13.2 | 25.2 | +11.3 | +6.8 … +16.7 | +4.8 | +2.6 … +6.9 | +16.8 | +8.6 … +30.6 |

## Audit loop (dex-loop arms)

| Metric | bare | dex@HEAD | dex | dex-loop | Δ dex@HEAD−bare | 95% CI | Δ dex−bare | 95% CI | Δ dex-loop−bare | 95% CI |
|---|---|---|---|---|---|---|---|---|---|---|
| Audit iterations the Stop hook ran | – | – | – | 1.3 | – | – | – | – | – | – |
| Loop finished with a receipt | – | – | – | 83% | – | – | – | – | – | – |

## Runtime behaviour (reference solution = 1.00x)

| Metric | bare | dex@HEAD | dex | dex-loop | Δ dex@HEAD−bare | 95% CI | Δ dex−bare | 95% CI | Δ dex-loop−bare | 95% CI |
|---|---|---|---|---|---|---|---|---|---|---|
| Time vs reference (geomean) | 0.73x | 0.75x | 0.75x | 0.78x | +0.02x | -0.02x … +0.06x | +0.02x | -0.03x … +0.07x | +0.05x | +0.00x … +0.10x |
| Worst timing noise (CV) | 15% | 16% | 17% | 15% | +0pp | -4pp … +4pp | +1pp | -1pp … +4pp | -0pp | -4pp … +4pp |
| Fuzz sequences agreeing with reference | 100% | 100% | 100% | 100% | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp |

## Code health

| Metric | bare | dex@HEAD | dex | dex-loop | Δ dex@HEAD−bare | 95% CI | Δ dex−bare | 95% CI | Δ dex-loop−bare | 95% CI |
|---|---|---|---|---|---|---|---|---|---|---|
| eslint findings per KLOC (source) | 0.0 | 0.4 | 0.4 | 0.0 | +0.4 | 0.0 … +1.1 | +0.4 | 0.0 … +1.2 | 0.0 | 0.0 … 0.0 |
| Cyclomatic complexity (mean) | 3.5 | 2.7 | 3.4 | 3.2 | -0.8 | -1.0 … -0.6 | -0.1 | -0.2 … +0.1 | -0.3 | -0.5 … -0.1 |
| Cyclomatic complexity (max) | 20 | 11 | 19 | 20 | -9 | -13 … -3 | -1 | -4 … +2 | +1 | -2 … +3 |
| Longest function (lines) | 98 | 37 | 71 | 77 | -60 | -80 … -42 | -27 | -58 … +6 | -21 | -45 … +1 |
| Deepest nesting | 3 | 3 | 3 | 3 | -1 | -1 … -0 | -0 | -1 … 0 | -0 | -1 … +0 |
| Duplicated source lines (%) | 0.4 | 0.0 | 0.0 | 0.0 | -0.4 | -1.2 … 0.0 | -0.4 | -1.2 … 0.0 | -0.4 | -1.2 … 0.0 |
| Dependencies declared | 0 | 0 | 0 | 0 | 0 | 0 … 0 | 0 | 0 … 0 | 0 | 0 … 0 |
| Packages installed | 0 | 0 | 0 | 0 | 0 | 0 … 0 | 0 | 0 … 0 | 0 | 0 … 0 |

## Test-suite health

| Metric | bare | dex@HEAD | dex | dex-loop | Δ dex@HEAD−bare | 95% CI | Δ dex−bare | 95% CI | Δ dex-loop−bare | 95% CI |
|---|---|---|---|---|---|---|---|---|---|---|
| Suite passes (of 5 runs) | 100% | 100% | 100% | 100% | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp |
| Flaky suite | 0% | 0% | 0% | 0% | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp |
| Suite runtime (s, median) | 0.5 | 0.4 | 0.4 | 0.4 | -0.1 | -0.3 … +0.0 | -0.1 | -0.3 … +0.1 | -0.1 | -0.2 … +0.0 |
| Files left behind by tests | 1 | 1 | 1 | 1 | 0 | 0 … 0 | 0 | 0 … 0 | 0 | 0 … 0 |

## Conventions and docs

| Metric | bare | dex@HEAD | dex | dex-loop | Δ dex@HEAD−bare | 95% CI | Δ dex−bare | 95% CI | Δ dex-loop−bare | 95% CI |
|---|---|---|---|---|---|---|---|---|---|---|
| Has a README | 0% | 100% | 50% | 50% | +100pp | +100pp … +100pp | +50pp | +50pp … +50pp | +50pp | +50pp … +50pp |
| README samples that run | – | 75% | 100% | 100% | – | – | – | – | – | – |
| Closing report accuracy (judge) | 100% | 100% | 100% | 83% | 0pp | 0pp … 0pp | 0pp | 0pp … 0pp | -17pp | -50pp … 0pp |

## Existing rubric (process-weighted; for continuity)

| Metric | bare | dex@HEAD | dex | dex-loop | Δ dex@HEAD−bare | 95% CI | Δ dex−bare | 95% CI | Δ dex-loop−bare | 95% CI |
|---|---|---|---|---|---|---|---|---|---|---|
| Rubric total | 92.7 | 93.8 | 93.3 | 93.2 | +1.2 | +0.5 … +1.8 | +0.7 | 0.0 … +1.3 | +0.5 | -0.3 … +1.3 |
| correctness | 100.0 | 100.0 | 100.0 | 100.0 | 0.0 | 0.0 … 0.0 | 0.0 | 0.0 … 0.0 | 0.0 | 0.0 … 0.0 |
| test_quality | 94.3 | 96.7 | 93.7 | 95.7 | +2.3 | +1.5 … +3.2 | -0.7 | -2.8 … +1.2 | +1.3 | +0.2 … +2.5 |
| robustness | 100.0 | 100.0 | 100.0 | 97.2 | 0.0 | 0.0 … 0.0 | 0.0 | 0.0 … 0.0 | -2.8 | -8.5 … 0.0 |
| verification | 100.0 | 100.0 | 100.0 | 100.0 | 0.0 | 0.0 … 0.0 | 0.0 | 0.0 … 0.0 | 0.0 | 0.0 … 0.0 |
| issue_detection | 92.5 | 100.0 | 100.0 | 100.0 | +7.5 | +2.5 … +12.5 | +7.5 | +2.5 … +12.5 | +7.5 | +2.5 … +12.5 |

Arm columns weight every scenario equally: the mean over scenarios of each scenario's mean over replicates.

## Blind pairwise review

Judge: `claude` `opus` (same model family as the arms). 30 pairs, each judged in both orders; a criterion counts for an arm only when both orders agree. The overall pick was the same in both orders for 19 of 30 pairs.

### dex@HEAD vs bare

| Criterion | All pairs | csv-rfc4180 | inventory-race |
|---|---|---|---|
| overall | dex@HEAD 0 · tie 2 · bare 4 | dex@HEAD 0 · tie 1 · bare 2 | dex@HEAD 0 · tie 1 · bare 2 |
| correctness | dex@HEAD 0 · tie 6 · bare 0 | dex@HEAD 0 · tie 3 · bare 0 | dex@HEAD 0 · tie 3 · bare 0 |
| readability | dex@HEAD 0 · tie 2 · bare 4 | dex@HEAD 0 · tie 2 · bare 1 | dex@HEAD 0 · tie 0 · bare 3 |
| maintainability | dex@HEAD 1 · tie 4 · bare 1 | dex@HEAD 1 · tie 2 · bare 0 | dex@HEAD 0 · tie 2 · bare 1 |
| tests | dex@HEAD 1 · tie 3 · bare 2 | dex@HEAD 0 · tie 1 · bare 2 | dex@HEAD 1 · tie 2 · bare 0 |
| scope | dex@HEAD 0 · tie 0 · bare 6 | dex@HEAD 0 · tie 0 · bare 3 | dex@HEAD 0 · tie 0 · bare 3 |

### dex vs bare

| Criterion | All pairs | csv-rfc4180 | inventory-race |
|---|---|---|---|
| overall | dex 2 · tie 2 · bare 2 | dex 1 · tie 1 · bare 1 | dex 1 · tie 1 · bare 1 |
| correctness | dex 1 · tie 4 · bare 1 | dex 0 · tie 3 · bare 0 | dex 1 · tie 1 · bare 1 |
| readability | dex 0 · tie 6 · bare 0 | dex 0 · tie 3 · bare 0 | dex 0 · tie 3 · bare 0 |
| maintainability | dex 2 · tie 3 · bare 1 | dex 1 · tie 2 · bare 0 | dex 1 · tie 1 · bare 1 |
| tests | dex 2 · tie 2 · bare 2 | dex 1 · tie 0 · bare 2 | dex 1 · tie 2 · bare 0 |
| scope | dex 0 · tie 3 · bare 3 | dex 0 · tie 0 · bare 3 | dex 0 · tie 3 · bare 0 |

### dex vs dex@HEAD

| Criterion | All pairs | csv-rfc4180 | inventory-race |
|---|---|---|---|
| overall | dex 2 · tie 3 · dex@HEAD 1 | dex 1 · tie 2 · dex@HEAD 0 | dex 1 · tie 1 · dex@HEAD 1 |
| correctness | dex 0 · tie 5 · dex@HEAD 1 | dex 0 · tie 3 · dex@HEAD 0 | dex 0 · tie 2 · dex@HEAD 1 |
| readability | dex 3 · tie 3 · dex@HEAD 0 | dex 1 · tie 2 · dex@HEAD 0 | dex 2 · tie 1 · dex@HEAD 0 |
| maintainability | dex 0 · tie 6 · dex@HEAD 0 | dex 0 · tie 3 · dex@HEAD 0 | dex 0 · tie 3 · dex@HEAD 0 |
| tests | dex 0 · tie 4 · dex@HEAD 2 | dex 0 · tie 3 · dex@HEAD 0 | dex 0 · tie 1 · dex@HEAD 2 |
| scope | dex 6 · tie 0 · dex@HEAD 0 | dex 3 · tie 0 · dex@HEAD 0 | dex 3 · tie 0 · dex@HEAD 0 |

### dex-loop vs bare

| Criterion | All pairs | csv-rfc4180 | inventory-race |
|---|---|---|---|
| overall | dex-loop 3 · tie 1 · bare 2 | dex-loop 2 · tie 0 · bare 1 | dex-loop 1 · tie 1 · bare 1 |
| correctness | dex-loop 0 · tie 5 · bare 1 | dex-loop 0 · tie 3 · bare 0 | dex-loop 0 · tie 2 · bare 1 |
| readability | dex-loop 3 · tie 3 · bare 0 | dex-loop 2 · tie 1 · bare 0 | dex-loop 1 · tie 2 · bare 0 |
| maintainability | dex-loop 3 · tie 3 · bare 0 | dex-loop 2 · tie 1 · bare 0 | dex-loop 1 · tie 2 · bare 0 |
| tests | dex-loop 2 · tie 3 · bare 1 | dex-loop 0 · tie 2 · bare 1 | dex-loop 2 · tie 1 · bare 0 |
| scope | dex-loop 0 · tie 0 · bare 6 | dex-loop 0 · tie 0 · bare 3 | dex-loop 0 · tie 0 · bare 3 |

### dex-loop vs dex

| Criterion | All pairs | csv-rfc4180 | inventory-race |
|---|---|---|---|
| overall | dex-loop 3 · tie 3 · dex 0 | dex-loop 3 · tie 0 · dex 0 | dex-loop 0 · tie 3 · dex 0 |
| correctness | dex-loop 1 · tie 5 · dex 0 | dex-loop 1 · tie 2 · dex 0 | dex-loop 0 · tie 3 · dex 0 |
| readability | dex-loop 1 · tie 3 · dex 2 | dex-loop 1 · tie 2 · dex 0 | dex-loop 0 · tie 1 · dex 2 |
| maintainability | dex-loop 0 · tie 6 · dex 0 | dex-loop 0 · tie 3 · dex 0 | dex-loop 0 · tie 3 · dex 0 |
| tests | dex-loop 3 · tie 3 · dex 0 | dex-loop 1 · tie 2 · dex 0 | dex-loop 2 · tie 1 · dex 0 |
| scope | dex-loop 0 · tie 4 · dex 2 | dex-loop 0 · tie 3 · dex 0 | dex-loop 0 · tie 1 · dex 2 |

## Per scenario

### csv-rfc4180 (bare n=3, dex@HEAD n=3, dex n=3, dex-loop n=3)

| Metric | bare | dex@HEAD | dex | dex-loop |
|---|---|---|---|---|
| Hidden tests: spec | 100% | 100% | 100% | 100% |
| Hidden tests: robust | 100% | 100% | 100% | 100% |
| Own test suite passes | 100% | 100% | 100% | 100% |
| Mutation score (own tests) | 95% | 90% | 91% | 94% |
| Claimed passing, suite failed | 0% | 0% | 0% | 0% |
| Source lines changed | 375 ±41 | 650 ±13 | 446 ±22 | 427 ±68 |
| Test lines changed | 664 ±99 | 1026 ±21 | 713 ±44 | 781 ±81 |
| Files changed | 5 ±2 | 13 ±1 | 7 ±2 | 7 ±1 |
| Files outside scope | 0 ±0 | 0 ±0 | 0 ±0 | 0 ±0 |
| Forbidden files touched | 0 ±0 | 0 ±0 | 0 ±0 | 0 ±0 |
| Follow-up hidden tests | 100% | 100% | 100% | 100% |
| Main hidden tests after follow-up | 100% | 100% | 100% | 100% |
| Own suite passes after follow-up | 100% | 100% | 100% | 100% |
| Follow-up cost ($) | 0.33 ±0.03 | 0.33 ±0.02 | 0.32 ±0.06 | 0.35 ±0.10 |
| Follow-up wall time (min) | 2.2 ±0.1 | 2.3 ±0.2 | 2.1 ±0.3 | 2.4 ±0.6 |
| Follow-up tokens | 396k ±39k | 363k ±47k | 349k ±196k | 375k ±156k |
| Follow-up source lines | 100 ±8 | 110 ±5 | 102 ±10 | 108 ±13 |
| Cost ($, API-equivalent) | 1.42 ±0.16 | 3.00 ±0.54 | 2.51 ±0.24 | 4.11 ±0.23 |
| Tokens (incl. cache) | 698k ±188k | 3330k ±1220k | 2525k ±440k | 6780k ±1309k |
| Output tokens | 49k ±6k | 85k ±12k | 72k ±7k | 95k ±4k |
| Turns | 15.0 ±4.0 | 40.7 ±9.1 | 32.3 ±6.0 | 62.0 ±15.1 |
| Wall time (min) | 8.0 ±1.0 | 15.8 ±1.2 | 12.8 ±1.6 | 18.6 ±1.1 |
| Audit iterations the Stop hook ran | – | – | – | 1.0 ±0.0 |
| Loop finished with a receipt | – | – | – | 100% |
| Time vs reference (geomean) | 0.47x ±0.02x | 0.50x ±0.04x | 0.54x ±0.07x | 0.58x ±0.07x |
| Worst timing noise (CV) | 14% | 17% | 15% | 15% |
| Fuzz sequences agreeing with reference | 100% | 100% | 100% | 100% |
| eslint findings per KLOC (source) | 0.0 ±0.0 | 0.0 ±0.0 | 0.0 ±0.0 | 0.0 ±0.0 |
| Cyclomatic complexity (mean) | 5.4 ±0.2 | 3.9 ±0.4 | 5.2 ±0.3 | 4.7 ±0.4 |
| Cyclomatic complexity (max) | 33 ±4 | 15 ±9 | 31 ±5 | 34 ±5 |
| Longest function (lines) | 165 ±33 | 50 ±23 | 121 ±67 | 126 ±40 |
| Deepest nesting | 5 ±1 | 3 ±1 | 4 ±0 | 4 ±1 |
| Duplicated source lines (%) | 0.8 ±1.4 | 0.0 ±0.0 | 0.0 ±0.0 | 0.0 ±0.0 |
| Dependencies declared | 0 ±0 | 0 ±0 | 0 ±0 | 0 ±0 |
| Packages installed | 0 ±0 | 0 ±0 | 0 ±0 | 0 ±0 |
| Suite passes (of 5 runs) | 100% | 100% | 100% | 100% |
| Flaky suite | 0% | 0% | 0% | 0% |
| Suite runtime (s, median) | 0.5 ±0.2 | 0.3 ±0.0 | 0.3 ±0.0 | 0.3 ±0.0 |
| Files left behind by tests | 1 ±0 | 1 ±0 | 1 ±0 | 1 ±0 |
| Has a README | 0% | 100% | 100% | 100% |
| README samples that run | – | 100% | 100% | 100% |
| Closing report accuracy (judge) | 100% | 100% | 100% | 100% |
| Rubric total | 93.7 ±0.6 | 93.7 ±0.6 | 93.7 ±0.6 | 94.0 ±0.0 |
| correctness | 100.0 ±0.0 | 100.0 ±0.0 | 100.0 ±0.0 | 100.0 ±0.0 |
| test_quality | 97.7 ±1.5 | 95.0 ±1.0 | 95.7 ±4.0 | 97.3 ±1.2 |
| robustness | 100.0 ±0.0 | 100.0 ±0.0 | 100.0 ±0.0 | 100.0 ±0.0 |
| verification | 100.0 ±0.0 | 100.0 ±0.0 | 100.0 ±0.0 | 100.0 ±0.0 |
| issue_detection | 95.0 ±8.7 | 100.0 ±0.0 | 100.0 ±0.0 | 100.0 ±0.0 |

### inventory-race (bare n=3, dex@HEAD n=3, dex n=3, dex-loop n=3)

| Metric | bare | dex@HEAD | dex | dex-loop |
|---|---|---|---|---|
| Hidden tests: spec | 100% | 100% | 100% | 100% |
| Hidden tests: robust | 100% | 100% | 100% | 94% |
| Hidden tests: preserve | 100% | 100% | 100% | 100% |
| Own test suite passes | 100% | 100% | 100% | 100% |
| Mutation score (own tests) | 82% | 96% | 84% | 88% |
| Claimed passing, suite failed | 0% | 0% | 0% | 0% |
| Source lines changed | 216 ±4 | 297 ±19 | 246 ±13 | 234 ±3 |
| Test lines changed | 425 ±28 | 1218 ±254 | 499 ±22 | 592 ±24 |
| Files changed | 3 ±1 | 9 ±1 | 4 ±0 | 6 ±1 |
| Files outside scope | 0 ±0 | 2 ±1 | 0 ±0 | 1 ±1 |
| Forbidden files touched | 0 ±0 | 0 ±0 | 0 ±0 | 0 ±0 |
| Follow-up hidden tests | 100% | 100% | 100% | 100% |
| Main hidden tests after follow-up | 100% | 100% | 100% | 98% |
| Own suite passes after follow-up | 100% | 100% | 100% | 100% |
| Follow-up cost ($) | 0.12 ±0.02 | 0.17 ±0.04 | 0.11 ±0.02 | 0.13 ±0.01 |
| Follow-up wall time (min) | 0.7 ±0.1 | 1.7 ±1.4 | 0.6 ±0.1 | 0.7 ±0.0 |
| Follow-up tokens | 135k ±55k | 202k ±114k | 127k ±40k | 149k ±2k |
| Follow-up source lines | 35 ±2 | 39 ±3 | 31 ±3 | 36 ±1 |
| Cost ($, API-equivalent) | 1.42 ±0.39 | 4.24 ±1.85 | 2.11 ±0.38 | 3.44 ±0.17 |
| Tokens (incl. cache) | 847k ±531k | 4247k ±1222k | 2094k ±666k | 8947k ±5500k |
| Output tokens | 46k ±13k | 107k ±34k | 58k ±9k | 50k ±43k |
| Turns | 14.7 ±6.4 | 27.3 ±17.6 | 25.0 ±5.0 | 57.5 ±4.9 |
| Wall time (min) | 8.8 ±3.1 | 23.7 ±10.2 | 13.5 ±3.2 | 31.7 ±24.5 |
| Audit iterations the Stop hook ran | – | – | – | 1.7 ±1.2 |
| Loop finished with a receipt | – | – | – | 67% |
| Time vs reference (geomean) | 0.99x ±0.07x | 0.99x ±0.04x | 0.96x ±0.03x | 0.98x ±0.03x |
| Worst timing noise (CV) | 16% | 15% | 18% | 14% |
| Fuzz sequences agreeing with reference | 100% | 100% | 100% | 100% |
| eslint findings per KLOC (source) | 0.0 ±0.0 | 0.8 ±1.3 | 0.8 ±1.4 | 0.0 ±0.0 |
| Cyclomatic complexity (mean) | 1.7 ±0.1 | 1.6 ±0.0 | 1.7 ±0.0 | 1.7 ±0.0 |
| Cyclomatic complexity (max) | 7 ±0 | 7 ±0 | 7 ±0 | 7 ±0 |
| Longest function (lines) | 30 ±3 | 25 ±9 | 21 ±1 | 27 ±6 |
| Deepest nesting | 2 ±0 | 2 ±0 | 2 ±0 | 2 ±0 |
| Duplicated source lines (%) | 0.0 ±0.0 | 0.0 ±0.0 | 0.0 ±0.0 | 0.0 ±0.0 |
| Dependencies declared | 0 ±0 | 0 ±0 | 0 ±0 | 0 ±0 |
| Packages installed | 0 ±0 | 0 ±0 | 0 ±0 | 0 ±0 |
| Suite passes (of 5 runs) | 100% | 100% | 100% | 100% |
| Flaky suite | 0% | 0% | 0% | 0% |
| Suite runtime (s, median) | 0.6 ±0.2 | 0.4 ±0.1 | 0.5 ±0.2 | 0.5 ±0.1 |
| Files left behind by tests | 1 ±0 | 1 ±0 | 1 ±0 | 1 ±0 |
| Has a README | 0% | 100% | 0% | 0% |
| README samples that run | – | 50% | – | – |
| Closing report accuracy (judge) | 100% | 100% | 100% | 67% |
| Rubric total | 91.7 ±1.2 | 94.0 ±0.0 | 93.0 ±0.0 | 92.3 ±1.2 |
| correctness | 100.0 ±0.0 | 100.0 ±0.0 | 100.0 ±0.0 | 100.0 ±0.0 |
| test_quality | 91.0 ±0.0 | 98.3 ±0.6 | 91.7 ±1.2 | 94.0 ±2.0 |
| robustness | 100.0 ±0.0 | 100.0 ±0.0 | 100.0 ±0.0 | 94.3 ±9.8 |
| verification | 100.0 ±0.0 | 100.0 ±0.0 | 100.0 ±0.0 | 100.0 ±0.0 |
| issue_detection | 90.0 ±8.7 | 100.0 ±0.0 | 100.0 ±0.0 | 100.0 ±0.0 |

Per-scenario cells are the mean over replicates, ± the sample standard deviation for non-percentages.

