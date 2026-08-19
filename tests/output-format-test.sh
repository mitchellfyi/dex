#!/usr/bin/env bash
set -euo pipefail

# Tests for lib/output.sh formatting helpers.
#
# dx_format_duration is the one duration formatter: the lifecycle banner, the
# Phase 3 wait notices, and the env-var tables in AGENTS.md and
# docs/autonomous-mode.md all show its output, so a change here is visible to
# users in several places at once. It also runs under both shells — dx.sh
# sources lib/ from zsh, hooks source it from bash — so each case is checked in
# both.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck disable=SC1091
source "$ROOT/tests/helpers.sh"

format_in() {
  local shell="$1" seconds="$2"
  "$shell" -c 'source "$1/lib/output.sh"; dx_format_duration "$2"' _ "$ROOT" "$seconds"
}

check_duration() {
  local seconds="$1" expected="$2" shell
  for shell in bash zsh; do
    command -v "$shell" >/dev/null 2>&1 || continue
    assert_eq "$expected" "$(format_in "$shell" "$seconds")" "dx_format_duration ${seconds} under ${shell}"
  done
}

check_duration 0 '0s'
check_duration 1 '1s'
check_duration 45 '45s'
check_duration 59 '59s'
# The minute boundary: below it the minutes field is dropped entirely.
check_duration 60 '1m 0s'
check_duration 61 '1m 1s'
check_duration 900 '15m 0s'
check_duration 3599 '59m 59s'
# The hour boundary: seconds stop carrying information, so they are dropped.
check_duration 3600 '1h 0m'
check_duration 3661 '1h 1m'
check_duration 86400 '24h 0m'
# A config file may spell a duration with a leading zero. Shell arithmetic and
# printf both read that as octal, which silently reported the wrong duration.
check_duration 090 '1m 30s'
check_duration 045 '45s'
# Not a whole number of seconds: pass it through rather than invent a value.
check_duration '' ''
check_duration 'unknown' 'unknown'
check_duration '-5' '-5'
check_duration '1.5' '1.5'

printf 'output-format: dx_format_duration cases passed\n'
