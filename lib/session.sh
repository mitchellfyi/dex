# shellcheck shell=bash
# Dex shared library — session ID and state file helpers
#
# Session IDs key all state and loop files. Path-based derivation makes them
# stable across branch renames (the SessionStart hook may rename branches to
# follow project conventions). See: docs/autonomous-mode.md § State Management
#
# Scope: state/loop dirs are global (~/.claude/.dex-{phases,loops}/), so
# session IDs include a repo-stable key plus the worktree/branch identifier.
# This prevents two repos using the same ticket, task, or branch name from
# sharing phase, provider, watcher, or loop state.
#
# Concurrency: dx_unique_session_id() appends PID+epoch to avoid collisions
# when multiple dxloop invocations run on the same branch. The unique ID is
# passed to Claude via DEX_SESSION_ID env var so the stop hook resolves
# to the same unique ID. See: hooks/phase-loop.sh line 29.

# dx_session_repo_key
# Derive a filesystem-safe repo key from the main repo root. The basename keeps
# state files readable; the cksum component makes same-named repos distinct.
dx_session_repo_key() {
  local root name slug hash
  root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  if [[ "$root" == *"/.dex/worktrees/"* ]]; then
    root="${root%%/.dex/worktrees/*}"
  fi
  [[ -n "$root" ]] || root="${PWD:-unknown}"

  name=$(basename "$root")
  slug=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//')
  [[ -n "$slug" ]] || slug="repo"

  hash=""
  if command -v cksum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | cksum 2>/dev/null | awk '{print $1}') || hash=""
  fi
  [[ -n "$hash" ]] || hash="nohash"

  printf 'repo-%s-%s\n' "$slug" "$hash"
}

# dx_scoped_session_id <raw_id>
# Add the current repo namespace to a raw worktree/branch/session identifier.
dx_scoped_session_id() {
  local raw_id="$1"
  printf '%s-%s\n' "$(dx_session_repo_key)" "$raw_id"
}

# dx_session_id [wt_name]
# Derive a stable session identifier used to key state and loop files.
#
# With argument:  "repo-<name>-<hash>-worktree-<wt_name>" — used by dx.sh
# which knows the name.
# Without argument: auto-detect from the current git directory:
#   - If inside a dex worktree (path contains /.dex/worktrees/),
#     derive from the directory name. This is stable even if the branch
#     is renamed by the SessionStart hook.
#   - Otherwise, fall back to a readable branch slug plus a digest of the exact
#     branch name, so names such as feature/foo and feature-foo cannot collide.
# shellcheck disable=SC2120  # Intentionally dual-mode: called with args from dx.sh, without from hooks
dx_session_id() {
  local raw_id scoped_id
  if [[ $# -ge 1 ]]; then
    raw_id="worktree-${1}"
    scoped_id=$(dx_scoped_session_id "$raw_id")
    printf '%s\n' "$scoped_id"
    return
  fi
  local toplevel
  toplevel=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  if [[ "$toplevel" == *"/.dex/worktrees/"* ]]; then
    raw_id="worktree-$(basename "$toplevel")"
  else
    local branch branch_slug branch_hash
    branch=$(git symbolic-ref --quiet --short HEAD 2>/dev/null || true)
    if [[ -z "$branch" ]]; then
      branch="detached-$(git rev-parse --short=12 HEAD 2>/dev/null || printf 'unknown')"
    fi
    branch_slug=$(printf '%s' "$branch" | LC_ALL=C sed -E 's/[^A-Za-z0-9._-]+/-/g; s/^-+//; s/-+$//')
    [[ -n "$branch_slug" ]] || branch_slug="branch"
    branch_slug=$(printf '%.64s' "$branch_slug")
    branch_hash=$(printf '%s' "$branch" | cksum 2>/dev/null | awk '{print $1}') || branch_hash=""
    [[ -n "$branch_hash" ]] || branch_hash="nohash"
    raw_id="branch-${branch_slug}-${branch_hash}"
  fi
  scoped_id=$(dx_scoped_session_id "$raw_id")
  printf '%s\n' "$scoped_id"
}

# dx_unique_session_id
# Generate a session ID unique to this shell invocation, for concurrent dxloop isolation.
# Appends PID, epoch seconds, and $RANDOM to the branch-based ID so multiple dxloop
# calls on the same branch get distinct state/prompt files — even if started in the
# same second ($RANDOM provides 0-32767 range, available in both bash and zsh).
dx_unique_session_id() {
  echo "$(dx_session_id)-$$-$(date +%s)-${RANDOM}"
}

# dx_session_id_valid <session_id> — reject traversal and unsafe state keys
dx_session_id_valid() {
  local session_id="${1:-}"
  [[ -n "$session_id" && ${#session_id} -le 180 ]] || return 1
  [[ "$session_id" != "." && "$session_id" != ".." ]] || return 1
  [[ "$session_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

# dx_state_file <session_id>  — phase state file path
dx_state_file() { echo "${DX_STATE_DIR}/${1}.phase"; }

# dx_times_file <session_id>  — phase timing file path
dx_times_file() { echo "${DX_STATE_DIR}/${1}.times"; }

# dx_loop_file <session_id>   — loop iteration state file path
dx_loop_file() { echo "${DX_LOOP_DIR}/${1}.state"; }

# dx_complete_file <session_id> — loop completion signal file path
dx_complete_file() { echo "${DX_LOOP_DIR}/${1}.complete"; }

# dx_active_file <session_id>  — loop activation signal file path (for in-session /dxloop)
dx_active_file() { echo "${DX_LOOP_DIR}/${1}.active"; }

# dx_owner_file <session_id> — Claude session id that owns this loop's state.
# Session IDs are derived from the repo+worktree/branch path, so an unrelated
# Claude session opened in the same checkout resolves the same session_id. The
# Stop hook records the owning Claude session id here and stays inert in any
# other session, so bystander sessions are never captured by an active loop.
dx_owner_file() { echo "${DX_LOOP_DIR}/${1}.owner"; }

# dx_prompt_file <session_id>  — original prompt file path (for dxloop prompt persistence)
dx_prompt_file() { echo "${DX_LOOP_DIR}/${1}.prompt"; }

# dx_context_file <session_id> — system prompt context file (survives compaction via --append-system-prompt-file)
dx_context_file() { echo "${DX_STATE_DIR}/${1}.system-context"; }

# dx_log_file <session_id> — structured phase execution log (TSV)
dx_log_file() { echo "${DX_STATE_DIR}/${1}.log"; }

# dx_phase_outcomes_file <session_id> — durable terminal outcome ledger for phases 0-6
dx_phase_outcomes_file() { echo "${DX_STATE_DIR}/${1}.phase-outcomes"; }

# dx_branch_file <session_id> — branch last used by this lifecycle session
dx_branch_file() { echo "${DX_STATE_DIR}/${1}.branch"; }

# dx_meta_file <session_id> — per-session metadata sidecar (ticket id, tracker key,
# workspace dir/mode, original input). Used to resume a lifecycle by ticket
# number even when the worktree dir or branch has been renamed.
dx_meta_file() { echo "${DX_STATE_DIR}/${1}.meta"; }

# dx_meta_read <session_id> <key>
# Print the value for <key> from the session meta sidecar, or empty if missing.
dx_meta_read() {
  local session_id="$1" key="$2" meta_file
  [[ -n "$session_id" && -n "$key" ]] || return 0
  meta_file=$(dx_meta_file "$session_id")
  [[ -f "$meta_file" ]] || return 0
  awk -F= -v k="$key" '$1 == k { sub(/^[^=]*=/, ""); print; exit }' "$meta_file" 2>/dev/null
}

# dx_meta_write <session_id> [key=value ...]
# Merge key/value pairs into the session meta sidecar. Existing keys are
# overwritten; unspecified keys are preserved. Creation time is only set the
# first time the file is written. Safe to call repeatedly. Bash/zsh compatible:
# uses awk to merge so we avoid associative arrays.
dx_meta_write() {
  local session_id="$1"; shift
  local meta_file tmp_file overrides_input now_epoch pair
  [[ -n "$session_id" ]] || return 0
  [[ $# -gt 0 ]] || return 0

  meta_file=$(dx_meta_file "$session_id")
  mkdir -p "$(dirname "$meta_file")"
  now_epoch=$(date +%s)

  # Build a TAB-separated key<TAB>value stream of overrides, including
  # updated_at. created_at is added only when the file is new.
  overrides_input=""
  for pair in "$@"; do
    [[ "$pair" == *=* ]] || continue
    local k="${pair%%=*}" v="${pair#*=}"
    [[ -n "$k" ]] || continue
    [[ "$k" == "created_at" || "$k" == "updated_at" ]] && continue
    overrides_input+=$(printf '%s\t%s\n' "$k" "$v")
    overrides_input+=$'\n'
  done
  overrides_input+=$(printf '%s\t%s\n' "updated_at" "$now_epoch")
  overrides_input+=$'\n'
  if [[ ! -f "$meta_file" ]]; then
    overrides_input+=$(printf '%s\t%s\n' "created_at" "$now_epoch")
    overrides_input+=$'\n'
  fi

  tmp_file="${meta_file}.tmp.$$"
  if ! printf '%s' "$overrides_input" | awk -F'\t' -v meta="$meta_file" '
    BEGIN {
      ok = 1
    }
    NF >= 2 {
      key = $1
      val = $0
      sub(/^[^\t]*\t/, "", val)
      overrides[key] = val
      order[++n] = key
    }
    END {
      # First, emit existing lines (preserve order), substituting overridden values
      # and recording which keys we have already written.
      if ((getline _ < meta) >= 0) {
        close(meta)
        while ((getline line < meta) > 0) {
          if (line == "") continue
          eq = index(line, "=")
          if (eq == 0) {
            print line
            continue
          }
          k = substr(line, 1, eq - 1)
          if (k in overrides) {
            print k "=" overrides[k]
            seen[k] = 1
          } else {
            print line
          }
        }
        close(meta)
      }
      for (i = 1; i <= n; i++) {
        k = order[i]
        if (!(k in seen)) {
          print k "=" overrides[k]
          seen[k] = 1
        }
      }
    }
  ' > "$tmp_file"; then
    command rm -f "$tmp_file" 2>/dev/null
    return 1
  fi

  if ! command mv -f "$tmp_file" "$meta_file"; then
    command rm -f "$tmp_file" 2>/dev/null
    return 1
  fi
}

# dx_meta_find_workspace_by_ticket <ticket_number>
# Scan meta sidecars in the current repo's session scope and print the first
# match as a TAB-separated record: session_id<TAB>wt_name<TAB>wt_dir<TAB>workspace_mode.
# Used to resume by ticket number when the conventional ticket-N directory
# does not exist (e.g. the worktree was originally named task-*).
dx_meta_find_workspace_by_ticket() {
  local ticket="$1" repo_key match="" match_identity="" candidate candidate_identity
  [[ -n "$ticket" ]] || return 1
  [[ -d "$DX_STATE_DIR" ]] || return 1
  repo_key=$(dx_session_repo_key)

  local meta_file session_id ticket_in_file wt_name wt_dir workspace_mode
  while IFS= read -r meta_file; do
    [[ -n "$meta_file" && -f "$meta_file" ]] || continue
    session_id="$(basename "$meta_file" .meta)"
    ticket_in_file=$(awk -F= '$1 == "ticket_number" { sub(/^[^=]*=/, ""); print; exit }' "$meta_file" 2>/dev/null)
    [[ "$ticket_in_file" == "$ticket" ]] || continue
    wt_name=$(awk -F= '$1 == "wt_name" { sub(/^[^=]*=/, ""); print; exit }' "$meta_file" 2>/dev/null)
    wt_dir=$(awk -F= '$1 == "wt_dir" { sub(/^[^=]*=/, ""); print; exit }' "$meta_file" 2>/dev/null)
    workspace_mode=$(awk -F= '$1 == "workspace_mode" { sub(/^[^=]*=/, ""); print; exit }' "$meta_file" 2>/dev/null)
    [[ -n "$wt_name" && -n "$wt_dir" ]] || continue
    [[ -d "$wt_dir" ]] || continue
    candidate=$(printf '%s\t%s\t%s\t%s' "$session_id" "$wt_name" "$wt_dir" "${workspace_mode:-worktree}")
    candidate_identity=$(printf '%s\t%s\t%s' "$wt_name" "$wt_dir" "${workspace_mode:-worktree}")
    if [[ -z "$match" ]]; then
      match="$candidate"
      match_identity="$candidate_identity"
    elif [[ "$candidate_identity" != "$match_identity" ]]; then
      dx_error "Multiple Dex workspaces are linked to ticket ${ticket}; use a workspace name instead."
      return 2
    fi
  done < <(find "$DX_STATE_DIR" -maxdepth 1 -type f -name "${repo_key}-*.meta" -print 2>/dev/null)
  [[ -n "$match" ]] || return 1
  printf '%s\n' "$match"
}

# dx_findings_file <session_id> — findings hash history for stuck loop detection
dx_findings_file() { echo "${DX_LOOP_DIR}/${1}.findings"; }

# dx_debt_file <session_id> — technical debt ledger (append-only markdown)
dx_debt_file() { echo "${DX_LOOP_DIR}/${1}.debt"; }

# dx_loop_config_file <session_id> — loop configuration (phase:promise:audit_file_path)
dx_loop_config_file() { echo "${DX_LOOP_DIR}/${1}.config"; }

# dx_handoff_mode_file <session_id> — marker for same-session phase handoff
dx_handoff_mode_file() { echo "${DX_LOOP_DIR}/${1}.handoff-mode"; }

# dx_paused_file <session_id> — marker allowing a paused session to exit without success cleanup
dx_paused_file() { echo "${DX_LOOP_DIR}/${1}.paused"; }

# dx_pause_state_file <session_id> — machine-readable reason/source for a pause
dx_pause_state_file() { echo "${DX_LOOP_DIR}/${1}.pause-state"; }

# dx_watch_pause_file <session_id> — marker that scheduled CI/PR watchers should no-op
dx_watch_pause_file() { echo "${DX_LOOP_DIR}/${1}.watch-pause"; }

# dx_watch_pause_ttl_seconds — watch-pause lifetime; 0 means no automatic expiry
dx_watch_pause_ttl_seconds() {
  local ttl="${DEX_WATCH_PAUSE_TTL_SECONDS:-3600}"
  if [[ "$ttl" =~ ^[0-9]+$ ]]; then
    echo "$ttl"
  else
    echo "3600"
  fi
}

# dx_watch_pause_active <session_id> — true when scheduled watchers should skip work
dx_watch_pause_active() {
  local session_id="$1" pause_file raw epoch now ttl age
  [[ "${DEX_WATCH_IGNORE_PAUSE:-0}" == "1" ]] && return 1

  pause_file=$(dx_watch_pause_file "$session_id")
  [[ -f "$pause_file" ]] || return 1

  raw=$(cat "$pause_file" 2>/dev/null || echo "")
  epoch="${raw%%$'\t'*}"
  if [[ ! "$epoch" =~ ^[0-9]+$ ]]; then
    rm -f "$pause_file" 2>/dev/null || true
    return 1
  fi

  ttl=$(dx_watch_pause_ttl_seconds)
  [[ "$ttl" -gt 0 ]] || return 0

  now=$(date +%s)
  age=$((now - epoch))
  if [[ "$age" -lt "$ttl" ]]; then
    return 0
  fi

  rm -f "$pause_file" 2>/dev/null || true
  return 1
}

# dx_write_watch_pause <session_id> [reason] — atomically write a watcher pause marker
dx_write_watch_pause() {
  local session_id="$1" reason="${2:-user-prompt}" pause_file tmp_file
  [[ -n "$session_id" ]] || return 0
  pause_file=$(dx_watch_pause_file "$session_id")
  mkdir -p "$(dirname "$pause_file")"
  tmp_file="${pause_file}.tmp.$$"
  if ! printf '%s\t%s\n' "$(date +%s)" "$reason" > "$tmp_file" || ! command mv -f "$tmp_file" "$pause_file"; then
    command rm -f "$tmp_file" 2>/dev/null
    return 1
  fi
}

# dx_clear_watch_pause <session_id> — remove any watcher pause marker for the session
dx_clear_watch_pause() {
  local session_id="$1"
  [[ -n "$session_id" ]] || return 0
  rm -f "$(dx_watch_pause_file "$session_id")" 2>/dev/null || true
}

# dx_watch_cycle_timeout_seconds — max runtime for one scheduled watcher cycle
dx_watch_cycle_timeout_seconds() {
  local timeout="${DEX_WATCH_CYCLE_TIMEOUT_SECONDS:-120}"
  if [[ "$timeout" =~ ^[0-9]+$ ]]; then
    echo "$timeout"
  else
    echo "120"
  fi
}

# dx_watch_command_timeout_seconds — max runtime for a single watcher shell command
dx_watch_command_timeout_seconds() {
  local timeout="${DEX_WATCH_COMMAND_TIMEOUT_SECONDS:-30}"
  if [[ "$timeout" =~ ^[0-9]+$ ]]; then
    echo "$timeout"
  else
    echo "30"
  fi
}

# dx_watch_lock_file <session_id> <watch_name> — per-watcher overlap guard
dx_watch_lock_file() { echo "${DX_LOOP_DIR}/${1}.${2}.watch-lock"; }

# dx_watch_lock_acquire <session_id> <watch_name> — acquire or reject active watcher lock
dx_watch_lock_acquire() {
  local session_id="$1" watch_name="$2" lock_file raw epoch now age timeout
  [[ -n "$session_id" && -n "$watch_name" ]] || return 1

  lock_file=$(dx_watch_lock_file "$session_id" "$watch_name")
  mkdir -p "$(dirname "$lock_file")"

  if ( set -C; printf '%s\t%s\n' "$(date +%s)" "$$" > "$lock_file" ) 2>/dev/null; then
    return 0
  fi

  raw=$(cat "$lock_file" 2>/dev/null || echo "")
  epoch="${raw%%$'\t'*}"
  timeout=$(dx_watch_cycle_timeout_seconds)
  now=$(date +%s)

  if [[ ! "$epoch" =~ ^[0-9]+$ ]]; then
    rm -f "$lock_file" 2>/dev/null || true
  else
    age=$((now - epoch))
    [[ "$timeout" -gt 0 && "$age" -lt "$timeout" ]] && return 1
    rm -f "$lock_file" 2>/dev/null || true
  fi

  ( set -C; printf '%s\t%s\n' "$(date +%s)" "$$" > "$lock_file" ) 2>/dev/null
}

# dx_watch_lock_release <session_id> <watch_name> — release a watcher overlap lock
dx_watch_lock_release() {
  local session_id="$1" watch_name="$2"
  [[ -n "$session_id" && -n "$watch_name" ]] || return 0
  rm -f "$(dx_watch_lock_file "$session_id" "$watch_name")" 2>/dev/null || true
}

dx_kill_process_tree() {
  local pid="$1" signal="${2:-TERM}" child
  [[ -n "$pid" && -n "$signal" ]] || return 0

  if command -v pgrep >/dev/null 2>&1; then
    while IFS= read -r child; do
      [[ -n "$child" ]] || continue
      dx_kill_process_tree "$child" "$signal"
    done < <(pgrep -P "$pid" 2>/dev/null || true)
  else
    while IFS= read -r child; do
      [[ -n "$child" ]] || continue
      dx_kill_process_tree "$child" "$signal"
    done < <(ps -eo pid=,ppid= 2>/dev/null | awk -v parent="$pid" '$2 == parent { print $1 }')
  fi

  kill "-$signal" "$pid" 2>/dev/null || true
}

# __dx_timeout_token_pids <token_file> — find a supervised command after reparenting
#
# PPID walks stop working as soon as a command exits and one of its background
# children is reparented. Every command launched by dx_run_with_timeout inherits
# a unique token in both its environment and an open file descriptor, so cleanup
# can still identify those children. Linux exposes both through /proc. macOS
# ships lsof, which can resolve the inherited descriptor after reparenting.
__dx_timeout_token_pids() {
  local token_file="$1"
  [[ -f "$token_file" ]] || return 0

  python3 - "$token_file" <<'PY'
import os
import re
import shutil
import subprocess
import sys
from pathlib import Path


try:
    token = Path(sys.argv[1]).read_bytes().strip()
except OSError:
    raise SystemExit(0)
if not re.fullmatch(rb"[A-Za-z0-9._-]{16,160}", token):
    raise SystemExit(0)
marker = b"DX_TIMEOUT_PROCESS_TOKEN=" + token


def linux_processes(token_path):
    matches = set()
    proc = Path("/proc")
    try:
        token_stat = token_path.stat()
    except OSError:
        return matches
    for entry in proc.iterdir():
        if not entry.name.isdigit():
            continue
        try:
            environment = (entry / "environ").read_bytes().split(b"\0")
        except OSError:
            environment = ()
        if marker in environment:
            matches.add(int(entry.name))
            continue
        fd_dir = entry / "fd"
        try:
            descriptors = tuple(fd_dir.iterdir())
        except OSError:
            continue
        for descriptor in descriptors:
            try:
                descriptor_stat = descriptor.stat()
            except OSError:
                continue
            if (
                descriptor_stat.st_dev == token_stat.st_dev
                and descriptor_stat.st_ino == token_stat.st_ino
            ):
                matches.add(int(entry.name))
                break
    return matches


def lsof_processes(token_path):
    lsof = shutil.which("lsof")
    if not lsof and sys.platform == "darwin":
        lsof = "/usr/sbin/lsof"
    if not lsof or not Path(lsof).is_file():
        return set()
    try:
        output = subprocess.check_output(
            [lsof, "-t", "--", str(token_path)], stderr=subprocess.DEVNULL
        )
    except (OSError, subprocess.CalledProcessError):
        return set()
    matches = set()
    for raw_pid in output.split():
        try:
            matches.add(int(raw_pid))
        except ValueError:
            continue
    return matches


if sys.platform.startswith("linux"):
    matches = linux_processes(Path(sys.argv[1]))
else:
    matches = lsof_processes(Path(sys.argv[1]))

for process_id in sorted(matches):
    print(process_id)
PY
}

# __dx_timeout_signal_processes <token_file> <root_pid> <signal>
__dx_timeout_signal_processes() {
  local token_file="$1" root_pid="${2:-}" signal="${3:-TERM}" pids pid

  # Capture token-bearing processes before the root is signalled. The PID list
  # remains useful even if descendants are reparented during the PPID walk.
  pids=$(__dx_timeout_token_pids "$token_file" 2>/dev/null || true)
  [[ -n "$root_pid" ]] && dx_kill_process_tree "$root_pid" "$signal"
  while IFS= read -r pid; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    kill "-$signal" "$pid" 2>/dev/null || true
  done <<EOF
$pids
EOF
}

# __dx_timeout_processes_alive <token_file> — whether supervised work remains
__dx_timeout_processes_alive() {
  local token_file="$1" pids
  pids=$(__dx_timeout_token_pids "$token_file" 2>/dev/null || true)
  [[ -n "$pids" ]]
}

# __dx_timeout_terminate_processes <token_file> [root_pid]
__dx_timeout_terminate_processes() {
  local token_file="$1" root_pid="${2:-}"

  __dx_timeout_signal_processes "$token_file" "$root_pid" TERM
  if __dx_timeout_processes_alive "$token_file"; then
    sleep 2 2>/dev/null || true
    if __dx_timeout_processes_alive "$token_file"; then
      __dx_timeout_signal_processes "$token_file" "$root_pid" KILL
    fi
  fi
}

__dx_timeout_stop_watchdog() {
  local watchdog_pid="${1:-}"
  [[ -n "$watchdog_pid" ]] || return 0
  dx_kill_process_tree "$watchdog_pid" TERM
  wait "$watchdog_pid" 2>/dev/null || true
}

__dx_timeout_remove_state() {
  local temp_dir="${1:-}" marker_file="${2:-}" token_file="${3:-}"
  command rm -f "$marker_file" "$token_file" 2>/dev/null || true
  [[ -n "$temp_dir" ]] && command rmdir "$temp_dir" 2>/dev/null || true
}

__dx_timeout_abort() {
  local exit_status="$1" temp_dir="$2" marker_file="$3" token_file="$4"
  local cmd_pid="${5:-}" watchdog_pid="${6:-}"
  __dx_timeout_stop_watchdog "$watchdog_pid"
  __dx_timeout_terminate_processes "$token_file" "$cmd_pid"
  [[ -n "$cmd_pid" ]] && wait "$cmd_pid" 2>/dev/null || true
  __dx_timeout_remove_state "$temp_dir" "$marker_file" "$token_file"
  exit "$exit_status"
}

# __dx_run_with_timeout_core <seconds> <command> [args...] — isolated supervisor
__dx_run_with_timeout_core() {
  local timeout="$1" temp_dir="" marker="" token_file="" token=""
  local cmd_pid="" watchdog_pid="" cmd_status timeout_enabled=0
  shift
  [[ $# -gt 0 ]] || return 2

  if [[ "$timeout" =~ ^[0-9]+$ && "$timeout" -gt 0 ]]; then
    timeout_enabled=1
  fi

  temp_dir=$(mktemp -d "${TMPDIR:-/tmp}/dex-timeout.XXXXXX") || return 2
  marker="$temp_dir/expired"
  token_file="$temp_dir/token"
  token="dx-${$}-${RANDOM}-${RANDOM}-$(date +%s)"
  (umask 077 && printf '%s\n' "$token" > "$token_file") || {
    __dx_timeout_remove_state "$temp_dir" "$marker" "$token_file"
    return 2
  }

  trap '__dx_timeout_abort 130 "$temp_dir" "$marker" "$token_file" "$cmd_pid" "$watchdog_pid"' INT
  trap '__dx_timeout_abort 143 "$temp_dir" "$marker" "$token_file" "$cmd_pid" "$watchdog_pid"' TERM
  trap '__dx_timeout_abort 129 "$temp_dir" "$marker" "$token_file" "$cmd_pid" "$watchdog_pid"' HUP
  # Explicit subshell preserves full function execution and exit status when the
  # command is a shell function with invocation-scoped environment variables.
  (
    export DX_TIMEOUT_PROCESS_TOKEN="$token"
    # A low, explicitly opened descriptor survives ordinary shell fork/exec
    # chains on both supported platforms and is discoverable after reparenting.
    exec 9< "$token_file"
    "$@"
  ) &
  cmd_pid=$!

  if [[ $timeout_enabled -eq 1 ]]; then
    (
      sleep "$timeout" 2>/dev/null
      if kill -0 "$cmd_pid" 2>/dev/null; then
        : > "$marker"
        __dx_timeout_terminate_processes "$token_file" "$cmd_pid"
      fi
    ) >/dev/null 2>&1 &
    watchdog_pid=$!
  fi

  cmd_status=0
  wait "$cmd_pid" 2>/dev/null || cmd_status=$?

  if [[ -f "$marker" ]]; then
    # The watchdog owns TERM-to-KILL escalation. Waiting here prevents the
    # command root's exit from cancelling cleanup before resistant children die.
    [[ -n "$watchdog_pid" ]] && wait "$watchdog_pid" 2>/dev/null || true
    # Sweep once more for a late orphan without repeating the watchdog's
    # TERM grace period.
    __dx_timeout_signal_processes "$token_file" "" KILL
    __dx_timeout_remove_state "$temp_dir" "$marker" "$token_file"
    return 124
  fi

  # A natural command exit may still leave background children. Stop the timer,
  # then terminate every process that inherited this invocation's token.
  __dx_timeout_stop_watchdog "$watchdog_pid"
  if [[ -f "$marker" ]]; then
    __dx_timeout_terminate_processes "$token_file" "$cmd_pid"
    __dx_timeout_remove_state "$temp_dir" "$marker" "$token_file"
    return 124
  fi
  __dx_timeout_terminate_processes "$token_file"
  __dx_timeout_remove_state "$temp_dir" "$marker" "$token_file"
  return "$cmd_status"
}

# dx_run_with_timeout <seconds> <command> [args...] — portable timeout wrapper
dx_run_with_timeout() {
  local timeout_supervisor_pid="" timeout_status=0 timeout_signal_status=0
  local timeout_prior_int="" timeout_prior_term="" timeout_prior_hup=""

  # zsh can scope traps to this function. Bash 3.2 cannot, so preserve and
  # restore its caller's handlers explicitly after the supervisor exits.
  if [[ -n "${ZSH_VERSION:-}" ]]; then
    setopt localoptions localtraps
  elif [[ -n "${BASH_VERSION:-}" ]]; then
    timeout_prior_int=$(trap -p INT)
    timeout_prior_term=$(trap -p TERM)
    timeout_prior_hup=$(trap -p HUP)
  fi

  trap 'timeout_signal_status=130; if [[ -n "$timeout_supervisor_pid" ]]; then kill -INT "$timeout_supervisor_pid" 2>/dev/null || true; wait "$timeout_supervisor_pid" 2>/dev/null || true; fi' INT
  trap 'timeout_signal_status=143; if [[ -n "$timeout_supervisor_pid" ]]; then kill -TERM "$timeout_supervisor_pid" 2>/dev/null || true; wait "$timeout_supervisor_pid" 2>/dev/null || true; fi' TERM
  trap 'timeout_signal_status=129; if [[ -n "$timeout_supervisor_pid" ]]; then kill -HUP "$timeout_supervisor_pid" 2>/dev/null || true; wait "$timeout_supervisor_pid" 2>/dev/null || true; fi' HUP

  (
    local timeout_core_status=0
    __dx_run_with_timeout_core "$@" || timeout_core_status=$?
    exit "$timeout_core_status"
  ) &
  timeout_supervisor_pid=$!
  wait "$timeout_supervisor_pid" 2>/dev/null || timeout_status=$?
  [[ $timeout_signal_status -ne 0 ]] && timeout_status=$timeout_signal_status

  trap - INT TERM HUP
  if [[ -n "${BASH_VERSION:-}" ]]; then
    # shellcheck disable=SC2294  # trusted trap definitions captured from this shell
    [[ -n "$timeout_prior_int" ]] && eval "$timeout_prior_int"
    # shellcheck disable=SC2294  # trusted trap definitions captured from this shell
    [[ -n "$timeout_prior_term" ]] && eval "$timeout_prior_term"
    # shellcheck disable=SC2294  # trusted trap definitions captured from this shell
    [[ -n "$timeout_prior_hup" ]] && eval "$timeout_prior_hup"
  fi

  return "$timeout_status"
}

# dx_review_state_file <session_id> — review sub-loop clean pass counter (survives interrupts)
dx_review_state_file() { dx_session_id_valid "${1:-}" || return 2; echo "${DX_LOOP_DIR}/${1}.review-state"; }

# dx_review_result_file <session_id> — per-iteration review result
dx_review_result_file() { dx_session_id_valid "${1:-}" || return 2; echo "${DX_LOOP_DIR}/${1}.review-result"; }

# dx_review_context_file <session_id> — compact context pack for review waves
dx_review_context_file() { dx_session_id_valid "${1:-}" || return 2; echo "${DX_LOOP_DIR}/${1}.review-context"; }

# dx_review_criteria_file <session_id> — approved lifecycle requirements for review
dx_review_criteria_file() { dx_session_id_valid "${1:-}" || return 2; echo "${DX_LOOP_DIR}/${1}.review-criteria.json"; }

# dx_review_criteria_approval_file <session_id> — sealed Phase 1 criteria hash and revision
dx_review_criteria_approval_file() { dx_session_id_valid "${1:-}" || return 2; echo "${DX_LOOP_DIR}/${1}.review-criteria-approval"; }

# A review context pack must expose the four auditable sections used by the
# evidence gate. This rejects placeholder sentinels while keeping the body
# human-readable for later diagnostics.
dx_review_context_valid() {
  local context_file="$1" expected_binding="${2:-}"
  [[ -f "$context_file" ]] || return 1
  [[ $(wc -c < "$context_file" 2>/dev/null | tr -d ' ') -ge 160 ]] || return 1
  LC_ALL=C grep -q '^## Scope' "$context_file" 2>/dev/null &&
    LC_ALL=C grep -q '^## Deterministic Checks' "$context_file" 2>/dev/null &&
    LC_ALL=C grep -q '^## Review Coverage' "$context_file" 2>/dev/null &&
    LC_ALL=C grep -q '^## Verification' "$context_file" 2>/dev/null || return 1
  if [[ -n "$expected_binding" ]]; then
    [[ "$expected_binding" == "standalone" || "$expected_binding" =~ ^[a-f0-9]{64}$ ]] || return 1
    LC_ALL=C grep -q '^## Acceptance Criteria' "$context_file" 2>/dev/null &&
      LC_ALL=C grep -Fqx "Criteria binding: ${expected_binding}" "$context_file" 2>/dev/null
  fi
}

# Each pass owns one 16-character lowercase SHA-256 prefix.
dx_review_findings_hash_valid() {
  local findings_file="$1"
  [[ -f "$findings_file" ]] || return 1
  LC_ALL=C awk '
    END {
      valid = (NR == 1 && length($0) == 16 && $0 !~ /[^0-9a-f]/)
      exit !valid
    }
  ' "$findings_file" 2>/dev/null
}

# dx_review_selection_file <session_id> — persisted risk tier chosen before review
dx_review_selection_file() { dx_session_id_valid "${1:-}" || return 2; echo "${DX_LOOP_DIR}/${1}.review-selection"; }

# dx_review_evidence_file <session_id> — versioned machine-readable pass evidence
dx_review_evidence_file() { dx_session_id_valid "${1:-}" || return 2; echo "${DX_LOOP_DIR}/${1}.review-evidence.json"; }

# dx_review_ledger_file <session_id> — accepted consecutive clean-pass records
dx_review_ledger_file() { dx_session_id_valid "${1:-}" || return 2; echo "${DX_LOOP_DIR}/${1}.review-ledger"; }

# dx_review_receipt_file <session_id> — machine-readable successful review gate
dx_review_receipt_file() { dx_session_id_valid "${1:-}" || return 2; echo "${DX_LOOP_DIR}/${1}.review-receipt"; }

# dx_review_lock_dir <repo_dir> — checkout-scoped review-loop ownership lock
dx_review_lock_dir() {
  local repo_dir="${1:-$PWD}" lock_key
  lock_key=$(DX_REVIEW_LOCK_REPO_DIR="$repo_dir" python3 - <<'PY'
import hashlib
import os
import subprocess
from pathlib import Path

requested = Path(os.environ["DX_REVIEW_LOCK_REPO_DIR"]).resolve()
probe = subprocess.run(
    ["git", "-C", str(requested), "rev-parse", "--show-toplevel"],
    check=False,
    stdout=subprocess.PIPE,
    stderr=subprocess.DEVNULL,
)
if probe.returncode != 0:
    raise SystemExit(1)
root = os.path.realpath(os.fsdecode(probe.stdout.rstrip(b"\n")))
print(hashlib.sha256(os.fsencode(root)).hexdigest()[:24])
PY
  ) || return 1
  [[ "$lock_key" =~ ^[a-f0-9]{24}$ ]] || return 1
  printf '%s/review-checkout-%s.lock\n' "$DX_LOOP_DIR" "$lock_key"
}

# __dx_review_path_age_seconds <path> — portable age check for lock recovery
__dx_review_path_age_seconds() {
  local target="$1"
  DX_REVIEW_AGE_TARGET="$target" python3 - <<'PY'
import os
import time

try:
    modified = os.stat(os.environ["DX_REVIEW_AGE_TARGET"], follow_symlinks=False).st_mtime
except OSError:
    raise SystemExit(1)
print(max(0, int(time.time() - modified)))
PY
}

# __dx_review_lock_publish_owner <lock_dir> <owner_token> <owner_pid>
__dx_review_lock_publish_owner() {
  local lock_dir="$1" owner_token="$2" owner_pid="$3" owner_file tmp_file
  owner_file="$lock_dir/owner"
  tmp_file="$lock_dir/.owner.${owner_pid}.${owner_token}"
  if ! printf '%s\t%s\t%s\n' "$(date +%s)" "$owner_pid" "$owner_token" > "$tmp_file" || \
     ! command mv -f "$tmp_file" "$owner_file"; then
    command rm -f "$tmp_file" 2>/dev/null || true
    return 1
  fi
}

# dx_review_lock_acquire <repo_dir> <owner_token> [owner_pid] — atomically own one checkout
dx_review_lock_acquire() {
  local repo_dir="$1" owner_token="$2" caller_pid="${3:-$$}" lock_dir owner_file reaper_dir raw
  local owner_epoch owner_pid recorded_token extra lock_age reaper_age
  local stale_grace=30
  [[ -n "$owner_token" && "$owner_token" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
  [[ "$caller_pid" =~ ^[0-9]+$ ]] && kill -0 "$caller_pid" 2>/dev/null || return 2
  lock_dir=$(dx_review_lock_dir "$repo_dir") || return 2
  owner_file="$lock_dir/owner"
  reaper_dir="${lock_dir}.reap"
  mkdir -p "$DX_LOOP_DIR" || return 2

  # Every acquisition passes through this short-lived mutex. That closes the
  # mkdir-to-owner publication window and serializes stale-lock reclamation.
  if ! command mkdir "$reaper_dir" 2>/dev/null; then
    reaper_age=$(__dx_review_path_age_seconds "$reaper_dir" 2>/dev/null || true)
    if [[ "$reaper_age" =~ ^[0-9]+$ && "$reaper_age" -ge "$stale_grace" ]]; then
      command rmdir "$reaper_dir" 2>/dev/null || return 1
      command mkdir "$reaper_dir" 2>/dev/null || return 1
    else
      return 1
    fi
  fi

  if command mkdir "$lock_dir" 2>/dev/null; then
    if __dx_review_lock_publish_owner "$lock_dir" "$owner_token" "$caller_pid"; then
      command rmdir "$reaper_dir" 2>/dev/null || true
      return 0
    fi
    command rm -f "$owner_file" 2>/dev/null || true
    command rmdir "$lock_dir" 2>/dev/null || true
    command rmdir "$reaper_dir" 2>/dev/null || true
    return 2
  fi

  raw=$(cat "$owner_file" 2>/dev/null || true)
  owner_epoch=""
  owner_pid=""
  recorded_token=""
  extra=""
  IFS=$'\t' read -r owner_epoch owner_pid recorded_token extra <<EOF
$raw
EOF
  if [[ -z "$extra" && "$owner_epoch" =~ ^[0-9]+$ && "$owner_pid" =~ ^[0-9]+$ && \
        "$recorded_token" =~ ^[A-Za-z0-9._-]+$ ]]; then
    if kill -0 "$owner_pid" 2>/dev/null; then
      command rmdir "$reaper_dir" 2>/dev/null || true
      return 1
    fi
  else
    lock_age=$(__dx_review_path_age_seconds "$lock_dir" 2>/dev/null || true)
    if [[ ! "$lock_age" =~ ^[0-9]+$ || "$lock_age" -lt "$stale_grace" ]]; then
      command rmdir "$reaper_dir" 2>/dev/null || true
      return 1
    fi
  fi

  command rm -f "$owner_file" 2>/dev/null || {
    command rmdir "$reaper_dir" 2>/dev/null || true
    return 1
  }
  command rmdir "$lock_dir" 2>/dev/null || {
    command rmdir "$reaper_dir" 2>/dev/null || true
    return 1
  }

  command mkdir "$lock_dir" 2>/dev/null || {
    command rmdir "$reaper_dir" 2>/dev/null || true
    return 1
  }
  if __dx_review_lock_publish_owner "$lock_dir" "$owner_token" "$caller_pid"; then
    command rmdir "$reaper_dir" 2>/dev/null || true
    return 0
  fi
  command rm -f "$owner_file" 2>/dev/null || true
  command rmdir "$lock_dir" 2>/dev/null || true
  command rmdir "$reaper_dir" 2>/dev/null || true
  return 2
}

# dx_review_lock_release <repo_dir> <owner_token> — release only our own lock
dx_review_lock_release() {
  local repo_dir="$1" owner_token="$2" lock_dir owner_file raw recorded_token
  [[ -n "$owner_token" ]] || return 0
  lock_dir=$(dx_review_lock_dir "$repo_dir" 2>/dev/null) || return 0
  owner_file="$lock_dir/owner"
  raw=$(cat "$owner_file" 2>/dev/null || true)
  recorded_token=$(printf '%s\n' "$raw" | awk -F '\t' 'NR == 1 { print $3 }')
  [[ "$recorded_token" == "$owner_token" ]] || return 1
  command rm -f "$owner_file" 2>/dev/null || return 1
  command rmdir "$lock_dir" 2>/dev/null || return 1
}

# dx_complete_state_file <session_id> — Phase 6 cycle bookkeeping ("cycle_count:last_check_epoch")
# Survives interrupts so resuming Phase 6 picks up the same cycle counter.
dx_complete_state_file() { echo "${DX_LOOP_DIR}/${1}.complete-state"; }

# dx_provider_state_file <session_id> — resolved provider engine for hook fallback
dx_provider_state_file() { echo "${DX_LOOP_DIR}/${1}.provider"; }

# dx_phase_started_file <session_id> <phase> — marker that the phase skill/workflow started
dx_phase_started_file() { echo "${DX_LOOP_DIR}/${1}.phase-${2}.started"; }

# dx_phase_ready_file <session_id> <phase> — marker that a pre-audit phase gate is satisfied
dx_phase_ready_file() { echo "${DX_LOOP_DIR}/${1}.phase-${2}.ready"; }

# dx_phase_busy_file <session_id> <phase> — marker that async phase work is still running
dx_phase_busy_file() { echo "${DX_LOOP_DIR}/${1}.phase-${2}.busy"; }

# dx_phase_busy_notice_file <session_id> <phase> — last busy-gate notice timestamp
dx_phase_busy_notice_file() { echo "${DX_LOOP_DIR}/${1}.phase-${2}.busy-notice"; }

# dx_phase_busy_cancel_file <session_id> <phase> — cancellation request for the busy owner
dx_phase_busy_cancel_file() { echo "${DX_LOOP_DIR}/${1}.phase-${2}.busy-cancel"; }

# dx_phase_busy_quiesced_file <session_id> <phase> — matching owner acknowledgement
dx_phase_busy_quiesced_file() { echo "${DX_LOOP_DIR}/${1}.phase-${2}.busy-quiesced"; }

# dx_log_phase <session_id> <step> <phase_name> <start_epoch> <end_epoch> <duration_s> <iterations> <status> <exit_code>
# Append a TSV row to the structured phase log. Creates the header on first write.
dx_log_phase() {
  local session_id="$1" step="$2" phase_name="$3"
  local start_epoch="$4" end_epoch="$5" duration_s="$6"
  local iterations="$7" phase_status="$8" exit_code="$9"
  local log_file
  log_file=$(dx_log_file "$session_id")

  mkdir -p "$(dirname "$log_file")"
  if [[ ! -f "$log_file" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "session_id" "phase" "phase_name" "start_epoch" "end_epoch" \
      "duration_s" "iterations" "status" "exit_code" > "$log_file"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$session_id" "$step" "$phase_name" "$start_epoch" "$end_epoch" \
    "$duration_s" "$iterations" "$phase_status" "$exit_code" >> "$log_file"
}

# dx_phase_outcome_record <session_id> <phase> <outcome> <source> <generation> <reason>
# Atomically append one idempotent phase outcome. Returns 3 when the same
# phase/generation receipt is already present.
dx_phase_outcome_record() {
  local session_id="$1" phase="$2" outcome="$3" source="$4" generation="$5" reason="$6"
  local outcome_file tmp_file recorded_at existing_status
  dx_session_id_valid "$session_id" || return 1
  [[ "$phase" =~ ^[0-6]$ ]] || return 1
  case "$outcome" in
    completed|skipped|waived) ;;
    *) return 1 ;;
  esac
  [[ "$source" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [[ "$generation" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  [[ "$reason" =~ ^[A-Za-z0-9._-]+$ ]] || return 1

  outcome_file=$(dx_phase_outcomes_file "$session_id")
  mkdir -p "$(dirname "$outcome_file")" || return 1
  if [[ ( -e "$outcome_file" || -L "$outcome_file" ) \
    && ( ! -f "$outcome_file" || -L "$outcome_file" ) ]]; then
    return 1
  fi
  if [[ -f "$outcome_file" ]]; then
    existing_status=$(awk -F '\t' -v phase="$phase" -v generation="$generation" \
      -v outcome="$outcome" -v source="$source" -v reason="$reason" '
      NR > 1 && $2 == phase && $5 == generation {
        found = 1
        if ($3 != outcome || $4 != source || $6 != reason) conflict = 1
      }
      END {
        if (conflict) print "conflict"
        else if (found) print "exact"
      }
    ' "$outcome_file" 2>/dev/null || true)
    [[ "$existing_status" == "exact" ]] && return 3
    [[ "$existing_status" == "conflict" ]] && return 1
  fi

  tmp_file=$(mktemp "${outcome_file}.tmp.XXXXXX") || return 1
  chmod 600 "$tmp_file" 2>/dev/null || true
  if [[ -f "$outcome_file" ]]; then
    if ! command cat "$outcome_file" > "$tmp_file"; then
      command rm -f "$tmp_file" 2>/dev/null || true
      return 1
    fi
  elif ! printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    recorded_at phase outcome source generation reason > "$tmp_file"; then
    command rm -f "$tmp_file" 2>/dev/null || true
    return 1
  fi

  recorded_at=$(date +%s)
  if ! printf '%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$recorded_at" "$phase" "$outcome" "$source" "$generation" "$reason" \
    >> "$tmp_file" || ! command mv -f "$tmp_file" "$outcome_file"; then
    command rm -f "$tmp_file" 2>/dev/null || true
    return 1
  fi
}

# dx_phase_outcome_latest <session_id> <phase>
# Prefer the explicit ledger, then recognize successful legacy TSV phase rows.
dx_phase_outcome_latest() {
  local session_id="$1" phase="$2" outcome_file log_file outcome=""
  local run_id="" events_file=""
  dx_session_id_valid "$session_id" || return 0
  [[ "$phase" =~ ^[0-6]$ ]] || return 0

  outcome_file=$(dx_phase_outcomes_file "$session_id")
  if [[ -f "$outcome_file" && ! -L "$outcome_file" ]]; then
    outcome=$(awk -F '\t' -v phase="$phase" '
      NR > 1 && $2 == phase { outcome = $3 }
      END { print outcome }
    ' "$outcome_file" 2>/dev/null || true)
  fi
  if [[ "$outcome" == "completed" || "$outcome" == "skipped" || "$outcome" == "waived" ]]; then
    printf '%s\n' "$outcome"
    return 0
  fi

  log_file=$(dx_log_file "$session_id")
  if [[ -f "$log_file" && ! -L "$log_file" ]]; then
    outcome=$(awk -F '\t' -v phase="$phase" '
      NR > 1 && $2 == phase && $8 == "advance" && $9 == "0" { outcome = "completed" }
      END { print outcome }
    ' "$log_file" 2>/dev/null || true)
    if [[ "$outcome" == "completed" ]]; then
      printf '%s\n' "$outcome"
      return 0
    fi
  fi

  # Older sessions may retain their run journal after the compact phase log
  # has been cleaned up. Reconcile the latest validated event for this phase;
  # PR state and other external artifacts are never completion evidence.
  if type dx_run_read_for_session >/dev/null 2>&1 \
    && type dx_run_events_file >/dev/null 2>&1 \
    && command -v python3 >/dev/null 2>&1; then
    run_id=$(dx_run_read_for_session "$session_id" 2>/dev/null || true)
    [[ -n "$run_id" ]] && events_file=$(dx_run_events_file "$run_id" 2>/dev/null || true)
  fi
  if [[ -n "$events_file" && -f "$events_file" && ! -L "$events_file" ]]; then
    outcome=$(python3 - "$events_file" "$phase" "$run_id" <<'PY' 2>/dev/null || true
import json
import sys

events_path, expected_phase, expected_run = sys.argv[1:]
relevant_types = {
    "phase.started",
    "phase.completed",
    "phase.failed",
    "phase.skipped",
    "phase.waived",
}
terminal_outcomes = {
    "phase.completed": "completed",
    "phase.skipped": "skipped",
    "phase.waived": "waived",
}
latest_sequence = -1
latest_type = ""
with open(events_path, "r", encoding="utf-8") as handle:
    for raw_line in handle:
        if len(raw_line) > 1_048_576:
            continue
        try:
            event = json.loads(raw_line)
        except (json.JSONDecodeError, TypeError):
            continue
        if not isinstance(event, dict):
            continue
        event_type = event.get("type")
        sequence = event.get("sequence")
        event_id = event.get("id")
        if event_type not in relevant_types or event.get("phase") != expected_phase:
            continue
        if event.get("run_id") != expected_run or event.get("severity") not in {"info", "warn", "error"}:
            continue
        if not isinstance(sequence, int) or sequence <= 0:
            continue
        if not isinstance(event_id, str) or not event_id.startswith(f"evt_{sequence:06d}_"):
            continue
        if sequence > latest_sequence:
            latest_sequence = sequence
            latest_type = event_type
outcome = terminal_outcomes.get(latest_type)
if outcome:
    print(outcome)
PY
)
    case "$outcome" in
      completed|skipped|waived) printf '%s\n' "$outcome" ;;
    esac
  fi
  return 0
}

# dx_record_session_branch <session_id> [repo_dir]
# Persist the branch used by this lifecycle. In-place sessions need this to
# resume safely because the checkout can be moved to a different branch between
# runs. Worktree sessions record it too for diagnostics.
dx_record_session_branch() {
  local session_id="$1" repo_dir="${2:-.}" branch branch_file tmp_file
  [[ -n "$session_id" ]] || return 0
  branch=$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  [[ -n "$branch" && "$branch" != "HEAD" ]] || return 0

  branch_file=$(dx_branch_file "$session_id")
  mkdir -p "$(dirname "$branch_file")"
  tmp_file="${branch_file}.tmp.$$"
  if ! printf '%s\n' "$branch" > "$tmp_file" || ! command mv -f "$tmp_file" "$branch_file"; then
    command rm -f "$tmp_file" 2>/dev/null
    return 1
  fi
}

# dx_cleanup_session <session_id>
# Remove all loop and phase state files for a session. Safe to call when dirs don't exist.
dx_cleanup_session() {
  local sid="$1"
  dx_session_id_valid "$sid" || return 2
  if [[ -d "$DX_LOOP_DIR" ]]; then
    dx_review_ledger_reset "$sid" 2>/dev/null || true
    rm -f "$(dx_loop_file "$sid")" "$(dx_complete_file "$sid")" "$(dx_active_file "$sid")" "$(dx_owner_file "$sid")" "$(dx_prompt_file "$sid")" "$(dx_findings_file "$sid")" "$(dx_debt_file "$sid")" "$(dx_loop_config_file "$sid")" "$(dx_handoff_mode_file "$sid")" "$(dx_paused_file "$sid")" "$(dx_pause_state_file "$sid")" "$(dx_watch_pause_file "$sid")" "${DX_LOOP_DIR}/${sid}.control" "$(dx_watch_lock_file "$sid" ci)" "$(dx_watch_lock_file "$sid" pr)" "$(dx_review_state_file "$sid")" "$(dx_review_result_file "$sid")" "$(dx_review_context_file "$sid")" "$(dx_review_criteria_file "$sid")" "$(dx_review_criteria_approval_file "$sid")" "$(dx_review_evidence_file "$sid")" "$(dx_review_selection_file "$sid")" "$(dx_review_receipt_file "$sid")" "$(dx_complete_state_file "$sid")" "$(dx_provider_state_file "$sid")" 2>/dev/null
    rm -f "${DX_LOOP_DIR}/${sid}.control-lock/owner" 2>/dev/null || true
    rmdir "${DX_LOOP_DIR}/${sid}.control-lock" 2>/dev/null || true
    find "$DX_LOOP_DIR" -maxdepth 1 -type f \( -name "${sid}.phase-*.started" -o -name "${sid}.phase-*.ready" -o -name "${sid}.phase-*.busy" -o -name "${sid}.phase-*.busy-notice" -o -name "${sid}.phase-*.busy-cancel" -o -name "${sid}.phase-*.busy-quiesced" \) -exec rm -f {} + 2>/dev/null || true
  fi
  [[ -d "$DX_STATE_DIR" ]] && rm -f "$(dx_state_file "$sid")" "$(dx_times_file "$sid")" "$(dx_context_file "$sid")" "$(dx_log_file "$sid")" "$(dx_phase_outcomes_file "$sid")" "$(dx_branch_file "$sid")" "$(dx_meta_file "$sid")" "${DX_STATE_DIR}/${sid}.interventions" "${DX_STATE_DIR}/${sid}.human-complete" 2>/dev/null
}

__dx_review_credit_session_from_path() {
  [[ $# -eq 1 ]] || return 1
  local name="${1##*/}" session_id
  case "$name" in
    *.review-ledger) session_id="${name%.review-ledger}" ;;
    *.review-proofs) session_id="${name%.review-proofs}" ;;
    *) return 1 ;;
  esac
  dx_session_id_valid "$session_id" || return 1
  printf '%s\n' "$session_id"
}

# dx_cleanup_stale_review_credit <max-age-days>
# Remove stale ledgers and their retained proof bundles as one unit.
dx_cleanup_stale_review_credit() {
  [[ $# -eq 1 ]] || return 1
  local max_age_days="$1" credit_path session_id cleanup_count=0 cleanup_status=0
  case "$max_age_days" in
    ''|*[!0-9]*) return 1 ;;
  esac
  [[ -d "$DX_LOOP_DIR" ]] || {
    printf '%s\n' "0"
    return 0
  }

  while IFS= read -r -d '' credit_path; do
    session_id=$(__dx_review_credit_session_from_path "$credit_path") || {
      cleanup_status=1
      continue
    }
    if dx_review_ledger_reset "$session_id"; then
      cleanup_count=$((cleanup_count + 1))
    else
      cleanup_status=1
    fi
  done < <(find "$DX_LOOP_DIR" -maxdepth 1 \( -type f -o -type l \) \
    -name '*.review-ledger' -mtime +"$max_age_days" -print0 2>/dev/null)

  while IFS= read -r -d '' credit_path; do
    session_id=$(__dx_review_credit_session_from_path "$credit_path") || {
      cleanup_status=1
      continue
    }
    if dx_review_ledger_reset "$session_id"; then
      cleanup_count=$((cleanup_count + 1))
    else
      cleanup_status=1
    fi
  done < <(find "$DX_LOOP_DIR" -maxdepth 1 \( -type d -o -type l \) \
    -name '*.review-proofs' -mtime +"$max_age_days" -print0 2>/dev/null)

  printf '%s\n' "$cleanup_count"
  return "$cleanup_status"
}

# Remove every phase and loop artifact scoped to the current repository. This
# also covers in-place sessions and worktrees that no longer exist on disk.
dx_cleanup_repo_sessions() {
  local repo_key last_session_file last_info last_path repo_root remainder state_dir prefix
  local credit_path credit_session

  repo_key=$(dx_session_repo_key) || return 1
  if [[ -d "$DX_LOOP_DIR" ]]; then
    for prefix in "" "init-" "sync-" "maintain-" "from-pr-" "refine-" "headless-invalid-"; do
      while IFS= read -r -d '' credit_path; do
        credit_session=$(__dx_review_credit_session_from_path "$credit_path") || return 1
        dx_review_ledger_reset "$credit_session" || return 1
      done < <(find "$DX_LOOP_DIR" -maxdepth 1 \
        \( -name "${prefix}${repo_key}-*.review-ledger" -o \
           -name "${prefix}${repo_key}-*.review-proofs" \) -print0)
    done
  fi
  for state_dir in "$DX_LOOP_DIR" "$DX_STATE_DIR"; do
    [[ -d "$state_dir" ]] || continue
    for prefix in "" "init-" "sync-" "maintain-" "from-pr-" "refine-" "headless-invalid-"; do
      find "$state_dir" -maxdepth 1 -type f -name "${prefix}${repo_key}-*" \
        -exec rm -f {} + || return $?
    done
  done

  last_session_file="$DX_STATE_DIR/last-session"
  [[ -f "$last_session_file" ]] || return 0
  last_info=$(cat "$last_session_file" 2>/dev/null) || return 0
  remainder=${last_info#*:}
  [[ "$remainder" != "$last_info" ]] || return 0
  last_path=${remainder%%:*}
  last_path=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' \
    "$last_path" 2>/dev/null) || return 0
  repo_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 0
  repo_root=$(cd "$repo_root" 2>/dev/null && pwd -P) || return 0
  if [[ "$last_path" == "$repo_root" || "$last_path" == "$repo_root/.dex/worktrees/"* ]]; then
    rm -f "$last_session_file"
  fi
}

__dx_session_artifact_matches_checkout() {
  local artifact_name="$1" checkout_session="$2" prefix

  for prefix in "" "init-" "sync-" "maintain-" "from-pr-" "refine-" "headless-invalid-"; do
    case "$artifact_name" in
      "${prefix}${checkout_session}".*|"${prefix}${checkout_session}"-*) return 0 ;;
    esac
  done
  return 1
}

# Remove state tied to the checkout running uninit without disturbing another
# initialized worktree in the same repository.
dx_cleanup_current_checkout_sessions() {
  local current_root base_session repo_key meta_file session_id meta_root worktree_output
  local last_session_file last_info remainder last_path state_dir prefix
  local candidate name stem suffix pid epoch tail random line worktree_path sibling_root
  local sibling_session protected_sessions="" git_status protected

  current_root=$(git rev-parse --show-toplevel 2>/dev/null) || return 1
  current_root=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' \
    "$current_root" 2>/dev/null) || return 1
  base_session=$(dx_session_id) || return 1
  repo_key=$(dx_session_repo_key) || return 1
  if worktree_output=$(git worktree list --porcelain 2>/dev/null); then
    :
  else
    git_status=$?
    return "$git_status"
  fi
  while IFS= read -r line; do
    case "$line" in
      "worktree "*)
        worktree_path=${line#worktree }
        sibling_root=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' \
          "$worktree_path" 2>/dev/null) || return 1
        [[ "$sibling_root" != "$current_root" ]] || continue
        sibling_session=$(cd "$worktree_path" 2>/dev/null && dx_session_id) || return 1
        protected_sessions="${protected_sessions}${sibling_session}
"
        ;;
    esac
  done < <(printf '%s\n' "$worktree_output")

  for state_dir in "$DX_LOOP_DIR" "$DX_STATE_DIR"; do
    [[ -d "$state_dir" ]] || continue
    for prefix in "" "init-" "sync-" "maintain-" "from-pr-" "refine-" "headless-invalid-"; do
      stem="${prefix}${base_session}"
      while IFS= read -r candidate; do
        name=$(basename "$candidate")
        protected=0
        while IFS= read -r sibling_session; do
          [[ -n "$sibling_session" ]] || continue
          if __dx_session_artifact_matches_checkout "$name" "$sibling_session"; then
            protected=1
            break
          fi
        done <<EOF
$protected_sessions
EOF
        [[ "$protected" == "0" ]] || continue
        case "$name" in
          "$stem".*)
            rm -f "$candidate"
            ;;
          "$stem"-*)
            suffix=${name#"$stem"-}
            pid=${suffix%%-*}
            tail=${suffix#*-}
            [[ "$tail" != "$suffix" ]] || continue
            epoch=${tail%%-*}
            tail=${tail#*-}
            [[ "$tail" != "$epoch" ]] || continue
            random=${tail%%.*}
            [[ "$random" != "$tail" ]] || continue
            case "$pid" in ""|*[!0-9]*) continue ;; esac
            case "$epoch" in ""|*[!0-9]*) continue ;; esac
            case "$random" in ""|*[!0-9]*) continue ;; esac
            rm -f "$candidate"
            ;;
        esac
      done < <(find "$state_dir" -maxdepth 1 -type f -print 2>/dev/null)
    done
  done

  if [[ -d "$DX_STATE_DIR" ]]; then
    while IFS= read -r meta_file; do
      meta_root=$(awk -F= '$1 == "wt_dir" { sub(/^[^=]*=/, ""); print; exit }' \
        "$meta_file" 2>/dev/null)
      [[ -n "$meta_root" ]] || continue
      meta_root=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' \
        "$meta_root" 2>/dev/null) || continue
      [[ "$meta_root" == "$current_root" ]] || continue
      session_id=$(basename "$meta_file" .meta)
      dx_cleanup_session "$session_id"
    done < <(find "$DX_STATE_DIR" -maxdepth 1 -type f -name "${repo_key}-*.meta" \
      -print 2>/dev/null)
  fi

  last_session_file="$DX_STATE_DIR/last-session"
  [[ -f "$last_session_file" ]] || return 0
  last_info=$(cat "$last_session_file" 2>/dev/null) || return 0
  remainder=${last_info#*:}
  [[ "$remainder" != "$last_info" ]] || return 0
  last_path=${remainder%%:*}
  last_path=$(python3 -c 'import os, sys; print(os.path.realpath(sys.argv[1]))' \
    "$last_path" 2>/dev/null) || return 0
  if [[ "$last_path" == "$current_root" ]]; then
    rm -f "$last_session_file"
  fi
}
