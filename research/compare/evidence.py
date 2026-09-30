#!/usr/bin/env python3
"""What went wrong in a comparison run, written for the improvement loop.

  evidence.py <run_dir> [--arm dex] [--limit 12]

improve.sh puts this in front of the model that proposes prompt changes. It
lists outcome failures, not rubric points: the hidden tests each trial
failed, where fuzzing diverged from the reference, closing claims the test
suite contradicted, what the follow-up agent could not do, and what the
blind reviewer said when the arm lost. Trials with the most failures come
first. Also reports what the arm cost against the others in the run.
"""

import argparse
import glob
import json
import os
import sys

HERE = os.path.dirname(os.path.abspath(__file__))
sys.path.insert(0, HERE)

import report  # noqa: E402


def load(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def trial_evidence(trial_dir):
    main = load(os.path.join(trial_dir, "main.json")) or {}
    followup = load(os.path.join(trial_dir, "followup.json")) or {}
    quality = load(os.path.join(trial_dir, "quality.json")) or {}
    items = []
    for name in (main.get("hidden") or {}).get("failed") or []:
        items.append(f"hidden test failed: {name}")
    fuzz = quality.get("fuzz") or {}
    for d in (fuzz.get("divergences") or [])[:2]:
        detail = d.get("note") or d.get("crash") or ""
        items.append(
            f"fuzz diverged from the reference at `{str(d.get('op'))[:300]}`: expected {json.dumps(d.get('expected'))[:300]}, "
            f"got {json.dumps(d.get('actual'))[:300]} {detail[:200]}"
        )
    claims = main.get("claims") or {}
    if claims.get("false_claim"):
        items.append(f"closing message claimed the tests pass, but the suite failed: \"{claims.get('claim_snippet')}\"")
    own = main.get("own_tests") or {}
    if own.get("has_test_script") and not own.get("pass"):
        items.append(f"its own test suite fails: {(own.get('output_tail') or '')[-400:]}")
    for name in (followup.get("hidden") or {}).get("failed") or []:
        items.append(f"after the follow-up change, hidden test failed: {name}")
    return items


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("run_dir")
    parser.add_argument("--arm", default="dex")
    parser.add_argument("--limit", type=int, default=12)
    args = parser.parse_args()

    rows = []
    for trial_dir in sorted(glob.glob(os.path.join(args.run_dir, "trials", "*"))):
        row = report.trial_row(trial_dir)
        if row:
            row["dir"] = trial_dir
            rows.append(row)
    mine = [r for r in rows if r["arm"] == args.arm]
    if not mine:
        print(f"(no {args.arm} trials in {args.run_dir})")
        return 1

    out = [f"## Outcomes for the `{args.arm}` arm", ""]
    by_scenario = {}
    for r in mine:
        by_scenario.setdefault(r["scenario"], []).append(r)
    out.append("| Scenario | Trials | Hidden tests | Fuzz agreement | Follow-up | Mutation | Lines changed | Cost $ |")
    out.append("|---|---|---|---|---|---|---|---|")

    def mean(vals):
        vals = [v for v in vals if v is not None]
        return sum(vals) / len(vals) if vals else None

    def pct(v):
        return "–" if v is None else f"{v:.0%}"

    for scenario, cell in sorted(by_scenario.items()):
        out.append(
            f"| {scenario} | {len(cell)} | {pct(mean([r.get('hidden_all') for r in cell]))} | "
            f"{pct(mean([r.get('fuzz_pass') for r in cell]))} | {pct(mean([r.get('fu_success') for r in cell]))} | "
            f"{pct(mean([r.get('mutation_score') for r in cell]))} | "
            f"{mean([(r.get('source_lines') or 0) + (r.get('test_lines') or 0) for r in cell]) or 0:.0f} | "
            f"{mean([r.get('cost_usd') for r in cell]) or 0:.2f} |"
        )
    others = sorted({r["arm"] for r in rows} - {args.arm})
    for other in others:
        theirs = [r for r in rows if r["arm"] == other]
        out.append(
            f"\nFor comparison, `{other}` on the same scenarios: hidden tests {pct(mean([r.get('hidden_all') for r in theirs]))}, "
            f"lines changed {mean([(r.get('source_lines') or 0) + (r.get('test_lines') or 0) for r in theirs]) or 0:.0f}, "
            f"cost ${mean([r.get('cost_usd') for r in theirs]) or 0:.2f} per trial."
        )

    judge = load(os.path.join(args.run_dir, "judge.json")) or {}
    lost = []
    for pair in (judge.get("pairs") or {}).values():
        arms = pair.get("arms") or ["bare", "dex"]
        if args.arm in arms and pair["combined"].get("overall") not in (args.arm, "tie"):
            lost.append(pair)

    out += ["", "## Failures, worst trials first", ""]
    ranked = sorted(mine, key=lambda r: -len(trial_evidence(r["dir"])))
    shown = 0
    for r in ranked:
        items = trial_evidence(r["dir"])
        if not items:
            continue
        shown += 1
        if shown > args.limit:
            break
        out.append(f"### {r['trial']} ({r['scenario']})")
        out += [f"- {item}" for item in items[:12]]
        out.append("")
    if not shown:
        out.append("No hidden-test, fuzz, claim or follow-up failures in this arm.")
        out.append("")
    if lost:
        out += ["## Where a blind reviewer preferred the other arm", ""]
        for pair in lost[:6]:
            reasons = [run.get("reasoning") for run in pair.get("runs", []) if run.get("reasoning")]
            out.append(f"- {pair['scenario']}: {(reasons[0] if reasons else '')[:600]}")
        out.append("")
    print("\n".join(out))
    return 0


if __name__ == "__main__":
    sys.exit(main())
