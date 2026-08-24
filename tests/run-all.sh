#!/usr/bin/env bash
# Run tests declared in tests/manifest.tsv with per-test isolation and timeouts.
#
# Service fixtures run alone first. Fast and slow tests use the parallel lane,
# and timing-sensitive serial tests run alone after the machine is idle.
#
# Usage:
#   bash tests/run-all.sh                 # all tests
#   bash tests/run-all.sh review worktree # names matching either filter
#
# Environment:
#   DX_TEST_JOBS      concurrent fast/slow tests (default: CPU count, max 8)
#   DX_TEST_TIMEOUT   override every manifest timeout
#   DX_TEST_LOG_DIR   where to keep logs (default: a mktemp dir)
#   DX_TEST_SUITE_DIR test discovery directory (default: tests/; for runner tests)
#   DX_TEST_MANIFEST  manifest path (default: <suite>/manifest.tsv)
#   DX_TEST_LANES     comma-separated lanes: fast,slow,service,serial (default: all)
#   DX_TEST_PLATFORM  linux or macos (default: detected)
#   DX_TEST_SHARD     one-based index/total, such as 1/2 (default: 1/1)
#   DX_TEST_REPORT_DIR optional output directory exposed to hermetic test fixtures
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SUITE_DIR="${DX_TEST_SUITE_DIR:-$ROOT/tests}"
MANIFEST="${DX_TEST_MANIFEST:-$SUITE_DIR/manifest.tsv}"
JOBS="${DX_TEST_JOBS:-}"
TIMEOUT_OVERRIDE="${DX_TEST_TIMEOUT:-}"
LOG_DIR="${DX_TEST_LOG_DIR:-$(mktemp -d "${TMPDIR:-/tmp}/dex-test-run.XXXXXX")}"
LANES="${DX_TEST_LANES:-all}"
PLATFORM="${DX_TEST_PLATFORM:-}"
SHARD="${DX_TEST_SHARD:-1/1}"

if [[ ! -d "$SUITE_DIR" ]]; then
  printf 'test suite directory does not exist: %s\n' "$SUITE_DIR" >&2
  exit 1
fi
if [[ ! -f "$MANIFEST" ]]; then
  printf 'test manifest does not exist: %s\n' "$MANIFEST" >&2
  exit 1
fi

if [[ -z "$PLATFORM" ]]; then
  case "$(uname -s)" in
    Darwin) PLATFORM=macos ;;
    Linux) PLATFORM=linux ;;
    *) PLATFORM=other ;;
  esac
fi
case "$PLATFORM" in
  linux|macos|other) ;;
  *)
    printf 'DX_TEST_PLATFORM must be linux, macos, or other\n' >&2
    exit 1
    ;;
esac

if [[ -z "$JOBS" ]]; then
  JOBS=$( { getconf _NPROCESSORS_ONLN || sysctl -n hw.ncpu || echo 4; } 2>/dev/null )
  [[ "$JOBS" =~ ^[0-9]+$ ]] || JOBS=4
  [[ "$JOBS" -gt 8 ]] && JOBS=8
fi
if [[ ! "$JOBS" =~ ^[1-9][0-9]*$ ]]; then
  printf 'DX_TEST_JOBS must be a positive integer\n' >&2
  exit 1
fi
if [[ -n "$TIMEOUT_OVERRIDE" && ! "$TIMEOUT_OVERRIDE" =~ ^[1-9][0-9]*$ ]]; then
  printf 'DX_TEST_TIMEOUT must be a positive integer\n' >&2
  exit 1
fi

shard_index="${SHARD%/*}"
shard_total="${SHARD#*/}"
if [[ "$SHARD" != */* || ! "$shard_index" =~ ^[1-9][0-9]*$ \
  || ! "$shard_total" =~ ^[1-9][0-9]*$ || "$shard_index" -gt "$shard_total" ]]; then
  printf 'DX_TEST_SHARD must be a one-based index/total such as 1/2\n' >&2
  exit 1
fi

if [[ "$LANES" != "all" ]]; then
  while IFS= read -r requested_lane; do
    case "$requested_lane" in
      fast|slow|service|serial) ;;
      *)
        printf 'unknown requested test lane: %s\n' "$requested_lane" >&2
        exit 1
        ;;
    esac
  done <<EOF
$(printf '%s\n' "$LANES" | tr ',' '\n')
EOF
fi

if ! mkdir -p "$LOG_DIR"; then
  printf 'could not create test log directory: %s\n' "$LOG_DIR" >&2
  exit 1
fi
if ! RUN_STATE_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-test-state.XXXXXX")" \
  || [[ -z "$RUN_STATE_DIR" || ! -d "$RUN_STATE_DIR" ]]; then
  printf 'could not create the test runner state directory\n' >&2
  exit 1
fi
cleanup() {
  rm -rf "$RUN_STATE_DIR"
}
trap cleanup EXIT

missing=""
for tool in zsh python3 git; do
  command -v "$tool" >/dev/null 2>&1 || missing="${missing} ${tool}"
done
if [[ -n "$missing" ]]; then
  printf 'missing required tools:%s\n' "$missing" >&2
  exit 1
fi
if ! command -v timeout >/dev/null 2>&1 && ! command -v perl >/dev/null 2>&1; then
  printf 'missing required timeout tool: install timeout or perl\n' >&2
  exit 1
fi

declared_names="$RUN_STATE_DIR/declared-names"
manifest_records="$RUN_STATE_DIR/manifest-records"
: > "$declared_names"
: > "$manifest_records"

line_number=0
while IFS= read -r manifest_line || [[ -n "$manifest_line" ]]; do
  line_number=$((line_number + 1))
  case "$manifest_line" in
    ""|\#*) continue ;;
  esac

  field_count="$(printf '%s\n' "$manifest_line" | awk -F '\t' '{ print NF }')"
  if [[ "$field_count" != "5" ]]; then
    printf 'invalid test manifest row %s: expected 5 tab-separated fields\n' \
      "$line_number" >&2
    exit 1
  fi

  IFS=$'\t' read -r name lane test_platform test_timeout isolation <<EOF
$manifest_line
EOF
  case "$name" in
    */*|"")
      printf 'invalid test name on manifest row %s: %s\n' "$line_number" "$name" >&2
      exit 1
      ;;
    *-test.sh) ;;
    *)
      printf 'invalid test name on manifest row %s: %s\n' "$line_number" "$name" >&2
      exit 1
      ;;
  esac
  case "$lane" in
    fast|slow|service|serial) ;;
    *)
      printf 'unknown test lane %s in %s\n' "$lane" "$name" >&2
      exit 1
      ;;
  esac
  case "$test_platform" in
    all|linux|macos) ;;
    *)
      printf 'unknown test platform %s in %s\n' "$test_platform" "$name" >&2
      exit 1
      ;;
  esac
  if [[ ! "$test_timeout" =~ ^[1-9][0-9]*$ ]]; then
    printf 'invalid test timeout %s in %s\n' "$test_timeout" "$name" >&2
    exit 1
  fi
  case "$isolation" in
    hermetic|shared) ;;
    *)
      printf 'unknown test isolation %s in %s\n' "$isolation" "$name" >&2
      exit 1
      ;;
  esac
  if grep -Fqx -- "$name" "$declared_names"; then
    printf 'duplicate test manifest entry: %s\n' "$name" >&2
    exit 1
  fi

  declared_lane=$(awk 'NR > 40 { exit } /^# dex-test-lane: / { print $3; exit }' \
    "$SUITE_DIR/$name" 2>/dev/null || true)
  if [[ -n "$declared_lane" && "$declared_lane" != "$lane" ]]; then
    printf 'test lane marker disagrees with manifest for %s: %s != %s\n' \
      "$name" "$declared_lane" "$lane" >&2
    exit 1
  fi

  printf '%s\n' "$name" >> "$declared_names"
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$name" "$lane" "$test_platform" "$test_timeout" "$isolation" \
    >> "$manifest_records"
done < "$MANIFEST"

LC_ALL=C sort "$declared_names" > "$RUN_STATE_DIR/declared-sorted"
if ! cmp -s "$declared_names" "$RUN_STATE_DIR/declared-sorted"; then
  printf 'test manifest entries must be sorted by name\n' >&2
  exit 1
fi

find "$SUITE_DIR" -maxdepth 1 -type f -name '*-test.sh' -print \
  | sed 's#^.*/##' | LC_ALL=C sort > "$RUN_STATE_DIR/discovered"
missing_tests="$(LC_ALL=C comm -23 "$RUN_STATE_DIR/discovered" "$RUN_STATE_DIR/declared-sorted" \
  | tr '\n' ' ' | sed 's/ $//')"
extra_tests="$(LC_ALL=C comm -13 "$RUN_STATE_DIR/discovered" "$RUN_STATE_DIR/declared-sorted" \
  | tr '\n' ' ' | sed 's/ $//')"
if [[ -n "$missing_tests" ]]; then
  printf 'tests missing from manifest: %s\n' "$missing_tests" >&2
  exit 1
fi
if [[ -n "$extra_tests" ]]; then
  printf 'manifest entries without test files: %s\n' "$extra_tests" >&2
  exit 1
fi

service_tests=""
parallel_tests=""
serial_tests=""
selected_names="$RUN_STATE_DIR/selected-names"
: > "$selected_names"
selected=0
platform_skipped=0
eligible_index=0
service_total=0
serial_total=0
fast_total=0
slow_total=0

while IFS=$'\t' read -r name lane test_platform test_timeout isolation; do
  [[ -n "$name" ]] || continue

  if [[ "$test_platform" != "all" && "$test_platform" != "$PLATFORM" ]]; then
    platform_skipped=$((platform_skipped + 1))
    continue
  fi
  if [[ "$LANES" != "all" ]]; then
    case ",$LANES," in
      *,"$lane",*) ;;
      *) continue ;;
    esac
  fi
  if [[ $# -gt 0 ]]; then
    matched=0
    for filter in "$@"; do
      case "$name" in
        *"$filter"*) matched=1; break ;;
      esac
    done
    [[ "$matched" -eq 1 ]] || continue
  fi

  eligible_index=$((eligible_index + 1))
  if [[ $(( (eligible_index - 1) % shard_total + 1 )) -ne "$shard_index" ]]; then
    continue
  fi

  selected=$((selected + 1))
  printf '%s\n' "$name" >> "$selected_names"
  record="${name}"$'\t'"${test_timeout}"$'\t'"${isolation}"$'\n'
  case "$lane" in
    service)
      service_tests="${service_tests}${record}"
      service_total=$((service_total + 1))
      ;;
    serial)
      serial_tests="${serial_tests}${record}"
      serial_total=$((serial_total + 1))
      ;;
    fast)
      parallel_tests="${parallel_tests}${record}"
      fast_total=$((fast_total + 1))
      ;;
    slow)
      parallel_tests="${parallel_tests}${record}"
      slow_total=$((slow_total + 1))
      ;;
  esac
done < "$manifest_records"

if [[ "$selected" -eq 0 ]]; then
  printf 'no tests matched the requested filters, lanes, platform, and shard\n' >&2
  exit 1
fi

printf '%s selected, %s skipped for %s; lanes: %s fast, %s slow, %s service, %s serial; shard %s\n' \
  "$selected" "$platform_skipped" "$PLATFORM" "$fast_total" "$slow_total" \
  "$service_total" "$serial_total" "$SHARD"
printf 'running service tests alone, up to %s fast/slow tests in parallel, then serial tests\n' \
  "$JOBS"

# A reused log directory must not turn an interrupted test into a stale pass.
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  rm -f "$LOG_DIR/$name.rc" "$LOG_DIR/$name.log"
done < "$selected_names"

run_one() {
  local name="$1" manifest_timeout="$2" isolation="$3"
  local start end rc effective_timeout test_root setup_failed=0
  local -a test_command

  effective_timeout="${TIMEOUT_OVERRIDE:-$manifest_timeout}"
  start=$(date +%s)
  if [[ "$isolation" == "hermetic" ]]; then
    test_root="$RUN_STATE_DIR/tests/${name%.sh}"
    if ! mkdir -p "$test_root/home/.claude" "$test_root/xdg/config" \
        "$test_root/xdg/cache" "$test_root/xdg/data" "$test_root/xdg/state" \
        "$test_root/xdg/runtime" "$test_root/codex" "$test_root/claude" \
        "$test_root/dex/state" "$test_root/dex/loops" "$test_root/dex/artifacts" \
        "$test_root/dex/tools" "$test_root/dex/runs" "$test_root/dex/maintenance" \
        "$test_root/tmp" \
      || ! chmod 700 "$test_root/xdg/runtime" \
      || ! git config --file "$test_root/home/.gitconfig" \
        user.email "dex-test@example.test" \
      || ! git config --file "$test_root/home/.gitconfig" user.name "Dex Test" \
      || ! git config --file "$test_root/home/.gitconfig" init.defaultBranch main; then
      printf 'could not prepare the isolated test environment\n' \
        > "$LOG_DIR/$name.log"
      setup_failed=1
    else
      test_command=(env -i
        "PATH=$PATH"
        "LANG=C"
        "LC_ALL=C"
        "TZ=UTC"
        "USER=dex-test"
        "LOGNAME=dex-test"
        "SHELL=/bin/bash"
        "DEX_DIR=$ROOT"
        "HOME=$test_root/home"
        "XDG_CONFIG_HOME=$test_root/xdg/config"
        "XDG_CACHE_HOME=$test_root/xdg/cache"
        "XDG_DATA_HOME=$test_root/xdg/data"
        "XDG_STATE_HOME=$test_root/xdg/state"
        "XDG_RUNTIME_DIR=$test_root/xdg/runtime"
        "CODEX_HOME=$test_root/codex"
        "CLAUDE_CONFIG_DIR=$test_root/claude"
        "ZDOTDIR=$test_root/home"
        "DX_STATE_DIR=$test_root/dex/state"
        "DX_LOOP_DIR=$test_root/dex/loops"
        "DX_ARTIFACT_DIR=$test_root/dex/artifacts"
        "DX_TOOL_DIR=$test_root/dex/tools"
        "DX_RUN_ROOT=$test_root/dex/runs"
        "DX_MAINTENANCE_DIR=$test_root/dex/maintenance"
        "DX_RTK_INSTALL_DIR=$test_root/dex/tools/rtk/bin"
        "TMPDIR=$test_root/tmp"
        "GIT_CONFIG_GLOBAL=$test_root/home/.gitconfig"
        "GIT_CONFIG_NOSYSTEM=1"
        "GIT_TERMINAL_PROMPT=0"
        "DX_TEST_REPORT_DIR=${DX_TEST_REPORT_DIR:-}"
        "DEX_TEST_CURRENT_NAME=$name"
        bash "$SUITE_DIR/$name")
    fi
  else
    test_command=(env "DEX_TEST_CURRENT_NAME=$name" bash "$SUITE_DIR/$name")
  fi

  # </dev/null keeps a test from consuming the runner's own manifest stream.
  if [[ "$setup_failed" -eq 1 ]]; then
    rc=2
  elif command -v timeout >/dev/null 2>&1; then
    timeout "$effective_timeout" "${test_command[@]}" \
      > "$LOG_DIR/$name.log" 2>&1 </dev/null
    rc=$?
  else
    perl -e 'alarm shift; exec @ARGV' "$effective_timeout" "${test_command[@]}" \
      > "$LOG_DIR/$name.log" 2>&1 </dev/null
    rc=$?
  fi
  end=$(date +%s)
  if [[ "$rc" -eq 0 ]]; then
    printf 'PASS %s (%ss)\n' "$name" "$((end - start))"
  else
    printf 'FAIL(%s) %s (%ss, timeout %ss)\n' \
      "$rc" "$name" "$((end - start))" "$effective_timeout"
  fi
  printf '%s\n' "$rc" > "$LOG_DIR/$name.rc"
}

while IFS=$'\t' read -r name test_timeout isolation; do
  [[ -n "$name" ]] || continue
  run_one "$name" "$test_timeout" "$isolation" </dev/null
done <<EOF
$service_tests
EOF

# `wait -n` is unavailable in bash 3.2, which is the macOS system bash.
while IFS=$'\t' read -r name test_timeout isolation; do
  [[ -n "$name" ]] || continue
  while [[ "$(jobs -pr | wc -l | tr -d ' ')" -ge "$JOBS" ]]; do
    sleep 0.2
  done
  run_one "$name" "$test_timeout" "$isolation" </dev/null &
done <<EOF
$parallel_tests
EOF
wait

while IFS=$'\t' read -r name test_timeout isolation; do
  [[ -n "$name" ]] || continue
  run_one "$name" "$test_timeout" "$isolation" </dev/null
done <<EOF
$serial_tests
EOF

passed=0
failed=""
while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  result_file="$LOG_DIR/$name.rc"
  if [[ ! -f "$result_file" ]]; then
    printf 'DID NOT RUN %s\n' "$name" >&2
    failed="${failed} ${name}"
    continue
  fi
  rc="$(cat "$result_file")"
  if [[ "$rc" == "0" ]]; then
    passed=$((passed + 1))
  else
    failed="${failed} ${name}"
  fi
done < "$selected_names"

printf '\n== %s passed, %s failed ==\n' "$passed" \
  "$(printf '%s' "$failed" | wc -w | tr -d ' ')"
if [[ -n "$failed" ]]; then
  for name in $failed; do
    printf '\n--- %s (last 40 lines) ---\n' "$name"
    tail -40 "$LOG_DIR/$name.log" 2>/dev/null
    if [[ ! -s "$LOG_DIR/$name.log" ]]; then
      printf '(no output from this test)\n'
      printf 'to see the failing line: bash -x tests/%s\n' "$name"
    fi
  done
  printf '\nfull logs: %s\n' "$LOG_DIR"
  exit 1
fi

printf 'logs: %s\n' "$LOG_DIR"
