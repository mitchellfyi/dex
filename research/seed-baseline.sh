#!/usr/bin/env bash
# Score every rubric against its own untouched seed.
#
# A seed is the scenario before an agent touches it. Whatever a rubric awards
# here is the floor: the score an agent gets for doing nothing at all, and the
# part of the scale that cannot tell one agent from another.
#
# A high floor is not automatically wrong. Most of these rubrics are built as a
# large "did not regress" base plus a smaller "did the task" delta, and for a
# refactor scenario — preserve behaviour, preserve tests — a test-quality
# dimension that starts at 100 and only falls is exactly right. What matters is
# knowing which dimensions those are, and noticing when a rubric edit quietly
# moves more of the score below the floor.
#
#   bash research/seed-baseline.sh
#   bash research/seed-baseline.sh long-refactor-inheritance
#
# Not part of tests/run-all.sh: most rubrics run `npm install` or `pip
# install`, and the suite is hermetic. Run this by hand when changing a rubric
# or a seed.
set -uo pipefail

RESEARCH_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
SCENARIOS_DIR="$RESEARCH_DIR/scenarios"
WORK="$(mktemp -d "${TMPDIR:-/tmp}/dex-seed-baseline.XXXXXX")"
trap 'rm -rf "$WORK"' EXIT
RESULT_DIR="$WORK/.empty-result"
mkdir -p "$RESULT_DIR"

only="${1:-}"

printf '%-30s %-6s %8s %8s %8s %8s %8s\n' 'scenario' 'start' 'correct' 'tests' 'robust' 'issues' 'TOTAL'
printf '%-30s %-6s %8s %8s %8s %8s %8s\n' '------------------------------' '------' '--------' '--------' '--------' '--------' '--------'

for scenario_path in "$SCENARIOS_DIR"/*/; do
  scenario="$(basename "$scenario_path")"
  [[ "$scenario" == "_template" ]] && continue
  [[ -z "$only" || "$only" == "$scenario" ]] || continue
  rubric="$scenario_path/rubric.sh"
  [[ -f "$rubric" ]] || continue
  seed_dir="$scenario_path/seed"

  # Reproduce what research/lib/workspace.sh hands an agent: a git repo with a
  # .gitignore commit, and the seed folded into that same commit when there is
  # one. A scenario with no seed starts empty and is built from scratch, so its
  # floor is whatever a rubric awards for an empty repo — which should be
  # nothing at all.
  workspace="$WORK/$scenario"
  mkdir -p "$workspace"
  git -C "$workspace" init -q 2>/dev/null || true
  git -C "$workspace" config user.email research@dex.local 2>/dev/null || true
  git -C "$workspace" config user.name "Research" 2>/dev/null || true
  printf 'node_modules/\n__pycache__/\n.venv/\ndist/\nbuild/\n*.pyc\n.DS_Store\n' \
    > "$workspace/.gitignore"
  git -C "$workspace" add .gitignore >/dev/null 2>&1 || true
  git -C "$workspace" commit -qm "init: empty workspace" >/dev/null 2>&1 || true
  if [[ -d "$seed_dir" ]]; then
    (cd "$seed_dir" && cp -R . "$workspace/") 2>/dev/null || true
    if [[ -n "$(git -C "$workspace" status --porcelain 2>/dev/null)" ]]; then
      git -C "$workspace" add -A >/dev/null 2>&1 || true
      git -C "$workspace" commit -q --amend --no-edit >/dev/null 2>&1 || true
    fi
    origin="seed"
  else
    origin="empty"
  fi

  # A subshell per rubric, so one scenario's definitions cannot answer for the
  # next — the same reason score_scenario unsets them between runs.
  (
    set +e
    # shellcheck disable=SC1090
    source "$rubric" 2>/dev/null
    # rubric_issue_detection takes the result directory as well, the way
    # score_scenario calls it. An empty one stands in for a run that produced
    # no transcript.
    for check in rubric_correctness rubric_test_quality rubric_robustness rubric_issue_detection; do
      if declare -f "$check" >/dev/null 2>&1; then
        if [[ "$check" == "rubric_issue_detection" ]]; then
          value=$("$check" "$workspace" "$RESULT_DIR" 2>/dev/null)
        else
          value=$("$check" "$workspace" 2>/dev/null)
        fi
        [[ "$value" =~ ^[0-9]+$ ]] || value='?'
      else
        value='-'
      fi
      printf '%s ' "$value"
    done
    printf '\n'
  ) > "$WORK/$scenario.scores" 2>/dev/null

  read -r correctness tests robustness issues < "$WORK/$scenario.scores"
  # The weighted floor: what score_scenario would report for this workspace.
  # verification and code_quality are not measured here, so they contribute
  # nothing — the total is a lower bound on the real floor, not an estimate.
  total=$(
    DX_C="${correctness:-0}" DX_T="${tests:-0}" DX_R="${robustness:-0}" DX_I="${issues:-0}" \
    DX_SC="$scenario_path/scenario.json" python3 - <<'PYEOF'
import json
import os

weights = {"correctness": 30, "test_quality": 20, "robustness": 15,
           "verification": 15, "issue_detection": 10, "code_quality": 10}
try:
    override = json.load(open(os.environ["DX_SC"])).get("weights")
    if isinstance(override, dict) and sum(int(v) for v in override.values()) == 100:
        weights = {k: int(override[k]) for k in weights}
except Exception:
    pass


def value(name):
    raw = os.environ.get(name, "0")
    return int(raw) if raw.isdigit() else 0


print((value("DX_C") * weights["correctness"]
       + value("DX_T") * weights["test_quality"]
       + value("DX_R") * weights["robustness"]
       + value("DX_I") * weights["issue_detection"]) // 100)
PYEOF
  )
  printf '%-30s %-6s %8s %8s %8s %8s %8s\n' \
    "$scenario" "$origin" "${correctness:-?}" "${tests:-?}" "${robustness:-?}" "${issues:-?}" "$total"
done

printf '\n%s\n' "The floor: what an agent scores for changing nothing."
printf '%s\n' "start=empty scenarios are built from scratch, so any score there is unearned."
printf '%s\n' "? means the check answered with something that is not a number."
printf '%s\n' "- means the rubric does not define that check."
printf '%s\n' "TOTAL is the weighted floor out of 100, counting only the four checks"
printf '%s\n' "measured here — a lower bound. The rest of the scale is what an agent"
printf '%s\n' "can actually win or lose."
