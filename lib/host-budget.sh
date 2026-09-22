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
#
# The module also measures the host facts the `heavy` admission pool and the
# per-phase host snapshot are derived from. Each reader below either answers or
# fails; the snapshot substitutes a conservative default for a reader that
# failed and records `fallback=<name>` so the substitution is visible instead
# of quietly shaping a budget.
#
# Inputs and outputs have separate names, and that separation is load-bearing.
# DX_HOST_CPUS_OVERRIDE, DX_HOST_MEM_GB_OVERRIDE and DX_HOST_LOAD1_OVERRIDE
# replace the corresponding probe, the way DX_HOST_MEMORY_FREE_PERCENT already
# does, so a container that knows its own shape — and every test — states it
# rather than inheriting whatever machine it landed on. The plain DX_HOST_CPUS,
# DX_HOST_MEM_GB, DX_HOST_LOAD1 and DX_HOST_FALLBACKS are what dx_host_snapshot
# *publishes* into a session, and no reader here consults them: a session
# launches further sessions (every review wave is one), so a reader that
# accepted its own published value would hand a nested launch the parent's
# launch-time load average as the current one, and a fallback marker would
# outlive the host condition that earned it.

# Conservative stand-ins for a host that cannot describe itself. Small on
# purpose: an unmeasurable host gets the budget of a small one, never the
# benefit of the doubt.
DX_HOST_FALLBACK_CPUS=2
DX_HOST_FALLBACK_MEM_GB=4
DX_HOST_FALLBACK_LOAD1="0.00"

# __dx_host_cgroup_file <name>
# A readable cgroup v2 limit file, or failure when this host has none.
# DX_HOST_CGROUP_DIR moves the whole lookup for tests and for a host that
# mounts the hierarchy somewhere else.
__dx_host_cgroup_file() {
  local cgroup_dir="${DX_HOST_CGROUP_DIR:-/sys/fs/cgroup}" cgroup_file
  cgroup_file="$cgroup_dir/$1"
  [[ -f "$cgroup_file" && -r "$cgroup_file" ]] || return 1
  printf '%s\n' "$cgroup_file"
}

# __dx_host_cgroup_cpu_limit <cpu.max-file>
# cgroup v2 writes "<quota-microseconds> <period-microseconds>", or "max" when
# the cgroup is not capped. quota/period rounded up is the number of whole CPUs
# it may keep busy; anything below one core still gets one, because zero cores
# is not a budget. Fails when the file names no limit.
__dx_host_cgroup_cpu_limit() {
  awk '
    NR == 1 {
      if ($1 !~ /^[1-9][0-9]*$/ || $2 !~ /^[1-9][0-9]*$/) { exit 1 }
      cpus = int(($1 + $2 - 1) / $2)
      if (cpus < 1) { cpus = 1 }
      print cpus
      found = 1
    }
    END { if (!found) exit 1 }' "$1"
}

# __dx_host_cgroup_memory_limit <memory.max-file>
# Bytes the cgroup may use, or failure for "max" and for the very large
# sentinel values a v1-style hierarchy writes instead.
__dx_host_cgroup_memory_limit() {
  awk '
    NR == 1 {
      if ($1 !~ /^[1-9][0-9]*$/ || length($1) > 17) { exit 1 }
      print $1
      found = 1
    }
    END { if (!found) exit 1 }' "$1"
}

# __dx_host_cpu_probe — logical CPUs this machine reports, or failure
__dx_host_cpu_probe() {
  local cpu_count=""
  cpu_count=$(getconf _NPROCESSORS_ONLN 2>/dev/null \
    || sysctl -n hw.ncpu 2>/dev/null || true)
  [[ "$cpu_count" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "$cpu_count"
}

# dx_host_cpu_count
# Logical CPUs this process may use: the machine's count, lowered to a cgroup
# v2 CPU quota when one is smaller, with DX_HOST_CPUS_OVERRIDE replacing the
# probe. Total by contract — every caller assigns its output under `set -e`, so
# it prints one CPU rather than failing on a host that cannot answer. A
# malformed override falls through to the probe; dx_host_snapshot is where an
# unmeasurable host is reported, as `fallback=cpus`.
dx_host_cpu_count() {
  local cpu_count="" cgroup_file cgroup_cpus=""
  if [[ "${DX_HOST_CPUS_OVERRIDE:-}" =~ ^[1-9][0-9]{0,4}$ ]]; then
    printf '%s\n' "$DX_HOST_CPUS_OVERRIDE"
    return 0
  fi
  cpu_count=$(__dx_host_cpu_probe) || cpu_count=1
  if cgroup_file=$(__dx_host_cgroup_file cpu.max); then
    cgroup_cpus=$(__dx_host_cgroup_cpu_limit "$cgroup_file" 2>/dev/null || true)
    if [[ "$cgroup_cpus" =~ ^[1-9][0-9]*$ \
      && "$cgroup_cpus" -lt "$cpu_count" ]]; then
      cpu_count="$cgroup_cpus"
    fi
  fi
  printf '%s\n' "$cpu_count"
}

# __dx_host_memory_total_kb <file>
# Linux: MemTotal, in kilobytes. Takes the file so the Linux parser is testable
# on a macOS host, the way __dx_host_memory_free_percent_meminfo is.
__dx_host_memory_total_kb() {
  awk '
    /^MemTotal:/ { if ($2 ~ /^[1-9][0-9]*$/) { print $2; found = 1 } exit }
    END { if (!found) exit 1 }' "$1"
}

# dx_host_memory_total_gb
# Whole gigabytes of memory this process may use, lowered to a cgroup v2 memory
# limit when one is smaller. Fails when the host reports none, so the caller
# decides what a missing measurement means. DX_HOST_MEM_GB_OVERRIDE replaces
# the probe.
dx_host_memory_total_gb() {
  local total_kb="" total_bytes="" total_gb="" cgroup_file cgroup_bytes=""
  local cgroup_gb=""
  if [[ -n "${DX_HOST_MEM_GB_OVERRIDE:-}" ]]; then
    [[ "${DX_HOST_MEM_GB_OVERRIDE}" =~ ^[1-9][0-9]{0,5}$ ]] || return 1
    printf '%s\n' "$DX_HOST_MEM_GB_OVERRIDE"
    return 0
  fi
  if [[ -r /proc/meminfo ]]; then
    total_kb=$(__dx_host_memory_total_kb /proc/meminfo) || total_kb=""
    [[ "$total_kb" =~ ^[1-9][0-9]*$ ]] && total_bytes=$((total_kb * 1024))
  elif command -v sysctl >/dev/null 2>&1; then
    total_bytes=$(sysctl -n hw.memsize 2>/dev/null || true)
  fi
  [[ "$total_bytes" =~ ^[1-9][0-9]*$ ]] || return 1
  total_gb=$((total_bytes / 1073741824))
  [[ "$total_gb" -ge 1 ]] || total_gb=1
  if cgroup_file=$(__dx_host_cgroup_file memory.max); then
    cgroup_bytes=$(__dx_host_cgroup_memory_limit "$cgroup_file" \
      2>/dev/null || true)
    if [[ "$cgroup_bytes" =~ ^[1-9][0-9]*$ ]]; then
      cgroup_gb=$((cgroup_bytes / 1073741824))
      [[ "$cgroup_gb" -ge 1 ]] || cgroup_gb=1
      [[ "$cgroup_gb" -lt "$total_gb" ]] && total_gb="$cgroup_gb"
    fi
  fi
  printf '%s\n' "$total_gb"
}

# dx_host_load1
# The one-minute load average, to two decimals. Linux reads /proc/loadavg;
# macOS reads `sysctl -n vm.loadavg`, which prints "{ 1.90 2.06 2.16 }". Fails
# on a host with neither — a container without /proc and without sysctl has no
# load average to report, and inventing one would misinform the reader.
# DX_HOST_LOAD1_OVERRIDE replaces the probe. The published DX_HOST_LOAD1 is
# deliberately not consulted: load is the one fact that changes minute to
# minute, so a nested launch reading it would re-publish its parent's
# launch-time number as the current one.
dx_host_load1() {
  local raw="" load1="" load_rest=""
  if [[ -n "${DX_HOST_LOAD1_OVERRIDE:-}" ]]; then
    [[ "${DX_HOST_LOAD1_OVERRIDE}" =~ ^[0-9]{1,5}(\.[0-9]{1,2})?$ ]] || return 1
    LC_ALL=C printf '%.2f\n' "$DX_HOST_LOAD1_OVERRIDE"
    return 0
  fi
  if [[ -r /proc/loadavg ]]; then
    # load_rest rather than _, which zsh ties to the previous command's last
    # argument; lib/ is sourced by dx.sh and runs there. It only exists to keep
    # the other four fields out of raw.
    # shellcheck disable=SC2034  # the remainder of the line is deliberately discarded
    read -r raw load_rest < /proc/loadavg 2>/dev/null || raw=""
  elif command -v sysctl >/dev/null 2>&1; then
    raw=$(sysctl -n vm.loadavg 2>/dev/null \
      | awk '{ for (field = 1; field <= NF; field++) {
          if ($field ~ /^[0-9]+\.[0-9]+$/) { print $field; exit } } }') || raw=""
  fi
  [[ "$raw" =~ ^[0-9]+(\.[0-9]+)?$ ]] || return 1
  load1=$(LC_ALL=C printf '%.2f' "$raw" 2>/dev/null) || return 1
  printf '%s\n' "$load1"
}

# dx_host_facts
# Measure the host once and publish the result as shell variables:
#   DX_HOST_FACT_CPUS, DX_HOST_FACT_MEM_GB, DX_HOST_FACT_LOAD1
#   DX_HOST_FACT_FALLBACKS — space-separated `fallback=<name>` markers, empty
#                            when every measurement answered
# Call it as a plain command, not inside `$( )`, or the variables stay in the
# subshell. Always succeeds: a fact that could not be measured gets its
# conservative default and a marker naming it.
dx_host_facts() {
  local fallbacks=""
  DX_HOST_FACT_CPUS=$(dx_host_cpu_count)
  if [[ ! "${DX_HOST_CPUS_OVERRIDE:-}" =~ ^[1-9][0-9]{0,4}$ ]] \
    && ! __dx_host_cpu_probe >/dev/null 2>&1; then
    DX_HOST_FACT_CPUS="$DX_HOST_FALLBACK_CPUS"
    fallbacks="${fallbacks}${fallbacks:+ }fallback=cpus"
  fi
  if ! DX_HOST_FACT_MEM_GB=$(dx_host_memory_total_gb 2>/dev/null); then
    DX_HOST_FACT_MEM_GB="$DX_HOST_FALLBACK_MEM_GB"
    fallbacks="${fallbacks}${fallbacks:+ }fallback=mem_gb"
  fi
  if ! DX_HOST_FACT_LOAD1=$(dx_host_load1 2>/dev/null); then
    DX_HOST_FACT_LOAD1="$DX_HOST_FALLBACK_LOAD1"
    fallbacks="${fallbacks}${fallbacks:+ }fallback=load1"
  fi
  DX_HOST_FACT_FALLBACKS="$fallbacks"
}

# dx_host_heavy_limit
# How many heavy commands — project gates, test suites, builds — this host
# admits at once, across every Dex session on it. A dev server is not one: it
# starts directly and is session-owned, never leased.
#
#   max(1, min(cpus / 4, mem_gb / 8)), clamped to 8
#
# Four cores and eight gigabytes is roughly what one project test suite or one
# cold build actually consumes while it runs, so the two terms are the same
# answer from opposite directions and the smaller one wins. The floor of one
# keeps a small host making progress; the ceiling of eight is the pool's own
# limit range. DEX_MAX_ACTIVE_HEAVY (1..8) replaces the whole calculation.
dx_host_heavy_limit() {
  local configured="${DEX_MAX_ACTIVE_HEAVY:-}" cpu_count mem_gb by_cpu by_memory
  local heavy_limit
  if [[ -n "$configured" ]]; then
    [[ "$configured" =~ ^[1-8]$ ]] || return 1
    printf '%s\n' "$configured"
    return 0
  fi
  cpu_count=$(dx_host_cpu_count)
  mem_gb=$(dx_host_memory_total_gb 2>/dev/null) \
    || mem_gb="$DX_HOST_FALLBACK_MEM_GB"
  by_cpu=$((cpu_count / 4))
  by_memory=$((mem_gb / 8))
  heavy_limit="$by_cpu"
  [[ "$by_memory" -lt "$heavy_limit" ]] && heavy_limit="$by_memory"
  [[ "$heavy_limit" -ge 1 ]] || heavy_limit=1
  [[ "$heavy_limit" -le 8 ]] || heavy_limit=8
  printf '%s\n' "$heavy_limit"
}

# dx_host_active_sessions
# Dex sessions on this host that still own processes.
#
# A session records the PID of the shell holding its process token, and that
# PID being alive is the cheapest portable liveness signal there is: one
# directory read, one shell read per session, one kill -0. No `ps`, no /proc,
# no fork per session — which is what lets this run at every phase start and
# every provider launch. `dx ps` answers the same question the expensive way,
# by confirming the holder still carries the token, and is the one to trust
# when the number looks wrong.
dx_host_active_sessions() {
  local holder_file holder_pid session_count=0
  if [[ ! -d "$DX_LOOP_DIR" ]]; then
    printf '0\n'
    return 0
  fi
  while IFS= read -r holder_file; do
    [[ -n "$holder_file" && -f "$holder_file" ]] || continue
    holder_pid=""
    read -r holder_pid < "$holder_file" 2>/dev/null || continue
    [[ "$holder_pid" =~ ^[1-9][0-9]*$ ]] || continue
    kill -0 "$holder_pid" 2>/dev/null || continue
    session_count=$((session_count + 1))
  done < <(find "$DX_LOOP_DIR" -maxdepth 2 -type f -name holder 2>/dev/null \
    || true)
  printf '%s\n' "$session_count"
}

# dx_host_active_heavy
# Heavy leases held on this host right now, for display. Advisory by design:
# it reads the pool without taking its lock so the snapshot stays cheap, and
# lib/review-capacity.sh owns the locked, pruning count that actually decides
# admission. Zero when the capacity module is not loaded.
dx_host_active_heavy() {
  if ! command -v dx_capacity_pool_live_count >/dev/null 2>&1; then
    printf '0\n'
    return 0
  fi
  dx_capacity_pool_live_count heavy 2>/dev/null || printf '0\n'
}

# dx_host_test_jobs_effective
# The job budget this process should pass on: an inherited DX_TEST_JOBS if a
# parent Dex already chose one, otherwise the derived budget. Same precedence
# as __dx_host_budget_line, so the snapshot and the launch environment cannot
# disagree.
dx_host_test_jobs_effective() {
  local inherited="${DX_TEST_JOBS:-}"
  if [[ "$inherited" =~ ^[1-9][0-9]*$ && "$inherited" -le 32 ]]; then
    printf '%s\n' "$inherited"
    return 0
  fi
  dx_host_test_jobs 2>/dev/null || printf '1\n'
}

# dx_host_snapshot
# The host picture every provider session carries and every phase handoff
# refreshes, as NAME=VALUE lines:
#   DX_HOST_CPUS, DX_HOST_MEM_GB, DX_HOST_LOAD1,
#   DX_HOST_ACTIVE_SESSIONS, DX_HOST_ACTIVE_HEAVY, DX_TEST_JOBS
# and DX_HOST_FALLBACKS, which names each measurement that was unavailable and
# got a conservative default, and is emitted *empty* when every one answered.
#
# Unlike dx_host_budget_env these are measurements, not policy, so every line is
# re-emitted from a fresh measurement — a stale core count or load average is
# worse than none, and an inherited fallback marker that the child did not earn
# is worse still, which is why the empty line is emitted rather than omitted.
# The readers above take their overrides from the DX_HOST_*_OVERRIDE names, so
# re-publishing cannot read back what a parent published. DX_TEST_JOBS is policy
# and does keep an inherited value.
dx_host_snapshot() {
  dx_host_facts
  printf 'DX_HOST_CPUS=%s\n' "$DX_HOST_FACT_CPUS"
  printf 'DX_HOST_MEM_GB=%s\n' "$DX_HOST_FACT_MEM_GB"
  printf 'DX_HOST_LOAD1=%s\n' "$DX_HOST_FACT_LOAD1"
  printf 'DX_HOST_ACTIVE_SESSIONS=%s\n' "$(dx_host_active_sessions)"
  printf 'DX_HOST_ACTIVE_HEAVY=%s\n' "$(dx_host_active_heavy)"
  printf 'DX_TEST_JOBS=%s\n' "$(dx_host_test_jobs_effective)"
  printf 'DX_HOST_FALLBACKS=%s\n' "$DX_HOST_FACT_FALLBACKS"
}

# dx_host_handoff_line
# One line for the phase handoff, in numbers the agent can act on rather than
# advice it has to interpret. This is the per-phase refresh for an inline
# lifecycle: the provider process is not relaunched between phases, so its
# exported snapshot is as old as the session and only this line is current.
dx_host_handoff_line() {
  printf 'Host: %s sessions, %s heavy commands running, %s test jobs available to you.\n' \
    "$(dx_host_active_sessions)" "$(dx_host_active_heavy)" \
    "$(dx_host_test_jobs_effective)"
}

# ─── Reduced scheduling priority for heavy work ─────────────────────────────
#
# A heavy command that competes with interactive work wins often enough to make
# the machine feel broken. Run it at reduced priority instead: slower is fine,
# blocking is not. Every wrapper below execs the next word, so an inherited
# descriptor — the session's fd 8, a timeout supervisor's fd 9 — survives the
# whole chain and the command stays owned.

# __dx_host_true_binary — a real `true` to probe a wrapper with
# The shell builtin will not do: each wrapper execs its argument, so the probe
# needs something on disk.
__dx_host_true_binary() {
  local candidate
  for candidate in /usr/bin/true /bin/true; do
    if [[ -x "$candidate" ]]; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done
  return 1
}

# DX_HOST_PRIORITY_WRAPPERS
# The reduced-priority wrappers, strongest first. Each is one name; the prefix
# for it is in dx_host_priority_prefix, and the two lists are the same set.
#
#   systemd-run+ionice  Linux, a transient scope with a halved CPU weight,
#                       renice, and the idle I/O class
#   systemd-run         the same scope where ionice is unavailable
#   nice+taskpolicy     macOS, `nice` plus the background task policy
#   nice+ionice         Linux without a user manager: renice plus idle I/O
#   nice                `nice` alone
#   none                this host would not even renice
#
# systemd-run+ionice exists because CPU weight and I/O class are not
# alternatives: a transient scope halves CPU share and says nothing about the
# disk, which is what a test suite or a cold build actually saturates. Treating
# them as a choice dropped the I/O half on exactly the platform that has it.
DX_HOST_PRIORITY_WRAPPERS="systemd-run+ionice systemd-run nice+taskpolicy nice+ionice nice"

# dx_host_priority_prefix <wrapper>
# The argv words that put a command at reduced priority under <wrapper>, one
# per line, nothing at all for `none`. Every word execs the next, so an
# inherited descriptor survives the whole chain.
dx_host_priority_prefix() {
  case "${1:-}" in
    none) ;;
    nice) printf '%s\n' nice -n 10 ;;
    nice+taskpolicy) printf '%s\n' nice -n 10 taskpolicy -c background ;;
    nice+ionice) printf '%s\n' nice -n 10 ionice -c 3 ;;
    systemd-run)
      printf '%s\n' systemd-run --user --scope -q -p CPUWeight=50 nice -n 10
      ;;
    systemd-run+ionice)
      printf '%s\n' systemd-run --user --scope -q -p CPUWeight=50 \
        nice -n 10 ionice -c 3
      ;;
    *) return 1 ;;
  esac
}

# dx_host_priority_wrapper
# The strongest wrapper in DX_HOST_PRIORITY_WRAPPERS this host can actually run.
#
# Each candidate is probed by running its own full prefix against a real
# binary, so composition is proved rather than inferred: a wrapper whose parts
# are all installed but whose combination fails here — `systemd-run --user` on a
# host with no user manager is the common one — is passed over silently and the
# next candidate is tried. The caller captures the answer once and reuses it,
# which is what makes this one probe per invocation. DEX_GATE_PRIORITY pins a
# name, or `auto` (the default) to probe; an unknown value fails rather than
# guessing.
dx_host_priority_wrapper() {
  local pinned="${DEX_GATE_PRIORITY:-auto}" true_bin="" candidate word
  local probe_head=""
  local probe_words=()
  case "$pinned" in
    auto) ;;
    *)
      dx_host_priority_prefix "$pinned" >/dev/null 2>&1 || return 1
      printf '%s\n' "$pinned"
      return 0
      ;;
  esac
  true_bin=$(__dx_host_true_binary) || { printf 'none\n'; return 0; }
  # Both loops read their list rather than splitting an unquoted parameter:
  # zsh, which sources lib/ through dx.sh, does not word-split one, so a
  # `for candidate in $DX_HOST_PRIORITY_WRAPPERS` would probe one candidate
  # named "systemd-run+ionice systemd-run nice+taskpolicy …" and report `none`
  # on every host. The prefix goes into an array for the same reason.
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    probe_words=()
    probe_head=""
    while IFS= read -r word; do
      [[ -n "$word" ]] || continue
      [[ -n "$probe_head" ]] || probe_head="$word"
      probe_words+=("$word")
    done < <(dx_host_priority_prefix "$candidate" 2>/dev/null || true)
    [[ -n "$probe_head" ]] || continue
    command -v "$probe_head" >/dev/null 2>&1 || continue
    if "${probe_words[@]}" "$true_bin" >/dev/null 2>&1; then
      printf '%s\n' "$candidate"
      return 0
    fi
  done <<EOF
$(printf '%s\n' "$DX_HOST_PRIORITY_WRAPPERS" | tr ' ' '\n')
EOF
  printf 'none\n'
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
# shellcheck disable=SC2120  # review-loop.sh and the tests pass the CPU count and wave limit
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

# ─── Heavy-gate receipts ────────────────────────────────────────────────────
#
# A gate that finished is evidence, and evidence is what stops the next phase
# re-running it. The receipt records what ran, on which tree, with what result,
# and it is written whether the gate passed or failed — a failure is as much a
# fact about that tree as a pass.
#
# Receipts live beside the session's other loop state rather than in the
# session temp root, because the temp root goes away with the session and a
# later phase of the same lifecycle is exactly who wants to read them. They are
# keyed by two fingerprints: the checkout fingerprint (HEAD) and the working
# fingerprint from lib/review.sh, the same working-tree hash bin/review-check.sh
# keys its own reuse on. A gate whose tree changed while it ran records
# `stable: false` and is never returned by a lookup: the result is real, but it
# is not a statement about any tree that still exists.

# dx_gate_receipt_dir <session_id>
dx_gate_receipt_dir() {
  dx_session_id_valid "${1:-}" || return 2
  printf '%s/%s.gate-receipts\n' "$DX_LOOP_DIR" "$1"
}

# dx_gate_receipt_slot <gate-name>
# One receipt per gate name per session: the newest result for a gate is the
# only one worth keeping, and a name that cannot be a filename is rejected
# rather than sanitised into a collision with another gate.
dx_gate_receipt_slot() {
  local gate_name="${1:-}"
  [[ -n "$gate_name" && ${#gate_name} -le 64 ]] || return 2
  [[ "$gate_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]] || return 2
  printf '%s\n' "$gate_name"
}

# dx_gate_receipt_write <session_id> <gate> <checkout-fp> <working-fp>
#   <stable:0|1> <exit-code> <duration-seconds> <queue-seconds> <wrapper>
#   <test-jobs> <parallelism-env> <log-path> <command> [args...]
# <parallelism-env> is a space-separated list of the variable names that were
# set, or empty. Written atomically, 0600, under a 0700 directory.
dx_gate_receipt_write() {
  [[ $# -ge 13 ]] || return 2
  local session_id="$1" gate_name="$2" checkout_fp="$3" working_fp="$4"
  local stable="$5" exit_code="$6" duration="$7" queued="$8" wrapper="$9"
  shift 9
  local test_jobs="$1" parallelism_env="$2" gate_log="$3"
  shift 3
  local receipt_dir receipt_slot receipt_file receipt_tmp
  [[ $# -ge 1 ]] || return 2
  receipt_dir=$(dx_gate_receipt_dir "$session_id") || return 2
  receipt_slot=$(dx_gate_receipt_slot "$gate_name") || return 2
  [[ "$stable" =~ ^[01]$ ]] || return 2
  [[ "$exit_code" =~ ^[0-9]{1,3}$ ]] || return 2
  [[ "$duration" =~ ^[0-9]{1,9}$ && "$queued" =~ ^[0-9]{1,9}$ ]] || return 2
  mkdir -p "$receipt_dir" || return 1
  chmod 700 "$receipt_dir" 2>/dev/null || true
  receipt_file="$receipt_dir/$receipt_slot.json"
  receipt_tmp="${receipt_file}.tmp.${$}"
  if ! DX_GATE_RECEIPT_SESSION="$session_id" \
    DX_GATE_RECEIPT_GATE="$gate_name" \
    DX_GATE_RECEIPT_CHECKOUT="$checkout_fp" \
    DX_GATE_RECEIPT_WORKING="$working_fp" \
    DX_GATE_RECEIPT_STABLE="$stable" \
    DX_GATE_RECEIPT_EXIT="$exit_code" \
    DX_GATE_RECEIPT_DURATION="$duration" \
    DX_GATE_RECEIPT_QUEUED="$queued" \
    DX_GATE_RECEIPT_WRAPPER="$wrapper" \
    DX_GATE_RECEIPT_JOBS="$test_jobs" \
    DX_GATE_RECEIPT_PARALLELISM="$parallelism_env" \
    DX_GATE_RECEIPT_LOG="$gate_log" \
    DX_GATE_RECEIPT_FILE="$receipt_tmp" \
    python3 - "$@" <<'PY'
import json
import os
import sys
from datetime import datetime, timezone

receipt = {
    "session": os.environ["DX_GATE_RECEIPT_SESSION"],
    "gate": os.environ["DX_GATE_RECEIPT_GATE"],
    "command": sys.argv[1:],
    "exit_code": int(os.environ["DX_GATE_RECEIPT_EXIT"]),
    "duration_seconds": int(os.environ["DX_GATE_RECEIPT_DURATION"]),
    "queue_seconds": int(os.environ["DX_GATE_RECEIPT_QUEUED"]),
    "checkout_fingerprint": os.environ["DX_GATE_RECEIPT_CHECKOUT"],
    "working_fingerprint": os.environ["DX_GATE_RECEIPT_WORKING"],
    "stable": os.environ["DX_GATE_RECEIPT_STABLE"] == "1",
    "priority_wrapper": os.environ["DX_GATE_RECEIPT_WRAPPER"],
    "test_jobs": os.environ["DX_GATE_RECEIPT_JOBS"],
    "parallelism_env": os.environ["DX_GATE_RECEIPT_PARALLELISM"].split(),
    "log": os.environ["DX_GATE_RECEIPT_LOG"],
    "recorded_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
target = os.environ["DX_GATE_RECEIPT_FILE"]
descriptor = os.open(target, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
with os.fdopen(descriptor, "w", encoding="utf-8") as handle:
    json.dump(receipt, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
  then
    command rm -f "$receipt_tmp" 2>/dev/null || true
    return 1
  fi
  command mv -f "$receipt_tmp" "$receipt_file" || {
    command rm -f "$receipt_tmp" 2>/dev/null || true
    return 1
  }
  printf '%s\n' "$receipt_file"
}

# The receipt name the prompts give the project's complete gate
# (`dx run-gate --name full-gate <command>`), so Phase 4 and the review tier
# floor can ask for that one by name instead of taking any passing receipt —
# a linter run through `dx run-gate` — as evidence for the whole suite.
# shellcheck disable=SC2034  # read by __dx_review_full_gate_green in lib/review.sh
DX_GATE_FULL_GATE_NAME="full-gate"

# dx_gate_receipt_lookup <session_id|-> <checkout-fp> <working-fp> [gate]
# Every gate this session already ran against exactly this tree, newest first,
# one per line:
#
#   session <TAB> gate <TAB> exit_code <TAB> duration_seconds <TAB>
#   recorded_at <TAB> command
#
# `-` as the session scans every session's receipts on the host. It is an
# explicit opt-in, not a default: the fingerprints hash the tree, not the
# environment, so two worktrees on one HEAD could share a pass their toolchains
# would not, and cross-session sharing is deferred until the single-session
# ladder has shown its numbers. Returns 0 when at least one receipt matched, 1
# when none did, and 2 for arguments it will not act on. A receipt whose tree
# moved while the gate ran (`stable: false`) never matches.
dx_gate_receipt_lookup() {
  [[ $# -ge 3 && $# -le 4 ]] || return 2
  local session_id="$1" checkout_fp="$2" working_fp="$3" gate_name="${4:-}"
  local receipt_root
  [[ -n "$checkout_fp" && -n "$working_fp" ]] || return 2
  if [[ "$session_id" == "-" ]]; then
    receipt_root="$DX_LOOP_DIR"
  else
    receipt_root=$(dx_gate_receipt_dir "$session_id") || return 2
  fi
  [[ -n "$gate_name" ]] && { dx_gate_receipt_slot "$gate_name" >/dev/null \
    || return 2; }
  [[ -d "$receipt_root" ]] || return 1
  DX_GATE_LOOKUP_ROOT="$receipt_root" \
  DX_GATE_LOOKUP_SCOPE="$session_id" \
  DX_GATE_LOOKUP_CHECKOUT="$checkout_fp" \
  DX_GATE_LOOKUP_WORKING="$working_fp" \
  DX_GATE_LOOKUP_GATE="$gate_name" \
    python3 - <<'PY'
import json
import os
import sys
from pathlib import Path

root = Path(os.environ["DX_GATE_LOOKUP_ROOT"])
scope = os.environ["DX_GATE_LOOKUP_SCOPE"]
checkout = os.environ["DX_GATE_LOOKUP_CHECKOUT"]
working = os.environ["DX_GATE_LOOKUP_WORKING"]
wanted = os.environ["DX_GATE_LOOKUP_GATE"]

paths = (
    sorted(root.glob("*.gate-receipts/*.json"))
    if scope == "-"
    else sorted(root.glob("*.json"))
)
rows = []
for path in paths:
    try:
        with path.open("r", encoding="utf-8") as handle:
            receipt = json.load(handle)
    except (OSError, json.JSONDecodeError):
        continue
    if not isinstance(receipt, dict) or not receipt.get("stable"):
        continue
    if receipt.get("checkout_fingerprint") != checkout:
        continue
    if receipt.get("working_fingerprint") != working:
        continue
    if wanted and receipt.get("gate") != wanted:
        continue
    command = receipt.get("command")
    command = " ".join(command) if isinstance(command, list) else ""
    rows.append(
        (
            str(receipt.get("recorded_at", "")),
            "\t".join(
                str(field).replace("\t", " ").replace("\n", " ")
                for field in (
                    receipt.get("session", ""),
                    receipt.get("gate", ""),
                    receipt.get("exit_code", ""),
                    receipt.get("duration_seconds", ""),
                    receipt.get("recorded_at", ""),
                    command,
                )
            ),
        )
    )
if not rows:
    raise SystemExit(1)
for _, line in sorted(rows, key=lambda row: row[0], reverse=True):
    print(line)
PY
}
