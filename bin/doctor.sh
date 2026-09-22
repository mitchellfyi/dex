#!/usr/bin/env bash
# shellcheck disable=SC1091
# dx doctor — one screen of host health, read-only
#
# Several lifecycles share one machine, and the question a human asks before
# starting another one — "what is already running here?" — needed four
# commands and a mental model of Dex's state directories. This answers it in
# about ten lines from the readers that already exist: the session process
# tokens (dx ps), the capacity pools (dx run-gate), the measured host facts
# (lib/host-budget.sh), and the process table `dx status` prints.
#
# It stops nothing, removes nothing, and writes nothing. `dxclean` lists and
# `dxclean --apply` removes what is left over; `dx ps --reap-orphans` is the
# only path that stops a process.
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: dx doctor

Summarise this host for a human: the Dex sessions running now, the heavy work
holding and waiting for a lease, what is left behind by sessions that are
gone, the measured load and memory, and the largest provider process trees.

Read-only — it stops nothing, removes nothing and writes nothing. Act on what
it reports with 'dxclean' (list) or 'dxclean --apply' (remove), and with
'dx ps --reap-orphans'.

Options:
  -h, --help  Show this help
USAGE
}

show_help=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) show_help=1 ;;
    *)
      dx_error "Unknown doctor option: $arg"
      usage >&2
      exit 1
      ;;
  esac
done
if [[ $show_help -eq 1 ]]; then
  usage
  exit 0
fi

# __dx_doctor_join <max> <item...> — the first <max> items, comma separated,
# with "and N more" when the list was longer, so ten sessions stay one line.
__dx_doctor_join() {
  local limit="$1" shown=0 joined="" item
  shift
  for item in "$@"; do
    if [[ "$shown" -ge "$limit" ]]; then
      printf '%s and %s more\n' "$joined" "$(($# - limit))"
      return 0
    fi
    joined="${joined}${joined:+, }${item}"
    shown=$((shown + 1))
  done
  printf '%s\n' "$joined"
}


# ── Which sessions still hold a process token ───────────────────────────────
#
# Live when the recorded holder PID answers `kill -0`. That is
# dx_host_active_sessions' rule and the host fact every provider launch
# already carries — one directory read and one signal per session, no `ps`.
# `dx ps` answers the same question the expensive way by scanning for the
# token itself, so it also catches a holder whose PID was recycled; this can
# therefore under-report orphans, never over-report them, which is the right
# direction for a read-only summary that names a destructive command.
DOCTOR_LIVE_SESSIONS=()
DOCTOR_ORPHAN_SESSIONS=()
if [[ -d "$DX_LOOP_DIR" ]]; then
  while IFS= read -r doctor_entry; do
    [[ -n "$doctor_entry" ]] || continue
    doctor_name="${doctor_entry##*/}"
    doctor_name="${doctor_name%.process}"
    dx_session_id_valid "$doctor_name" || continue
    doctor_holder=$(dx_session_process_holder_pid "$doctor_name" 2>/dev/null) \
      || doctor_holder=""
    if [[ "$doctor_holder" =~ ^[1-9][0-9]*$ ]] \
      && kill -0 "$doctor_holder" 2>/dev/null; then
      DOCTOR_LIVE_SESSIONS+=("$doctor_name")
      DOCTOR_HOLDERS="${DOCTOR_HOLDERS:-}${DOCTOR_HOLDERS:+ }${doctor_holder}:${doctor_name}"
    else
      DOCTOR_ORPHAN_SESSIONS+=("$doctor_name")
    fi
  done < <(find "$DX_LOOP_DIR" -maxdepth 1 -type d -name '*.process' 2>/dev/null \
    | LC_ALL=C sort)
fi
DOCTOR_HOLDERS="${DOCTOR_HOLDERS:-}"
DOCTOR_LIVE_COUNT="${#DOCTOR_LIVE_SESSIONS[@]}"
DOCTOR_ORPHAN_COUNT="${#DOCTOR_ORPHAN_SESSIONS[@]}"

# Only the orphan candidates are scanned for the processes they still own: a
# dead holder is already enough to call the session gone, and the token scan
# is the one part of this that costs real time.
DOCTOR_ORPHAN_PROCESSES=0
if [[ "$DOCTOR_ORPHAN_COUNT" -gt 0 ]]; then
  for doctor_name in "${DOCTOR_ORPHAN_SESSIONS[@]}"; do
    while IFS= read -r doctor_pid; do
      [[ "$doctor_pid" =~ ^[0-9]+$ ]] || continue
      DOCTOR_ORPHAN_PROCESSES=$((DOCTOR_ORPHAN_PROCESSES + 1))
    done < <(dx_session_process_carriers "$doctor_name" 2>/dev/null || true)
  done
fi

# ── The process table, read once ────────────────────────────────────────────
# Machine-readable lines the shell formats below, so the layout lives in one
# language: `sessions <TAB> records <TAB> running`, and one `tree` row per
# provider process tree.
DOCTOR_TABLE_STATUS=0
DOCTOR_TABLE=$(
  DX_DOCTOR_SCRIPTS="$DEX_DIR/scripts" \
  DX_DOCTOR_CLAUDE_SESSIONS="${CLAUDE_CONFIG_DIR:-$HOME/.claude}/sessions" \
  DX_DOCTOR_HOLDERS="$DOCTOR_HOLDERS" \
    python3 - <<'PY' 2>/dev/null
"""Provider process trees, largest first, and Claude Code's session records.

scripts/host_budget.py already reads one `ps` listing and groups it by the
provider session that started each process, for `dx status`. This imports
that reader instead of keeping a second copy of the grouping.
"""
import json
import os
import subprocess
import sys

sys.path.insert(0, os.environ.get("DX_DOCTOR_SCRIPTS", ""))
try:
    import host_budget
except Exception:  # a vendored subset without scripts/ still gets the rest
    host_budget = None

holders = {}
for pair in os.environ.get("DX_DOCTOR_HOLDERS", "").split():
    holder_pid, _, holder_name = pair.partition(":")
    if holder_pid.isdigit() and holder_name:
        holders[int(holder_pid)] = holder_name


def owning_session(table, pid):
    """The Dex session whose token holder is an ancestor of this tree root."""
    seen = set()
    while pid and pid not in seen:
        if pid in holders:
            return holders[pid]
        seen.add(pid)
        entry = table.get(pid)
        if not entry:
            return ""
        pid = entry[0]
    return ""


def size(megabytes):
    if megabytes >= 1024:
        return "%.1fG" % (megabytes / 1024.0)
    return "%dM" % megabytes


def claude_sessions(directory):
    """(records, running) from Claude Code's own per-session files."""
    records = running = 0
    if not directory or not os.path.isdir(directory):
        return None
    try:
        names = sorted(os.listdir(directory))
    except OSError:
        return None
    for name in names:
        if not name.endswith(".json"):
            continue
        records += 1
        try:
            with open(os.path.join(directory, name), encoding="utf-8") as handle:
                pid = int(json.load(handle).get("pid", 0))
        except (OSError, ValueError, TypeError, AttributeError):
            continue
        if pid <= 0:
            continue
        try:
            os.kill(pid, 0)
        except ProcessLookupError:
            continue
        except OSError:
            pass  # another user's process: alive, just not ours to signal
        running += 1
    return records, running


counted = claude_sessions(os.environ.get("DX_DOCTOR_CLAUDE_SESSIONS", ""))
if counted:
    print("sessions\t%d\t%d" % counted)

# "No provider process tree is running" and "this host would not describe its
# process table" are different facts, and only one of them is reassuring. Say
# which, the way the host readers record a `fallback=` marker rather than
# letting an unmeasurable host read as a measured zero.
if host_budget is None:
    print("table\tunavailable")
    raise SystemExit(0)
try:
    table = host_budget.processes()
except (OSError, subprocess.SubprocessError):
    print("table\tunavailable")
    raise SystemExit(0)
print("table\tok")

trees = []
for root in host_budget.session_roots(table):
    kin = host_budget.descendants(table, root)
    total = table[root][1] + sum(table[pid][1] for pid in kin)
    command = table[root][2].split()[0] if table[root][2] else "?"
    trees.append((total, len(kin) + 1, root,
                  os.path.basename(command)[:8], owning_session(table, root)))
trees.sort(key=lambda row: row[0], reverse=True)

# The three largest, plus every Dex-owned tree those three missed. A host
# whose biggest trees all belong to someone else would otherwise print a
# Sessions line saying Dex owns processes and a Trees section showing none of
# them, which is the one combination that reads as a contradiction.
shown = trees[:3]
for tree in trees:
    if len(shown) >= 6:
        break
    if tree[4] and tree not in shown:
        shown.append(tree)
for total, count, root, command, owner in shown:
    print("tree\t%s\t%d\t%d\t%s\t%s"
          % (size(total), count, root, command, owner or "(no Dex session)"))
PY
) || DOCTOR_TABLE_STATUS=$?

# Did the reader answer at all? A python that could not start loses both the
# trees and the Claude session records, and that has to be said rather than
# rendered as an empty host.
DOCTOR_TABLE_OK=0
if [[ "$DOCTOR_TABLE_STATUS" -eq 0 ]] \
  && printf '%s\n' "$DOCTOR_TABLE" | grep -qx 'table	ok'; then
  DOCTOR_TABLE_OK=1
fi

# ── Host facts, each with the fallback its reader recorded ──────────────────
dx_host_facts
DOCTOR_FREE_PERCENT=$(dx_host_memory_free_percent 2>/dev/null) || DOCTOR_FREE_PERCENT=""
DOCTOR_MEMORY_FLOOR="${DEX_MIN_FREE_MEMORY_PERCENT:-10}"
DOCTOR_TEST_JOBS=$(dx_host_test_jobs_effective 2>/dev/null) || DOCTOR_TEST_JOBS="?"
DOCTOR_MEMORY_TEXT="memory-free percentage unavailable on this host"
if [[ -n "$DOCTOR_FREE_PERCENT" ]]; then
  DOCTOR_MEMORY_TEXT="${DOCTOR_FREE_PERCENT}% memory free (floor ${DOCTOR_MEMORY_FLOOR}%)"
fi
# One marker set, the same shape dx_host_facts publishes, so an unreadable
# process table is recorded beside an unmeasurable memory total instead of
# disappearing into a confident-looking report.
DOCTOR_FALLBACKS="$DX_HOST_FACT_FALLBACKS"
if [[ "$DOCTOR_TABLE_OK" -eq 0 ]]; then
  DOCTOR_FALLBACKS="${DOCTOR_FALLBACKS}${DOCTOR_FALLBACKS:+ }fallback=process_table"
fi

# ── Output ──────────────────────────────────────────────────────────────────
printf '%s\n\n' "Dex — doctor"

printf '%s\n' "Sessions:"
if [[ "$DOCTOR_LIVE_COUNT" -gt 0 ]]; then
  printf '  %s Dex session(s) own processes: %s\n' "$DOCTOR_LIVE_COUNT" \
    "$(__dx_doctor_join 4 "${DOCTOR_LIVE_SESSIONS[@]}")"
else
  printf '  %s\n' "No Dex session on this host currently owns a process."
fi
if [[ "$DOCTOR_TABLE_STATUS" -ne 0 ]]; then
  printf '  %s\n' "Claude Code session records could not be read."
else
  while IFS=$'\t' read -r doctor_kind doctor_records doctor_running; do
    [[ "$doctor_kind" == "sessions" ]] || continue
    printf '  %s of %s Claude Code session record(s) still running\n' \
      "$doctor_running" "$doctor_records"
  done <<< "$DOCTOR_TABLE"
fi

printf '%s\n' "Pools:"
for doctor_pool in heavy waves checks; do
  doctor_limit=$(dx_capacity_pool_limit "$doctor_pool" 2>/dev/null) || doctor_limit="?"
  doctor_held=$(dx_capacity_pool_live_count "$doctor_pool" 2>/dev/null) || doctor_held="?"
  doctor_queued=$(dx_capacity_pool_live_count "$doctor_pool" wait 2>/dev/null) || doctor_queued="?"
  printf '  %-7s %s held (limit %s), %s queued\n' \
    "$doctor_pool" "$doctor_held" "$doctor_limit" "$doctor_queued"
done

printf '%s\n' "Orphans:"
if [[ "$DOCTOR_ORPHAN_COUNT" -gt 0 ]]; then
  printf '  %s session(s) whose process token is dead, %s process(es) still running\n' \
    "$DOCTOR_ORPHAN_COUNT" "$DOCTOR_ORPHAN_PROCESSES"
  printf '  %s\n' "'dx ps' lists them, 'dx ps --reap-orphans' stops them, 'dxclean' shows the rest."
else
  printf '  %s\n' "Nothing left behind by a session that is gone."
fi

printf '%s\n' "Host:"
printf '  %s CPU(s), %s GB memory, load %s, %s\n' \
  "$DX_HOST_FACT_CPUS" "$DX_HOST_FACT_MEM_GB" "$DX_HOST_FACT_LOAD1" \
  "$DOCTOR_MEMORY_TEXT"
printf '  %s test job(s) per session%s\n' "$DOCTOR_TEST_JOBS" \
  "${DOCTOR_FALLBACKS:+; measured with ${DOCTOR_FALLBACKS}}"

printf '%s\n' "Trees:"
DOCTOR_TREE_COUNT=0
if [[ "$DOCTOR_TABLE_OK" -eq 1 ]]; then
  while IFS=$'\t' read -r doctor_kind doctor_size doctor_procs doctor_pid \
    doctor_command doctor_owner; do
    [[ "$doctor_kind" == "tree" ]] || continue
    DOCTOR_TREE_COUNT=$((DOCTOR_TREE_COUNT + 1))
    printf '  %6s  %3s process(es)  pid %-7s %-8s %s\n' \
      "$doctor_size" "$doctor_procs" "$doctor_pid" "$doctor_command" "$doctor_owner"
  done <<< "$DOCTOR_TABLE"
fi
if [[ "$DOCTOR_TABLE_OK" -eq 0 ]]; then
  printf '  %s\n' "Could not read this host's process table (fallback=process_table)."
elif [[ "$DOCTOR_TREE_COUNT" -eq 0 ]]; then
  printf '  %s\n' "No provider process tree is running on this host."
fi

dx_info "Read-only. Nothing here was stopped, removed or written."
