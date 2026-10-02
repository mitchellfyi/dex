#!/usr/bin/env python3
"""Summarize an arm comparison run.

  report.py <run_dir>

Reads every trial under <run_dir>/trials/, prints a markdown report and writes
it to <run_dir>/report.md, with the numbers behind it in summary.json.

Metrics are reported as a set, not a weighted total: one number would hide a
trade such as "better code at three times the cost". The delta column is
dex minus bare, averaged over scenarios, with a 95% bootstrap interval over
replicates. With three replicates the interval is wide; read it as "is this
difference bigger than the noise", not as a precise estimate.
"""

import glob
import json
import os
import random
import statistics
import sys

BOOTSTRAP_SAMPLES = 2000


def load(path):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return None


def rate(hidden, groups):
    if not hidden:
        return None
    passed = total = 0
    for group in groups:
        bucket = (hidden.get("groups") or {}).get(group)
        if bucket:
            passed += bucket["passed"]
            total += bucket["total"]
    return passed / total if total else None


def status(meta, main):
    usage = (main or {}).get("usage") or {}
    if meta.get("exit_code") == 124:
        return "censored"
    if not usage.get("has_result"):
        return "invalid"
    if usage.get("is_error") and (usage.get("num_turns") or 0) <= 2:
        return "invalid"
    return "valid"


def trial_row(trial_dir):
    meta = load(os.path.join(trial_dir, "meta.json"))
    if not meta:
        return None
    main = load(os.path.join(trial_dir, "main.json")) or {}
    followup = load(os.path.join(trial_dir, "followup.json"))
    legacy = load(os.path.join(trial_dir, "rubric-results.json")) or {}
    usage = main.get("usage") or {}
    diff = main.get("diff") or {}
    hidden = main.get("hidden")
    mutation = main.get("mutation") or {}
    row = {
        "trial": meta["trial_id"],
        "arm": meta["arm"],
        "scenario": meta["scenario"],
        "status": status(meta, main),
        "model": usage.get("model"),
        "hidden_spec": rate(hidden, ["spec"]),
        "hidden_preserve": rate(hidden, ["preserve"]),
        "hidden_robust": rate(hidden, ["robust"]),
        "hidden_all": rate(hidden, ["spec", "preserve", "robust"]),
        "own_tests_pass": (main.get("own_tests") or {}).get("pass"),
        "mutation_score": mutation.get("score"),
        "source_lines": diff.get("source_lines"),
        "test_lines": diff.get("test_lines"),
        "total_lines": diff.get("total_lines"),
        "files_changed": diff.get("files_changed"),
        "outside_scope": len(diff.get("outside_scope") or []) if diff else None,
        "forbidden_touched": len(diff.get("forbidden_touched") or []) if diff else None,
        "false_claim": (main.get("claims") or {}).get("false_claim"),
        "cost_usd": usage.get("cost_usd"),
        "tokens_total": (usage.get("tokens") or {}).get("total"),
        "tokens_output": (usage.get("tokens") or {}).get("output"),
        "turns": usage.get("num_turns"),
        "wall_minutes": meta["wall_seconds"] / 60 if meta.get("wall_seconds") is not None else None,
        "loop_audits": usage.get("stop_hook_blocks") if os.path.exists(os.path.join(trial_dir, "loop.json")) else None,
        "loop_completed": (load(os.path.join(trial_dir, "loop.json")) or {}).get("completed")
        if os.path.exists(os.path.join(trial_dir, "loop.json"))
        else None,
        "legacy_total": meta.get("legacy_total"),
    }
    for dim in ("correctness", "test_quality", "robustness", "verification", "issue_detection", "code_quality"):
        row[f"legacy_{dim}"] = legacy.get(dim)
    if followup:
        fusage = followup.get("usage") or {}
        fdiff = followup.get("diff") or {}
        fhidden = followup.get("hidden")
        row.update(
            {
                "fu_success": rate(fhidden, ["followup"]),
                "fu_regression_free": rate(fhidden, ["spec", "preserve", "robust"]),
                "fu_own_tests_pass": (followup.get("own_tests") or {}).get("pass"),
                "fu_cost_usd": fusage.get("cost_usd"),
                "fu_tokens_total": (fusage.get("tokens") or {}).get("total"),
                "fu_wall_minutes": meta["followup_wall_seconds"] / 60
                if meta.get("followup_wall_seconds") is not None
                else None,
                "fu_source_lines": fdiff.get("source_lines"),
                "fu_turns": fusage.get("num_turns"),
            }
        )
    quality = load(os.path.join(trial_dir, "quality.json"))
    if quality:
        row.update(quality_fields(quality))
    return row


def quality_fields(q):
    """Flatten quality.json (written by quality.py) into report metrics."""
    perf = q.get("perf") or {}
    fuzz = q.get("fuzz") or {}
    static = q.get("static") or {}
    dup = q.get("duplication") or {}
    deps = q.get("deps") or {}
    suite = q.get("suite") or {}
    cli = q.get("cli") or {}
    docs = q.get("docs") or {}
    audit = deps.get("audit") or {}
    cvs = [w.get("cv") for w in perf.get("workloads") or [] if w.get("cv") is not None]
    fields = {
        "perf_ratio": perf.get("geomean_ratio"),
        "perf_noise": max(cvs) if cvs else None,
        "fuzz_pass": fuzz.get("pass_rate"),
        "lint_per_kloc": (static.get("findings_per_kloc") or {}).get("source"),
        "complexity_mean": (static.get("complexity") or {}).get("mean"),
        "complexity_max": (static.get("complexity") or {}).get("max"),
        "fn_lines_max": (static.get("function_lines") or {}).get("max"),
        "max_depth": static.get("max_depth"),
        "duplication_pct": dup.get("percentage"),
        "deps_declared": deps.get("declared"),
        "packages_installed": deps.get("installed_packages"),
        "vulns_total": audit.get("total") if isinstance(audit.get("total"), int) else None,
        "cli_rate": cli.get("rate"),
        "has_readme": docs.get("readme") if docs else None,
        "docs_rate": docs.get("rate"),
    }
    if suite.get("has_test_script"):
        fields.update(
            {
                "suite_pass_rate": suite["passes"] / suite["runs"],
                "suite_flaky": suite.get("flaky"),
                "suite_seconds": suite.get("median_seconds"),
                "suite_leftovers": len(suite.get("workspace_leftovers") or []) + (suite.get("tmp_leftovers") or 0),
            }
        )
    return fields


# key, label, format, direction (+1 higher is better, -1 lower is better, 0 neither)
SECTIONS = [
    (
        "Outcome quality",
        [
            ("hidden_spec", "Hidden tests: spec", "pct", 1),
            ("hidden_robust", "Hidden tests: robust", "pct", 1),
            ("hidden_preserve", "Hidden tests: preserve", "pct", 1),
            ("own_tests_pass", "Own test suite passes", "pct", 1),
            ("mutation_score", "Mutation score (own tests)", "pct", 1),
            ("false_claim", "Claimed passing, suite failed", "pct", -1),
        ],
    ),
    (
        "Size and scope",
        [
            ("source_lines", "Source lines changed", "int", 0),
            ("test_lines", "Test lines changed", "int", 0),
            ("files_changed", "Files changed", "int", 0),
            ("outside_scope", "Files outside scope", "int", -1),
            ("forbidden_touched", "Forbidden files touched", "int", -1),
        ],
    ),
    (
        "Changeability (fixed follow-up agent)",
        [
            ("fu_success", "Follow-up hidden tests", "pct", 1),
            ("fu_regression_free", "Main hidden tests after follow-up", "pct", 1),
            ("fu_own_tests_pass", "Own suite passes after follow-up", "pct", 1),
            ("fu_cost_usd", "Follow-up cost ($)", "usd", -1),
            ("fu_wall_minutes", "Follow-up wall time (min)", "min", -1),
            ("fu_tokens_total", "Follow-up tokens", "tok", -1),
            ("fu_source_lines", "Follow-up source lines", "int", -1),
        ],
    ),
    (
        "Cost",
        [
            ("cost_usd", "Cost ($, API-equivalent)", "usd", -1),
            ("tokens_total", "Tokens (incl. cache)", "tok", -1),
            ("tokens_output", "Output tokens", "tok", -1),
            ("turns", "Turns", "num", -1),
            ("wall_minutes", "Wall time (min)", "min", -1),
        ],
    ),
    (
        "Audit loop (dex-loop arms)",
        [
            ("loop_audits", "Audit iterations the Stop hook ran", "num", 0),
            ("loop_completed", "Loop finished with a receipt", "pct", 1),
        ],
    ),
    (
        "Runtime behaviour (reference solution = 1.00x)",
        [
            ("perf_ratio", "Time vs reference (geomean)", "ratio", -1),
            ("perf_noise", "Worst timing noise (CV)", "pct", 0),
            ("fuzz_pass", "Fuzz sequences agreeing with reference", "pct", 1),
        ],
    ),
    (
        "Code health",
        [
            ("lint_per_kloc", "eslint findings per KLOC (source)", "num", -1),
            ("complexity_mean", "Cyclomatic complexity (mean)", "num", -1),
            ("complexity_max", "Cyclomatic complexity (max)", "int", -1),
            ("fn_lines_max", "Longest function (lines)", "int", -1),
            ("max_depth", "Deepest nesting", "int", -1),
            ("duplication_pct", "Duplicated source lines (%)", "num", -1),
            ("deps_declared", "Dependencies declared", "int", -1),
            ("packages_installed", "Packages installed", "int", -1),
            ("vulns_total", "npm audit findings", "int", -1),
        ],
    ),
    (
        "Test-suite health",
        [
            ("suite_pass_rate", "Suite passes (of 5 runs)", "pct", 1),
            ("suite_flaky", "Flaky suite", "pct", -1),
            ("suite_seconds", "Suite runtime (s, median)", "num", -1),
            ("suite_leftovers", "Files left behind by tests", "int", -1),
        ],
    ),
    (
        "Conventions and docs",
        [
            ("cli_rate", "CLI conventions met", "pct", 1),
            ("has_readme", "Has a README", "pct", 0),
            ("docs_rate", "README samples that run", "pct", 1),
            ("report_accuracy", "Closing report accuracy (judge)", "pct", 1),
        ],
    ),
    (
        "Existing rubric (process-weighted; for continuity)",
        [
            ("legacy_total", "Rubric total", "num", 0),
            ("legacy_correctness", "correctness", "num", 0),
            ("legacy_test_quality", "test_quality", "num", 0),
            ("legacy_robustness", "robustness", "num", 0),
            ("legacy_verification", "verification", "num", 0),
            ("legacy_issue_detection", "issue_detection", "num", 0),
        ],
    ),
]


def numeric(value):
    if isinstance(value, bool):
        return 1.0 if value else 0.0
    if isinstance(value, (int, float)):
        return float(value)
    return None


def values(rows, key):
    return [v for v in (numeric(r.get(key)) for r in rows) if v is not None]


def fmt(value, kind):
    if value is None:
        return "–"
    if kind == "pct":
        return f"{value * 100:.0f}%"
    if kind == "usd":
        return f"{value:.2f}"
    if kind == "min":
        return f"{value:.1f}"
    if kind == "tok":
        return f"{value / 1000:.0f}k"
    if kind == "int":
        return f"{value:.0f}"
    if kind == "ratio":
        return f"{value:.2f}x"
    return f"{value:.1f}"


def fmt_delta(delta, kind):
    if delta is None:
        return "–"
    sign = "+" if delta > 0 else ""
    if kind == "pct":
        return f"{sign}{delta * 100:.0f}pp"
    return f"{sign}{fmt(delta, kind)}"


def paired_delta(cells, scenarios, key, rng, arm="dex", baseline="bare"):
    """Mean over scenarios of (arm mean - baseline mean), with a bootstrap CI."""
    usable = [s for s in scenarios if values(cells.get((s, arm), []), key) and values(cells.get((s, baseline), []), key)]
    if not usable:
        return None, None, None
    point = statistics.mean(
        statistics.mean(values(cells[(s, arm)], key)) - statistics.mean(values(cells[(s, baseline)], key)) for s in usable
    )
    samples = []
    for _ in range(BOOTSTRAP_SAMPLES):
        per_scenario = []
        for s in usable:
            a = values(cells[(s, arm)], key)
            b = values(cells[(s, baseline)], key)
            per_scenario.append(statistics.mean(rng.choices(a, k=len(a))) - statistics.mean(rng.choices(b, k=len(b))))
        samples.append(statistics.mean(per_scenario))
    samples.sort()
    return point, samples[int(0.025 * len(samples))], samples[int(0.975 * len(samples)) - 1]


def pairwise_section(judge):
    """Blind pairwise review: how often each arm of a pair won, per criterion."""
    pairs = list((judge.get("pairs") or {}).values())
    if not pairs:
        return []
    criteria = ["overall", "correctness", "readability", "maintainability", "tests", "scope"]
    groups = {}
    for p in pairs:
        # judge.json from before multi-arm runs stored "bare"/"dex" keys.
        arms = tuple(p.get("arms") or ("bare", "dex"))
        groups.setdefault(arms, []).append(p)

    lines = ["## Blind pairwise review", ""]
    family = " (same model family as the arms)" if judge.get("same_family_as_arms") else ""
    consistent = sum(1 for p in pairs if p["combined"].get("position_consistent"))
    lines.append(
        f"Judge: `{judge.get('provider')}`{' `' + judge['model'] + '`' if judge.get('model') else ''}{family}. "
        f"{len(pairs)} pairs, each judged in both orders; a criterion counts for an arm only when both "
        f"orders agree. The overall pick was the same in both orders for {consistent} of {len(pairs)} pairs."
    )
    lines.append("")
    for (first, second), subset in groups.items():
        scenarios = sorted({p["scenario"] for p in subset})

        def tally(group, criterion):
            picks = [
                p["combined"]["overall"] if criterion == "overall" else p["combined"]["criteria"].get(criterion)
                for p in group
            ]
            return {k: sum(1 for x in picks if x == k) for k in (second, "tie", first)}

        lines.append(f"### {second} vs {first}")
        lines.append("")
        header = ["Criterion", "All pairs"] + scenarios
        lines.append("| " + " | ".join(header) + " |")
        lines.append("|" + "---|" * len(header))
        for criterion in criteria:
            cells = []
            for group in [subset] + [[p for p in subset if p["scenario"] == sc] for sc in scenarios]:
                t = tally(group, criterion)
                cells.append(f"{second} {t[second]} · tie {t['tie']} · {first} {t[first]}")
            lines.append(f"| {criterion} | " + " | ".join(cells) + " |")
        lines.append("")
    return lines


def main():
    if len(sys.argv) != 2:
        print(__doc__, file=sys.stderr)
        return 2
    run_dir = sys.argv[1]
    run = load(os.path.join(run_dir, "run.json")) or {}
    rows = [r for r in (trial_row(d) for d in sorted(glob.glob(os.path.join(run_dir, "trials", "*")))) if r]
    planned = sum(1 for line in open(os.path.join(run_dir, "trials.tsv")) if line.strip()) if os.path.exists(
        os.path.join(run_dir, "trials.tsv")
    ) else len(rows)

    judge = load(os.path.join(run_dir, "judge.json")) or {}
    for r in rows:
        rating = ((judge.get("accuracy") or {}).get(r["trial"]) or {}).get("rating")
        r["report_accuracy"] = rating / 2 if isinstance(rating, int) else None

    counted = [r for r in rows if r["status"] in ("valid", "censored")]
    present = {r["arm"] for r in counted}
    arms = [a for a in (run.get("arms") or "").split() if a in present]
    arms += sorted(present - set(arms), key=lambda a: (a != "bare", a))
    baseline = arms[0] if arms else None
    others = arms[1:]
    scenarios = sorted({r["scenario"] for r in counted})
    cells = {}
    for r in counted:
        cells.setdefault((r["scenario"], r["arm"]), []).append(r)

    out = []
    out.append(f"# Dex vs bare Claude — {run.get('run_id', os.path.basename(run_dir))}")
    out.append("")
    out.append(
        f"Model `{run.get('model')}` at effort `{run.get('effort')}` for every arm; follow-up agent "
        f"`{run.get('followup_model')}` at `{run.get('followup_effort')}`. Dex commit `{run.get('dex_commit')}`"
        f" ({run.get('dex_dirty_files', '?')} uncommitted files under prompts/, skills/, hooks/, research/)."
    )
    models = sorted({r["model"] for r in rows if r.get("model")})
    if models:
        out.append(f"Resolved model: {', '.join(models)}.")
    status_counts = {}
    for r in rows:
        status_counts[r["status"]] = status_counts.get(r["status"], 0) + 1
    out.append(
        f"Trials: {len(rows)} of {planned} finished — "
        + ", ".join(f"{k} {v}" for k, v in sorted(status_counts.items()))
        + ". Invalid trials (no result, or an API error in the first turns) are excluded; censored"
        " trials (hit the time budget) are counted as they stand."
    )
    invalid = [r["trial"] for r in rows if r["status"] == "invalid"]
    if invalid:
        out.append(f"Invalid: {', '.join(invalid)}.")
    out.append("")

    rng = random.Random(0)
    summary = {"run": run, "rows": rows, "deltas": {}, "cells": {}}

    def cell_mean(scenario, arm, key):
        vals = values(cells.get((scenario, arm), []), key)
        summary["cells"].setdefault(key, {})[f"{scenario}/{arm}"] = {
            "mean": statistics.mean(vals) if vals else None,
            "n": len(vals),
            "values": vals,
        }
        return statistics.mean(vals) if vals else None

    def arm_mean(arm, key):
        means = [m for m in (cell_mean(s, arm, key) for s in scenarios) if m is not None]
        return statistics.mean(means) if means else None

    for title, metrics in SECTIONS:
        present = [m for m in metrics if any(numeric(r.get(m[0])) is not None for r in counted)]
        if not present:
            continue
        out.append(f"## {title}")
        out.append("")
        header = ["Metric"] + arms
        for arm in others:
            header += [f"Δ {arm}−{baseline}", "95% CI"]
        out.append("| " + " | ".join(header) + " |")
        out.append("|" + "---|" * len(header))
        for key, label, kind, _direction in present:
            line = [label] + [fmt(arm_mean(a, key), kind) for a in arms]
            for arm in others:
                point, low, high = paired_delta(cells, scenarios, key, rng, arm, baseline)
                summary["deltas"].setdefault(key, {})[arm] = {"point": point, "low": low, "high": high}
                line.append(fmt_delta(point, kind))
                line.append(f"{fmt_delta(low, kind)} … {fmt_delta(high, kind)}" if point is not None else "–")
            out.append("| " + " | ".join(line) + " |")
        out.append("")

    out.append("Arm columns weight every scenario equally: the mean over scenarios of each scenario's mean over replicates.")
    out.append("")
    perf_noise = [r.get("perf_noise") for r in counted if r.get("perf_noise") is not None]
    if perf_noise and max(perf_noise) > 0.25:
        out.append(
            f"Timing caution: repeat runs of the same code varied by up to {max(perf_noise) * 100:.0f}% (CV)."
            " Treat perf ratios within about ±25% of 1.00x as equal."
        )
        out.append("")
    out.extend(pairwise_section(judge))
    out.append("## Per scenario")
    out.append("")
    for scenario in scenarios:
        n = {a: len(cells.get((scenario, a), [])) for a in arms}
        out.append(f"### {scenario} (" + ", ".join(f"{a} n={n[a]}" for a in arms) + ")")
        out.append("")
        out.append("| Metric | " + " | ".join(arms) + " |")
        out.append("|---|" + "---|" * len(arms))
        for _title, metrics in SECTIONS:
            for key, label, kind, _direction in metrics:
                cols = []
                for a in arms:
                    vals = values(cells.get((scenario, a), []), key)
                    if not vals:
                        cols.append("–")
                    elif len(vals) > 1 and kind != "pct":
                        cols.append(f"{fmt(statistics.mean(vals), kind)} ±{fmt(statistics.stdev(vals), kind)}")
                    else:
                        cols.append(fmt(statistics.mean(vals), kind))
                if any(c != "–" for c in cols):
                    out.append(f"| {label} | " + " | ".join(cols) + " |")
        out.append("")

    out.append("Per-scenario cells are the mean over replicates, ± the sample standard deviation for non-percentages.")
    out.append("")
    report = "\n".join(out) + "\n"
    with open(os.path.join(run_dir, "report.md"), "w") as fh:
        fh.write(report)
    with open(os.path.join(run_dir, "summary.json"), "w") as fh:
        json.dump(summary, fh, indent=2)
        fh.write("\n")
    sys.stdout.write(report)
    return 0


if __name__ == "__main__":
    sys.exit(main())
