#!/usr/bin/env bash
set -euo pipefail

# Tests for lib/lock.sh, the shared advisory lock used wherever Dex serializes
# writers. The important property is mutual exclusion under contention and
# during stale-lock reclamation.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-lock-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
mkdir -p "$HOME"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

lock="$TMP_DIR/work.lock"

# A free lock is acquired, and a second holder is refused while it is held.
dx_lock_acquire "$lock" holder-a || {
  printf 'could not acquire a free lock\n' >&2
  exit 1
}
if dx_lock_acquire "$lock" holder-b; then
  printf 'a held lock was handed to a second owner\n' >&2
  exit 1
fi

# Release is owner-checked: a non-owner cannot drop someone else's lock.
if dx_lock_release "$lock" holder-b; then
  printf 'a non-owner released the lock\n' >&2
  exit 1
fi
dx_lock_release "$lock" holder-a || {
  printf 'owner could not release its own lock\n' >&2
  exit 1
}
[[ ! -d "$lock" ]] || {
  printf 'lock directory survived release\n' >&2
  exit 1
}

# A lock whose owner process is gone is reclaimed once past the grace period.
dead_pid=$(bash -c 'echo $$')
while kill -0 "$dead_pid" 2>/dev/null; do
  dead_pid=$((dead_pid + 1))
  [[ "$dead_pid" -lt 4194304 ]] || break
done
mkdir -p "$lock"
printf '%s\t%s\t%s\n' "$(( $(date +%s) - 600 ))" "$dead_pid" "gone" > "$lock/owner"
dx_lock_acquire "$lock" holder-c || {
  printf 'a lock owned by a dead process was not reclaimed\n' >&2
  exit 1
}
dx_lock_release "$lock" holder-c

# The age that decides staleness is the age of the path named, not of whatever
# it points at. os.stat follows a symlink, so a reaper symlinked at an old
# directory reported that directory's age and was reclaimable on demand — which
# is the mutex that stops two waiters both stealing the same lock.
symlink_target="$TMP_DIR/aged-target"
mkdir -p "$symlink_target"
python3 - "$symlink_target" <<'PY'
import os
import sys
import time

old = time.time() - 9999
os.utime(sys.argv[1], (old, old))
PY
ln -s "$symlink_target" "$TMP_DIR/aged-link"
if [[ "$(dx_lock_path_age_seconds "$symlink_target")" != "9999" ]]; then
  printf 'the aged directory did not report its own age\n' >&2
  exit 1
fi
if [[ "$(dx_lock_path_age_seconds "$TMP_DIR/aged-link")" != "0" ]]; then
  printf 'a symlink reported its target age instead of its own: %s\n' \
    "$(dx_lock_path_age_seconds "$TMP_DIR/aged-link")" >&2
  exit 1
fi
rm -rf "$symlink_target" "$TMP_DIR/aged-link"

# A lock with a corrupt owner record is only reclaimed after the grace period,
# never immediately, so a publication in flight is not stolen.
mkdir -p "$lock"
printf 'garbage\n' > "$lock/owner"
if dx_lock_acquire "$lock" holder-d 1000 5; then
  printf 'a fresh lock with an unreadable owner was stolen immediately\n' >&2
  exit 1
fi
rm -rf "$lock"

# Mutual exclusion under real contention: many concurrent workers each
# increment a shared counter under the lock. A lost update means the lock let
# two writers in at once.
counter="$TMP_DIR/counter"
printf '0\n' > "$counter"
cat > "$TMP_DIR/worker.sh" <<'WORKER'
#!/usr/bin/env bash
set -uo pipefail
# shellcheck disable=SC1091
source "$DEX_DIR/lib/common.sh"
lock="$1"
counter="$2"
id="$3"
waited=0
until dx_lock_acquire "$lock" "worker-$id"; do
  [[ $? -ne 2 ]] || exit 2
  waited=$((waited + 1))
  [[ "$waited" -lt 400 ]] || exit 3
  sleep 0.05
done
value=$(cat "$counter")
# Widen the read-modify-write window so an unsafe lock reliably loses updates.
sleep 0.02
printf '%s\n' "$((value + 1))" > "$counter"
dx_lock_release "$lock" "worker-$id"
WORKER
chmod +x "$TMP_DIR/worker.sh"

worker_pids=""
for i in $(seq 1 12); do
  bash "$TMP_DIR/worker.sh" "$lock" "$counter" "$i" &
  worker_pids="$worker_pids $!"
done
for pid in $worker_pids; do
  if ! wait "$pid"; then
    printf 'a lock worker failed (status %s)\n' "$?" >&2
    exit 1
  fi
done
final=$(cat "$counter")
if [[ "$final" != "12" ]]; then
  printf 'lost updates under contention: expected 12, got %s\n' "$final" >&2
  exit 1
fi

# dx_lock_with runs its command under the lock and always releases it.
dx_lock_with "$lock" runner 20 true || {
  printf 'dx_lock_with failed for a succeeding command\n' >&2
  exit 1
}
[[ ! -d "$lock" ]] || {
  printf 'dx_lock_with left the lock held after success\n' >&2
  exit 1
}
if dx_lock_with "$lock" runner 20 false; then
  printf 'dx_lock_with hid a failing command status\n' >&2
  exit 1
fi
[[ ! -d "$lock" ]] || {
  printf 'dx_lock_with left the lock held after failure\n' >&2
  exit 1
}

# A caller that cannot take the lock in time reports a distinct status rather
# than proceeding unlocked.
dx_lock_acquire "$lock" blocker
set +e
dx_lock_with "$lock" latecomer 2 true
timeout_status=$?
set -e
dx_lock_release "$lock" blocker
if [[ "$timeout_status" != "75" ]]; then
  printf 'expected lock timeout status 75, got %s\n' "$timeout_status" >&2
  exit 1
fi

printf 'lock tests passed\n'
