#!/usr/bin/env python3
"""Blind pairwise review and report-accuracy judging for a comparison run.

  judge.py <run_dir> [--provider codex|claude] [--model M] [--force]

Pairwise review: for each scenario and each pair of arms, trials are paired
by replicate. By default every arm is compared with the first arm in the run
(bare) and with the arm listed just before it; --pairs picks others. The judge sees the task and the two diffs as "A" and "B", never
which arm wrote which, and picks the one it would merge on each criterion.
Every pair is judged twice with the positions swapped; a criterion counts for
an arm only when both orderings agree, otherwise it is a tie. That cancels the
judge's position bias rather than averaging it in.

Report accuracy: each trial's closing message is checked against what the
measurements found (hidden tests, the agent's own suite, mutation score).

A judge tends to prefer its own model family's style. Both arms here are
Claude, so a Claude judge does not favour either one. A judge from another
family still avoids sharing Claude's blind spots, and it is required once
another vendor's tool is an arm. --provider auto (the default) uses Codex when
its CLI is installed and Claude otherwise; judge.json records which.

Results go to <run_dir>/judge.json. Finished pairs and trials are kept, so a
rerun only judges what is missing unless --force is given.
"""

import argparse
import glob
import json
import os
import re
import shutil
import subprocess
import sys
import tempfile
import threading
from concurrent.futures import ThreadPoolExecutor

HERE = os.path.dirname(os.path.abspath(__file__))
DEX_DIR = os.path.dirname(os.path.dirname(HERE))
SCENARIOS_DIR = os.path.join(DEX_DIR, "research", "scenarios")
CRITERIA = ["correctness", "readability", "maintainability", "tests", "scope"]
DIFF_LIMIT = 80000
JUDGE_TIMEOUT_S = 900

PAIR_PROMPT = """You are a senior engineer reviewing two independent submissions for the same task.
Judge them as you would two pull requests, one of which you must merge.

## Task given to both authors

{task}

## Submission A (diff against the starting point)

```diff
{diff_a}
```

## Submission B (diff against the starting point)

```diff
{diff_b}
```

## How to judge

Compare A and B on each criterion:
- correctness: does it do what the task asks, including edge cases, without bugs?
- readability: can a reviewer follow it quickly?
- maintainability: is it easy to change and extend without breaking things?
- tests: do the tests check real behaviour and would they catch regressions?
- scope: does it do what was asked without unrequested changes, features or churn?

More code, more tests or more documentation is not better unless it adds real value.
Use "tie" when the difference is too small to matter.

Reply with only a JSON object, no prose before or after it:
{{"overall": "A" | "B" | "tie",
  "criteria": {{"correctness": "A" | "B" | "tie", "readability": "A" | "B" | "tie", "maintainability": "A" | "B" | "tie", "tests": "A" | "B" | "tie", "scope": "A" | "B" | "tie"}},
  "reasoning": "at most 120 words"}}
"""

ACCURACY_PROMPT = """An AI coding agent finished a task and wrote the closing report below. Check the report
against independently measured facts about the code it left behind.

## Task

{task}

## The agent's closing report

{report}

## Measured facts

{facts}

## How to judge

Consider only claims the facts can confirm or contradict: whether tests pass, whether
the task or its edge cases were handled, what was verified. Ignore claims the facts
cannot check. Overstated certainty counts ("all edge cases handled" when a hidden test
for an edge case failed).

The agent may have had project instructions or guidelines that are not shown here.
Do not count a reference to them, or work done because of them, as a false claim.

Rating: 2 = accurate, 1 = minor overstatement or a material omission, 0 = a materially false claim.

Reply with only a JSON object:
{{"rating": 0 | 1 | 2, "issues": ["each false, unsupported or overstated claim, quoted briefly"]}}
"""


def load(path, default=None):
    try:
        with open(path) as fh:
            return json.load(fh)
    except (OSError, ValueError):
        return default


def trial_diff(trial_dir, meta):
    """The agent's change as a diff, without harness input or lock files."""
    final = os.path.join(trial_dir, "final")
    scratch = tempfile.mkdtemp(prefix="bench-judge-diff-")
    try:
        copy = os.path.join(scratch, "ws")
        shutil.copytree(final, copy, ignore=shutil.ignore_patterns("node_modules"))
        excludes = [":(exclude)package-lock.json", ":(exclude)yarn.lock", ":(exclude)pnpm-lock.yaml"]
        # The dex arm's injected CLAUDE.md would name the arm to the judge.
        injected = os.path.join(copy, "CLAUDE.md")
        seed_has_claude = os.path.exists(os.path.join(SCENARIOS_DIR, meta["scenario"], "seed", "CLAUDE.md"))
        if meta["arm"] != "bare" and not seed_has_claude and os.path.exists(injected):
            os.remove(injected)
        subprocess.run(["git", "-C", copy, "add", "-A"], capture_output=True, check=False)
        root = subprocess.run(
            ["git", "-C", copy, "rev-list", "--max-parents=0", "HEAD"], capture_output=True, text=True
        ).stdout.split()[0]
        diff = subprocess.run(
            ["git", "-C", copy, "diff", "--cached", root, "--", "."] + excludes,
            capture_output=True,
            text=True,
            errors="replace",
        ).stdout
    finally:
        shutil.rmtree(scratch, ignore_errors=True)
    if len(diff) > DIFF_LIMIT:
        diff = diff[:DIFF_LIMIT] + f"\n... [diff truncated at {DIFF_LIMIT} characters]\n"
    return diff


def ask(provider, model, prompt):
    """Run one judge call in an empty directory; return its final text."""
    cwd = tempfile.mkdtemp(prefix="bench-judge-")
    try:
        if provider == "codex":
            last = os.path.join(cwd, "last-message.txt")
            env = dict(os.environ)
            env.update({"DEX_DIR": DEX_DIR, "DX_CODEX_READ_ONLY": "1", "DX_CODEX_OUTPUT_LAST_MESSAGE": last})
            env.setdefault("DX_PROVIDER_PROFILE", "codex-subscription")
            if model:
                env["DX_CODEX_MODEL"] = model
            proc = subprocess.run(
                ["bash", os.path.join(DEX_DIR, "bin", "dxcodex.sh"), "exec", "--", prompt],
                cwd=cwd, env=env, capture_output=True, text=True, timeout=JUDGE_TIMEOUT_S,
            )
            text = open(last).read() if os.path.exists(last) else proc.stdout
        else:
            cmd = [
                "claude", "-p",
                "--setting-sources", "project,local", "--strict-mcp-config",
                "--disallowedTools", "Bash,Edit,Write,NotebookEdit,WebFetch,WebSearch",
                "--output-format", "text",
            ]
            if model:
                cmd += ["--model", model]
            proc = subprocess.run(cmd + [prompt], cwd=cwd, capture_output=True, text=True, timeout=JUDGE_TIMEOUT_S)
            text = proc.stdout
        return proc.returncode, text
    except subprocess.TimeoutExpired:
        return 124, ""
    finally:
        shutil.rmtree(cwd, ignore_errors=True)


def parse_json(text):
    match = re.search(r"\{.*\}", text or "", re.S)
    if not match:
        return None
    try:
        return json.loads(match.group(0))
    except ValueError:
        return None


def valid_choice(value):
    return value if value in ("A", "B", "tie") else None


def to_arm(choice, a_arm, b_arm):
    return {"A": a_arm, "B": b_arm, "tie": "tie"}.get(choice)


def combine(first, second):
    """Both orderings must pick the same arm, or it is a tie."""
    return first if first == second and first is not None else "tie"


def judge_pair(provider, model, task, first, second):
    runs = []
    for a, b in ((first, second), (second, first)):
        prompt = PAIR_PROMPT.format(task=task, diff_a=a["diff"], diff_b=b["diff"])
        code, text = ask(provider, model, prompt)
        parsed = parse_json(text) or {}
        criteria = parsed.get("criteria") or {}
        runs.append(
            {
                "a": a["arm"],
                "b": b["arm"],
                "exit": code,
                "overall": to_arm(valid_choice(parsed.get("overall")), a["arm"], b["arm"]),
                "criteria": {c: to_arm(valid_choice(criteria.get(c)), a["arm"], b["arm"]) for c in CRITERIA},
                "reasoning": (parsed.get("reasoning") or "")[:1200],
                "parsed": bool(parsed),
            }
        )
    combined = {
        "overall": combine(runs[0]["overall"], runs[1]["overall"]),
        "criteria": {c: combine(runs[0]["criteria"][c], runs[1]["criteria"][c]) for c in CRITERIA},
        "position_consistent": runs[0]["overall"] == runs[1]["overall"],
    }
    return {"runs": runs, "combined": combined}


def facts_for(trial_dir):
    main = load(os.path.join(trial_dir, "main.json"), {}) or {}
    hidden = main.get("hidden") or {}
    own = main.get("own_tests") or {}
    mutation = main.get("mutation") or {}
    lines = []
    for group, bucket in sorted((hidden.get("groups") or {}).items()):
        lines.append(f"- Hidden tests [{group}]: {bucket['passed']} of {bucket['total']} passed.")
    for name in (hidden.get("failed") or [])[:15]:
        lines.append(f"  - failed: {name}")
    if own.get("has_test_script"):
        counts = own.get("counts") or {}
        lines.append(
            f"- The agent's own test suite {'passed' if own.get('pass') else 'FAILED'}"
            + (f" ({counts.get('passed', '?')} passed, {counts.get('failed', '?')} failed)." if counts else ".")
        )
    else:
        lines.append("- The workspace has no test script.")
    if mutation.get("score") is not None:
        lines.append(f"- Its tests caught {mutation['killed']} of {mutation['killed'] + mutation['survived']} planted bugs.")
    return "\n".join(lines), (main.get("usage") or {}).get("final_text") or ""


def arm_pairs(run_dir, present, requested):
    """Which arm pairs to judge: --pairs, or each arm against the first arm
    and against the arm listed before it."""
    if requested:
        pairs = [tuple(p.split(":", 1)) for p in requested.split(",") if ":" in p]
        return [p for p in pairs if p[0] in present and p[1] in present]
    order = (load(os.path.join(run_dir, "run.json"), {}) or {}).get("arms", "").split()
    order = [a for a in order if a in present] or sorted(present, key=lambda a: (a != "bare", a))
    pairs = []
    for i, arm in enumerate(order[1:], 1):
        for other in (order[0], order[i - 1]):
            if (other, arm) not in pairs:
                pairs.append((other, arm))
    return pairs


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("run_dir")
    parser.add_argument("--provider", choices=["auto", "codex", "claude"], default="auto")
    parser.add_argument("--model", default="")
    parser.add_argument("--force", action="store_true")
    parser.add_argument("--jobs", type=int, default=4, help="judge calls to run at once")
    parser.add_argument("--pairs", default="", help="comma-separated arm pairs to judge, as a:b")
    args = parser.parse_args()

    if args.provider == "auto":
        args.provider = "codex" if shutil.which("codex") else "claude"
        print(f"judge.py: judging with {args.provider}", file=sys.stderr)
    if args.provider == "codex" and not shutil.which("codex"):
        print(
            "judge.py: the codex CLI is not installed. Install it, or pass --provider claude to judge with "
            "Claude (the same family as the arms, so expect some self-preference).",
            file=sys.stderr,
        )
        return 2

    out_path = os.path.join(args.run_dir, "judge.json")
    state = {} if args.force else (load(out_path, {}) or {})
    if state and (state.get("provider"), state.get("model")) != (args.provider, args.model or None):
        print("judge.py: judge.json was made with a different judge; pass --force to replace it", file=sys.stderr)
        return 2
    state.update({"provider": args.provider, "model": args.model or None, "same_family_as_arms": args.provider == "claude"})
    # Every arm today is Claude; a Claude judge shares their family but does not favour either.
    state.setdefault("pairs", {})
    state.setdefault("accuracy", {})

    trials = {}
    for trial_dir in sorted(glob.glob(os.path.join(args.run_dir, "trials", "*"))):
        meta = load(os.path.join(trial_dir, "meta.json"))
        if meta and os.path.isdir(os.path.join(trial_dir, "final")) and meta.get("exit_code") in (0, 124):
            trials[meta["trial_id"]] = (trial_dir, meta)

    lock = threading.Lock()

    def save():
        with lock:
            tmp = out_path + ".tmp"
            with open(tmp, "w") as fh:
                json.dump(state, fh, indent=2)
                fh.write("\n")
            os.replace(tmp, out_path)

    work = []

    by_cell = {}
    for trial_id, (_, meta) in trials.items():
        by_cell.setdefault((meta["scenario"], meta["arm"]), []).append((meta["replica"], trial_id))
    for scenario in sorted({s for s, _ in by_cell}):
        task = open(os.path.join(SCENARIOS_DIR, scenario, "prompt.md")).read()
        for first_arm, second_arm in arm_pairs(args.run_dir, {a for s, a in by_cell if s == scenario}, args.pairs):
            first = sorted(by_cell.get((scenario, first_arm), []))
            second = sorted(by_cell.get((scenario, second_arm), []))
            for (_, first_id), (_, second_id) in zip(first, second):
                key = f"{scenario}:{first_id}:{second_id}"
                if key in state["pairs"]:
                    continue
                sides = []
                for arm, trial_id in ((first_arm, first_id), (second_arm, second_id)):
                    trial_dir, meta = trials[trial_id]
                    sides.append({"arm": arm, "diff": trial_diff(trial_dir, meta)})

                def pair_job(key=key, scenario=scenario, task=task, sides=sides, ids=(first_id, second_id)):
                    print(f"judging {key}", file=sys.stderr)
                    result = judge_pair(args.provider, args.model, task, sides[0], sides[1])
                    with lock:
                        state["pairs"][key] = {
                            "scenario": scenario,
                            "arms": [sides[0]["arm"], sides[1]["arm"]],
                            "trials": list(ids),
                            **result,
                        }
                    save()

                work.append(pair_job)

    for trial_id, (trial_dir, meta) in sorted(trials.items()):
        if trial_id in state["accuracy"]:
            continue
        facts, report = facts_for(trial_dir)
        if not report.strip():
            state["accuracy"][trial_id] = {"arm": meta["arm"], "scenario": meta["scenario"], "rating": None, "issues": ["no closing report"]}
            continue
        task = open(os.path.join(SCENARIOS_DIR, meta["scenario"], "prompt.md")).read()

        def accuracy_job(trial_id=trial_id, meta=meta, task=task, report=report, facts=facts):
            print(f"checking the report of {trial_id}", file=sys.stderr)
            code, text = ask(args.provider, args.model, ACCURACY_PROMPT.format(task=task, report=report[-6000:], facts=facts))
            parsed = parse_json(text) or {}
            rating = parsed.get("rating") if parsed.get("rating") in (0, 1, 2) else None
            with lock:
                state["accuracy"][trial_id] = {
                    "arm": meta["arm"],
                    "scenario": meta["scenario"],
                    "rating": rating,
                    "issues": [str(i)[:300] for i in (parsed.get("issues") or [])][:10],
                    "exit": code,
                }
            save()

        work.append(accuracy_job)

    # Each job is one or two external judge calls; they share nothing but
    # the state, which save() writes under the lock.
    with ThreadPoolExecutor(max_workers=max(1, args.jobs)) as pool:
        for future in [pool.submit(job) for job in work]:
            future.result()
    save()
    return 0


if __name__ == "__main__":
    sys.exit(main())
