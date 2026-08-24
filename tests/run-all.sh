#!/usr/bin/env bash
# Run every tests/*-test.sh with a per-test timeout.
#
# Local service fixtures run first in the exclusive `service` lane. Tests whose
# assertions are wall-clock bounds use the exclusive `serial` lane after the
# parallel batch. A `# dex-test-lane: <lane>` line near the top of the test
# keeps its resource requirement with the test itself.
#
# Usage:
#   bash tests/run-all.sh                 # all tests
#   bash tests/run-all.sh review worktree # only tests whose name matches a filter
#
# Environment:
#   DX_TEST_JOBS      concurrent tests (default: CPU count, max 8)
#   DX_TEST_TIMEOUT   per-test timeout in seconds (default: 1200)
#   DX_TEST_LOG_DIR   where to keep logs (default: a mktemp dir)
#   DX_TEST_SUITE_DIR test discovery directory (default: tests/; for runner tests)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUITE_DIR="${DX_TEST_SUITE_DIR:-$ROOT/tests}"
JOBS="${DX_TEST_JOBS:-}"
TIMEOUT="${DX_TEST_TIMEOUT:-1200}"
LOG_DIR="${DX_TEST_LOG_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/dex-test-run.XXXXXX")}"

if [[ ! -d "$SUITE_DIR" ]]; then
  printf 'test suite directory does not exist: %s\n' "$SUITE_DIR" >&2
  exit 1
fi

if [[ -z "$JOBS" ]]; then
  JOBS=$( { getconf _NPROCESSORS_ONLN || sysctl -n hw.ncpu || echo 4; } 2>/dev/null )
  [[ "$JOBS" =~ ^[0-9]+$ ]] || JOBS=4
  [[ "$JOBS" -gt 8 ]] && JOBS=8
fi

mkdir -p "$LOG_DIR"

missing=""
for tool in zsh python3 git; do
  command -v "$tool" >/dev/null 2>&1 || missing="${missing} ${tool}"
done
if [[ -n "$missing" ]]; then
  printf 'missing required tools:%s\n' "$missing" >&2
  exit 1
fi

tests=""
for path in "$SUITE_DIR"/*-test.sh; do
  [[ -f "$path" ]] || continue
  name="$(basename "$path")"
  if [[ $# -gt 0 ]]; then
    matched=0
    for filter in "$@"; do
      case "$name" in
        *"$filter"*) matched=1; break ;;
      esac
    done
    [[ $matched -eq 1 ]] || continue
  fi
  tests="${tests}${name}"$'\n'
done
tests="$(printf '%s' "$tests" | sed '/^$/d')"

if [[ -z "$tests" ]]; then
  printf 'no tests matched\n' >&2
  exit 1
fi

total="$(printf '%s\n' "$tests" | wc -l | tr -d ' ')"

# Service fixtures get the machine first, one at a time. Timing-sensitive
# tests also run alone after the parallel batch. Each test declares its lane
# near the top of its own file.
parallel_tests=""
service_tests=""
serial_tests=""
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  lane=$(awk 'NR > 40 { exit } /^# dex-test-lane: / { print $3; exit }' "$SUITE_DIR/$name")
  case "$lane" in
    service) service_tests="${service_tests}${name}"$'\n' ;;
    serial) serial_tests="${serial_tests}${name}"$'\n' ;;
    "") parallel_tests="${parallel_tests}${name}"$'\n' ;;
    *)
      printf 'unknown test lane %s in %s\n' "$lane" "$name" >&2
      exit 1
      ;;
  esac
done <<EOF
$tests
EOF
service_total="$(printf '%s' "$service_tests" | grep -c . || true)"
serial_total="$(printf '%s' "$serial_tests" | grep -c . || true)"

printf 'running %s test(s): %s in the service lane, up to %s parallel, then %s in the serial lane, %ss timeout\n' \
  "$total" "$service_total" "$JOBS" "$serial_total" "$TIMEOUT"

run_one() {
  local name="$1" start end rc
  start=$(date +%s)
  # </dev/null matters: a test that reads stdin would otherwise consume the
  # runner's own test list and silently drop every remaining test.
  if command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT" bash "$SUITE_DIR/$name" >"$LOG_DIR/$name.log" 2>&1 </dev/null
    rc=$?
  else
    perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" bash "$SUITE_DIR/$name" \
      >"$LOG_DIR/$name.log" 2>&1 </dev/null
    rc=$?
  fi
  end=$(date +%s)
  if [[ $rc -eq 0 ]]; then
    printf 'PASS %s (%ss)\n' "$name" "$((end - start))"
  else
    printf 'FAIL(%s) %s (%ss)\n' "$rc" "$name" "$((end - start))"
  fi
  printf '%s\n' "$rc" > "$LOG_DIR/$name.rc"
}

# Local HTTP fixtures bind ports and start Python worker threads. Running them
# alone prevents host resource pressure from turning startup into a race.
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  run_one "$name" </dev/null
done <<EOF
$service_tests
EOF

# Throttle with `jobs -pr` rather than `wait -n`, which bash 3.2 (the macOS
# system bash) does not support.
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  while [[ "$(jobs -pr | wc -l | tr -d ' ')" -ge "$JOBS" ]]; do
    sleep 0.2
  done
  run_one "$name" </dev/null &
done <<EOF
$parallel_tests
EOF
wait

# The serial lane, on a machine the runner has stopped loading.
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  run_one "$name" </dev/null
done <<EOF
$serial_tests
EOF

passed=0
failed=""
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  if [[ ! -f "$LOG_DIR/$name.rc" ]]; then
    printf 'DID NOT RUN %s\n' "$name" >&2
    failed="${failed} ${name}"
    continue
  fi
  rc="$(cat "$LOG_DIR/$name.rc")"
  if [[ "$rc" == "0" ]]; then
    passed=$((passed + 1))
  else
    failed="${failed} ${name}"
  fi
done <<EOF
$tests
EOF

printf '\n== %s passed, %s failed ==\n' "$passed" "$(printf '%s' "$failed" | wc -w | tr -d ' ')"
if [[ -n "$failed" ]]; then
  for name in $failed; do
    printf '\n--- %s (last 40 lines) ---\n' "$name"
    tail -40 "$LOG_DIR/$name.log" 2>/dev/null
    # Several tests assert with a bare `[[ … ]]` under `set -e`, which exits
    # without printing anything. "FAIL(1)" over an empty log says only that
    # something went wrong, so name the command that shows what.
    if [[ ! -s "$LOG_DIR/$name.log" ]]; then
      printf '(no output — this test asserts silently)\n'
      printf 'to see the failing line: bash -x tests/%s\n' "$name"
    fi
  done
  printf '\nfull logs: %s\n' "$LOG_DIR"
  exit 1
fi

printf 'logs: %s\n' "$LOG_DIR"
