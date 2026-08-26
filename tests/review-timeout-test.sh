#!/usr/bin/env bash
set -euo pipefail
umask 077

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
TIMEOUT_SCAN_COUNT_FILE="$TMP_DIR/token-scan-calls"
timeout_terminate_definition=$(declare -f __dx_timeout_terminate_processes)
eval "${timeout_terminate_definition/__dx_timeout_terminate_processes/__dx_timeout_terminate_processes_impl}"
__dx_timeout_terminate_processes() {
  printf 'call\n' >> "$TIMEOUT_TERMINATE_COUNT_FILE"
  __dx_timeout_terminate_processes_impl "$@"
}
timeout_scan_definition=$(declare -f __dx_timeout_token_pids)
eval "${timeout_scan_definition/__dx_timeout_token_pids/__dx_timeout_token_pids_impl}"
__dx_timeout_token_pids() {
  printf 'scan\n' >> "$TIMEOUT_SCAN_COUNT_FILE"
  __dx_timeout_token_pids_impl "$@"
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
timeout_scans=$(wc -l < "$TIMEOUT_SCAN_COUNT_FILE" | tr -d ' ')
if [[ "$timeout_scans" -lt 2 || "$timeout_scans" -gt 3 ]]; then
  printf 'timeout cleanup: expected 2-3 token scans, got %s\n' \
    "$timeout_scans" >&2
  exit 1
fi
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
normal_cumulative_scans=$(wc -l < "$TIMEOUT_SCAN_COUNT_FILE" | tr -d ' ')
if [[ "$normal_cumulative_scans" -lt 3 || "$normal_cumulative_scans" -gt 5 ]]; then
  printf 'normal exit cleanup: expected 3-5 cumulative token scans, got %s\n' \
    "$normal_cumulative_scans" >&2
  exit 1
fi
wait_for_file "$normal_pid_file" "normal exit cleanup"
assert_process_gone "$(cat "$normal_pid_file")" "normal exit cleanup"

# The grace-period KILL must use a fresh token scan. Reusing the TERM list can
# target an unrelated process if a child exits and its PID is recycled.
stale_pid_probe="$TMP_DIR/stale-pid-signals"
stale_pid_scan_counter="$TMP_DIR/stale-pid-scans"
printf '0\n' > "$stale_pid_scan_counter"
(
  __dx_timeout_token_pids() {
    probe_scan=$(cat "$stale_pid_scan_counter")
    probe_scan=$((probe_scan + 1))
    printf '%s\n' "$probe_scan" > "$stale_pid_scan_counter"
    if [[ "$probe_scan" -eq 1 ]]; then
      printf '%s\n' 4242
    else
      printf '%s\n' 4343
    fi
  }
  __dx_timeout_pid_list_alive() { return 0; }
  __dx_timeout_signal_pid_list() {
    printf '%s\t%s\t%s\n' "$3" "${2:-none}" "$1" >> "$stale_pid_probe"
  }
  sleep() { return 0; }
  __dx_timeout_terminate_processes unused-token 4242
)
assert_eq $'TERM\t4242\t' "$(sed -n '1p' "$stale_pid_probe")" \
  "TERM reaches the owned root before token scanning"
assert_eq $'TERM\tnone\t4242' "$(sed -n '2p' "$stale_pid_probe")" \
  "TERM uses the validated token scan for descendants"
assert_eq $'KILL\tnone\t4343' "$(sed -n '3p' "$stale_pid_probe")" \
  "KILL uses only the fresh token scan"

# A running supervisor re-reads the attributed policy instead of freezing the
# value present at provider launch.
LIVE_TIMEOUT_SESSION="repo-live-timeout-main"
(
  /bin/sleep 0.2
  dx_override_set "$LIVE_TIMEOUT_SESSION" review.pass-timeout 4 phase 3 \
    human "Extend the running provider deadline" 0
) &
live_writer_pid=$!
set +e
dx_run_with_live_timeout "$LIVE_TIMEOUT_SESSION" review.pass-timeout 2 3 1 \
  /bin/sleep 3
live_timeout_status=$?
set -e
wait "$live_writer_pid"
assert_eq "0" "$live_timeout_status" "live timeout extension"

dx_override_clear "$LIVE_TIMEOUT_SESSION" review.pass-timeout phase 3 human \
  "Restore the default before testing disable"
(
  /bin/sleep 0.2
  dx_override_set "$LIVE_TIMEOUT_SESSION" review.pass-timeout 0 phase 3 \
    human "Disable the running provider deadline" 0
) &
live_writer_pid=$!
set +e
dx_run_with_live_timeout "$LIVE_TIMEOUT_SESSION" review.pass-timeout 2 3 1 \
  /bin/sleep 3
live_timeout_status=$?
set -e
wait "$live_writer_pid"
assert_eq "0" "$live_timeout_status" "live timeout disable"

dx_override_clear "$LIVE_TIMEOUT_SESSION" review.pass-timeout phase 3 human \
  "Restore the default before testing a shorter deadline"
(
  /bin/sleep 0.2
  dx_override_set "$LIVE_TIMEOUT_SESSION" review.pass-timeout 1 phase 3 \
    human "Shorten the running provider deadline" 0
) &
live_writer_pid=$!
set +e
dx_run_with_live_timeout "$LIVE_TIMEOUT_SESSION" review.pass-timeout 5 3 1 \
  /bin/sleep 3
live_timeout_status=$?
set -e
wait "$live_writer_pid"
assert_eq "124" "$live_timeout_status" "live timeout shortening"

dx_override_set "$LIVE_TIMEOUT_SESSION" review.pass-timeout 0 phase 3 human \
  "Start without a provider deadline" 0
(
  /bin/sleep 0.2
  dx_override_clear "$LIVE_TIMEOUT_SESSION" review.pass-timeout phase 3 human \
    "Restore the default provider deadline"
) &
live_writer_pid=$!
set +e
dx_run_with_live_timeout "$LIVE_TIMEOUT_SESSION" review.pass-timeout 1 3 1 \
  /bin/sleep 3
live_timeout_status=$?
set -e
wait "$live_writer_pid"
assert_eq "124" "$live_timeout_status" "live timeout restore"

run_signal_case() {
  local signal="$1" expected_status="$2" label="$3"
  local pid_file="$TMP_DIR/${signal}-child.pid" helper_pid helper_status alarm_pid

  set +e
  dx_run_with_timeout 0 spawn_resistant_descendant "$pid_file" &
  helper_pid=$!
  set -e
  wait_for_file "$pid_file" "$label"
  kill "-$signal" "$helper_pid"
  # Bound the wait. An unbounded one turns "the signal never arrived" into the
  # whole per-test budget and a FAIL over an empty log — which is what nohup,
  # or any supervisor that starts the suite with a signal ignored, produces:
  # an ignored disposition is inherited across fork and exec by every
  # descendant, and a child cannot reset it.
  ( /bin/sleep 20; kill -KILL "$helper_pid" 2>/dev/null || true ) &
  alarm_pid=$!
  set +e
  wait "$helper_pid"
  helper_status=$?
  set -e
  kill -KILL "$alarm_pid" 2>/dev/null || true
  wait "$alarm_pid" 2>/dev/null || true
  if [[ "$helper_status" -eq 137 && "$expected_status" -ne 137 ]]; then
    printf '%s: SIG%s never reached the helper — only the alarm ended it.\n' "$label" "$signal" >&2
    printf '  SIG%s looks ignored in this environment. Re-run without nohup\n' "$signal" >&2
    printf '  (or whatever else set it to ignored); the disposition is\n' >&2
    printf '  inherited by every descendant, including this test.\n' >&2
    exit 1
  fi
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
