#!/usr/bin/env bash
# Rubric for: template
# Each rubric_* function receives the workspace path and returns a score 0-100.

rubric_correctness() {
  local ws="$1"
  local score=0
  # TODO: Add correctness checks
  echo "$score"
}

rubric_test_quality() {
  local ws="$1"
  local score=0
  # TODO: Add test quality checks
  echo "$score"
}

rubric_robustness() {
  local ws="$1"
  : "$ws"
  local score=0
  # TODO: Add robustness checks
  echo "$score"
}
