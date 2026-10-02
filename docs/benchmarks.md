# The Benchmark Workflow

`dx run` has a workflow for public agent benchmarks such as Terminal-Bench and
SWE-bench, where a harness scores the files an agent leaves behind. The
harness that runs Dex on them, the experiment plan, and the results so far are
in [research/public-benchmarks/](../research/public-benchmarks/README.md).

## What it keeps

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

## Leaving out Plan or Review

`workflow.phases` picks which phases run, so their contribution can be
measured: `["plan","implement","review"]` (the default),
`["implement","review"]`, `["plan","implement"]` or `["implement"]`.
Implement always runs.

- Without Plan, `dx run` seals the task text as the acceptance criteria before
  launch, split into criterion-sized lines, so Implement and Review still work
  against approved requirements.
- Without Review, Implement ends the lifecycle. Its risk-tier and criteria
  gates exist to feed Review, so they do not apply.

The phase table lives in `lib/lifecycle-control.sh`
(`dx_lifecycle_first_phase`, `dx_lifecycle_final_phase`,
`dx_lifecycle_benchmark_runs`) and the prompt text in `lib/benchmark.sh`.
