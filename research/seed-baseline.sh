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

only="${1:-}"

printf '%-34s %9s %9s %9s %9s\n' 'scenario' 'correct' 'tests' 'robust' 'issues'
printf '%-34s %9s %9s %9s %9s\n' '----------------------------------' '---------' '---------' '---------' '---------'

for seed_dir in "$SCENARIOS_DIR"/*/seed; do
  [[ -d "$seed_dir" ]] || continue
  scenario="$(basename "$(dirname "$seed_dir")")"
  [[ -z "$only" || "$only" == "$scenario" ]] || continue
  rubric="$SCENARIOS_DIR/$scenario/rubric.sh"
  [[ -f "$rubric" ]] || continue

  workspace="$WORK/$scenario"
  mkdir -p "$workspace"
  cp -R "$seed_dir/." "$workspace/" 2>/dev/null || true
  # The rubrics ask git what changed, so the seed has to be a committed tree.
  git -C "$workspace" init -q 2>/dev/null || true
  git -C "$workspace" config user.email seed@example.test 2>/dev/null || true
  git -C "$workspace" config user.name "Seed" 2>/dev/null || true
  git -C "$workspace" add -A >/dev/null 2>&1 || true
  git -C "$workspace" commit -qm "seed" >/dev/null 2>&1 || true

  # A subshell per rubric, so one scenario's definitions cannot answer for the
  # next — the same reason score_scenario unsets them between runs.
  (
    set +e
    # shellcheck disable=SC1090
    source "$rubric" 2>/dev/null
    for check in rubric_correctness rubric_test_quality rubric_robustness rubric_issue_detection; do
      if declare -f "$check" >/dev/null 2>&1; then
        value=$("$check" "$workspace" 2>/dev/null)
        [[ "$value" =~ ^[0-9]+$ ]] || value='?'
      else
        value='-'
      fi
      printf '%s ' "$value"
    done
    printf '\n'
  ) > "$WORK/$scenario.scores" 2>/dev/null

  read -r correctness tests robustness issues < "$WORK/$scenario.scores"
  printf '%-34s %9s %9s %9s %9s\n' \
    "$scenario" "${correctness:-?}" "${tests:-?}" "${robustness:-?}" "${issues:-?}"
done

printf '\n%s\n' "- is the floor: what an agent scores for changing nothing."
printf '%s\n' "? means the check answered with something that is not a number."
printf '%s\n' "- means the rubric does not define that check."
