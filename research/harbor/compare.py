#!/usr/bin/env python3
"""Compare a Dex job with a Claude Code baseline job from Harbor.

Usage:
  compare.py JOBS_DIR                 # latest paired run per dataset
  compare.py BASELINE_RUN DEX_RUN     # two explicit runs
  compare.py --summary RUN            # one arm on its own, e.g. a screening run
  compare.py --tasks failed|passed RUN [--sample N]
                                      # task names from one run, for run.sh

A RUN is a job directory, or the job-name prefix of a run.sh --one-at-a-time
run, whose tasks each have a <prefix>--<task> job directory.

Reads each trial's result.json (reward, cost, tokens, timings) and, for Dex
trials, how far the lifecycle got. Prints the paired per-task outcome and a
summary. With few tasks, read the discordant pairs (tasks only one arm
solved), not the headline rate: a 10-task difference of one task is noise.
"""

from __future__ import annotations

import glob
import json
import random
import re
import sys
from datetime import datetime
from pathlib import Path

JOB_NAME = re.compile(
    r"^(?P<dataset>.+?)-(?P<arm>claude-code|dex(?:-[a-z]+)?)-(?P<stamp>\d{8}-\d{6})(?:--(?P<task>.+))?$"
)


def run_dirs(run: Path) -> list[Path]:
    """The job directories of a run: the directory itself, or every
    <prefix>--<task> directory of a one-at-a-time run."""
    if run.is_dir():
        return [run]
    return sorted(p for p in run.parent.glob(f"{glob.escape(run.name)}--*") if p.is_dir())


def seconds(span: dict | None) -> float | None:
    if not span or not span.get("started_at") or not span.get("finished_at"):
        return None
    start = datetime.fromisoformat(span["started_at"].replace("Z", "+00:00"))
    end = datetime.fromisoformat(span["finished_at"].replace("Z", "+00:00"))
    return (end - start).total_seconds()


def dex_outcome(trial_dir: Path) -> str:
    log = trial_dir / "agent" / "dex.txt"
    if not log.is_file():
        return ""
    text = log.read_text(encoding="utf-8", errors="replace")
    if "Ticket lifecycle complete" in text:
        return "complete"
    paused = re.findall(r"Paused at Phase (\d)", text)
    if paused:
        return f"paused@{paused[-1]}"
    return "incomplete"


def load_trials(run: Path) -> dict[str, list[dict]]:
    trials: dict[str, list[dict]] = {}
    result_files = [f for d in run_dirs(run) for f in sorted(d.glob("*/result.json"))]
    for result_file in result_files:
        data = json.loads(result_file.read_text(encoding="utf-8"))
        rewards = (data.get("verifier_result") or {}).get("rewards") or {}
        agent = data.get("agent_result") or {}
        exception = data.get("exception_info") or {}
        trials.setdefault(data["task_name"], []).append(
            {
                "reward": rewards.get("reward"),
                "cost": agent.get("cost_usd"),
                "input": agent.get("n_input_tokens"),
                "output": agent.get("n_output_tokens"),
                "agent_s": seconds(data.get("agent_execution")),
                "error": exception.get("exception_type") or "",
                "dex": dex_outcome(result_file.parent),
            }
        )
    return trials


def mean(values: list[float]) -> float | None:
    values = [v for v in values if v is not None]
    return sum(values) / len(values) if values else None


def fmt(value, spec: str = "", missing: str = "-") -> str:
    return missing if value is None else format(value, spec)


def pick_jobs(jobs_dir: Path) -> list[tuple[str, dict[str, Path]]]:
    """The arms of the latest run.sh invocation per dataset: same stamp.

    Pairing the latest job of each arm independently would put a screening
    run's baseline next to a later hard-set run's Dex job.
    """
    runs: dict[tuple[str, str], dict[str, Path]] = {}
    for job_dir in jobs_dir.iterdir():
        match = JOB_NAME.match(job_dir.name)
        if match and job_dir.is_dir():
            # A one-at-a-time run is named by its prefix; run_dirs expands it.
            prefix = jobs_dir / f'{match["dataset"]}-{match["arm"]}-{match["stamp"]}'
            runs.setdefault((match["dataset"], match["stamp"]), {})[match["arm"]] = prefix
    latest: dict[str, tuple[str, dict[str, Path]]] = {}
    for (dataset, stamp), arms in runs.items():
        if "claude-code" in arms and any(a.startswith("dex") for a in arms):
            if dataset not in latest or stamp > latest[dataset][0]:
                latest[dataset] = (stamp, arms)
    return [(dataset, arms) for dataset, (_, arms) in sorted(latest.items())]


def select_tasks(kind: str, job_dir: Path, sample: int | None) -> list[str]:
    """Tasks a job failed (reward below 1, or no reward) or passed."""
    chosen = []
    for task, runs in sorted(load_trials(job_dir).items()):
        reward = mean([t["reward"] for t in runs])
        passed = reward is not None and reward >= 1.0
        if passed == (kind == "passed"):
            chosen.append(task)
    if sample is not None and sample < len(chosen):
        # A fixed seed keeps a sample reproducible across reruns.
        chosen = sorted(random.Random(0).sample(chosen, sample))
    return chosen


def summarize(label: str, trials: dict[str, list[dict]]) -> str:
    rewards = [mean([t["reward"] for t in runs]) for runs in trials.values()]
    solved = sum(1 for r in rewards if r is not None and r >= 1.0)
    costs = [t["cost"] for runs in trials.values() for t in runs if t["cost"] is not None]
    times = [t["agent_s"] for runs in trials.values() for t in runs if t["agent_s"] is not None]
    errors = sum(1 for runs in trials.values() for t in runs if t["error"])
    rate = solved / len(trials) if trials else 0.0
    return (
        f"{label:<12} tasks {len(trials):>3}  solved {solved:>3} ({rate:.0%})  "
        f"cost ${sum(costs):.2f}  mean agent time {fmt(mean(times), '.0f')}s  errors {errors}"
    )


def compare(dataset: str, arms: dict[str, Path]) -> None:
    order = ["claude-code"] + sorted(a for a in arms if a != "claude-code")
    order = [a for a in order if a in arms]
    trials = {arm: load_trials(arms[arm]) for arm in order}
    tasks = sorted(set().union(*trials.values()))
    print(f"\n{dataset}")
    for arm in order:
        print(f"  {arm:<14} {arms[arm]}")
    print()
    header = f"  {'task':<40}" + "".join(f" {arm[:13]:>13}" for arm in order)
    print(header)
    for task in tasks:
        cells = []
        for arm in order:
            runs = trials[arm].get(task, [])
            reward = mean([t["reward"] for t in runs])
            lifecycle = ",".join(sorted({t["dex"] for t in runs if t["dex"]}))
            cell = fmt(reward, ".2f")
            if lifecycle and lifecycle != "complete":
                cell += f" ({lifecycle})"
            cells.append(f" {cell:>13}")
        print(f"  {task[:40]:<40}" + "".join(cells))
    print()
    for arm in order:
        print("  " + summarize(arm, trials[arm]))
    if "claude-code" not in trials:
        return
    base = trials["claude-code"]
    print()
    for arm in order[1:]:
        rescued, broke = [], []
        for task in tasks:
            b = mean([t["reward"] for t in base.get(task, [])]) or 0
            d = mean([t["reward"] for t in trials[arm].get(task, [])]) or 0
            if d >= 1.0 > b:
                rescued.append(task)
            if b >= 1.0 > d:
                broke.append(task)
        print(f"  {arm}: rescued {len(rescued)} {' '.join(rescued)}")
        print(f"  {' ' * len(arm)}  broke   {len(broke)} {' '.join(broke)}")


def main(argv: list[str]) -> int:
    if len(argv) == 3 and argv[1] == "--summary":
        run = Path(argv[2]).expanduser()
        trials = load_trials(run)
        if not trials:
            print(f"No finished trials in {run}", file=sys.stderr)
            return 1
        print(f"\n{run}\n")
        for task, runs in sorted(trials.items()):
            reward = mean([t["reward"] for t in runs])
            print(f"  {task[:70]:<70} {fmt(reward, '.2f'):>5} "
                  f"${fmt(mean([t['cost'] for t in runs]), '.2f')} "
                  f"{fmt(mean([t['agent_s'] for t in runs]), '.0f')}s "
                  f"{','.join(sorted({t['error'] for t in runs if t['error']}))}")
        print("\n  " + summarize("run", trials))
        return 0
    if len(argv) >= 4 and argv[1] == "--tasks" and argv[2] in ("failed", "passed"):
        sample = None
        if len(argv) == 6 and argv[4] == "--sample":
            sample = int(argv[5])
        elif len(argv) != 4:
            print(__doc__, file=sys.stderr)
            return 2
        for task in select_tasks(argv[2], Path(argv[3]).expanduser(), sample):
            print(task)
        return 0
    if len(argv) == 2:
        pairs = pick_jobs(Path(argv[1]).expanduser())
        if not pairs:
            print(f"No run in {argv[1]} has both a claude-code arm and a dex arm", file=sys.stderr)
            return 1
        for dataset, arms in pairs:
            compare(dataset, arms)
        return 0
    if len(argv) == 3:
        compare("explicit runs", {"claude-code": Path(argv[1]).expanduser(),
                                  "dex": Path(argv[2]).expanduser()})
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
