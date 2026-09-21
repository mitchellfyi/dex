#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-host-budget.XXXXXX")"

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

unset DEX_TEST_JOBS DEX_REVIEW_MAX_ACTIVE_WAVES DEX_MIN_FREE_MEMORY_PERCENT
unset DEX_MAX_CONCURRENT_SUBAGENTS DEX_MAX_SUBAGENT_SPAWN_DEPTH
unset DX_TEST_JOBS VITEST_MAX_THREADS VITEST_MAX_FORKS PYTEST_XDIST_AUTO_NUM_WORKERS
unset CARGO_BUILD_JOBS RUST_TEST_THREADS GOFLAGS MAKEFLAGS
unset CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH

# --- test-job budget -------------------------------------------------------
assert_eq "4" "$(dx_host_test_jobs 8 1)" "one session keeps half the cores"
assert_eq "2" "$(dx_host_test_jobs 12 3)" "three sessions share half the cores"
assert_eq "1" "$(dx_host_test_jobs 4 3)" "budget never drops below one job"
assert_eq "4" "$(dx_host_test_jobs 64 1)" "budget is capped at four jobs"
assert_eq "1" "$(dx_host_test_jobs 8)" \
  "default divisor is the review-wave admission limit"
assert_eq "4" "$(DEX_REVIEW_MAX_ACTIVE_WAVES=1 dx_host_test_jobs 8)" \
  "single-wave hosts get the full per-session budget"
assert_eq "6" "$(DEX_TEST_JOBS=6 dx_host_test_jobs 2 8)" \
  "explicit DEX_TEST_JOBS wins over the derived budget"
if DEX_TEST_JOBS=0 dx_host_test_jobs 8 1 >/dev/null 2>&1; then
  fail "zero DEX_TEST_JOBS was accepted"
fi
if DEX_TEST_JOBS=33 dx_host_test_jobs 8 1 >/dev/null 2>&1; then
  fail "oversized DEX_TEST_JOBS was accepted"
fi
if dx_host_test_jobs 8 9 >/dev/null 2>&1; then
  fail "invalid session count was accepted"
fi
assert_eq "2" "$(__dx_review_test_jobs 8 2)" \
  "review waves derive their test budget from the host budget"
assert_eq "3" "$(DEX_TEST_JOBS=3 __dx_review_test_jobs 8 2)" \
  "review waves honour the host-wide DEX_TEST_JOBS"
assert_eq "5" "$(DEX_TEST_JOBS=3 DEX_REVIEW_TEST_JOBS=5 __dx_review_test_jobs 8 2)" \
  "the review-specific budget still takes precedence"

# --- budget environment ----------------------------------------------------
budget_env="$TMP_DIR/budget.env"
dx_host_budget_env 2 > "$budget_env"
assert_contains "DX_TEST_JOBS=2" "$budget_env"
assert_contains "VITEST_MAX_THREADS=2" "$budget_env"
assert_contains "VITEST_MAX_FORKS=2" "$budget_env"
assert_contains "PYTEST_XDIST_AUTO_NUM_WORKERS=2" "$budget_env"
assert_contains "CARGO_BUILD_JOBS=2" "$budget_env"
assert_contains "RUST_TEST_THREADS=2" "$budget_env"
assert_contains "GOFLAGS=-p=2" "$budget_env"
assert_contains "MAKEFLAGS=-j2" "$budget_env"
assert_contains "CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=4" "$budget_env"
assert_contains "CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=2" "$budget_env"
assert_eq "10" "$(wc -l < "$budget_env" | tr -d ' ')" \
  "every budget line is emitted when nothing is preset"

preset_env="$TMP_DIR/preset.env"
GOFLAGS=-mod=vendor CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=9 dx_host_budget_env 2 > "$preset_env"
if grep -q '^GOFLAGS=' "$preset_env"; then
  fail "a preset GOFLAGS was overridden"
fi
if grep -q '^CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=' "$preset_env"; then
  fail "a preset subagent cap was overridden"
fi
assert_contains "DX_TEST_JOBS=2" "$preset_env"
operator_env="$TMP_DIR/operator.env"
DEX_MAX_CONCURRENT_SUBAGENTS=2 DEX_MAX_SUBAGENT_SPAWN_DEPTH=1 dx_host_budget_env 1 > "$operator_env"
assert_contains "CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS=2" "$operator_env"
assert_contains "CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH=1" "$operator_env"
if DEX_MAX_CONCURRENT_SUBAGENTS=0 dx_host_budget_env 1 >/dev/null 2>&1; then
  fail "zero subagent cap was accepted"
fi
if dx_host_budget_env 0 >/dev/null 2>&1; then
  fail "zero job budget was accepted"
fi

# --- memory probe ----------------------------------------------------------
meminfo="$TMP_DIR/meminfo"
printf 'MemTotal:       16000000 kB\nMemFree:         1000000 kB\nMemAvailable:    4000000 kB\n' > "$meminfo"
assert_eq "25" "$(__dx_host_memory_free_percent_meminfo "$meminfo")" \
  "Linux meminfo free percentage"
printf 'MemFree:         1000000 kB\n' > "$meminfo"
if __dx_host_memory_free_percent_meminfo "$meminfo" >/dev/null 2>&1; then
  fail "meminfo without totals was accepted"
fi
pressure_output=$'The system has 2147483648 (524288 pages with a page size of 4096).\n\nStats: \nPages free: 2000\n\nSystem-wide memory free percentage: 43%\n'
assert_eq "43" "$(printf '%s' "$pressure_output" | __dx_host_memory_free_percent_pressure)" \
  "macOS memory_pressure free percentage"
if printf 'no such line\n' | __dx_host_memory_free_percent_pressure >/dev/null 2>&1; then
  fail "memory_pressure output without the summary line was accepted"
fi
assert_eq "7" "$(DX_HOST_MEMORY_FREE_PERCENT=7 dx_host_memory_free_percent)" \
  "override replaces the probe"
if DX_HOST_MEMORY_FREE_PERCENT=101 dx_host_memory_free_percent >/dev/null 2>&1; then
  fail "out-of-range override was accepted"
fi
if DX_HOST_MEMORY_FREE_PERCENT=7 dx_host_memory_low; then :; else
  fail "7% free is not reported as low against the 10% default floor"
fi
if DX_HOST_MEMORY_FREE_PERCENT=10 dx_host_memory_low; then
  fail "10% free was reported as low against the 10% floor"
fi
if DX_HOST_MEMORY_FREE_PERCENT=7 DEX_MIN_FREE_MEMORY_PERCENT=0 dx_host_memory_low; then
  fail "a zero floor did not disable the check"
fi
if DX_HOST_MEMORY_FREE_PERCENT=7 DEX_MIN_FREE_MEMORY_PERCENT=5 dx_host_memory_low; then
  fail "7% free was reported as low against a 5% floor"
fi
low_rc=0
DX_HOST_MEMORY_FREE_PERCENT=7 DEX_MIN_FREE_MEMORY_PERCENT=abc dx_host_memory_low || low_rc=$?
assert_eq "2" "$low_rc" "malformed floor is rejected"

# --- provider launch exports the budget --------------------------------------
mkdir -p "$TMP_DIR/bin"
cat > "$TMP_DIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf 'DX_TEST_JOBS=%s\nVITEST_MAX_THREADS=%s\nGOFLAGS=%s\nSUBAGENTS=%s\n' \
  "${DX_TEST_JOBS:-unset}" "${VITEST_MAX_THREADS:-unset}" "${GOFLAGS:-unset}" \
  "${CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS:-unset}"
STUB
chmod +x "$TMP_DIR/bin/claude"
launch_output="$TMP_DIR/launch.out"
(
  export PATH="$TMP_DIR/bin:$PATH"
  export DX_PROVIDER_APPLIED=1 DX_PROVIDER_ENGINE=claude DX_PROVIDER_PROFILE_RESOLVED=claude
  export DEX_TEST_JOBS=3 GOFLAGS=-mod=vendor
  unset DEX_SESSION_ID
  dx_provider_claude -p test
) > "$launch_output"
assert_contains "DX_TEST_JOBS=3" "$launch_output"
assert_contains "VITEST_MAX_THREADS=3" "$launch_output"
assert_contains "GOFLAGS=-mod=vendor" "$launch_output"
assert_contains "SUBAGENTS=4" "$launch_output"
[[ -z "${DX_TEST_JOBS:-}" ]] || assert_at $LINENO
[[ -z "${VITEST_MAX_THREADS:-}" ]] || assert_at $LINENO

echo "host-budget tests passed"
