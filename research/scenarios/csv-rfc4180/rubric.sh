#!/usr/bin/env bash
# Rubric for: csv-rfc4180
# Scored from compare/hidden, so research/run.sh and research/compare grade
# the same behaviour. Correctness is the spec's rules one at a time;
# robustness is the rules combined and at their edges.

_CSV_RFC4180_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
_CSV_RFC4180_SCORE="$_CSV_RFC4180_DIR/../../compare/hidden_score.py"

rubric_correctness() {
  python3 "$_CSV_RFC4180_SCORE" "$_CSV_RFC4180_DIR" "$1" groups spec
}

rubric_test_quality() {
  python3 "$_CSV_RFC4180_SCORE" "$_CSV_RFC4180_DIR" "$1" tests
}

rubric_robustness() {
  python3 "$_CSV_RFC4180_SCORE" "$_CSV_RFC4180_DIR" "$1" groups robust
}
