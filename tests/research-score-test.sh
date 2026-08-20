#!/usr/bin/env bash
set -euo pipefail

# score_scenario turns a rubric's answers into the number a benchmark run
# reports, and had no coverage at all. What matters most is the difference
# between "the agent scored badly" and "the rubric did not run": both used to
# come out as 0, with the rubric's error thrown away.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-research-score-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export RESEARCH_DIR="$TMP_DIR/research"
mkdir -p "$RESEARCH_DIR"

# shellcheck disable=SC1091
source "$ROOT/research/lib/common.sh"
# shellcheck disable=SC1091
source "$ROOT/research/lib/score.sh"

SCENARIOS_DIR="$TMP_DIR/scenarios"
WORKSPACES_DIR="$TMP_DIR/workspaces"
mkdir -p "$SCENARIOS_DIR" "$WORKSPACES_DIR"

# Point the path helpers at the fixture tree without depending on how the real
# ones are spelled.
scenario_dir() { printf '%s/%s\n' "$SCENARIOS_DIR" "$1"; }
workspace_dir() { printf '%s/%s\n' "$WORKSPACES_DIR" "$1"; }
json_write() { printf '%s\n' "$2" > "$1"; }

# One weight only, so the total is whichever value correctness reported.
W_CORRECTNESS=100 W_TEST_QUALITY=0 W_ROBUSTNESS=0
W_VERIFICATION=0 W_ISSUE_DETECTION=0 W_CODE_QUALITY=0

make_scenario() {
  local name="$1" body="$2"
  mkdir -p "$SCENARIOS_DIR/$name" "$WORKSPACES_DIR/$name"
  printf '%s\n' "$body" > "$SCENARIOS_DIR/$name/rubric.sh"
}

score() {
  local name="$1"
  local out="$TMP_DIR/$name.result"
  mkdir -p "$out"
  score_scenario "$name" "$out" skip-llm 2> "$TMP_DIR/$name.err"
}

# A rubric that works: its number is the score.
make_scenario good 'rubric_correctness() { printf "77\n"; }
rubric_test_quality() { printf "0\n"; }
rubric_robustness() { printf "0\n"; }
_score_verification() { printf "0\n"; }
_score_issue_detection_default() { printf "0\n"; }'
assert_eq "77" "$(score good)" "a working rubric reports its own number"

# A rubric that scores the agent zero. This is a real result and must stay
# quiet — it is the case the broken ones have to be told apart from.
make_scenario zero 'rubric_correctness() { printf "0\n"; }
rubric_test_quality() { printf "0\n"; }
rubric_robustness() { printf "0\n"; }
_score_verification() { printf "0\n"; }
_score_issue_detection_default() { printf "0\n"; }'
assert_eq "0" "$(score zero)" "a genuine zero"
if grep -q 'rubric check' "$TMP_DIR/zero.err"; then
  printf 'a genuine zero was reported as a broken rubric:\n' >&2
  cat "$TMP_DIR/zero.err" >&2
  exit 1
fi

# A rubric that fails outright. Still scores 0 — the run should continue — but
# it must say so, or a broken rubric reads as a failing agent.
make_scenario crashing 'rubric_correctness() { return 3; }
rubric_test_quality() { printf "0\n"; }
rubric_robustness() { printf "0\n"; }
_score_verification() { printf "0\n"; }
_score_issue_detection_default() { printf "0\n"; }'
assert_eq "0" "$(score crashing)" "a crashing rubric still scores"
assert_contains "correctness" "$TMP_DIR/crashing.err"
assert_contains "rubric check failed" "$TMP_DIR/crashing.err"

# A rubric that answers with something that is not a number.
make_scenario garbage 'rubric_correctness() { printf "probably fine\n"; }
rubric_test_quality() { printf "0\n"; }
rubric_robustness() { printf "0\n"; }
_score_verification() { printf "0\n"; }
_score_issue_detection_default() { printf "0\n"; }'
assert_eq "0" "$(score garbage)" "a non-numeric answer still scores"
assert_contains "not a number" "$TMP_DIR/garbage.err"

# Whatever the rubric said on stderr is worth seeing when it failed, because
# that is the only description of what went wrong.
make_scenario noisy 'rubric_correctness() { printf "cannot find the go toolchain\n" >&2; return 1; }
rubric_test_quality() { printf "0\n"; }
rubric_robustness() { printf "0\n"; }
_score_verification() { printf "0\n"; }
_score_issue_detection_default() { printf "0\n"; }'
score noisy > /dev/null
assert_contains "cannot find the go toolchain" "$TMP_DIR/noisy.err"

printf 'research score tests passed\n'
