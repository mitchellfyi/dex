#!/usr/bin/env bash
set -euo pipefail

# dex-test-lane: serial
# Asserts the review pass timeout terminates its process tree within 8s.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-review-timeout-test.XXXXXX")"

cleanup() {
  local pid
  if [[ -d "$TMP_DIR" ]]; then
    while IFS= read -r pid; do
      [[ "$pid" =~ ^[0-9]+$ ]] || continue
      kill -KILL "$pid" 2>/dev/null || true
    done < <(find "$TMP_DIR" -type f -name '*.pid' -exec cat {} \; 2>/dev/null || true)
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

export DEX_DIR="$ROOT"
export HOME="$TMP_DIR/home"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

TIMEOUT_TERMINATE_COUNT_FILE="$TMP_DIR/terminate-calls"
timeout_terminate_definition=$(declare -f __dx_timeout_terminate_processes)
eval "${timeout_terminate_definition/__dx_timeout_terminate_processes/__dx_timeout_terminate_processes_impl}"
__dx_timeout_terminate_processes() {
  printf 'call\n' >> "$TIMEOUT_TERMINATE_COUNT_FILE"
  __dx_timeout_terminate_processes_impl "$@"
}


wait_for_file() {
  local file="$1" label="$2" attempt=0
  while [[ ! -s "$file" && $attempt -lt 100 ]]; do
    /bin/sleep 0.05
    attempt=$((attempt + 1))
  done
  if [[ ! -s "$file" ]]; then
    printf '%s: child PID file was not written\n' "$label" >&2
    exit 1
  fi
}

assert_process_gone() {
  local pid="$1" label="$2" attempt=0
  while kill -0 "$pid" 2>/dev/null && [[ $attempt -lt 100 ]]; do
    /bin/sleep 0.05
    attempt=$((attempt + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    printf '%s: descendant %s survived cleanup\n' "$label" "$pid" >&2
    kill -KILL "$pid" 2>/dev/null || true
    exit 1
  fi
}

spawn_resistant_descendant() {
  local pid_file="$1"
  bash -c '
    trap "" INT TERM HUP
    printf "%s\n" "$$" > "$1"
    while :; do
      /bin/sleep 1
    done
  ' _ "$pid_file" &
  wait "$!"
}

spawn_background_and_exit() {
  local pid_file="$1" status="$2"
  /bin/sleep 30 &
  printf '%s\n' "$!" > "$pid_file"
  return "$status"
}

# A timeout must finish TERM-to-KILL escalation even after the command root exits.
timeout_pid_file="$TMP_DIR/timeout-child.pid"
started_epoch=$(date +%s)
set +e
dx_run_with_timeout 1 spawn_resistant_descendant "$timeout_pid_file"
timeout_status=$?
set -e
timeout_elapsed=$(( $(date +%s) - started_epoch ))
assert_eq "124" "$timeout_status" "timeout status"
assert_eq "1" "$(wc -l < "$TIMEOUT_TERMINATE_COUNT_FILE" | tr -d ' ')" "timeout full termination passes"
wait_for_file "$timeout_pid_file" "timeout cleanup"
assert_process_gone "$(cat "$timeout_pid_file")" "timeout cleanup"
if [[ $timeout_elapsed -gt 8 ]]; then
  printf 'timeout cleanup: expected bounded runtime, took %ss\n' "$timeout_elapsed" >&2
  exit 1
fi

# A successful or failing command must not daemonize work past its return.
normal_pid_file="$TMP_DIR/normal-child.pid"
set +e
dx_run_with_timeout 5 spawn_background_and_exit "$normal_pid_file" 37
normal_status=$?
set -e
assert_eq "37" "$normal_status" "normal command status"
wait_for_file "$normal_pid_file" "normal exit cleanup"
assert_process_gone "$(cat "$normal_pid_file")" "normal exit cleanup"

run_signal_case() {
  local signal="$1" expected_status="$2" label="$3"
  local pid_file="$TMP_DIR/${signal}-child.pid" helper_pid helper_status

  set +e
  dx_run_with_timeout 0 spawn_resistant_descendant "$pid_file" &
  helper_pid=$!
  set -e
  wait_for_file "$pid_file" "$label"
  kill "-$signal" "$helper_pid"
  set +e
  wait "$helper_pid"
  helper_status=$?
  set -e
  assert_eq "$expected_status" "$helper_status" "$label status"
  assert_process_gone "$(cat "$pid_file")" "$label"
}

run_signal_case TERM 143 "TERM cleanup"
run_signal_case HUP 129 "HUP cleanup"

# Exercise the same normal-exit cleanup through non-interactive zsh. The child
# program is passed through the environment to avoid shell-specific quoting.
zsh_pid_file="$TMP_DIR/zsh-child.pid"
# shellcheck disable=SC2016  # expanded by the child /bin/sh, not this test shell
zsh_program='/bin/sleep 30 & printf "%s\n" "$!" > "$1"; exit 23'
set +e
DEX_TIMEOUT_TEST_PROGRAM="$zsh_program" \
DEX_TIMEOUT_TEST_PID_FILE="$zsh_pid_file" \
  zsh -fc '
    source "$DEX_DIR/lib/common.sh"
    dx_run_with_timeout 5 /bin/sh -c "$DEX_TIMEOUT_TEST_PROGRAM" _ "$DEX_TIMEOUT_TEST_PID_FILE"
  '
zsh_status=$?
set -e
assert_eq "23" "$zsh_status" "zsh command status"
wait_for_file "$zsh_pid_file" "zsh normal exit cleanup"
assert_process_gone "$(cat "$zsh_pid_file")" "zsh normal exit cleanup"

printf 'review-timeout-test passed\n'
