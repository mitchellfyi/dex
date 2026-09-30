# Dex vs bare Claude

This harness runs the same task through two arms that use the same model, then
measures what each produced. The question is whether Dex's layer changes the
result enough to pay for what it costs.

```bash
# The full matrix: every scenario with a compare/ directory, 3 replicas per arm
bash research/compare/run.sh

# One scenario, one replica, cheaply, to check the pipeline
CLAUDE_MODEL=sonnet CLAUDE_EFFORT=low FOLLOWUP_EFFORT=low \
  bash research/compare/run.sh --scenario buggy-code-fix --replicas 1

# Finish a run that was interrupted or hit a rate limit
bash research/compare/run.sh --resume research/results/compare/<run-id>

# Measure the quality dimensions and judge the pairs (run.sh does this at the end)
bash research/compare/quality.sh research/results/compare/<run-id>

# Re-print the report
python3 research/compare/report.py research/results/compare/<run-id>
```

Results go to `research/results/compare/<run-id>/`, which is gitignored. That
directory holds `report.md`, `summary.json`, `judge.json`, and one directory
per trial with the agent's stream, its final workspace, the follow-up
workspace and every measurement.

A run has two phases. First the agents run, several at once
(`trial.sh`, via `run.sh --jobs`), and each trial is measured for correctness,
size, cost and changeability as it finishes. Then `quality.sh` measures the
remaining dimensions one trial at a time, runs the judge, and rewrites the
report. The second phase reads only the snapshots the first one saved. That
keeps the timing-sensitive measurements away from agents that are still
running, and it means any earlier run can gain a new dimension without
running an agent again.

## The arms

Both arms run `claude -p` with the same `--model` and `--effort` (defaults
`opus` and `max`, from `research/config.sh`) and the same time budget. Both run
isolated: `--setting-sources project,local --strict-mcp-config`. That drops
the operator's `settings.json` (hooks and enabled plugins), `~/.claude/CLAUDE.md`
and every MCP server. The existing `research/run.sh` does not isolate its runs:
they inherit whatever the operator has installed, which on the machine this
was built on included the superpowers plugin, RTK, codegraph and around 50 MCP
servers. Org-managed plugins still load, and they load in both arms.

| | bare | dex | dex-loop |
|---|---|---|---|
| Prompt | the scenario prompt, plus one line saying nobody will answer questions | Dex's plan / implement / verify / self-review prompt (`_build_dxloop_prompt`) | the dex prompt, plus the line dxloop adds about the stop-hook audit |
| Workspace context | none | `prompts/guardrails.md` and the non-interactive guidance from `prompts/workflows/dximplement.md`, as `CLAUDE.md` | as dex |
| Hooks | none | Dex's guard hooks (PreToolUse, PostToolUse) from `settings.json` | the guards plus the `phase-loop.sh` Stop hook |
| Audit loop | none | none | the prompt-loop audit, activated with `bin/activate-loop.sh` and finished with the generation-bound `complete-receipt.sh`, as dxloop's implementation phase does |

`dex@<git-ref>` and `dex-loop@<git-ref>` inject the guardrails and
non-interactive guidance from that revision, so two versions of Dex's prompts
can run side by side: `--arms bare,dex@HEAD,dex` compares the committed
prompts with the working tree's. `run.sh` snapshots every arm's prompts into
`<run>/arms/` when the run starts, so editing them mid-run changes nothing.
The audit prompt and `phase-loop.sh` itself always come from the working tree.

The dex arms reuse `_inject_workspace_context` and `_build_dxloop_prompt` from
`research/lib/capture.sh`, so they are the arms `improve.sh` tunes. Each dex
trial's Dex state (`DX_STATE_DIR`, `DX_LOOP_DIR`, `DX_RUN_ROOT` and the rest)
lives in its scratch directory, never under the operator's home.

Not covered by any arm yet: the review loop, the phased lifecycle, and RTK.

## What is measured

Each trial runs the arm on a fresh workspace in a temp directory. The path does
not contain `dex` or `research`, and nothing from the harness is reachable
through a relative path. After the arm finishes, `measure.py` grades a copy of
the workspace. Then a fixed follow-up agent gets a second task on a copy of
the arm's output, and that result is graded too.

**Outcome quality**
- Hidden tests (`compare/hidden/`), grouped by name prefix:
  - `[spec]`: what the prompt asks for.
  - `[robust]`: inputs the prompt implies but does not list.
  - `[preserve]`: behaviour the prompt did not ask to change.
  - Where the prompt leaves a choice open (throw, ignore or clamp), every reasonable choice passes.
- Own test suite: whether `npm test` passes, with pass/fail counts.
- Mutation score: the share of planted bugs in the agent's source that its own tests catch. `measure.py` flips one operator per mutant, up to 40 per trial, sampled deterministically from the code. Scored only when the suite passes on the unmutated code.
- False claim: the closing message says the tests pass and `npm test` fails.

**Size and scope**
- Lines changed by category: source, test, docs, config. Lock files and the injected `CLAUDE.md` are left out.
- Files changed outside the scenario's allowed paths, and forbidden files touched (for example `tests/` in the refactor scenario).

**Changeability.** The follow-up agent is the same for every arm: bare, isolated, `FOLLOWUP_MODEL` (default `sonnet`) at `FOLLOWUP_EFFORT` (default `high`). A difference in how it does therefore comes from the code it was given. Before it starts, the injected `CLAUDE.md` is removed. Measured:
- whether it succeeds (`compare/followup/hidden/`);
- whether the main hidden tests still pass after its change;
- its cost, time, tokens and diff size.

**Cost**
- API-equivalent dollars, from the stream's `result` event. On a subscription this is the price of the tokens, not what was billed.
- Tokens including cache, output tokens, turns and wall time.

**Quality phase** (`quality.py`, `judge.py`, run by `quality.sh`):
- **Differential fuzzing** (`compare/fuzz.js`). Random operation sequences run against the agent's code and the reference solution, and must agree step by step. Only unambiguous operations are generated, so a design choice the prompt leaves open never counts as a divergence. Each sequence has its own seed, and `quality.json` records the first divergence with its history so it can be replayed.
- **Performance** (`compare/perf.js`). Scaled workloads timed against the reference in fresh processes, with an untimed warm-up pair and alternating order. The metric is the median ratio: 1.00x means as fast as the reference. The report prints a caution when repeat runs of the same code varied by more than 25%. On a busy machine, ratios within about ±25% of 1.00x are noise.
- **Suite health.** The agent's `npm test` runs 5 times, each with a private `TMPDIR`. Measured: passes, flakiness, median runtime, and files the tests leave in the workspace or the temp directory.
- **Static health.** eslint's recommended rules (findings per KLOC), cyclomatic complexity, function length, nesting depth and parameter counts, plus duplicated source lines from jscpd. These are proxies; the follow-up task measures changeability more directly. The tools are pinned in `tools/package.json` and installed into `research/.tools/compare/`, never into a workspace. `python3 research/compare/quality.py tools` installs them ahead of time.
- **Dependencies.** Declared, installed, and `npm audit` findings.
- **CLI conventions** (a `cli` block in `compare/quality.json`). Errors go to stderr with a non-zero exit, a usage text lists the commands, and error messages name the bad input.
- **README accuracy.** The `node`/`npm` commands and local-import code samples in the agent's README are run in order. A command annotated as an expected error (`# errors: ...`) passes when it fails.
- **Blind pairwise review.** A judge sees the task and two anonymised diffs and picks per criterion: correctness, readability, maintainability, tests, scope, overall. Each pair is judged in both orders, and a pick counts only when both orders agree.
- **Report accuracy.** A judge checks each closing message against the measured facts. The judge is told the agent may have had instructions it cannot see, so a Dex run that cites its guidelines is not marked down for it.

A judge tends to prefer its own model family's style. Both arms here are Claude, so a Claude judge does not favour either one. A judge from another family is still better, because it doesn't share Claude's blind spots, and it is required once another vendor's tool is an arm. `--judge-provider auto` (the default) uses Codex, through `bin/dxcodex.sh` in read-only mode, when the Codex CLI is installed, and Claude otherwise. `judge.json` and the report record which judge ran. Re-judge a run with `quality.sh <run_dir> --judge-only --rejudge --judge-provider codex`.

**Audit loop** (dex-loop arms): how many audits the Stop hook ran, and whether the loop finished with a receipt.

**Existing rubric.** `score_scenario` still runs, so these trials can be compared with `scores.tsv`. It is reported separately and not folded into anything. Several of its checks reward process, not outcome: test counts over 15/25/35, grep counts of `try {` and `throw`, and "made more than 3 edits". Dex's guardrails ask for exactly those things.

A trial with no `result` event, or an API error in its first turns, is invalid and left out. A trial that hits its time budget is censored and counted as it stands, because the budget is part of the task.

## Reading the report

Each metric row shows the arm means, weighting every scenario equally, then
dex minus bare with a 95% bootstrap interval over replicates. With three
replicates per cell the interval is wide. Treat it as a check on whether a
difference is bigger than the noise, not as a precise effect size. The
existing harness records about ±9 points of run-to-run variance per scenario.

A tie is a valid result. If the hidden tests, the follow-up agent and the diff
cannot tell the arms apart, the arms are equal on quality and the cost rows
decide.

## Scenarios

A scenario takes part when it has `compare/hidden/`:

```
research/scenarios/<name>/compare/
  compare.json              mutation targets, scope globs, extra diff excludes
  quality.json              fuzz and perf sizes, the cli block
  hidden/*.test.js          node:test suites; read the workspace from $BENCH_WS
  hidden/_*.js              helpers and fixtures staged beside them
  followup/prompt.md        the follow-up task
  followup/hidden/*.test.js staged together with hidden/, so helpers are shared
  reference/                a correct solution, overlaid on the seed
  followup/reference/       the follow-up on top of that
  fuzz.js                   runSequence({ agentWs, refWs, rng, steps })
  perf.js                   workloads: [{ name, kind, setup(ws), run(ctx) }]
```

The fuzzer and the perf workloads use the reference as their oracle, so the
reference has to be right. `tests/research-compare-test.sh` checks that each
fuzz definition agrees with its own reference and catches the unfixed code,
and that every perf workload runs.

The references exist to check the hidden tests. `tests/research-compare-test.sh`
requires every reference to pass every hidden group, and the code before the
fix to fail `[spec]`. Keep a scenario out of a run until that holds.

`long-refactor-inheritance` pins behaviour with golden output: `hidden/_cases.js`
drives the public factory API, and `hidden/golden.json` is what the seed
returns. After editing a case, regenerate it with
`node research/scenarios/long-refactor-inheritance/compare/hidden/_generate-golden.js`.

Six scenarios have a `compare/` directory today, all Node.

- `buggy-code-fix`, `cli-todo-app`, `oss-bug-triage` and `long-refactor-inheritance`
  are scenarios `improve.sh` has tuned Dex's prompts against, so they are a
  development set. Opus passes their hidden tests with or without Dex, so they
  measure cost, volume and review preference more than correctness.
- `inventory-race` and `csv-rfc4180` were written to be hard, and nothing has
  been tuned against them yet.
  - `inventory-race`: fix concurrency bugs in a seeded async service without
    serializing calls that share no SKU. A service-wide lock is correct but
    fails the overlap tests, which count concurrent store calls instead of
    timing them. Per-key locking has to take its keys in a fixed order or
    opposite-order bundles deadlock.
  - `csv-rfc4180`: an exact-spec parser whose streaming form must give the
    same records and errors wherever the input is cut. That includes a CR
    and LF split across chunks, and an escaped quote split between its two
    quotes.

A claim about Dex in general still needs held-out tasks that no improvement
loop has seen.

## The improvement loop

`research/loop.sh` tunes Dex's prompts. By default (`--objective outcomes`) each
suite is a comparison run of the `dex` arm (`--replicas`, `--jobs`), and
`objective.py` compares it with the previous one. The rule is guarded, not
weighted:
- it reverts when hidden tests, any one scenario, fuzz agreement or follow-up success get worse;
- otherwise it keeps a change only for a measured gain: better correctness, fuzzing or changeability, or the same quality for clearly less cost or code;
- otherwise it reverts, so no gain means the simpler prompt stays.

`improve.sh` builds its analysis from `evidence.py`: the hidden tests each
trial failed, fuzz divergences, false claims, follow-up failures and, when the
run was judged, what the reviewer said. `--objective legacy` restores the old
rubric-driven loop.

## Limits

- The workspace sits in a temp directory, not a sandbox. As with `research/review-loop`, an agent running as the same user could search the disk for the hidden tests. Nothing here stops a process that goes looking.
- The mutation tester is a tokenizer, not a parser. It skips strings, template text, comments and regex literals, and it discards mutants that fail `node --check`. Equivalent mutants still count as survivors.
- The claim check is a regex over the closing message. `claim_snippet` in `main.json` holds the matched text for audit.
