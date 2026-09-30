#!/usr/bin/env python3
"""Keep or revert a prompt change, judged on outcomes.

  objective.py <previous_run_dir> <current_run_dir> [--arm dex] [--json]
  objective.py --smoke <run_dir>

Both directories are research/compare runs of the same arm on the same
scenarios, one before a change to Dex's prompts and one after. Prints the
comparison and a verdict. Exit 0 means keep, 1 means revert, 2 means the runs
cannot be compared.

This is a guarded rule, not a weighted score. A weighted score let the old
loop trade correctness for volume: it paid for test counts and file counts,
and Dex learned to write more. Here:

1. Revert if correctness got worse: hidden tests overall, any one scenario's
   hidden tests, differential fuzzing, or the follow-up agent's success.
2. Otherwise keep only for a measured gain: better correctness, fuzzing or
   changeability, or the same quality for clearly less cost or less code.
3. Otherwise revert. No measured gain means the simpler, older prompt stays.

Thresholds are environment variables (OBJECTIVE_*) with the defaults below;
three replicates move these metrics by a few points on their own, so the
thresholds sit above that noise.
"""

import argparse
import json
import os
import statistics
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import report  # noqa: E402  (trial_row: the metrics the report uses)

THRESHOLDS = {
    "correctness_drop": float(os.environ.get("OBJECTIVE_CORRECTNESS_DROP", "0.02")),
    "scenario_drop": float(os.environ.get("OBJECTIVE_SCENARIO_DROP", "0.10")),
    "fuzz_drop": float(os.environ.get("OBJECTIVE_FUZZ_DROP", "0.05")),
    "followup_drop": float(os.environ.get("OBJECTIVE_FOLLOWUP_DROP", "0.05")),
    "correctness_gain": float(os.environ.get("OBJECTIVE_CORRECTNESS_GAIN", "0.02")),
    "fuzz_gain": float(os.environ.get("OBJECTIVE_FUZZ_GAIN", "0.05")),
    "followup_gain": float(os.environ.get("OBJECTIVE_FOLLOWUP_GAIN", "0.05")),
    "cost_cut": float(os.environ.get("OBJECTIVE_COST_CUT", "0.10")),
    "lines_cut": float(os.environ.get("OBJECTIVE_LINES_CUT", "0.15")),
}


def load(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def scenario_means(run_dir, arm):
    """Per scenario: the arm's mean of each metric over valid replicates."""
    import glob

    rows = []
    for trial_dir in sorted(glob.glob(os.path.join(run_dir, "trials", "*"))):
        row = report.trial_row(trial_dir)
        if row and row["arm"] == arm and row["status"] in ("valid", "censored"):
            row["lines"] = (row.get("source_lines") or 0) + (row.get("test_lines") or 0)
            rows.append(row)
    keys = ["hidden_all", "fuzz_pass", "fu_success", "cost_usd", "lines", "mutation_score"]
    out = {}
    for scenario in sorted({r["scenario"] for r in rows}):
        cell = [r for r in rows if r["scenario"] == scenario]
        out[scenario] = {"n": len(cell)}
        for key in keys:
            vals = [report.numeric(r.get(key)) for r in cell]
            vals = [v for v in vals if v is not None]
            out[scenario][key] = statistics.mean(vals) if vals else None
    return out


def overall(means, key, scenarios):
    vals = [means[s][key] for s in scenarios if means[s].get(key) is not None]
    return statistics.mean(vals) if vals else None


def verdict(prev, curr, t=THRESHOLDS):
    reasons_bad, reasons_good = [], []
    missing = sorted(set(prev) - set(curr))
    if missing:
        return False, [f"scenarios measured before but not now: {', '.join(missing)}"], []
    scenarios = sorted(prev)

    def delta(key):
        a, b = overall(prev, key, scenarios), overall(curr, key, scenarios)
        return (b - a) if a is not None and b is not None else None, a, b

    d, a, b = delta("hidden_all")
    if d is not None and d < -t["correctness_drop"]:
        reasons_bad.append(f"hidden tests fell {a:.1%} -> {b:.1%}")
    for s in scenarios:
        pa, pb = prev[s].get("hidden_all"), curr[s].get("hidden_all")
        if pa is not None and pb is not None and pb - pa < -t["scenario_drop"]:
            reasons_bad.append(f"{s}: hidden tests fell {pa:.1%} -> {pb:.1%}")
    for key, label, drop in (("fuzz_pass", "fuzz agreement", "fuzz_drop"), ("fu_success", "follow-up success", "followup_drop")):
        dk, ak, bk = delta(key)
        if dk is not None and dk < -t[drop]:
            reasons_bad.append(f"{label} fell {ak:.1%} -> {bk:.1%}")
    if reasons_bad:
        return False, reasons_bad, []

    if d is not None and d >= t["correctness_gain"]:
        reasons_good.append(f"hidden tests rose {a:.1%} -> {b:.1%}")
    for key, label, gain in (("fuzz_pass", "fuzz agreement", "fuzz_gain"), ("fu_success", "follow-up success", "followup_gain")):
        dk, ak, bk = delta(key)
        if dk is not None and dk >= t[gain]:
            reasons_good.append(f"{label} rose {ak:.1%} -> {bk:.1%}")
    for key, label, cut in (("cost_usd", "cost", "cost_cut"), ("lines", "lines changed", "lines_cut")):
        _, ak, bk = delta(key)
        if ak and bk is not None and (ak - bk) / ak >= t[cut]:
            reasons_good.append(f"{label} fell {ak:.2f} -> {bk:.2f} at the same quality")
    if reasons_good:
        return True, [], reasons_good
    return False, ["no measured gain: the change neither improved outcomes nor cut cost or code"], []


def smoke(run_dir):
    """A smoke run passes when one trial finished and its own suite passes."""
    import glob

    for path in glob.glob(os.path.join(run_dir, "trials", "*", "main.json")):
        main = load(path) or {}
        if (main.get("usage") or {}).get("has_result") and (main.get("own_tests") or {}).get("pass"):
            return 0
    print(f"objective: no finished trial with a passing test suite in {run_dir}", file=sys.stderr)
    return 1


def main():
    if len(sys.argv) == 3 and sys.argv[1] == "--smoke":
        return smoke(sys.argv[2])
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("previous")
    parser.add_argument("current")
    parser.add_argument("--arm", default="dex")
    parser.add_argument("--json", action="store_true")
    args = parser.parse_args()

    runs = [load(os.path.join(d, "run.json")) or {} for d in (args.previous, args.current)]
    for field in ("model", "effort"):
        if runs[0].get(field) != runs[1].get(field):
            print(f"objective: the runs differ in {field} ({runs[0].get(field)} vs {runs[1].get(field)})", file=sys.stderr)
            return 2
    prev = scenario_means(args.previous, args.arm)
    curr = scenario_means(args.current, args.arm)
    if not prev or not curr:
        print(f"objective: no valid {args.arm} trials in one of the runs", file=sys.stderr)
        return 2

    keep, bad, good = verdict(prev, curr)
    result = {"keep": keep, "regressions": bad, "gains": good, "previous": prev, "current": curr, "thresholds": THRESHOLDS}
    if args.json:
        print(json.dumps(result, indent=2))
    else:
        print(f"{'Scenario':28} {'hidden':>14} {'fuzz':>14} {'follow-up':>14} {'cost $':>14} {'lines':>14}")
        for s in sorted(prev):
            cells = []
            for key, kind in (("hidden_all", "pct"), ("fuzz_pass", "pct"), ("fu_success", "pct"), ("cost_usd", "usd"), ("lines", "int")):
                a, b = prev[s].get(key), (curr.get(s) or {}).get(key)
                f = (lambda v: "–" if v is None else f"{v:.0%}") if kind == "pct" else (lambda v: "–" if v is None else f"{v:.2f}" if kind == "usd" else f"{v:.0f}")
                cells.append(f"{f(a):>6}->{f(b):<6}")
            print(f"{s:28} " + " ".join(f"{c:>14}" for c in cells))
        print()
        print("KEEP" if keep else "REVERT", "—", "; ".join(good or bad))
    return 0 if keep else 1


if __name__ == "__main__":
    sys.exit(main())
