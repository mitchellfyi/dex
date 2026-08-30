# shellcheck shell=bash
# Dex shared library — advisory directory locks with stale recovery
#
# One lock primitive for every Dex component that serializes writers. All
# callers get the same guarantees:
#
#   * Acquisition is atomic. `mkdir` is the only portable create-if-absent
#     primitive available in both bash and zsh without extra dependencies.
#   * Ownership is published. The lock directory holds an `owner` file
#     recording epoch, pid, and a caller token, so a stale lock can be told
#     apart from a live one.
#   * Reclamation is serialized. Every acquisition passes through a
#     short-lived reaper mutex, which closes the window between `mkdir`
#     succeeding and the owner file appearing, and stops two waiters from both
#     deciding a dead lock is theirs to steal.
#
# The last point is why hand-rolled `rm -f lock && mkdir lock` takeovers are
# unsafe: two contenders can both observe an expired lock, and the second
# removes the first's freshly created one, leaving two live writers.
#
# Known residual window: recovering a *stale reaper* (a process that died
# inside the mutex during its own milliseconds-long critical section, observed
# 30s later) is itself an unserialized rmdir+mkdir, so two waiters arriving in
# that exact window could both claim it. The steal path below still bounds the
# damage — a second stealer's rmdir fails once the first has republished an
# owner — and fully closing it needs a different primitive than mkdir.

# Bash 3.2 can apply errexit to a failing `command` builtin even when its
# containing function is evaluated by `if`. Keep alias/function bypassing, but
# put the builtin in a subshell so a normal "lock is busy" result stays data.
__dx_lock_command() {
  (command "$@")
}

# dx_lock_path_age_seconds <path> — portable age in seconds, or empty
#
# The age decides whether a lock or reaper is stale enough to take, so it has
# to be the age of the thing named and not of whatever it points at. os.stat
# follows a symlink: pointing one at an old directory reported that directory's
# age and made the lock reclaimable on demand, while pointing it at something
# freshly touched kept it un-reclaimable forever.
dx_lock_path_age_seconds() {
  local target="$1"
  [[ -e "$target" || -L "$target" ]] || return 1
  python3 - "$target" <<'PY' 2>/dev/null
import os
import sys
import time

try:
    modified = os.stat(sys.argv[1], follow_symlinks=False).st_mtime
except OSError:
    raise SystemExit(1)
print(max(0, int(time.time() - modified)))
PY
}

# dx_lock_self_pid_var — set DX_LOCK_SELF_PID to the calling process's PID
#
# $$ names the top-level shell even inside a backgrounded subshell, in both
# bash and zsh, so an owner record keyed on it makes a killed subshell's lock
# look held for as long as its parent lives — and lets a parent and its
# subshell forge each other's release tokens. bash 3.2 has no BASHPID, so
# when that variable is absent one exec'd sh answers with the caller's real
# PID. This must run as a plain command in the owning process: calling it
# through a command substitution would report the substitution's subshell.
dx_lock_self_pid_var() {
  DX_LOCK_SELF_PID="${BASHPID:-}"
  if [[ ! "$DX_LOCK_SELF_PID" =~ ^[0-9]+$ ]]; then
    DX_LOCK_SELF_PID=$(exec sh -c 'echo "$PPID"' 2>/dev/null) \
      || DX_LOCK_SELF_PID=""
  fi
  [[ "$DX_LOCK_SELF_PID" =~ ^[0-9]+$ ]] || DX_LOCK_SELF_PID="$$"
}

# __dx_lock_pid_alive <pid> — whether a process still exists
__dx_lock_pid_alive() {
  local pid="$1"
  [[ "$pid" =~ ^[0-9]+$ ]] || return 1
  kill -0 "$pid" 2>/dev/null && return 0
  # kill -0 also fails with EPERM for a live process owned by another user, so
  # confirm with ps before declaring the owner dead and stealing its lock.
  ps -p "$pid" >/dev/null 2>&1
}

# __dx_lock_publish_owner <lock_dir> <owner_token> <owner_pid>
__dx_lock_publish_owner() {
  local lock_dir="$1" owner_token="$2" owner_pid="$3" owner_file="$1/owner" tmp
  tmp="${owner_file}.tmp.$owner_pid"
  printf '%s\t%s\t%s\n' "$(date +%s)" "$owner_pid" "$owner_token" > "$tmp" 2>/dev/null || return 1
  __dx_lock_command mv -f "$tmp" "$owner_file" 2>/dev/null || {
    __dx_lock_command rm -f "$tmp" 2>/dev/null || true
    return 1
  }
}

# dx_lock_acquire <lock_dir> <owner_token> [owner_pid] [stale_grace_seconds]
#
# Returns 0 when the lock is held by this caller, 1 when another live owner
# holds it (retry later), 2 on a usage or filesystem error.
dx_lock_acquire() {
  local lock_dir="$1" owner_token="$2" caller_pid="${3:-}" stale_grace="${4:-30}"
  local owner_file reaper_dir raw owner_epoch owner_pid recorded_token extra lock_age reaper_age
  if [[ -z "$caller_pid" ]]; then
    # Default to the acquiring process itself, not $$ — see dx_lock_self_pid_var.
    dx_lock_self_pid_var
    caller_pid="$DX_LOCK_SELF_PID"
  fi
  [[ -n "$lock_dir" ]] || return 2
  [[ -n "$owner_token" && "$owner_token" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
  [[ "$caller_pid" =~ ^[0-9]+$ ]] && kill -0 "$caller_pid" 2>/dev/null || return 2
  owner_file="$lock_dir/owner"
  reaper_dir="${lock_dir}.reap"
  __dx_lock_command mkdir -p "$(dirname "$lock_dir")" 2>/dev/null || return 2

  if ! __dx_lock_command mkdir "$reaper_dir" 2>/dev/null; then
    reaper_age=$(dx_lock_path_age_seconds "$reaper_dir" 2>/dev/null || true)
    if [[ "$reaper_age" =~ ^[0-9]+$ && "$reaper_age" -ge "$stale_grace" ]]; then
      __dx_lock_command rmdir "$reaper_dir" 2>/dev/null || return 1
      __dx_lock_command mkdir "$reaper_dir" 2>/dev/null || return 1
    else
      return 1
    fi
  fi

  if __dx_lock_command mkdir "$lock_dir" 2>/dev/null; then
    if __dx_lock_publish_owner "$lock_dir" "$owner_token" "$caller_pid"; then
      __dx_lock_command rmdir "$reaper_dir" 2>/dev/null || true
      return 0
    fi
    __dx_lock_command rm -f "$owner_file" 2>/dev/null || true
    __dx_lock_command rmdir "$lock_dir" 2>/dev/null || true
    __dx_lock_command rmdir "$reaper_dir" 2>/dev/null || true
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
    # A published owner record is authoritative: if that process is gone the
    # lock is stale now, with no grace period to wait out.
    if __dx_lock_pid_alive "$owner_pid"; then
      __dx_lock_command rmdir "$reaper_dir" 2>/dev/null || true
      return 1
    fi
  else
    lock_age=$(dx_lock_path_age_seconds "$lock_dir" 2>/dev/null || true)
    if [[ ! "$lock_age" =~ ^[0-9]+$ || "$lock_age" -lt "$stale_grace" ]]; then
      __dx_lock_command rmdir "$reaper_dir" 2>/dev/null || true
      return 1
    fi
  fi

  __dx_lock_command rm -f "$owner_file" 2>/dev/null || {
    __dx_lock_command rmdir "$reaper_dir" 2>/dev/null || true
    return 1
  }
  __dx_lock_command rmdir "$lock_dir" 2>/dev/null || {
    __dx_lock_command rmdir "$reaper_dir" 2>/dev/null || true
    return 1
  }
  __dx_lock_command mkdir "$lock_dir" 2>/dev/null || {
    __dx_lock_command rmdir "$reaper_dir" 2>/dev/null || true
    return 1
  }
  if __dx_lock_publish_owner "$lock_dir" "$owner_token" "$caller_pid"; then
    __dx_lock_command rmdir "$reaper_dir" 2>/dev/null || true
    return 0
  fi
  __dx_lock_command rm -f "$owner_file" 2>/dev/null || true
  __dx_lock_command rmdir "$lock_dir" 2>/dev/null || true
  __dx_lock_command rmdir "$reaper_dir" 2>/dev/null || true
  return 2
}

# dx_lock_release <lock_dir> <owner_token> — release only a lock we still own
dx_lock_release() {
  local lock_dir="$1" owner_token="$2" owner_file raw recorded_token
  local releasing_owner
  [[ -n "$lock_dir" && -n "$owner_token" ]] || return 0
  owner_file="$lock_dir/owner"
  raw=$(cat "$owner_file" 2>/dev/null || true)
  recorded_token=$(printf '%s\n' "$raw" | awk -F '\t' 'NR == 1 { print $3 }')
  [[ "$recorded_token" == "$owner_token" ]] || return 1
  releasing_owner="${lock_dir}.releasing.${owner_token}"
  [[ ! -e "$releasing_owner" && ! -L "$releasing_owner" ]] || return 1
  __dx_lock_command mv "$owner_file" "$releasing_owner" 2>/dev/null || return 1
  if ! __dx_lock_command rmdir "$lock_dir" 2>/dev/null; then
    if [[ -d "$lock_dir" && ! -e "$owner_file" && ! -L "$owner_file" ]] \
      && __dx_lock_command mv "$releasing_owner" "$owner_file" 2>/dev/null; then
      return 1
    fi
    return 1
  fi
  __dx_lock_command rm -f "$releasing_owner" 2>/dev/null || true
}

# A failed release can restore the exact owner for a safe retry. Preserve the
# first failure as the result so callers never report a transition as clean,
# even when the retry prevents the live process from stranding the lock.
dx_lock_release_checked() {
  local lock_dir="$1" owner_token="$2"
  if dx_lock_release "$lock_dir" "$owner_token"; then
    return 0
  fi
  dx_lock_release "$lock_dir" "$owner_token" 2>/dev/null || true
  return 1
}

# dx_lock_with <lock_dir> <owner_token> <timeout_seconds> <command...>
#
# Run a command under the lock, releasing it even if the command fails.
# Returns 75 (EX_TEMPFAIL) when the lock could not be taken in time.
dx_lock_with() {
  local lock_dir="$1" owner_token="$2" timeout="$3"
  shift 3
  # `status` is read-only in zsh; lib/ must work in both shells.
  local waited_tenths=0 command_status acquire_status
  while :; do
    # Capture the real status: inside `while ! cmd`, $? reflects the negated
    # condition (always 0 in the body), so a hard error could never surface.
    dx_lock_acquire "$lock_dir" "$owner_token" && break
    acquire_status=$?
    [[ "$acquire_status" -eq 2 ]] && return 2
    # The retry sleeps a tenth of a second, so the deadline is timeout * 10
    # ticks — comparing ticks against seconds cut every wait to a tenth.
    if [[ "$waited_tenths" -ge $((timeout * 10)) ]]; then
      return 75
    fi
    sleep 0.1
    waited_tenths=$((waited_tenths + 1))
  done
  "$@"
  command_status=$?
  dx_lock_release "$lock_dir" "$owner_token" || true
  return "$command_status"
}
