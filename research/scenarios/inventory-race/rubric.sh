#!/usr/bin/env bash
# Rubric for: inventory-race
# Scored from compare/hidden, so research/run.sh and research/compare grade
# the same behaviour. Correctness is the reported bugs and the documented
# contract; robustness is the same bug classes reached another way.

_INVENTORY_RACE_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_INVENTORY_RACE_SCORE="$_INVENTORY_RACE_DIR/../../compare/hidden_score.py"

rubric_correctness() {
  python3 "$_INVENTORY_RACE_SCORE" "$_INVENTORY_RACE_DIR" "$1" groups spec,preserve
}

rubric_test_quality() {
  python3 "$_INVENTORY_RACE_SCORE" "$_INVENTORY_RACE_DIR" "$1" tests
}

rubric_robustness() {
  python3 "$_INVENTORY_RACE_SCORE" "$_INVENTORY_RACE_DIR" "$1" groups robust
}
