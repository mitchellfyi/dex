# Running Public Benchmarks

Dex can be measured on public agent benchmarks such as Terminal-Bench 2 and
SWE-bench through [Harbor](https://github.com/harbor-framework/harbor), the
harness Terminal-Bench ships with. The absolute score mostly measures the
model. The number that says something about Dex is the difference it makes:
the same model on the same tasks, once as plain Claude Code and once under Dex.

## The benchmark workflow

A benchmark task is a prompt and a container. A verifier runs after the agent
stops and scores the files it left behind. A ticket lifecycle does far more
than that, so a run spec with `workflow.name: "benchmark"` keeps only the part
a verifier can see:

| Phase | Ticket lifecycle | Benchmark |
|-------|------------------|-----------|
| 0 Setup | Read the ticket, assign it, set status | Skipped |
| 1 Plan | `dxplan`, human approval | `dxplan`; the run spec authorizes the plan |
| 2 Implement | `dximplement`, push every commit | `dximplement`; local commits only |
| 3 Review | `dxreviewloop` until the clean gate passes | Same, then the lifecycle ends |
| 4 Verify | Full quality pipeline | Skipped |
| 5 PR | Open and describe the PR | Skipped |
| 6 Complete | Watch CI and reviews | Skipped |

Also dropped:

- Issue hygiene: no issue searches, no tracker writes, no `Issue/PR work:` line.
  The task text is the whole request, and the agent is told not to look up the
  upstream fix.
- UI proof: recorded as N/A.
- Every phase audit carries an addendum that marks push, PR, tracker and
  approval checks N/A, so the audit loop doesn't chase work that can't exist.
- `dx init` in a benchmark checkout writes only the `.dex/` skeleton: no PR
  template, commit hook or plugin bootstrap.
- Completion leaves the lifecycle branch checked out. A ticket lifecycle
  switches back to the default branch, which here would take the change away
  before the verifier reads it.

The session runs Claude in print mode, since task containers have no
terminal. The Stop hook still drives the phase handoffs, and the session exits
when Review succeeds. The workflow supports the Claude harness only.

The phase table lives in `lib/lifecycle-control.sh`
(`dx_lifecycle_first_phase`, `dx_lifecycle_final_phase`) and the prompt text in
`lib/benchmark.sh`.

## Running it locally

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
research/harbor/run.sh --oracle --task log-summary-date-ranges
```

Run one task with both arms, then compare:

```bash
research/harbor/run.sh --task log-summary-date-ranges --timeout-multiplier 3
python3 research/harbor/compare.py ~/.dex/bench/jobs
```

`run.sh` options:

| Option | Default | Notes |
|--------|---------|-------|
| `--agent dex\|claude-code\|both` | `both` | `claude-code` is Harbor's built-in agent |
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

`research/harbor/dex_agent.py` subclasses Harbor's `claude-code` agent, so it
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
- Report cost and time per solved task next to the solve rate.
- The `dex lifecycle` column shows how far each Dex run got: `complete`,
  `paused@N`, or `incomplete` when the time limit ended it.

## Limits

- Every trial installs Claude Code and Dex from scratch: about four minutes
  per trial under emulation on an Apple Silicon Mac.
- Task containers are small (Terminal-Bench: 1 CPU, 2 GB). Review waves are
  separate Claude processes and compete for that memory.
- An M-series laptop with 24 GB and 8 cores is fine for smoke tests at
  concurrency 1. For full datasets use an x86 Linux host or Harbor's cloud
  environments (`-- --env daytona`, `modal`).
