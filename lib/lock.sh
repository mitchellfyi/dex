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

# dx_lock_path_age_seconds <path> — portable age in seconds, or empty
dx_lock_path_age_seconds() {
  local path="$1"
  [[ -e "$path" ]] || return 1
  python3 - "$path" <<'PY' 2>/dev/null
import os
import sys
import time

try:
    age = int(time.time() - os.stat(sys.argv[1]).st_mtime)
except OSError:
    raise SystemExit(1)
print(age if age > 0 else 0)
PY
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
  command mv -f "$tmp" "$owner_file" 2>/dev/null || {
    command rm -f "$tmp" 2>/dev/null || true
    return 1
  }
}

# dx_lock_acquire <lock_dir> <owner_token> [owner_pid] [stale_grace_seconds]
#
# Returns 0 when the lock is held by this caller, 1 when another live owner
# holds it (retry later), 2 on a usage or filesystem error.
dx_lock_acquire() {
  local lock_dir="$1" owner_token="$2" caller_pid="${3:-$$}" stale_grace="${4:-30}"
  local owner_file reaper_dir raw owner_epoch owner_pid recorded_token extra lock_age reaper_age
  [[ -n "$lock_dir" ]] || return 2
  [[ -n "$owner_token" && "$owner_token" =~ ^[A-Za-z0-9._-]+$ ]] || return 2
  [[ "$caller_pid" =~ ^[0-9]+$ ]] && kill -0 "$caller_pid" 2>/dev/null || return 2
  owner_file="$lock_dir/owner"
  reaper_dir="${lock_dir}.reap"
  command mkdir -p "$(dirname "$lock_dir")" 2>/dev/null || return 2

  if ! command mkdir "$reaper_dir" 2>/dev/null; then
    reaper_age=$(dx_lock_path_age_seconds "$reaper_dir" 2>/dev/null || true)
    if [[ "$reaper_age" =~ ^[0-9]+$ && "$reaper_age" -ge "$stale_grace" ]]; then
      command rmdir "$reaper_dir" 2>/dev/null || return 1
      command mkdir "$reaper_dir" 2>/dev/null || return 1
    else
      return 1
    fi
  fi

  if command mkdir "$lock_dir" 2>/dev/null; then
    if __dx_lock_publish_owner "$lock_dir" "$owner_token" "$caller_pid"; then
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
    # A published owner record is authoritative: if that process is gone the
    # lock is stale now, with no grace period to wait out.
    if __dx_lock_pid_alive "$owner_pid"; then
      command rmdir "$reaper_dir" 2>/dev/null || true
      return 1
    fi
  else
    lock_age=$(dx_lock_path_age_seconds "$lock_dir" 2>/dev/null || true)
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
  if __dx_lock_publish_owner "$lock_dir" "$owner_token" "$caller_pid"; then
    command rmdir "$reaper_dir" 2>/dev/null || true
    return 0
  fi
  command rm -f "$owner_file" 2>/dev/null || true
  command rmdir "$lock_dir" 2>/dev/null || true
  command rmdir "$reaper_dir" 2>/dev/null || true
  return 2
}

# dx_lock_release <lock_dir> <owner_token> — release only a lock we still own
dx_lock_release() {
  local lock_dir="$1" owner_token="$2" owner_file raw recorded_token
  [[ -n "$lock_dir" && -n "$owner_token" ]] || return 0
  owner_file="$lock_dir/owner"
  raw=$(cat "$owner_file" 2>/dev/null || true)
  recorded_token=$(printf '%s\n' "$raw" | awk -F '\t' 'NR == 1 { print $3 }')
  [[ "$recorded_token" == "$owner_token" ]] || return 1
  command rm -f "$owner_file" 2>/dev/null || return 1
  command rmdir "$lock_dir" 2>/dev/null || return 1
}

# dx_lock_with <lock_dir> <owner_token> <timeout_seconds> <command...>
#
# Run a command under the lock, releasing it even if the command fails.
# Returns 75 (EX_TEMPFAIL) when the lock could not be taken in time.
dx_lock_with() {
  local lock_dir="$1" owner_token="$2" timeout="$3"
  shift 3
  local waited=0 status
  while ! dx_lock_acquire "$lock_dir" "$owner_token"; do
    [[ $? -eq 2 ]] && return 2
    if [[ "$waited" -ge "$timeout" ]]; then
      return 75
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  "$@"
  status=$?
  dx_lock_release "$lock_dir" "$owner_token" || true
  return "$status"
}
