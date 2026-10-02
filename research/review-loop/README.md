# Review-loop evaluation

This harness measures whether `dxreviewloop` selects the expected risk tier,
runs the full clean-pass gate, and catches seeded defects. The catalog contains
nine fixtures: one control and two defects at each of the small, normal, and
complex tiers. A standard stage runs three replicas with both Claude and Codex,
for 54 trials.

Each trial uses:

- a fresh clone with a real `origin/main...HEAD` change;
- a committed, pinned Dex runtime;
- isolated state, run, tool, and home directories;
- visible checks that pass before the review starts;
- a controller-only oracle that scores each captured wave and the final tree;
- explicit model and effort metadata;
- a whole-trial deadline, with timeouts reported as censored rather than clean.

The runner writes results under
`${DX_RUN_ROOT:-$HOME/.dex/runs}/review-evaluations` by default. `run.json` binds
the matrix, fixture catalog, controller, launcher, observer, runtime commit,
models, and tool versions used for the run. Each run also contains
`controller-inputs/`, an exact private copy of the controller and catalog used
for that matrix. Its source commit and dirty-worktree state are recorded in
`run.json`, so the result remains reconstructible when the harness itself had
uncommitted changes.

## Threat model

The harness is designed for ordinary evaluation runs, not a hostile provider
process. Providers run as the current user and can use unrestricted local tools.
Path randomization, clean environments, private permissions, and delayed oracle
scoring prevent accidental leakage, but they are not a security boundary against
a process that searches the host or inspects other same-user processes.

The controller samples the operating system process table while each worker is
alive and remembers descendants after they reparent. This cleans up ordinary
double-forked and `setsid` children on timeout or cancellation. It remains
best-effort: a process that forks and reparents entirely between samples, or a
host that does not expose compatible process metadata, can escape same-user
cleanup. Use process or container isolation when that distinction matters.

Do not describe these fixtures as secret or leakage-proof. An adversarial
evaluation needs a separate user or container, read-only runtime mounts, a
private temporary filesystem, and network and process isolation appropriate to
the provider being tested.

## Run a stage

Use a clean committed ref and pin every provider setting:

```bash
bash research/review-loop/run.sh \
  --stage baseline \
  --replicas 3 \
  --runner claude \
  --runner codex \
  --jobs 2 \
  --dex-ref <commit> \
  --trial-timeout 7200 \
  --claude-model <model> \
  --claude-effort <effort> \
  --codex-model <model>
```

Use `--dry-run` to inspect the resolved matrix without starting providers. Use
`--scenario <id>` and `--replicas 1` for a smoke run. The runner rejects test
stubs, duplicate providers, and unbounded concurrency. The Dex runtime comes
only from the resolved commit. Before starting real trials, the runner archives
the exact controller and catalog inputs and then runs against those copies.

`summary.json` reports eligible and censored trials, tier accuracy, oracle
results, false-clean waves, control edits, and defect fixes. A false-clean wave
means the product reported `CLEAN` while the oracle still found the planted
defect. Oracle errors are tracked separately and do not count as false cleans.
