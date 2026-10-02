# Public Benchmarks

Runs Dex on public agent benchmarks (Terminal-Bench, SWE-bench Pro and the rest
of the SWE-bench family) through [Harbor](https://github.com/harbor-framework/harbor),
the harness Terminal-Bench ships with, next to Harbor's plain Claude Code agent
on the same model and tasks. The absolute score mostly measures the model; the
number that says something about Dex is the difference it makes, and what that
costs.

[`research/compare/`](../compare/README.md) answers the same question on
scenarios written for Dex. This directory uses tasks nobody here wrote.

| File | What it is |
|------|------------|
| `run.sh` | Runs one or more arms on a dataset; see the options below |
| `dex_agent.py` | The Harbor agent that runs Dex inside a task container |
| `compare.py` | Lines arms up per task; selects failed, passed or errored tasks |
| `task_images.py` | Lists a task's benchmark images for `--prune-images` |
| `tasksets/` | Fixed task lists, such as the SWE-bench Pro screening set |
| `results/` | Dated summaries of runs. The raw jobs stay in `~/.dex/bench/jobs` |

Dex runs here through the `benchmark` workflow of `dx run`, described in
[docs/benchmarks.md](../../docs/benchmarks.md): Plan, Implement and Review in
one headless session, with no ticket, remote, PR or reviewer.

## Status

Paused on 2 October 2026, after the baseline screen and before any Dex run on
the hard set. See [results/2026-09-30-swebenchpro-screen.md](results/2026-09-30-swebenchpro-screen.md).

What exists and works:

- The `benchmark` workflow, with `workflow.phases` to leave out Plan or
  Review. Covered by `tests/benchmark-workflow-test.sh`.
- The Harbor agent and tooling in this directory: named arms, screening and
  hard-set selection, one job per task, resumable runs, image pruning.
- End-to-end runs. Locally, without Docker, the full and the no-Plan
  configurations completed with correct changes (about $0.74 and 5 minutes on
  a toy task). In a Terminal-Bench container (`log-summary-date-ranges`), Dex
  solved the task at $0.45 and 6.4 minutes against plain Claude Code's $0.04
  and 20 seconds: the overhead on a task that needs none of it.
- A SWE-bench Pro baseline screen: plain Claude Code on 22 tasks, 14 solved,
  6 failed, 2 errored, $2.57.

Not done:

- Round 2, Dex on the hard set. Nothing yet says whether Dex rescues tasks
  plain Claude Code fails. The command to run it is in the results file.
- Rounds 3 and 4 (which part helps, how much review), which depend on round 2.

Open problems, in the order they would bite:

1. **Running anywhere but a laptop.** On an Apple Silicon Mac every trial runs
   under x86 emulation (about 8 minutes of setup per trial; the 22-task screen
   took 5.5 hours) and Docker Desktop's disk file grows about 3 GB a task until
   Docker reclaims the space. The devbox cannot host it as it stands: its
   policy keeps API credentials out of VMs, and every trial is an
   authenticated agent inside one. That needs the host credential broker its
   instructions anticipate, built in the devbox repository. Harbor's cloud
   environments (`-- --env daytona`, `modal`) need an account.
2. **One unexplained stall.** In one container run, `claude -p` went idle after
   the Stop hook rejected Phase 2 and never resumed. The hook, the API and the
   input pipe were ruled out; the same rejection path later recovered normally,
   and a local reproduction never stalled. Runs now carry a per-phase time
   limit (`phase_timeout`, 20 minutes) and Claude's debug log
   (`agent/claude-debug.log`), so a repeat fails fast and explains itself.
3. **Implement forgets the review risk tier.** The Phase 2 gate rejects it and
   the agent recovers, at the cost of an audit round trip, even with the
   reminder in the Phase 2 text.
4. **Old Debian images.** The two gravitational/teleport tasks errored for both
   arms: Harbor's Claude Code installer insists on apt's `nodejs`, and their
   Debian 11 security mirror now returns 404. Claude Code's own installer does
   not need it, but changing the Dex agent alone would make its setup differ
   from the baseline's.
5. **Codex.** The benchmark workflow runs Claude only; the Codex engine has no
   print-mode launch for it yet.

## Running it

Prerequisites:

- Docker running. On Apple Silicon the task images run under x86_64 emulation:
  it works, but it is slow.
- Harbor: `uv tool install harbor`.
- `ANTHROPIC_API_KEY` in the environment (or `CLAUDE_CODE_OAUTH_TOKEN` from
  `claude setup-token`). Use an API key for anything beyond a smoke test:
  subscription rate limits turn into timeouts, and those skew the result.
  An organisation-level key, one not created inside a workspace, is rejected
  with "API key is not scoped to a workspace"; also set
  `ANTHROPIC_WORKSPACE_ID` and `run.sh` sends the `anthropic-workspace-id`
  header for both arms.

Check that Harbor and Docker work, with no model involved:

```bash
research/public-benchmarks/run.sh --oracle --task log-summary-date-ranges
```

Run one task with both arms, then compare:

```bash
research/public-benchmarks/run.sh --task log-summary-date-ranges --timeout-multiplier 3
python3 research/public-benchmarks/compare.py ~/.dex/bench/jobs
```

`run.sh` options:

| Option | Default | Notes |
|--------|---------|-------|
| `--agent ARMS` | `both` | Comma-separated: `claude-code`, `dex`, `dex-noplan`, `dex-noreview`, `dex-implement`; `both` or `all` |
| `--review-tier TIER` | unset | Forces Dex's review depth: `trivial`, `small`, `normal`, `complex` |
| `--failed-in RUN` / `--passed-in RUN` | unset | Take tasks from an earlier run's failures or passes; `--sample N` limits the passes |
| `--task-file FILE` | unset | Task names, one per line |
| `--one-at-a-time` | off | One job per task, so a failure does not stop the rest |
| `--prune-images` | off | Delete each task's benchmark images after its job; general images are never touched |
| `--setup-timeout-multiplier X` | 3 | Time allowed to install the agent. Under emulation it outlasts Harbor's 6 minutes; the agent's own time limit is unaffected |
| `--stamp STAMP` | new | Continue a `--one-at-a-time` run: verified tasks are skipped, errored ones rerun |
| `--dataset NAME@VERSION` | `terminal-bench-sample@2.0` | `harbor datasets list --legacy` lists the rest |
| `--model MODEL` | `anthropic/claude-sonnet-5-5` | Both arms use the same model |
| `--tasks N` / `--task GLOB` | all | Limit the task set |
| `--concurrency N` | 1 | Trials at once |
| `--attempts K` | 1 | Attempts per task |
| `--timeout-multiplier X` | 1 | Applied to both arms |
| `--effort LEVEL` | unset | Applied to both arms |

Arguments after `--` go to `harbor run` unchanged. Results land in
`~/.dex/bench/jobs` (override with `DEX_BENCH_JOBS_DIR`); `harbor view jobs -o
~/.dex/bench/jobs` browses the trajectories.

Datasets worth knowing:

| Dataset | Tasks | Fit |
|---------|-------|-----|
| `swebenchpro@1.0` | 731 | Best fit: issue to patch, hidden tests, room above current scores |
| `swebench_multilingual@1.0` | 300 | Tests Dex's toolchain discovery across languages |
| `swebench-verified@1.0` | 500 | Near saturation; little room to show a difference |
| `terminal-bench@2.0` | 89 | Terminal and ops tasks; Dex's lifecycle mostly doesn't apply |
| `terminal-bench-sample@2.0` | 10 | Smoke tests |

## What the Dex agent does

`dex_agent.py` subclasses Harbor's `claude-code` agent, so it
installs Claude Code the same way and reports cost and tokens the same way.
The difference is in the run:

1. It uploads the runtime part of this checkout (uncommitted edits included)
   to `/opt/dex` and installs Dex's hooks and skills for the container user.
2. In the task directory it makes sure there is a git repository with a local
   base branch, `dex-bench-base`. A Terminal-Bench `/app` is often not a
   repository, so it runs `git init` and commits the starting tree. Only git
   metadata changes; the files on disk stay as the task shipped them. `.dex/`
   goes in `.git/info/exclude`.
3. It writes a run spec (`workflow.name: benchmark`, the task text as the
   source body) and starts `dx run --spec`.
4. It copies Dex's run journal and phase state into the trial's `agent/`
   folder next to the transcript, with `dex.txt` holding the lifecycle's own
   output and `dex-exit-code` its exit status.

A Dex failure is recorded, not raised. The verifier scores whatever is on disk,
as it would for a baseline agent that crashed.

Dex strips `ANTHROPIC_*` variables from the environment it launches Claude
with. Inside the container the API key reaches Claude through an
`apiKeyHelper` in the session settings instead, and a custom base URL through
settings `env`. `run.sh` unsets the host's `ANTHROPIC_BASE_URL` before calling
Harbor: on a machine routed through the Dex router it is a loopback address,
which means nothing inside a container. Set `DEX_BENCH_BASE_URL` to give the
containers a reachable endpoint.

## Reading the results

- Compare the arms on the same model and the same timeout multiplier. Dex
  plans and runs review waves, so it needs more time than a single session.
  Terminal-Bench gives most tasks 15 minutes, which is tight for plan,
  implement and review; SWE-bench tasks allow 50. Raise the multiplier for both
  arms, and remember that a leaderboard submission has to use the defaults.
- With a few dozen tasks, look at the tasks only one arm solved, not the
  percentage. `compare.py` lists both.
- A task whose verifier never ran (setup time-out, cancelled trial) is
  errored, not failed. `compare.py --tasks errored RUN` lists them, rerunning
  with `--stamp` retries them, and they never enter a hard set.
- Report cost and time per solved task next to the solve rate.
- The `dex lifecycle` column shows how far each Dex run got: `complete`,
  `paused@N`, or `incomplete` when the time limit ended it.

## Which parts of Dex to test

The aim is the best score per dollar, and knowing which parts earn it. Each
part of the benchmark lifecycle is a hypothesis about how agents fail on these
tasks:

| Part | Failure it targets | Cost | Expectation on SWE-bench-style tasks |
|------|--------------------|------|--------------------------------------|
| Plan | Fixing the wrong place; missing a requirement buried in the issue | 1-3 minutes, a few cents | Helps on large repositories and indirect issues; little on precise ones |
| Implement discipline and audit loop | Stopping before running the tests; incomplete fixes; untested edge cases | Small: extra turns in one session | Most of the gain per dollar, if there is gain |
| Review waves | Edge cases and missed requirements that the author's own context hides | The bulk of Dex's cost: a fresh session per wave | Rescues some hard tasks; risks churn and time-outs on easy ones |
| Review depth (tier) | Too few waves on a risky change, or too many on a trivial one | One wave per step up | Implement's own choice should match forced depth at lower cost |

`run.sh` names the configurations that test these:

| Arm | Phases | Answers |
|-----|--------|---------|
| `claude-code` | – | The baseline |
| `dex` | Plan, Implement, Review | Does Dex help at all? |
| `dex-implement` | Implement | Is the cheap part most of it? |
| `dex-noplan` | Implement, Review | What Plan adds on top of Review |
| `dex-noreview` | Plan, Implement | What Review adds on top of Plan |
| any Dex arm with `--review-tier complex` | as the arm | Whether more review waves pay |

Without Plan, the task text is sealed as the acceptance criteria that Implement
and Review work against. Without Review, Implement ends the lifecycle and its
risk-tier and criteria gates do not apply.

Run it in rounds, each cheaper than the one it saves:

1. **Screen**: `claude-code` on a spread of tasks
   (`research/public-benchmarks/tasksets/swebenchpro-screen.txt`: two from each of
   SWE-bench Pro's 11 repositories). Its failures are the hard set.
2. **Does it help**: `claude-code,dex,dex-implement` on the hard set plus a
   small sample of the screen's passes (`--failed-in` / `--passed-in --sample`).
   The rerun of `claude-code` is the baseline's own retry rate; a Dex rescue
   only counts above it. The passes catch Dex breaking easy tasks and give the
   overhead cost.
3. **Where it helps**, only if round 2 shows a lift: `dex-noplan,dex-noreview`
   on the hard set, to split the gain between Plan and Review.
4. **How much review**: `--review-tier complex` on the tasks where Review
   mattered, against the tier Implement chose.

The result that matters is per task, not the headline rate: which kinds of
task each part rescues, and what it costs. If Review only rescues large or
cross-cutting changes, the tier thresholds in `dx_review_scope_minimum_tier`
are the place to encode that, and Dex gets cheaper on small tasks without
losing the rescues. A leaderboard submission then uses the best configuration
at the benchmark's own time limits.

## Limits

- Every trial installs Claude Code and Dex from scratch: about four minutes
  per trial under emulation on an Apple Silicon Mac.
- Task containers are small (Terminal-Bench: 1 CPU, 2 GB). Review waves are
  separate Claude processes and compete for that memory.
- An M-series laptop with 24 GB and 8 cores is fine for smoke tests at
  concurrency 1. For full datasets use an x86 Linux host or Harbor's cloud
  environments (`-- --env daytona`, `modal`).
