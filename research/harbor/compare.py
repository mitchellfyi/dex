#!/usr/bin/env python3
"""Compare a Dex job with a Claude Code baseline job from Harbor.

Usage:
  compare.py JOBS_DIR                 # latest claude-code and dex job per dataset
  compare.py BASELINE_JOB DEX_JOB     # two explicit job directories

Reads each trial's result.json (reward, cost, tokens, timings) and, for Dex
trials, how far the lifecycle got. Prints the paired per-task outcome and a
summary. With few tasks, read the discordant pairs (tasks only one arm
solved), not the headline rate: a 10-task difference of one task is noise.
"""

from __future__ import annotations

import json
import re
import sys
from datetime import datetime
from pathlib import Path

JOB_NAME = re.compile(r"^(?P<dataset>.+)-(?P<arm>claude-code|dex)-(?P<stamp>\d{8}-\d{6})$")


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


def load_trials(job_dir: Path) -> dict[str, list[dict]]:
    trials: dict[str, list[dict]] = {}
    for result_file in sorted(job_dir.glob("*/result.json")):
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


def pick_jobs(jobs_dir: Path) -> list[tuple[str, Path, Path]]:
    latest: dict[tuple[str, str], tuple[str, Path]] = {}
    for job_dir in jobs_dir.iterdir():
        match = JOB_NAME.match(job_dir.name)
        if not match or not job_dir.is_dir():
            continue
        key = (match["dataset"], match["arm"])
        if key not in latest or match["stamp"] > latest[key][0]:
            latest[key] = (match["stamp"], job_dir)
    pairs = []
    for dataset in sorted({dataset for dataset, _ in latest}):
        if (dataset, "claude-code") in latest and (dataset, "dex") in latest:
            pairs.append((dataset, latest[(dataset, "claude-code")][1], latest[(dataset, "dex")][1]))
    return pairs


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


def compare(dataset: str, baseline_dir: Path, dex_dir: Path) -> None:
    baseline = load_trials(baseline_dir)
    dex = load_trials(dex_dir)
    tasks = sorted(set(baseline) | set(dex))
    print(f"\n{dataset}\n  baseline: {baseline_dir}\n  dex:      {dex_dir}\n")
    print(f"  {'task':<36} {'base':>5} {'dex':>5} {'base $':>7} {'dex $':>7} {'base s':>7} {'dex s':>7}  dex lifecycle")
    only_base, only_dex = [], []
    for task in tasks:
        b_runs, d_runs = baseline.get(task, []), dex.get(task, [])
        b_reward = mean([t["reward"] for t in b_runs])
        d_reward = mean([t["reward"] for t in d_runs])
        if (b_reward or 0) >= 1.0 > (d_reward or 0):
            only_base.append(task)
        if (d_reward or 0) >= 1.0 > (b_reward or 0):
            only_dex.append(task)
        lifecycle = ",".join(sorted({t["dex"] or t["error"] or "?" for t in d_runs}))
        print(
            f"  {task[:36]:<36} {fmt(b_reward, '.2f'):>5} {fmt(d_reward, '.2f'):>5} "
            f"{fmt(mean([t['cost'] for t in b_runs]), '.2f'):>7} "
            f"{fmt(mean([t['cost'] for t in d_runs]), '.2f'):>7} "
            f"{fmt(mean([t['agent_s'] for t in b_runs]), '.0f'):>7} "
            f"{fmt(mean([t['agent_s'] for t in d_runs]), '.0f'):>7}  {lifecycle}"
        )
    print()
    print("  " + summarize("claude-code", baseline))
    print("  " + summarize("dex", dex))
    print(f"  only baseline solved: {len(only_base)}  {' '.join(only_base)}")
    print(f"  only dex solved:      {len(only_dex)}  {' '.join(only_dex)}")


def main(argv: list[str]) -> int:
    if len(argv) == 2:
        pairs = pick_jobs(Path(argv[1]).expanduser())
        if not pairs:
            print(f"No dataset has both a claude-code and a dex job in {argv[1]}", file=sys.stderr)
            return 1
        for dataset, baseline_dir, dex_dir in pairs:
            compare(dataset, baseline_dir, dex_dir)
        return 0
    if len(argv) == 3:
        compare("explicit jobs", Path(argv[1]).expanduser(), Path(argv[2]).expanduser())
        return 0
    print(__doc__, file=sys.stderr)
    return 2


if __name__ == "__main__":
    sys.exit(main(sys.argv))
