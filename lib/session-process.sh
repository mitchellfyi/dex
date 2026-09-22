# shellcheck shell=bash
# Dex shared library — session process ownership and per-session telemetry
#
# Split out of lib/session.sh, which keeps session IDs, state paths and the
# per-command timeout. This module owns everything a provider session starts:
# the per-phase ownership token, the carrier scan, the reap at session end,
# phase exit and orphan sweep, the `dx ps` process descriptions, and the gate,
# peak-RSS and summary telemetry the reap reports.
#
# Depends on lib/session.sh (dx_session_id_valid, the state-dir helpers,
# __dx_timeout_token_pids and __dx_timeout_process_tree_pids), so lib/common.sh
# sources it right after that module. Fast paths that list modules in
# DX_COMMON_MODULES name both: hooks/session-end.sh loads
# "session session-process" and nothing else, and the minimal vendored runtimes
# in tests carry exactly those two files beside common.sh.

# ─── Session process ownership ──────────────────────────────────────────────
#
# A process an agent starts during a session must not outlive the session,
# however it was launched. The provider session opens the session token file on
# fd 8 and exports DX_SESSION_PROCESS_TOKEN, so every descendant carries both —
# including one that later nohup/disown/setsid's itself out of the process
# tree, where a PPID walk can no longer reach it. At session end the same
# descriptor-identity scan `dx_run_with_timeout` uses finds them again.
#
# fd 8 and fd 9 are deliberately different descriptors: `dx_run_with_timeout`
# re-opens fd 9 for each supervised command, so sharing one would drop the
# session's ownership of everything that command started.
#
# Everything here derives from the session ID alone, because the SessionEnd
# hook has nothing else to work from.

DX_SESSION_PROCESS_FD=8
DX_SESSION_PROCESS_ENV=DX_SESSION_PROCESS_TOKEN

# dx_session_process_dir <session_id> — per-session process-ownership state
dx_session_process_dir() {
  dx_session_id_valid "${1:-}" || return 2
  printf '%s/%s.process\n' "$DX_LOOP_DIR" "$1"
}

# dx_session_process_token_file <session_id> — the file fd 8 is opened on
dx_session_process_token_file() {
  local process_dir
  process_dir=$(dx_session_process_dir "${1:-}") || return 2
  printf '%s/token\n' "$process_dir"
}

# dx_session_process_holder_file <session_id> — PID of the shell holding fd 8
dx_session_process_holder_file() {
  local process_dir
  process_dir=$(dx_session_process_dir "${1:-}") || return 2
  printf '%s/holder\n' "$process_dir"
}

# dx_session_tmp_dir <session_id> — the session's temp root (DX_SESSION_TMP)
#
# Browser profiles, gate logs, and anything else a session scratches onto disk
# belong here so session end removes them with one directory rather than
# guessing at $TMPDIR entries it did not create.
dx_session_tmp_dir() {
  local process_dir
  process_dir=$(dx_session_process_dir "${1:-}") || return 2
  printf '%s/tmp\n' "$process_dir"
}

# __dx_session_process_token_value <session_id> — read a valid existing token
__dx_session_process_token_value() {
  local token_file token_value
  token_file=$(dx_session_process_token_file "${1:-}") || return 2
  [[ -f "$token_file" ]] || return 1
  token_value=$(cat "$token_file" 2>/dev/null) || return 1
  token_value="${token_value%%$'\n'*}"
  [[ "$token_value" =~ ^[A-Za-z0-9._-]{16,160}$ ]] || return 1
  printf '%s\n' "$token_value"
}

# dx_session_process_token_attach <session_id> — own this shell's descendants
#
# Call this inside the subshell that is about to run the provider: `exec`
# applies to the calling shell, so calling it anywhere else would leave fd 8
# open in an interactive shell. One token per provider session, which in a
# lifecycle is one phase: the phase-exit reap stops what the token identifies
# and removes it, and the next phase attaches a fresh one.
dx_session_process_token_attach() {
  local session_id="${1:-}" process_dir token_file holder_file tmp_dir
  local token_value holder_pid token_tmp
  dx_session_id_valid "$session_id" || return 2
  process_dir=$(dx_session_process_dir "$session_id") || return 2
  token_file=$(dx_session_process_token_file "$session_id") || return 2
  holder_file=$(dx_session_process_holder_file "$session_id") || return 2
  tmp_dir=$(dx_session_tmp_dir "$session_id") || return 2

  mkdir -p "$process_dir" 2>/dev/null || return 1
  chmod 700 "$process_dir" 2>/dev/null || true
  if ! token_value=$(__dx_session_process_token_value "$session_id"); then
    token_value="dxs-${$}-${RANDOM}-${RANDOM}-$(date +%s)"
    [[ "$token_value" =~ ^[A-Za-z0-9._-]{16,160}$ ]] || return 1
    token_tmp="${token_file}.tmp.${$}"
    (umask 077 && printf '%s\n' "$token_value" > "$token_tmp") || return 1
    command mv "$token_tmp" "$token_file" 2>/dev/null || {
      command rm -f "$token_tmp" 2>/dev/null || true
      return 1
    }
  fi
  mkdir -p "$tmp_dir" 2>/dev/null || return 1
  chmod 700 "$tmp_dir" 2>/dev/null || true

  # This phase's telemetry starts empty even when the directory did not. A
  # directory that outlived its last session still carries that session's
  # summary marker, gate rows and peak; inheriting the marker would mean this
  # phase is never summarised at all.
  __dx_session_telemetry_reset "$session_id" || true

  # $$ stays the main shell's PID inside a subshell on both shells, and this
  # runs in one, so a short child has to report the real holder. It writes
  # through a redirect rather than a command substitution on purpose: bash
  # forks an extra subshell to run a *list* inside `$( … )`, and `$PPID` would
  # then name that fork instead of this shell.
  holder_pid=""
  /bin/sh -c 'printf "%s\n" "$PPID"' > "${holder_file}.tmp.${$}" 2>/dev/null \
    || true
  if [[ -s "${holder_file}.tmp.${$}" ]]; then
    holder_pid=$(cat "${holder_file}.tmp.${$}" 2>/dev/null || true)
    holder_pid="${holder_pid%%$'\n'*}"
  fi
  if [[ "$holder_pid" =~ ^[0-9]+$ ]]; then
    chmod 600 "${holder_file}.tmp.${$}" 2>/dev/null || true
    command mv "${holder_file}.tmp.${$}" "$holder_file" 2>/dev/null || true
  fi
  command rm -f "${holder_file}.tmp.${$}" 2>/dev/null || true

  export DX_SESSION_PROCESS_TOKEN="$token_value"
  export DX_SESSION_TMP="$tmp_dir"
  exec 8< "$token_file" || return 1
}

# dx_session_process_carriers <session_id> [method_file]
#   — PIDs currently carrying this session's token
dx_session_process_carriers() {
  local session_id="${1:-}" method_file="${2:-}" token_file
  token_file=$(dx_session_process_token_file "$session_id") || return 2
  [[ -f "$token_file" ]] || return 0
  DX_TOKEN_SCAN_METHOD_FILE="$method_file" \
    __dx_timeout_token_pids "$token_file" "" "$DX_SESSION_PROCESS_FD" \
      "$DX_SESSION_PROCESS_ENV" 2>/dev/null || true
}

# dx_session_process_holder_pid <session_id> — recorded holder PID, if any
dx_session_process_holder_pid() {
  local holder_file holder_pid
  holder_file=$(dx_session_process_holder_file "${1:-}") || return 2
  [[ -f "$holder_file" ]] || return 1
  holder_pid=$(cat "$holder_file" 2>/dev/null) || return 1
  holder_pid="${holder_pid%%$'\n'*}"
  [[ "$holder_pid" =~ ^[0-9]{1,12}$ ]] || return 1
  printf '%s\n' "$holder_pid"
}

# __dx_session_reaper_self_pid_var — set DX_SESSION_REAP_SELF_PID to the real
# PID of the shell calling the reaper.
#
# `$$` names the top-level shell even inside a subshell, so a reap running in
# one would exclude its parent's ancestry and then stop itself. lib/lock.sh
# already answers this portably, including on a bash 3.2 without BASHPID, so
# this loads that module rather than keeping a second copy of the trick. Like
# the helper it borrows, it must be called as a plain command: through a
# command substitution it would report the substitution's subshell.
__dx_session_reaper_self_pid_var() {
  DX_SESSION_REAP_SELF_PID=""
  if ! command -v dx_lock_self_pid_var >/dev/null 2>&1; then
    if [[ -f "${DEX_DIR:-}/lib/lock.sh" ]]; then
      # shellcheck disable=SC1091
      source "${DEX_DIR}/lib/lock.sh" 2>/dev/null || true
    fi
  fi
  if command -v dx_lock_self_pid_var >/dev/null 2>&1; then
    dx_lock_self_pid_var
    DX_SESSION_REAP_SELF_PID="${DX_LOCK_SELF_PID:-}"
  fi
  [[ "$DX_SESSION_REAP_SELF_PID" =~ ^[0-9]+$ ]] || DX_SESSION_REAP_SELF_PID="$$"
}

# __dx_session_process_ancestors [pid] — this process and everything above it
#
# The reaper usually runs from inside the session it is reaping: the SessionEnd
# hook, the provider that spawned it, and the shell holding fd 8 all carry the
# token. Excluding the caller's own ancestry is what keeps a reap pass from
# stopping itself before it finishes.
__dx_session_process_ancestors() {
  local pid="${1:-$$}" seen=0
  while [[ "$pid" =~ ^[0-9]+$ && "$pid" -gt 1 && $seen -lt 64 ]]; do
    printf '%s\n' "$pid"
    seen=$((seen + 1))
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]')
  done
}

# dx_session_process_describe <pids…> — one TSV row per live PID
#   pid<TAB>ppid<TAB>age_seconds<TAB>rss_kb<TAB>cwd<TAB>command
#
# `ps` covers both platforms for everything but the working directory, which
# needs /proc on Linux and one lsof call for every PID on macOS. A host that
# can supply neither reports "-" rather than dropping the row.
dx_session_process_describe() {
  local pid_list="$*"
  [[ -n "${pid_list//[[:space:]]/}" ]] || return 0
  DX_SESSION_DESCRIBE_PIDS="$pid_list" python3 - <<'PY'
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path

requested = []
for value in os.environ.get("DX_SESSION_DESCRIBE_PIDS", "").split():
    if value.isdigit() and int(value) > 0:
        requested.append(int(value))
if not requested:
    raise SystemExit(0)

ELAPSED = re.compile(r"^(?:(?:(\d+)-)?(\d+):)?(\d+):(\d+)$")


def elapsed_seconds(text):
    matched = ELAPSED.match(text.strip())
    if not matched:
        return -1
    days, hours, minutes, seconds = (int(part or 0) for part in matched.groups())
    return ((days * 24 + hours) * 60 + minutes) * 60 + seconds


def lsof_cwd(lsof, process_ids):
    """{pid: cwd} from one lsof call, or None when the call itself failed.

    lsof exits 1 whenever any listed PID had nothing to show — one that exited
    between the snapshot and this call — so the exit status is not the failure
    signal; an exception, or nothing listed at an exit above 1, is.
    """
    try:
        completed = subprocess.run(
            [lsof, "-a", "-p", ",".join(str(pid) for pid in process_ids),
             "-d", "cwd", "-Fpn"],
            stdout=subprocess.PIPE, stderr=subprocess.DEVNULL, timeout=5,
            text=True, check=False,
        )
    except (OSError, subprocess.TimeoutExpired):
        return None
    found = {}
    selected = None
    for line in completed.stdout.splitlines():
        if line.startswith("p") and line[1:].isdigit():
            selected = int(line[1:])
        elif line.startswith("n") and selected is not None:
            found.setdefault(selected, line[1:] or "-")
    if not found and completed.returncode not in (0, 1):
        return None
    return found


def working_directories(process_ids):
    """cwd per PID: /proc where it answers, else one lsof call for the rest.

    The per-PID lsof this replaced cost about 0.4 s per process on macOS —
    `dx ps` spent six seconds describing fourteen — and the same call runs
    inside the SessionEnd reap under the host's ten-second budget. One
    `lsof -a -p <pid,pid,...> -d cwd -Fpn` answers for all of them; the
    per-PID form is kept only for a batch call that failed outright.
    """
    resolved = {}
    pending = []
    for process_id in process_ids:
        try:
            resolved[process_id] = os.readlink(Path("/proc") / str(process_id) / "cwd")
        except OSError:
            pending.append(process_id)
    if not pending:
        return resolved
    lsof = shutil.which("lsof")
    if not lsof and sys.platform == "darwin" and Path("/usr/sbin/lsof").is_file():
        lsof = "/usr/sbin/lsof"
    if not lsof:
        return resolved
    batch = lsof_cwd(lsof, pending)
    if batch is None:
        for process_id in pending:
            single = lsof_cwd(lsof, [process_id])
            if single:
                resolved.update(single)
        return resolved
    resolved.update(batch)
    return resolved


try:
    listing = subprocess.check_output(
        ["ps", "-o", "pid=,ppid=,etime=,rss=,args=", "-p",
         ",".join(str(pid) for pid in requested)],
        stderr=subprocess.DEVNULL, timeout=10, text=True,
    )
except (OSError, subprocess.CalledProcessError, subprocess.TimeoutExpired):
    raise SystemExit(0)

rows = []
for line in listing.splitlines():
    fields = line.split(None, 4)
    if len(fields) < 4 or not fields[0].isdigit():
        continue
    process_id = int(fields[0])
    if process_id not in requested:
        continue
    rows.append((process_id, fields))
cwds = working_directories([process_id for process_id, _ in rows])
for process_id, fields in rows:
    parent_id = fields[1] if fields[1].isdigit() else "-"
    age = elapsed_seconds(fields[2])
    rss = fields[3] if fields[3].isdigit() else "-"
    command = (fields[4] if len(fields) > 4 else "-").strip() or "-"
    command = command.replace("\t", " ")[:200]
    print("\t".join([
        str(process_id), parent_id, str(age), rss,
        cwds.get(process_id, "-").replace("\t", " "), command,
    ]))
PY
}

# __dx_session_output_ready — load lib/output.sh on demand
#
# The SessionEnd fast path loads only lib/session.sh and this module, so the output helpers
# are not there. A reap that stopped something has to say so on that path too,
# which is the whole point of it not being a hidden janitor.
__dx_session_output_ready() {
  command -v dx_info >/dev/null 2>&1 && return 0
  [[ -f "${DEX_DIR:-}/lib/output.sh" ]] || return 1
  # shellcheck disable=SC1091
  source "${DEX_DIR}/lib/output.sh" 2>/dev/null || return 1
  command -v dx_info >/dev/null 2>&1
}

# __dx_session_report <info|ok|warn> <message>
# Prints the same shapes lib/output.sh does when that module cannot be loaded,
# rather than going silent where it matters most.
__dx_session_report() {
  local kind="$1" message="$2"
  if __dx_session_output_ready; then
    case "$kind" in
      ok) dx_ok "$message" ;;
      warn) dx_warn "$message" ;;
      *) dx_info "$message" ;;
    esac
    return 0
  fi
  case "$kind" in
    ok) printf '[ok]    %s\n' "$message" ;;
    warn) printf '[warn]  %s\n' "$message" >&2 ;;
    *) printf '[info]  %s\n' "$message" ;;
  esac
}

# __dx_session_events_ready — load the run-event helpers only when needed
#
# The SessionEnd hook has a short host-side deadline and loads only
# lib/session.sh and this module to protect it. A reap that found nothing therefore costs no extra
# sourcing; one that did pays for the event modules once.
#
# The journal lock is part of that cost. `dx_event_emit` calls
# `dx_lock_self_pid_var` and then uses the variable it sets, so a missing
# lib/lock.sh is not a degraded event — under `set -u` it is an unbound
# variable that ends the hook. Both modules load together, and the caller gets
# no events at all unless both are present.
__dx_session_events_ready() {
  if ! command -v dx_lock_self_pid_var >/dev/null 2>&1; then
    [[ -f "${DEX_DIR:-}/lib/lock.sh" ]] || return 1
    # shellcheck disable=SC1091
    source "${DEX_DIR}/lib/lock.sh" 2>/dev/null || return 1
  fi
  if ! command -v dx_event_emit_for_session >/dev/null 2>&1; then
    [[ -f "${DEX_DIR:-}/lib/events.sh" ]] || return 1
    # shellcheck disable=SC1091
    source "${DEX_DIR}/lib/events.sh" 2>/dev/null || return 1
  fi
  command -v dx_event_emit_for_session >/dev/null 2>&1 \
    && command -v dx_lock_self_pid_var >/dev/null 2>&1 \
    && command -v dx_lock_acquire >/dev/null 2>&1
}

# __dx_session_reap_event <session_id> <type> <severity> <message> <data_json>
__dx_session_reap_event() {
  local session_id="$1" event_type="$2" severity="$3" message="$4"
  local data_json="$5"
  __dx_session_events_ready || return 0
  dx_event_emit_for_session "$session_id" "$event_type" "$severity" \
    "$message" "" "$data_json" 2>/dev/null || true
  return 0
}

# __dx_session_reap_json <pid> <ppid> <age> <rss> <cwd> <command> <method>
#   <reason>
__dx_session_reap_json() {
  DX_REAP_PID="$1" DX_REAP_PPID="$2" DX_REAP_AGE="$3" DX_REAP_RSS="$4" \
  DX_REAP_CWD="$5" DX_REAP_COMMAND="$6" DX_REAP_METHOD="$7" \
  DX_REAP_REASON="$8" \
    python3 - <<'PY'
import json
import os


def number(name):
    value = os.environ.get(name, "")
    try:
        parsed = int(value)
    except ValueError:
        return None
    return parsed if parsed >= 0 else None


print(json.dumps({
    "pid": number("DX_REAP_PID"),
    "ppid": number("DX_REAP_PPID"),
    "age_seconds": number("DX_REAP_AGE"),
    "rss_kb": number("DX_REAP_RSS"),
    "cwd": os.environ.get("DX_REAP_CWD", "")[:400],
    "command": os.environ.get("DX_REAP_COMMAND", "")[:200],
    "method": os.environ.get("DX_REAP_METHOD", ""),
    "reason": os.environ.get("DX_REAP_REASON", ""),
}, separators=(",", ":")))
PY
}

# dx_session_reap_processes <session_id> <reason> [scope]
#
#   scope=session  (default) stop every token carrier except the caller's own
#                  ancestry — the session is ending, so its children end too.
#   scope=detached stop only carriers outside the live holder's process tree.
#                  `dx control stop` runs while the provider may still be up;
#                  the leftovers it detached are the ones that must go.
#
# TERM, a grace period, then KILL, through the same terminator the per-command
# timeout uses. Prints one line per reaped process and emits `session.reaped`
# for each plus one `session.reap.completed` summary.
#
# Returns 0 when every owned process is gone and 1 when one survived, so a
# caller can tell the difference before it decides to delete the token — which
# is the only way to find that process again. 2 rejects bad arguments.
dx_session_reap_processes() {
  local session_id="${1:-}" reason="${2:-session-end}" scope="${3:-session}"
  local token_file method_file method="unavailable" excluded="" carriers=""
  local holder_pid holder_tree="" candidate_pid row reaped=0 survived=0
  local candidate_count=0 reaped_json snapshot_file describe_pids="" self_pid
  local describe_lines="" settle_attempt=0
  dx_session_id_valid "$session_id" || return 2
  [[ "$reason" =~ ^[a-z][a-z0-9-]{0,63}$ ]] || return 2
  case "$scope" in
    session|detached) ;;
    *) return 2 ;;
  esac
  token_file=$(dx_session_process_token_file "$session_id") || return 2
  [[ -f "$token_file" ]] || return 0
  __dx_session_reaper_self_pid_var
  self_pid="$DX_SESSION_REAP_SELF_PID"

  method_file="${token_file}.scan.${self_pid}"
  carriers=$(dx_session_process_carriers "$session_id" "$method_file")
  if [[ -s "$method_file" ]]; then
    method=$(cat "$method_file" 2>/dev/null || true)
    method="${method%%$'\n'*}"
  fi
  command rm -f "$method_file" 2>/dev/null || true
  if [[ -z "${carriers//[[:space:]]/}" ]]; then
    # "Nothing is running" and "this host could not tell me" are different
    # answers. Reading the second as the first would delete the token, and
    # with it the only way to find whatever is still running.
    [[ "$method" != "unavailable" ]] || {
      printf 'unscannable: no ownership scan on this host (no /proc, no libproc, no lsof)\n'
      return 1
    }
    return 0
  fi

  excluded=$(__dx_session_process_ancestors "$self_pid" | tr '\n' ' ')
  if [[ "$scope" == "detached" ]]; then
    if holder_pid=$(dx_session_process_holder_pid "$session_id"); then
      holder_tree=$(__dx_timeout_process_tree_pids "$holder_pid" 2>/dev/null \
        || true)
      excluded="${excluded}$(printf '%s' "$holder_tree" | tr '\n' ' ') "
    fi
  fi

  while IFS= read -r candidate_pid; do
    [[ "$candidate_pid" =~ ^[0-9]+$ ]] || continue
    case " $excluded " in
      *" $candidate_pid "*) continue ;;
    esac
    candidate_count=$((candidate_count + 1))
    describe_pids="${describe_pids}${candidate_pid} "
    describe_lines="${describe_lines}${candidate_pid}"$'\n'
  done <<EOF
$carriers
EOF
  [[ "$candidate_count" -gt 0 ]] || return 0

  # Snapshot before signalling: a reaped process cannot be described after it
  # is gone, and the log is the only visible record of what was stopped.
  snapshot_file="${token_file}.snapshot.${self_pid}"
  (umask 077 && dx_session_process_describe "$describe_pids" \
    > "$snapshot_file") 2>/dev/null || true

  __dx_timeout_terminate_processes "$token_file" "" "" \
    "$DX_SESSION_PROCESS_FD" "$DX_SESSION_PROCESS_ENV" "$excluded" \
    2>/dev/null || true

  # `kill -0` still succeeds on a zombie, and the terminator only spends its
  # grace period when a non-zombie survivor exists — so a process that died
  # promptly can still look alive the instant it returns. Give the whole set a
  # bounded window, using the Z*-aware liveness check, before classifying any
  # of it: a misread here drops the reap log entry the process was owed and
  # reports a survivor that is already gone.
  while [[ $settle_attempt -lt 40 ]]; do
    __dx_timeout_pid_list_alive "$describe_lines" || break
    dx_pause 0.05 2>/dev/null || true
    settle_attempt=$((settle_attempt + 1))
  done

  if [[ -f "$snapshot_file" ]]; then
    while IFS= read -r row; do
      [[ -n "$row" ]] || continue
      if __dx_session_reap_report "$session_id" "$reason" "$method" "$row"; then
        reaped=$((reaped + 1))
      else
        survived=$((survived + 1))
      fi
    done < "$snapshot_file"
    command rm -f "$snapshot_file" 2>/dev/null || true
  fi

  reaped_json=$(DX_REAP_REASON="$reason" DX_REAP_SCOPE="$scope" \
    DX_REAP_METHOD="$method" DX_REAP_CANDIDATES="$candidate_count" \
    DX_REAP_STOPPED="$reaped" DX_REAP_SURVIVED="$survived" python3 - <<'PY'
import json
import os

print(json.dumps({
    "reason": os.environ.get("DX_REAP_REASON", ""),
    "scope": os.environ.get("DX_REAP_SCOPE", ""),
    "method": os.environ.get("DX_REAP_METHOD", ""),
    "candidates": int(os.environ.get("DX_REAP_CANDIDATES", "0") or 0),
    "reaped": int(os.environ.get("DX_REAP_STOPPED", "0") or 0),
    "survived": int(os.environ.get("DX_REAP_SURVIVED", "0") or 0),
}, separators=(",", ":")))
PY
  ) || reaped_json=""
  [[ -n "$reaped_json" ]] && __dx_session_reap_event "$session_id" \
    session.reap.completed info \
    "Session reap stopped ${reaped} of ${candidate_count} owned process(es)" \
    "$reaped_json"
  [[ "$survived" -eq 0 ]] || return 1
  return 0
}

# dx_session_finish_processes <session_id> <reason> [scope]
#
# The one "this session is over" entry point. It reaps, says what it stopped,
# and removes the token and temp root only when nothing survived — deleting the
# token of a process that is still running throws away the only way to find it
# again. A `detached` pass never cleans up either: sparing the live provider's
# tree means the session still owns processes by design.
#
# A reason that actually ends a session also gets one `session.summary` —
# what the session cost and what the reap found — emitted once, here, because
# every session-ending path already goes through this function.
#
# Publishes DX_SESSION_REAP_REAPED and DX_SESSION_REAP_SURVIVED for a caller
# that reports totals, and returns non-zero when something survived. Must be
# called as a plain command for those to be visible.
dx_session_finish_processes() {
  local session_id="${1:-}" reason="${2:-session-end}" scope="${3:-session}"
  local report line reap_result=0
  DX_SESSION_REAP_REAPED=0
  DX_SESSION_REAP_SURVIVED=0
  dx_session_id_valid "$session_id" || return 2
  report=$(dx_session_reap_processes "$session_id" "$reason" "$scope") \
    || reap_result=$?
  [[ "$reap_result" -ne 2 ]] || return 2
  if [[ -n "$report" ]]; then
    while IFS= read -r line; do
      [[ -n "$line" ]] || continue
      case "$line" in
        reaped\ *)
          DX_SESSION_REAP_REAPED=$((DX_SESSION_REAP_REAPED + 1))
          __dx_session_report ok "${session_id}: ${line}"
          ;;
        survived\ *)
          DX_SESSION_REAP_SURVIVED=$((DX_SESSION_REAP_SURVIVED + 1))
          __dx_session_report warn "${session_id}: ${line}"
          ;;
        unscannable*) __dx_session_report warn "${session_id}: ${line}" ;;
        *) __dx_session_report info "${session_id}: ${line}" ;;
      esac
    done <<EOF
$report
EOF
  fi
  # After the reap, so the counts are final; before the cleanup, so the gate
  # ledger and the peak-RSS record are still there to be read.
  __dx_session_summary "$session_id" "$reason" "$scope" \
    "$DX_SESSION_REAP_REAPED" "$DX_SESSION_REAP_SURVIVED" || true
  if [[ "$DX_SESSION_REAP_SURVIVED" -gt 0 || "$reap_result" -ne 0 ]]; then
    __dx_session_report warn "${session_id}: keeping its process token so the survivors stay identifiable. 'dx ps' lists them."
    return 1
  fi
  [[ "$scope" == "session" ]] || return 0
  dx_session_process_cleanup "$session_id" || return 1
  return 0
}

# __dx_session_reap_report <session_id> <reason> <method> <tsv_row>
# Prints the line a human reads and emits the matching event. Returns 0 when
# the process is gone, 1 when it survived — the caller counts both.
__dx_session_reap_report() {
  local session_id="$1" reason="$2" method="$3" row="$4"
  local pid ppid age rss cwd_value command_value event_json
  IFS=$'\t' read -r pid ppid age rss cwd_value command_value <<EOF
$row
EOF
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  # Not `kill -0`: that succeeds on a zombie, so a process that died and has
  # not been waited on yet would be logged as a survivor and lose its event.
  if __dx_timeout_pid_list_alive "$pid"; then
    printf 'survived pid=%s rss=%sk age=%ss %s\n' \
      "$pid" "$rss" "$age" "$command_value"
    return 1
  fi
  printf 'reaped pid=%s rss=%sk age=%ss %s\n' \
    "$pid" "$rss" "$age" "$command_value"
  event_json=$(__dx_session_reap_json "$pid" "$ppid" "$age" "$rss" \
    "$cwd_value" "$command_value" "$method" "$reason" 2>/dev/null) \
    || event_json=""
  [[ -n "$event_json" ]] && __dx_session_reap_event "$session_id" \
    session.reaped info "Reaped session-owned process ${pid}" "$event_json"
  return 0
}

# dx_session_process_cleanup <session_id> — drop the token, holder and temp root
#
# Runs after the reaper, never before: the scan needs the token file to still
# exist to identify what it is about to stop.
dx_session_process_cleanup() {
  local session_id="${1:-}" process_dir
  dx_session_id_valid "$session_id" || return 2
  process_dir=$(dx_session_process_dir "$session_id") || return 2
  [[ -d "$process_dir" ]] || return 0
  (command rm -rf "$process_dir") 2>/dev/null || true
  return 0
}

# ─── Session telemetry ──────────────────────────────────────────────────────
#
# A session that took the machine down leaves nothing to look at afterwards
# unless something wrote the numbers down while it ran. Two files in the
# session's `.process` directory hold them: one line per heavy gate that
# finished, and the running peak resident size of the token-carrying process
# tree. Both are per provider session — one lifecycle phase — because that is
# the lifetime of the directory they live in, and the summary says which phase
# it is talking about for exactly that reason.

# dx_session_gate_ledger_file <session_id> — one row per finished heavy gate
dx_session_gate_ledger_file() {
  local process_dir
  process_dir=$(dx_session_process_dir "${1:-}") || return 2
  printf '%s/gates.tsv\n' "$process_dir"
}

# dx_session_peak_rss_file <session_id> — running peak RSS, in kilobytes
dx_session_peak_rss_file() {
  local process_dir
  process_dir=$(dx_session_process_dir "${1:-}") || return 2
  printf '%s/peak-rss\n' "$process_dir"
}

# __dx_session_summary_marker <session_id> — "this session has been summarised"
#
# A directory, not a file, because creating it is the test-and-set: the
# watchdog reap and the phase-exit reap can be running at the same moment, and
# a check followed by a create would let both of them through.
__dx_session_summary_marker() {
  local process_dir
  process_dir=$(dx_session_process_dir "${1:-}") || return 2
  printf '%s/summary-emitted\n' "$process_dir"
}

# __dx_session_telemetry_reset <session_id> — start this phase's records clean
#
# The `.process` directory outlives its provider session whenever the reap
# could not account for everything: a survivor, or a host with no ownership
# scan, keeps the token because it is the only handle left on those processes.
# The next phase then re-attaches to that same directory. Without this it
# would inherit the previous phase's summary marker and never be summarised at
# all — silencing exactly the sessions this telemetry exists to explain — and
# it would inherit that phase's gate rows and peak on top.
__dx_session_telemetry_reset() {
  local session_id="${1:-}" process_dir ledger_file peak_file marker
  dx_session_id_valid "$session_id" || return 2
  process_dir=$(dx_session_process_dir "$session_id") || return 2
  [[ -d "$process_dir" ]] || return 0
  ledger_file=$(dx_session_gate_ledger_file "$session_id") || return 2
  peak_file=$(dx_session_peak_rss_file "$session_id") || return 2
  marker=$(__dx_session_summary_marker "$session_id") || return 2
  (command rm -rf "$marker" "$ledger_file" "$peak_file") 2>/dev/null || true
  return 0
}

# dx_session_gate_record <session_id> <gate> <exit> <duration-s> <queue-s>
#   <over-budget:0|1>
#
# Appended rather than rewritten: several gates in one session can finish in
# the same second, and one short O_APPEND write per gate is what keeps their
# rows from interleaving. A session that never took process ownership has
# nowhere to record this and says so rather than creating a directory that
# nothing will ever remove.
dx_session_gate_record() {
  [[ $# -eq 6 ]] || return 2
  local session_id="$1" gate_name="$2" exit_code="$3" duration="$4"
  local queued="$5" over_budget="$6" ledger_file process_dir
  dx_session_id_valid "$session_id" || return 2
  [[ "$gate_name" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,63}$ ]] || return 2
  [[ "$exit_code" =~ ^[0-9]{1,3}$ ]] || return 2
  [[ "$duration" =~ ^[0-9]{1,9}$ && "$queued" =~ ^[0-9]{1,9}$ ]] || return 2
  [[ "$over_budget" =~ ^[01]$ ]] || return 2
  process_dir=$(dx_session_process_dir "$session_id") || return 2
  [[ -d "$process_dir" ]] || return 1
  ledger_file=$(dx_session_gate_ledger_file "$session_id") || return 2
  if [[ ! -e "$ledger_file" ]]; then
    (umask 077; : > "$ledger_file") 2>/dev/null || return 1
  fi
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$gate_name" "$exit_code" "$duration" "$queued" "$over_budget" \
    >> "$ledger_file" 2>/dev/null || return 1
  return 0
}

# dx_session_peak_rss_sample <session_id> — sample the owned tree's total RSS
#
# Called from the runtime supervisor's existing heartbeat, not from a loop of
# its own. It sums `ps -o rss=` — kilobytes on both platforms — over exactly
# the PIDs the ownership scan already produces, which is the same set the
# reaper would stop, and keeps the larger of the sample and the recorded peak.
#
# Prints the sample in kilobytes. Returns 1 when there was nothing to sample
# or the host would not report resident size, and writes nothing in that case:
# a peak that was never taken has to stay distinguishable from a peak of zero,
# because the summary reports one as a number and the other as unavailable.
dx_session_peak_rss_sample() {
  local session_id="${1:-}" process_dir peak_file carriers pid_list=""
  local rss_output rss_line sampled=0 readings=0 peak_kb=0 samples=0
  local recorded recorded_peak recorded_samples peak_tmp
  dx_session_id_valid "$session_id" || return 2
  process_dir=$(dx_session_process_dir "$session_id") || return 2
  [[ -d "$process_dir" ]] || return 1
  peak_file=$(dx_session_peak_rss_file "$session_id") || return 2
  carriers=$(dx_session_process_carriers "$session_id" 2>/dev/null) || carriers=""
  while IFS= read -r rss_line; do
    [[ "$rss_line" =~ ^[0-9]+$ ]] || continue
    pid_list="${pid_list}${pid_list:+,}${rss_line}"
  done <<EOF
$carriers
EOF
  [[ -n "$pid_list" ]] || return 1

  rss_output=$(ps -o rss= -p "$pid_list" 2>/dev/null) || rss_output=""
  while IFS= read -r rss_line; do
    rss_line="${rss_line//[[:space:]]/}"
    [[ "$rss_line" =~ ^[0-9]+$ ]] || continue
    sampled=$((sampled + rss_line))
    readings=$((readings + 1))
  done <<EOF
$rss_output
EOF
  [[ "$readings" -gt 0 ]] || return 1

  if [[ -f "$peak_file" ]]; then
    recorded=$(cat "$peak_file" 2>/dev/null) || recorded=""
    recorded="${recorded%%$'\n'*}"
    IFS=$'\t' read -r recorded_peak recorded_samples <<EOF
$recorded
EOF
    if [[ "$recorded_peak" =~ ^[0-9]+$ ]]; then
      peak_kb="$recorded_peak"
    fi
    if [[ "$recorded_samples" =~ ^[0-9]+$ ]]; then
      samples="$recorded_samples"
    fi
  fi
  [[ "$sampled" -le "$peak_kb" ]] || peak_kb="$sampled"
  samples=$((samples + 1))

  peak_tmp="${peak_file}.tmp.${$}"
  if ! (umask 077; printf '%s\t%s\n' "$peak_kb" "$samples" > "$peak_tmp") \
    2>/dev/null; then
    command rm -f "$peak_tmp" 2>/dev/null || true
    return 1
  fi
  if ! command mv -f "$peak_tmp" "$peak_file" 2>/dev/null; then
    command rm -f "$peak_tmp" 2>/dev/null || true
    return 1
  fi
  printf '%s\n' "$sampled"
}

# dx_session_telemetry_read <session_id> — what this session has cost so far
#
# Publishes DX_SESSION_TELEMETRY_GATES, _GATE_SECONDS, _QUEUE_SECONDS,
# _OVER_BUDGET, _PEAK_RSS_MB (empty when no sample was ever taken) and
# _PEAK_RSS_SAMPLES. Like the reaper's counters, it must be called as a plain
# command for those to be visible to the caller.
dx_session_telemetry_read() {
  local session_id="${1:-}" ledger_file peak_file recorded
  local ledger_gate ledger_exit ledger_duration ledger_queue ledger_budget
  local recorded_peak recorded_samples
  DX_SESSION_TELEMETRY_GATES=0
  DX_SESSION_TELEMETRY_GATE_SECONDS=0
  DX_SESSION_TELEMETRY_QUEUE_SECONDS=0
  DX_SESSION_TELEMETRY_OVER_BUDGET=0
  DX_SESSION_TELEMETRY_PEAK_RSS_MB=""
  DX_SESSION_TELEMETRY_PEAK_RSS_SAMPLES=0
  dx_session_id_valid "$session_id" || return 2
  ledger_file=$(dx_session_gate_ledger_file "$session_id") || return 2
  peak_file=$(dx_session_peak_rss_file "$session_id") || return 2

  if [[ -f "$ledger_file" ]]; then
    while IFS=$'\t' read -r ledger_gate ledger_exit ledger_duration \
      ledger_queue ledger_budget; do
      [[ -n "$ledger_gate" ]] || continue
      [[ "$ledger_exit" =~ ^[0-9]+$ ]] || continue
      [[ "$ledger_duration" =~ ^[0-9]+$ ]] || continue
      [[ "$ledger_queue" =~ ^[0-9]+$ ]] || continue
      DX_SESSION_TELEMETRY_GATES=$((DX_SESSION_TELEMETRY_GATES + 1))
      DX_SESSION_TELEMETRY_GATE_SECONDS=$((DX_SESSION_TELEMETRY_GATE_SECONDS \
        + ledger_duration))
      DX_SESSION_TELEMETRY_QUEUE_SECONDS=$((DX_SESSION_TELEMETRY_QUEUE_SECONDS \
        + ledger_queue))
      if [[ "$ledger_budget" == "1" ]]; then
        DX_SESSION_TELEMETRY_OVER_BUDGET=$((DX_SESSION_TELEMETRY_OVER_BUDGET + 1))
      fi
    done < "$ledger_file"
  fi

  if [[ -f "$peak_file" ]]; then
    recorded=$(cat "$peak_file" 2>/dev/null) || recorded=""
    recorded="${recorded%%$'\n'*}"
    IFS=$'\t' read -r recorded_peak recorded_samples <<EOF
$recorded
EOF
    if [[ "$recorded_peak" =~ ^[0-9]+$ ]]; then
      DX_SESSION_TELEMETRY_PEAK_RSS_MB=$((recorded_peak / 1024))
    fi
    if [[ "$recorded_samples" =~ ^[0-9]+$ ]]; then
      DX_SESSION_TELEMETRY_PEAK_RSS_SAMPLES="$recorded_samples"
    fi
  fi
  return 0
}

# __dx_session_phase_value <session_id> — the lifecycle phase, when there is one
#
# Read through the same trusted reader every other consumer of this state
# uses. No phase state, or state the reader will not trust, means there is no
# phase to name — a different answer from phase 0.
__dx_session_phase_value() {
  local session_id="$1" phase_raw="" phase_rc=0
  phase_raw=$(dx_session_trusted_file_read \
    "$(dx_state_file "$session_id")" 32 2>/dev/null) || phase_rc=$?
  [[ "$phase_rc" -eq 0 ]] || return 1
  phase_raw="${phase_raw%%$'\n'*}"
  [[ "$phase_raw" =~ ^[0-7]$ ]] || return 1
  printf '%s\n' "$phase_raw"
}

# __dx_session_summary <session_id> <reason> <scope> <reaped> <survived>
#
# One `session.summary` event and one human-readable line, once, at the end of
# a provider session. It runs after the reap so the counts are final and
# before the cleanup so the numbers still exist to be read.
#
# Only the reasons that actually end a session qualify: `dx control stop` and
# `dx ps --reap-orphans` reap without ending anything the summary is about. A
# marker inside the `.process` directory makes it once-per-session even though
# two paths (the SessionEnd hook and the phase-exit reap, or the watchdog and
# the phase-exit reap) can both run for one session; a pass that finds the
# directory already gone has nothing left to summarise.
__dx_session_summary() {
  local session_id="${1:-}" reason="${2:-}" scope="${3:-session}"
  local reaped="${4:-0}" survived="${5:-0}"
  local process_dir marker phase_value="" phase_json="null" peak_json="null"
  local peak_text summary_json summary_line
  case "$reason" in
    session-end|phase-exit|watchdog-kill|launcher-stopped) ;;
    *) return 0 ;;
  esac
  [[ "$scope" == "session" ]] || return 0
  dx_session_id_valid "$session_id" || return 0
  process_dir=$(dx_session_process_dir "$session_id") || return 0
  [[ -d "$process_dir" ]] || return 0
  # Both counts land in JSON unquoted, so a caller that handed over something
  # that is not a number must not be able to break the journal line.
  [[ "$reaped" =~ ^[0-9]{1,9}$ ]] || reaped=0
  [[ "$survived" =~ ^[0-9]{1,9}$ ]] || survived=0
  marker=$(__dx_session_summary_marker "$session_id") || return 0
  # The create is the claim. A mkdir that fails because the marker is already
  # there means another reap for this session got here first; one that fails
  # for any other reason means no summary, which is how telemetry should fail.
  mkdir "$marker" 2>/dev/null || return 0

  dx_session_telemetry_read "$session_id" || true
  if phase_value=$(__dx_session_phase_value "$session_id"); then
    phase_json="\"${phase_value}\""
  else
    phase_value=""
  fi
  if [[ -n "$DX_SESSION_TELEMETRY_PEAK_RSS_MB" ]]; then
    peak_json="$DX_SESSION_TELEMETRY_PEAK_RSS_MB"
    peak_text="peak RSS ${DX_SESSION_TELEMETRY_PEAK_RSS_MB} MB"
  else
    # The supervisor never sampled, or this host would not report resident
    # size. Saying so beats reporting a zero nobody measured.
    peak_text="peak RSS unavailable"
  fi

  summary_json=$(printf '{"reason":"%s","phase":%s,"heavy_commands":%s,"heavy_seconds":%s,"queue_seconds":%s,"over_budget_commands":%s,"peak_rss_mb":%s,"peak_rss_samples":%s,"reaped":%s,"survived":%s}' \
    "$reason" "$phase_json" "$DX_SESSION_TELEMETRY_GATES" \
    "$DX_SESSION_TELEMETRY_GATE_SECONDS" \
    "$DX_SESSION_TELEMETRY_QUEUE_SECONDS" \
    "$DX_SESSION_TELEMETRY_OVER_BUDGET" "$peak_json" \
    "$DX_SESSION_TELEMETRY_PEAK_RSS_SAMPLES" "$reaped" "$survived")
  summary_line=$(printf 'session summary: phase %s, %s heavy command(s) (%ss running, %ss queued), %s, %s reaped, %s survived' \
    "${phase_value:--}" "$DX_SESSION_TELEMETRY_GATES" \
    "$DX_SESSION_TELEMETRY_GATE_SECONDS" \
    "$DX_SESSION_TELEMETRY_QUEUE_SECONDS" "$peak_text" "$reaped" "$survived")
  __dx_session_report info "${session_id}: ${summary_line}"
  __dx_session_reap_event "$session_id" session.summary info \
    "$summary_line" "$summary_json"
  return 0
}
