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
printf 'DX_HOST_CPUS=%s\nDX_HOST_MEM_GB=%s\nDX_HOST_LOAD1=%s\n' \
  "${DX_HOST_CPUS:-unset}" "${DX_HOST_MEM_GB:-unset}" "${DX_HOST_LOAD1:-unset}"
printf 'DX_HOST_ACTIVE_SESSIONS=%s\nDX_HOST_ACTIVE_HEAVY=%s\n' \
  "${DX_HOST_ACTIVE_SESSIONS:-unset}" "${DX_HOST_ACTIVE_HEAVY:-unset}"
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

# The host snapshot rides the same launch path, so the session knows what else
# is on the machine instead of assuming it is alone. Measured values, not
# constants: the assertion is that each one arrived and is a number.
launch_host="$TMP_DIR/launch-host.out"
(
  export PATH="$TMP_DIR/bin:$PATH"
  export DX_PROVIDER_APPLIED=1 DX_PROVIDER_ENGINE=claude DX_PROVIDER_PROFILE_RESOLVED=claude
  unset DEX_SESSION_ID
  dx_provider_claude -p test
) > "$launch_host"
launch_cpus="$(sed -n 's/^DX_HOST_CPUS=//p' "$launch_host")"
launch_mem="$(sed -n 's/^DX_HOST_MEM_GB=//p' "$launch_host")"
launch_load="$(sed -n 's/^DX_HOST_LOAD1=//p' "$launch_host")"
[[ "$launch_cpus" =~ ^[1-9][0-9]*$ ]] || assert_at $LINENO
[[ "$launch_mem" =~ ^[1-9][0-9]*$ ]] || assert_at $LINENO
[[ "$launch_load" =~ ^[0-9]+\.[0-9]{2}$ ]] || assert_at $LINENO
assert_contains "DX_HOST_ACTIVE_SESSIONS=0" "$launch_host"
assert_contains "DX_HOST_ACTIVE_HEAVY=0" "$launch_host"
# And it leaves the launching shell exactly as it found it.
[[ -z "${DX_HOST_ACTIVE_HEAVY:-}" ]] || assert_at $LINENO
[[ -z "${DX_HOST_LOAD1:-}" ]] || assert_at $LINENO

# --- measured host facts, and the fallback when a host cannot answer ---------
# Every fact has an override so a container, and every test, states its own
# shape rather than inheriting whichever machine this runs on.
assert_eq "6" "$(DX_HOST_CPUS_OVERRIDE=6 dx_host_cpu_count)" \
  "DX_HOST_CPUS_OVERRIDE replaces the probe"
assert_eq "48" "$(DX_HOST_MEM_GB_OVERRIDE=48 dx_host_memory_total_gb)" \
  "DX_HOST_MEM_GB_OVERRIDE replaces the probe"
assert_eq "1.75" "$(DX_HOST_LOAD1_OVERRIDE=1.75 dx_host_load1)" \
  "DX_HOST_LOAD1_OVERRIDE replaces the probe"
assert_eq "3.00" "$(DX_HOST_LOAD1_OVERRIDE=3 dx_host_load1)" \
  "a whole-number load average is normalised to two decimals"
if DX_HOST_MEM_GB_OVERRIDE=plenty dx_host_memory_total_gb >/dev/null 2>&1; then
  fail "a malformed memory override was accepted"
fi
if DX_HOST_LOAD1_OVERRIDE=busy dx_host_load1 >/dev/null 2>&1; then
  fail "a malformed load override was accepted"
fi
# A malformed CPU override falls through to the probe rather than failing: every
# caller assigns dx_host_cpu_count's output under `set -e`.
[[ "$(DX_HOST_CPUS_OVERRIDE=many dx_host_cpu_count)" =~ ^[1-9][0-9]*$ ]] || assert_at $LINENO

# The unmeasurable host. Both readers fail, both facts get their conservative
# default, and the snapshot says which ones were substituted instead of letting
# a budget be shaped by a number nobody measured.
facts_output="$TMP_DIR/facts.env"
(
  dx_host_memory_total_gb() { return 1; }
  dx_host_load1() { return 1; }
  dx_host_facts
  printf 'cpus=%s\nmem=%s\nload=%s\nfallbacks=%s\n' \
    "$DX_HOST_FACT_CPUS" "$DX_HOST_FACT_MEM_GB" "$DX_HOST_FACT_LOAD1" \
    "$DX_HOST_FACT_FALLBACKS"
) > "$facts_output"
assert_contains "mem=4" "$facts_output"
assert_contains "load=0.00" "$facts_output"
assert_contains "fallbacks=fallback=mem_gb fallback=load1" "$facts_output"
(
  dx_host_facts
  [[ -z "$DX_HOST_FACT_FALLBACKS" ]] || assert_at $LINENO
) || fail "a host that can answer recorded a fallback"

# --- cgroup limits win when they are lower than the machine ------------------
# A container is budgeted against its own share, not its host's.
cgroup_dir="$TMP_DIR/cgroup"
mkdir -p "$cgroup_dir"
printf '200000 100000\n' > "$cgroup_dir/cpu.max"
assert_eq "2" "$(__dx_host_cgroup_cpu_limit "$cgroup_dir/cpu.max")" \
  "quota over period is the whole-CPU allowance"
printf '50000 100000\n' > "$cgroup_dir/cpu.max"
assert_eq "1" "$(__dx_host_cgroup_cpu_limit "$cgroup_dir/cpu.max")" \
  "half a core still allows one"
printf 'max 100000\n' > "$cgroup_dir/cpu.max"
if __dx_host_cgroup_cpu_limit "$cgroup_dir/cpu.max" >/dev/null 2>&1; then
  fail "an uncapped cgroup was read as a limit"
fi
printf '200000 100000\n' > "$cgroup_dir/cpu.max"
assert_eq "2" "$(DX_HOST_CGROUP_DIR="$cgroup_dir" dx_host_cpu_count)" \
  "a cgroup quota below the machine's core count wins"
printf '6400000 100000\n' > "$cgroup_dir/cpu.max"
assert_eq "$(DX_HOST_CGROUP_DIR="$TMP_DIR/no-cgroup" dx_host_cpu_count)" \
  "$(DX_HOST_CGROUP_DIR="$cgroup_dir" dx_host_cpu_count)" \
  "a cgroup quota above the machine's core count changes nothing"
printf '8589934592\n' > "$cgroup_dir/memory.max"
assert_eq "8589934592" \
  "$(__dx_host_cgroup_memory_limit "$cgroup_dir/memory.max")" \
  "a cgroup memory limit reads as bytes"
printf 'max\n' > "$cgroup_dir/memory.max"
if __dx_host_cgroup_memory_limit "$cgroup_dir/memory.max" >/dev/null 2>&1; then
  fail "an uncapped memory cgroup was read as a limit"
fi
printf '2147483648\n' > "$cgroup_dir/memory.max"
assert_eq "2" "$(DX_HOST_CGROUP_DIR="$cgroup_dir" DX_HOST_MEM_GB_OVERRIDE="" \
  dx_host_memory_total_gb)" "a 2 GB cgroup limit wins over the machine's memory"

# The Linux MemTotal reader, exercised on whichever platform runs this.
meminfo_total="$TMP_DIR/meminfo-total"
printf 'MemTotal:       16384000 kB\nMemFree:  100 kB\n' > "$meminfo_total"
assert_eq "16384000" "$(__dx_host_memory_total_kb "$meminfo_total")" \
  "Linux MemTotal in kilobytes"
printf 'MemFree:  100 kB\n' > "$meminfo_total"
if __dx_host_memory_total_kb "$meminfo_total" >/dev/null 2>&1; then
  fail "meminfo without MemTotal was accepted"
fi

# --- the heavy admission limit, against a matrix of host shapes -------------
# max(1, min(cpus/4, mem_gb/8)), capped at 8.
assert_eq "1" "$(DX_HOST_CPUS_OVERRIDE=2 DX_HOST_MEM_GB_OVERRIDE=8 dx_host_heavy_limit)" \
  "a two-core host admits one heavy command"
assert_eq "2" "$(DX_HOST_CPUS_OVERRIDE=8 DX_HOST_MEM_GB_OVERRIDE=16 dx_host_heavy_limit)" \
  "eight cores and sixteen gigabytes admit two"
assert_eq "8" "$(DX_HOST_CPUS_OVERRIDE=32 DX_HOST_MEM_GB_OVERRIDE=128 dx_host_heavy_limit)" \
  "a large host admits eight"
assert_eq "8" "$(DX_HOST_CPUS_OVERRIDE=128 DX_HOST_MEM_GB_OVERRIDE=512 dx_host_heavy_limit)" \
  "the limit is capped at the pool's own range"
assert_eq "1" "$(DX_HOST_CPUS_OVERRIDE=64 DX_HOST_MEM_GB_OVERRIDE=8 dx_host_heavy_limit)" \
  "memory is the binding constraint when it is the smaller one"
assert_eq "1" "$(DX_HOST_CPUS_OVERRIDE=4 DX_HOST_MEM_GB_OVERRIDE=256 dx_host_heavy_limit)" \
  "cores are the binding constraint when they are the smaller one"
printf '8589934592\n' > "$cgroup_dir/memory.max"
assert_eq "8" "$(DX_HOST_CGROUP_DIR="$TMP_DIR/no-cgroup" DX_HOST_CPUS_OVERRIDE=32 \
  DX_HOST_MEM_GB_OVERRIDE=128 dx_host_heavy_limit)" \
  "thirty-two cores and plenty of memory admit eight"
assert_eq "1" "$(DX_HOST_CGROUP_DIR="$cgroup_dir" DX_HOST_CPUS_OVERRIDE=32 \
  dx_host_heavy_limit)" \
  "the same cores inside an 8 GB container admit one; a cgroup limit wins"
assert_eq "5" "$(DEX_MAX_ACTIVE_HEAVY=5 DX_HOST_CPUS_OVERRIDE=2 DX_HOST_MEM_GB_OVERRIDE=8 \
  dx_host_heavy_limit)" "DEX_MAX_ACTIVE_HEAVY replaces the calculation"
if DEX_MAX_ACTIVE_HEAVY=0 dx_host_heavy_limit >/dev/null 2>&1; then
  fail "a zero heavy limit was accepted"
fi
if DEX_MAX_ACTIVE_HEAVY=9 dx_host_heavy_limit >/dev/null 2>&1; then
  fail "a heavy limit past the pool's range was accepted"
fi
# A host that cannot report memory gets the conservative default's answer, not
# the benefit of its core count.
assert_eq "1" "$(
  dx_host_memory_total_gb() { return 1; }
  DX_HOST_CPUS_OVERRIDE=32 dx_host_heavy_limit
)" "an unmeasurable memory total holds the heavy limit down"

# --- the per-phase host snapshot --------------------------------------------
snapshot_env="$TMP_DIR/snapshot.env"
DX_HOST_CPUS_OVERRIDE=8 DX_HOST_MEM_GB_OVERRIDE=16 DX_HOST_LOAD1_OVERRIDE=2.5 DEX_TEST_JOBS=3 \
  dx_host_snapshot > "$snapshot_env"
assert_contains "DX_HOST_CPUS=8" "$snapshot_env"
assert_contains "DX_HOST_MEM_GB=16" "$snapshot_env"
assert_contains "DX_HOST_LOAD1=2.50" "$snapshot_env"
assert_contains "DX_HOST_ACTIVE_SESSIONS=0" "$snapshot_env"
assert_contains "DX_HOST_ACTIVE_HEAVY=0" "$snapshot_env"
assert_contains "DX_TEST_JOBS=3" "$snapshot_env"
assert_contains "DX_HOST_FALLBACKS=" "$snapshot_env"
if grep -q '^DX_HOST_FALLBACKS=fallback' "$snapshot_env"; then
  fail "a fully measured host reported a fallback"
fi
assert_eq "7" "$(wc -l < "$snapshot_env" | tr -d ' ')" \
  "the snapshot is seven lines, one per published fact"
# An inherited job budget survives, the way the rest of the budget does.
assert_eq "7" "$(DX_TEST_JOBS=7 dx_host_test_jobs_effective)" \
  "an inherited DX_TEST_JOBS is passed on unchanged"

# A nested publish re-measures. Every session can launch further sessions — a
# review wave is one — so the snapshot a child publishes must describe the host
# now, not repeat what its parent published at launch. 999.99 and 99999 are
# values no host reports, so seeing one back means it was inherited rather than
# measured.
nested_env="$TMP_DIR/nested-snapshot.env"
DX_HOST_CPUS=99999 DX_HOST_MEM_GB=99999 DX_HOST_LOAD1=999.99 \
  DX_HOST_FALLBACKS="fallback=mem_gb fallback=load1" \
  dx_host_snapshot > "$nested_env"
assert_not_contains "DX_HOST_CPUS=99999" "$nested_env"
assert_not_contains "DX_HOST_MEM_GB=99999" "$nested_env"
assert_not_contains "DX_HOST_LOAD1=999.99" "$nested_env"
# And a fallback marker the child did not earn is cleared rather than carried.
assert_contains "DX_HOST_FALLBACKS=" "$nested_env"
if grep -q '^DX_HOST_FALLBACKS=fallback' "$nested_env"; then
  fail "an inherited fallback marker outlived the condition that earned it"
fi
nested_cpus="$(sed -n 's/^DX_HOST_CPUS=//p' "$nested_env")"
nested_load="$(sed -n 's/^DX_HOST_LOAD1=//p' "$nested_env")"
[[ "$nested_cpus" =~ ^[1-9][0-9]{0,4}$ ]] || assert_at $LINENO
[[ "$nested_load" =~ ^[0-9]+\.[0-9]{2}$ ]] || assert_at $LINENO
# The override names are what a test or a container states, and they do win.
override_env="$TMP_DIR/override-snapshot.env"
DX_HOST_CPUS=1 DX_HOST_LOAD1=1.00 DX_HOST_CPUS_OVERRIDE=99999 \
  DX_HOST_LOAD1_OVERRIDE=999.99 dx_host_snapshot > "$override_env"
assert_contains "DX_HOST_CPUS=99999" "$override_env"
assert_contains "DX_HOST_LOAD1=999.99" "$override_env"
handoff_line="$TMP_DIR/handoff.txt"
DX_HOST_CPUS_OVERRIDE=8 DEX_TEST_JOBS=2 dx_host_handoff_line > "$handoff_line"
assert_contains "Host: 0 sessions, 0 heavy commands running, 2 test jobs available to you." \
  "$handoff_line"

# --- reduced scheduling priority -------------------------------------------
# Probed, never assumed: the name recorded is one this host can actually run.
host_wrapper="$(dx_host_priority_wrapper)"
case "$host_wrapper" in
  none|nice|nice+taskpolicy|nice+ionice|systemd-run|systemd-run+ionice) ;;
  *) fail "unknown priority wrapper: $host_wrapper" ;;
esac
# The name list and the prefix table are the same set, or a probed candidate
# would silently have no prefix.
for wrapper_name in $DX_HOST_PRIORITY_WRAPPERS; do
  [[ -n "$(dx_host_priority_prefix "$wrapper_name")" ]] || assert_at $LINENO
done
assert_eq "systemd-run+ionice systemd-run nice+taskpolicy nice+ionice nice" \
  "$DX_HOST_PRIORITY_WRAPPERS" "candidates are ordered strongest first"
if [[ "$(uname -s)" == "Darwin" ]]; then
  assert_eq "nice+taskpolicy" "$host_wrapper" \
    "macOS ships taskpolicy, so the gate wrapper uses it"
fi
assert_eq "nice
-n
10" "$(dx_host_priority_prefix nice)" "nice alone is three words"
assert_eq "nice
-n
10
taskpolicy
-c
background" "$(dx_host_priority_prefix nice+taskpolicy)" \
  "the macOS wrapper adds the background task policy"
assert_eq "nice
-n
10
ionice
-c
3" "$(dx_host_priority_prefix nice+ionice)" \
  "the Linux wrapper adds the idle I/O class"
assert_eq "systemd-run
--user
--scope
-q
-p
CPUWeight=50
nice
-n
10" "$(dx_host_priority_prefix systemd-run)" \
  "the systemd wrapper halves the CPU weight of a transient scope"
# CPU weight and I/O class are not alternatives. A transient scope halves the
# CPU share and says nothing about the disk, which is what a test suite or a
# cold build actually saturates, so where both exist the chain carries both.
assert_eq "systemd-run
--user
--scope
-q
-p
CPUWeight=50
nice
-n
10
ionice
-c
3" "$(dx_host_priority_prefix systemd-run+ionice)" \
  "the strongest Linux wrapper keeps the idle I/O class inside the scope"
assert_eq "" "$(dx_host_priority_prefix none)" "none adds no words"
if dx_host_priority_prefix invented >/dev/null 2>&1; then
  fail "an unknown wrapper name produced a prefix"
fi
assert_eq "none" "$(DEX_GATE_PRIORITY=none dx_host_priority_wrapper)" \
  "DEX_GATE_PRIORITY pins the wrapper without probing"
if DEX_GATE_PRIORITY=fastest dx_host_priority_wrapper >/dev/null 2>&1; then
  fail "an unknown DEX_GATE_PRIORITY was accepted"
fi
assert_eq "systemd-run+ionice" \
  "$(DEX_GATE_PRIORITY=systemd-run+ionice dx_host_priority_wrapper)" \
  "the composed Linux wrapper can be pinned by name"

# Which wrapper a host gets is otherwise decided by running the whole prefix,
# so the Linux ordering is testable anywhere with stub binaries that exec what
# they are handed. The stubs are what a Linux host would answer with; this is
# the only place the systemd-run path runs on a macOS developer machine.
wrapper_bin="$TMP_DIR/wrapper-bin"
mkdir -p "$wrapper_bin"
cat > "$wrapper_bin/systemd-run" <<'STUB'
#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    --user|--scope|-q) shift ;;
    -p) shift 2 ;;
    *) break ;;
  esac
done
exec "$@"
STUB
cat > "$wrapper_bin/ionice" <<'STUB'
#!/bin/sh
while [ $# -gt 0 ]; do
  case "$1" in
    -c) shift 2 ;;
    -*) shift ;;
    *) break ;;
  esac
done
exec "$@"
STUB
printf '#!/bin/sh\nexit 1\n' > "$wrapper_bin/refuses"
chmod +x "$wrapper_bin/systemd-run" "$wrapper_bin/ionice" "$wrapper_bin/refuses"
assert_eq "systemd-run+ionice" "$(PATH="$wrapper_bin:$PATH" dx_host_priority_wrapper)" \
  "a host with a working scope and ionice keeps both"
# A scope that is installed but refuses here — no user manager, the common
# case on a headless box — falls through instead of losing the I/O class too.
cp "$wrapper_bin/refuses" "$wrapper_bin/systemd-run"
cp "$wrapper_bin/refuses" "$wrapper_bin/taskpolicy"
assert_eq "nice+ionice" "$(PATH="$wrapper_bin:$PATH" dx_host_priority_wrapper)" \
  "a refusing scope degrades to nice plus the idle I/O class"
cp "$wrapper_bin/refuses" "$wrapper_bin/ionice"
assert_eq "nice" "$(PATH="$wrapper_bin:$PATH" dx_host_priority_wrapper)" \
  "with every class refusing, renice alone is still applied"

# The probe has to give the same answer in zsh, which is where lib/ actually
# runs: dx.sh sources it. This suite runs under bash, so a zsh-only break is
# invisible here — and one happened. `for candidate in $DX_HOST_PRIORITY_WRAPPERS`
# probed a single candidate named "systemd-run+ionice systemd-run nice+…" there,
# because zsh does not word-split an unquoted parameter, and every host read
# `none`: no renice, no background class, nothing.
if command -v zsh >/dev/null 2>&1; then
  zsh_wrapper="$(
    zsh -fc "
      export DEX_DIR='$ROOT'
      source \"\$DEX_DIR/lib/common.sh\"
      dx_host_priority_wrapper
    " 2>/dev/null
  )"
  assert_eq "$host_wrapper" "$zsh_wrapper" \
    "the priority probe answers the same in zsh, where lib/ is sourced from"
else
  printf 'skip: no zsh on this host, so the zsh priority probe is unexercised\n'
fi

echo "host-budget tests passed"
