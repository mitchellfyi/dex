#!/usr/bin/env bash
# Run every tests/*-test.sh, in parallel, with a per-test timeout.
#
# A test whose assertions are wall-clock bounds cannot share the machine with
# seven others. Those declare themselves with a `# dex-test-lane: serial` line
# and run one at a time, after the parallel batch has finished — the fact lives
# with the test, so adding one does not mean editing this runner.
#
# Usage:
#   bash tests/run-all.sh                 # all tests
#   bash tests/run-all.sh review worktree # only tests whose name matches a filter
#
# Environment:
#   DX_TEST_JOBS      concurrent tests (default: CPU count, max 8)
#   DX_TEST_TIMEOUT   per-test timeout in seconds (default: 1200)
#   DX_TEST_LOG_DIR   where to keep logs (default: a mktemp dir)
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JOBS="${DX_TEST_JOBS:-}"
TIMEOUT="${DX_TEST_TIMEOUT:-1200}"
LOG_DIR="${DX_TEST_LOG_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/dex-test-run.XXXXXX")}"

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
for path in "$ROOT"/tests/*-test.sh; do
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

# Split off the tests that measure elapsed time. The marker is read from the
# head of the file so a test declares its own lane.
parallel_tests=""
serial_tests=""
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  if head -40 "$ROOT/tests/$name" | grep -q '^# dex-test-lane: serial'; then
    serial_tests="${serial_tests}${name}"$'\n'
  else
    parallel_tests="${parallel_tests}${name}"$'\n'
  fi
done <<EOF
$tests
EOF
serial_total="$(printf '%s' "$serial_tests" | grep -c . || true)"

if [[ "$serial_total" -gt 0 ]]; then
  printf 'running %s test(s): %s at a time, then %s in a serial lane, %ss timeout\n' \
    "$total" "$JOBS" "$serial_total" "$TIMEOUT"
else
  printf 'running %s test(s), %s at a time, %ss timeout\n' "$total" "$JOBS" "$TIMEOUT"
fi

run_one() {
  local name="$1" start end rc
  start=$(date +%s)
  # </dev/null matters: a test that reads stdin would otherwise consume the
  # runner's own test list and silently drop every remaining test.
  if command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT" bash "$ROOT/tests/$name" >"$LOG_DIR/$name.log" 2>&1 </dev/null
    rc=$?
  else
    perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" bash "$ROOT/tests/$name" \
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
