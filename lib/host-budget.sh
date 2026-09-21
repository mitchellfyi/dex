# shellcheck shell=bash
# Host resource budget shared by every Dex-launched provider session.
#
# Several lifecycles on one machine each launch a provider session, and each
# of those can start a test runner, a build, a review wave, or a fan-out of
# subagents. The provider caps none of what those children spawn, so six
# sessions on a twelve-core host can start sixty test workers. This module
# derives one per-session budget from the host and the expected number of
# concurrent sessions, then exports it in the forms common runners already
# read. Prompts carry the same number as DX_TEST_JOBS for runners that only
# take a flag.

dx_host_cpu_count() {
  local cpu_count=""
  cpu_count=$(getconf _NPROCESSORS_ONLN 2>/dev/null \
    || sysctl -n hw.ncpu 2>/dev/null || true)
  [[ "$cpu_count" =~ ^[1-9][0-9]*$ ]] || cpu_count=1
  printf '%s\n' "$cpu_count"
}

# __dx_host_memory_free_percent_meminfo <file>
# Linux: MemAvailable as a share of MemTotal.
__dx_host_memory_free_percent_meminfo() {
  awk '
    /^MemTotal:/ { total = $2 }
    /^MemAvailable:/ { available = $2 }
    END {
      if (total > 0 && available != "") { printf "%d\n", (available * 100) / total }
      else { exit 1 }
    }' "$1"
}

# __dx_host_memory_free_percent_pressure
# macOS: the free percentage line from `memory_pressure`, read from stdin.
__dx_host_memory_free_percent_pressure() {
  awk -F': *' '
    /^System-wide memory free percentage:/ {
      sub(/%.*$/, "", $2); print $2 + 0; found = 1; exit
    }
    END { if (!found) exit 1 }'
}

# dx_host_memory_free_percent
# Prints an integer 0-100, or fails when the host cannot report it.
# DX_HOST_MEMORY_FREE_PERCENT replaces the probe for tests and containers.
dx_host_memory_free_percent() {
  local override="${DX_HOST_MEMORY_FREE_PERCENT:-}" percent=""
  if [[ -n "$override" ]]; then
    [[ "$override" =~ ^(100|[0-9]{1,2})$ ]] || return 1
    printf '%s\n' "$override"
    return 0
  fi
  if [[ -r /proc/meminfo ]]; then
    percent=$(__dx_host_memory_free_percent_meminfo /proc/meminfo) || return 1
  elif command -v memory_pressure >/dev/null 2>&1; then
    percent=$(memory_pressure 2>/dev/null \
      | __dx_host_memory_free_percent_pressure) || return 1
  else
    return 1
  fi
  [[ "$percent" =~ ^(100|[0-9]{1,2})$ ]] || return 1
  printf '%s\n' "$percent"
}

# dx_host_memory_low
# Succeeds when free memory is below DEX_MIN_FREE_MEMORY_PERCENT (default 10;
# 0 disables the check). An unreadable host counts as not low, so a probe
# failure never stalls work. Returns 2 for a malformed floor.
dx_host_memory_low() {
  local floor="${DEX_MIN_FREE_MEMORY_PERCENT:-10}" percent=""
  [[ "$floor" =~ ^(100|[0-9]{1,2})$ ]] || return 2
  [[ "$floor" -gt 0 ]] || return 1
  percent=$(dx_host_memory_free_percent 2>/dev/null) || return 1
  [[ "$percent" -lt "$floor" ]]
}

# dx_host_test_jobs [cpu-count] [concurrent-sessions]
# DEX_TEST_JOBS (1..32) is the explicit budget. Otherwise half the host's
# cores are shared across the sessions expected to run at once, which defaults
# to the review-wave admission limit, clamped to 1..4.
dx_host_test_jobs() {
  local cpu_count="${1:-}" concurrent="${2:-}" configured="${DEX_TEST_JOBS:-}"
  if [[ -n "$configured" ]]; then
    [[ "$configured" =~ ^[1-9][0-9]*$ && "$configured" -le 32 ]] || return 1
    printf '%s\n' "$configured"
    return 0
  fi
  [[ "$cpu_count" =~ ^[1-9][0-9]*$ ]] || cpu_count=$(dx_host_cpu_count)
  [[ -n "$concurrent" ]] || concurrent="${DEX_REVIEW_MAX_ACTIVE_WAVES:-3}"
  [[ "$concurrent" =~ ^[1-8]$ ]] || return 1
  cpu_count=$((cpu_count / 2 / concurrent))
  [[ "$cpu_count" -ge 1 ]] || cpu_count=1
  [[ "$cpu_count" -le 4 ]] || cpu_count=4
  printf '%s\n' "$cpu_count"
}

# __dx_host_budget_line <name> <value>
# One NAME=VALUE line, unless the caller already exported that name. A value
# the operator or a parent Dex process chose always wins over the derived one.
__dx_host_budget_line() {
  local name="$1" value="$2"
  printenv "$name" >/dev/null 2>&1 && return 0
  printf '%s=%s\n' "$name" "$value"
}

# dx_host_budget_env [jobs]
# Prints the budget as NAME=VALUE lines. Runners that read an environment
# variable get the job count directly; the subagent caps bound how far one
# provider session can fan out on its own.
dx_host_budget_env() {
  local jobs="${1:-}" subagents depth
  if [[ -z "$jobs" ]]; then
    jobs=$(dx_host_test_jobs) || return 1
  fi
  [[ "$jobs" =~ ^[1-9][0-9]*$ && "$jobs" -le 32 ]] || return 1
  subagents="${DEX_MAX_CONCURRENT_SUBAGENTS:-4}"
  depth="${DEX_MAX_SUBAGENT_SPAWN_DEPTH:-2}"
  [[ "$subagents" =~ ^[1-9][0-9]?$ ]] || return 1
  [[ "$depth" =~ ^[1-9]$ ]] || return 1
  __dx_host_budget_line DX_TEST_JOBS "$jobs"
  __dx_host_budget_line VITEST_MAX_THREADS "$jobs"
  __dx_host_budget_line VITEST_MAX_FORKS "$jobs"
  __dx_host_budget_line PYTEST_XDIST_AUTO_NUM_WORKERS "$jobs"
  __dx_host_budget_line CARGO_BUILD_JOBS "$jobs"
  __dx_host_budget_line RUST_TEST_THREADS "$jobs"
  __dx_host_budget_line GOFLAGS "-p=${jobs}"
  __dx_host_budget_line MAKEFLAGS "-j${jobs}"
  __dx_host_budget_line CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS "$subagents"
  __dx_host_budget_line CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH "$depth"
}
