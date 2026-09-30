#!/usr/bin/env python3
"""Score a workspace from a scenario's compare/ hidden suite, for rubric.sh.

  hidden_score.py <scenario_dir> <ws> groups <group,group,...>
  hidden_score.py <scenario_dir> <ws> tests

`groups` prints the share of those hidden tests that pass, 0-100. `tests`
prints 50 for a passing own suite plus 50 times its mutation score, 0-100.
Lets the legacy harness grade a scenario on the same behaviour the arm
comparison does, instead of a second, grep-based rubric. Always prints one
integer, as rubric.sh functions must.
"""

import os
import sys

sys.path.insert(0, os.path.dirname(os.path.abspath(__file__)))

import measure  # noqa: E402


def main():
    scenario_dir, ws, mode = sys.argv[1], sys.argv[2], sys.argv[3]
    if mode == "groups":
        wanted = sys.argv[4].split(",")
        result = measure.run_hidden(ws, measure.hidden_dirs(scenario_dir, False)) or {}
        passed = total = 0
        for group in wanted:
            bucket = (result.get("groups") or {}).get(group) or {}
            passed += bucket.get("passed", 0)
            total += bucket.get("total", 0)
        print(round(100 * passed / total) if total else 0)
        return
    measure.npm_install(ws)
    own = measure.own_tests(ws)
    score = 50 if own.get("pass") else 0
    config = measure.compare_config(scenario_dir).get("mutation")
    mutation = measure.mutation(ws, config, own.get("pass")) if config else None
    if mutation and mutation.get("score") is not None:
        score += round(50 * mutation["score"])
    elif own.get("pass"):
        score += 25
    print(score)


if __name__ == "__main__":
    main()
