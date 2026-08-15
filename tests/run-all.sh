#!/usr/bin/env bash
# Run every tests/*-test.sh, in parallel, with a per-test timeout.
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
printf 'running %s test(s), %s at a time, %ss timeout\n' "$total" "$JOBS" "$TIMEOUT"

run_one() {
  local name="$1" start end rc
  start=$(date +%s)
  if command -v timeout >/dev/null 2>&1; then
    timeout "$TIMEOUT" bash "$ROOT/tests/$name" >"$LOG_DIR/$name.log" 2>&1
    rc=$?
  else
    perl -e 'alarm shift; exec @ARGV' "$TIMEOUT" bash "$ROOT/tests/$name" \
      >"$LOG_DIR/$name.log" 2>&1
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

running=0
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  run_one "$name" &
  running=$((running + 1))
  if [[ $running -ge $JOBS ]]; then
    wait -n 2>/dev/null || wait
    running=$((running - 1))
  fi
done <<EOF
$tests
EOF
wait

passed=0
failed=""
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  rc="$(cat "$LOG_DIR/$name.rc" 2>/dev/null || echo 1)"
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
  done
  printf '\nfull logs: %s\n' "$LOG_DIR"
  exit 1
fi

printf 'logs: %s\n' "$LOG_DIR"
