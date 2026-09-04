#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-review-capacity.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_REVIEW_CAPACITY_DIR="$TMP_DIR/capacity"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
# shellcheck disable=SC1091
source "$ROOT/tests/helpers.sh"
# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

assert_eq "2" "$(DEX_REVIEW_MAX_ACTIVE_WAVES=2 dx_review_capacity_limit)" \
  "explicit host review-wave capacity"
if DEX_REVIEW_MAX_ACTIVE_WAVES=0 dx_review_capacity_limit >/dev/null 2>&1; then
  printf 'zero host review-wave capacity was accepted\n' >&2
  exit 1
fi
if DEX_REVIEW_MAX_ACTIVE_WAVES=9 dx_review_capacity_limit >/dev/null 2>&1; then
  printf 'oversized host review-wave capacity was accepted\n' >&2
  exit 1
fi

assert_eq "3" "$(__dx_review_scout_parallelism 3 1)" \
  "single-wave scout parallelism"
assert_eq "1" "$(__dx_review_scout_parallelism 3 2)" \
  "multi-wave scout parallelism"
assert_eq "2" "$(DEX_REVIEW_SCOUT_PARALLELISM=2 __dx_review_scout_parallelism 3 1)" \
  "explicit scout parallelism"
assert_eq "2" "$(DEX_REVIEW_SCOUT_PARALLELISM=3 __dx_review_scout_parallelism 2 1)" \
  "scout parallelism bounded by group count"
if DEX_REVIEW_SCOUT_PARALLELISM=0 __dx_review_scout_parallelism 3 1 >/dev/null 2>&1; then
  printf 'zero scout parallelism was accepted\n' >&2
  exit 1
fi

assert_eq "2" "$(DEX_REVIEW_TEST_JOBS=2 __dx_review_test_jobs 8)" \
  "explicit review test-job budget"
assert_eq "2" "$(__dx_review_test_jobs 8 2)" \
  "test-job budget accounts for concurrent review waves"
if DEX_REVIEW_TEST_JOBS=0 __dx_review_test_jobs 8 >/dev/null 2>&1; then
  printf 'zero review test-job budget was accepted\n' >&2
  exit 1
fi
assert_eq "timeout" "$(__dx_review_provider_failure_class 124)" \
  "provider timeout classification"
assert_eq "signal-terminated" "$(__dx_review_provider_failure_class 143)" \
  "provider signal classification"
assert_eq "provider-exit" "$(__dx_review_provider_failure_class 7)" \
  "generic provider failure classification"

dx_review_capacity_enqueue session-holder holder
dx_review_capacity_try_acquire session-holder holder 1
assert_eq "1" "$(dx_review_capacity_active_count)" \
  "one active review-wave lease"

# FIFO order is established when callers enqueue, not by which polling process
# happens to wake first.
dx_review_capacity_enqueue session-first first
dx_review_capacity_enqueue session-second second
if dx_review_capacity_try_acquire session-second second 1; then
  printf 'later review waiter bypassed the FIFO queue\n' >&2
  exit 1
fi
dx_review_capacity_release holder
dx_review_capacity_try_acquire session-first first 1
if dx_review_capacity_try_acquire session-second second 1; then
  printf 'second review waiter acquired a full capacity pool\n' >&2
  exit 1
fi
dx_review_capacity_release first
dx_review_capacity_try_acquire session-second second 1
dx_review_capacity_release second
assert_eq "0" "$(dx_review_capacity_active_count)" \
  "review-wave leases released"

# A process that exits without releasing its lease must not strand the host.
(
  dx_review_capacity_enqueue session-stale stale
  dx_review_capacity_try_acquire session-stale stale 1
) &
stale_pid=$!
wait "$stale_pid"

dx_review_capacity_enqueue session-after-stale after-stale
dx_review_capacity_try_acquire session-after-stale after-stale 1
dx_review_capacity_release after-stale

# Several independent review owners may queue at once, but the shared lease
# count must never exceed the configured host limit.
stress_results="$TMP_DIR/stress-results"
stress_pids=""
for stress_index in 1 2 3 4 5 6 7 8; do
  (
    stress_token="stress-${stress_index}"
    DX_REVIEW_CAPACITY_RECHECK_SECONDS=1 \
      dx_review_capacity_wait "session-${stress_token}" "$stress_token" 2
    stress_active="$(dx_review_capacity_active_count)"
    printf '%s\t%s\n' "$stress_token" "$stress_active" >> "$stress_results"
    /bin/sleep 0.1
    dx_review_capacity_release "$stress_token"
  ) &
  stress_pids="${stress_pids} $!"
done
for stress_pid in $stress_pids; do
  wait "$stress_pid"
done
assert_eq "8" "$(wc -l < "$stress_results" | tr -d ' ')" \
  "all concurrent review waiters acquired a lease"
stress_max_active="$(awk -F '\t' 'BEGIN { max = 0 } $2 > max { max = $2 } END { print max }' "$stress_results")"
[[ "$stress_max_active" -le 2 ]] || fail "host review capacity exceeded its configured limit"
assert_eq "0" "$(dx_review_capacity_active_count)" \
  "concurrent review leases released"

# The blocking helper observes cancellation and removes its waiter record.
dx_review_capacity_enqueue session-blocker blocker
dx_review_capacity_try_acquire session-blocker blocker 1
cancel_file="$TMP_DIR/cancel"
cancel_check() {
  [[ -f "$cancel_file" ]]
}
touch "$cancel_file"
set +e
DX_REVIEW_CAPACITY_RECHECK_SECONDS=1 \
  dx_review_capacity_wait session-cancelled cancelled 1 cancel_check
wait_rc=$?
set -e
assert_eq "125" "$wait_rc" "capacity wait cancellation"
dx_review_capacity_release blocker
if [[ -e "$DX_REVIEW_CAPACITY_DIR/wait-cancelled" \
  || -e "$DX_REVIEW_CAPACITY_DIR/lease-cancelled" ]]; then
  printf 'cancelled review capacity record survived\n' >&2
  exit 1
fi

[[ "$(dx_path_mode "$DX_REVIEW_CAPACITY_DIR")" == "700" ]] || assert_at $LINENO

printf 'review-capacity-test passed\n'
