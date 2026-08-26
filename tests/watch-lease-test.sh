#!/usr/bin/env bash
set -euo pipefail

# dx_watch_lock_acquire keeps one /dxwatchpr cycle per session from overlapping
# the next. It is a lease rather than a lock: DEX_WATCH_CYCLE_TIMEOUT_SECONDS is
# a cycle's runtime budget, and a cycle that outruns it hands over. These are
# the four states that decides, and they had no coverage.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-watch-lease-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export DEX_DIR="$ROOT"
export HOME="$TMP_DIR/home"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

SESSION="repo-watch-lease-main"
WATCH="pr"
export DEX_WATCH_CYCLE_TIMEOUT_SECONDS=120
LOCK="$(dx_watch_lock_file "$SESSION" "$WATCH")"
mkdir -p "$(dirname "$LOCK")"

write_lease() {
  printf '%s\t%s\n' "$1" "$2" > "$LOCK"
}

acquires() {
  local label="$1"
  if ! dx_watch_lock_acquire "$SESSION" "$WATCH"; then
    printf 'the watcher was refused a lease it should have taken: %s\n' "$label" >&2
    exit 1
  fi
}

refuses() {
  local label="$1"
  if dx_watch_lock_acquire "$SESSION" "$WATCH"; then
    printf 'the watcher took a lease it should have left alone: %s\n' "$label" >&2
    exit 1
  fi
}

# No lease at all.
rm -f "$LOCK"
acquires "a free lease"
[[ -s "$LOCK" ]] || {
  printf 'acquiring wrote no lease\n' >&2
  exit 1
}
assert_eq "$$" "$(cut -f2 "$LOCK")" "the lease records its owner"

# A watcher that is alive and inside its budget keeps it. $$ is this process,
# which is certainly alive.
write_lease "$(date +%s)" "$$"
refuses "a live watcher inside its runtime budget"

# A watcher that crashed. The pid has been recorded in every lease from the
# start and nothing read it, so this used to wait out the whole budget — two
# minutes during which nothing was watching the PR.
dead_pid=$(bash -c 'echo $$')
while kill -0 "$dead_pid" 2>/dev/null; do
  dead_pid=$((dead_pid + 1))
  [[ "$dead_pid" -lt 4194304 ]] || break
done
write_lease "$(date +%s)" "$dead_pid"
acquires "a lease whose owner is gone"

# Past the budget the next tick takes over even from a live owner. That is the
# documented contract — the budget is the cycle's, and a cycle that outruns it
# has broken it — so it is pinned here rather than left to be changed by
# accident.
write_lease "$(( $(date +%s) - 300 ))" "$$"
acquires "a live watcher that outran its runtime budget"

# An unreadable lease is not a reason to stop watching forever.
printf 'not-an-epoch\n' > "$LOCK"
acquires "a corrupt lease"

# A budget of zero disables the age rule; only liveness decides.
write_lease "$(( $(date +%s) - 300 ))" "$$"
DEX_WATCH_CYCLE_TIMEOUT_SECONDS=0 refuses "a live owner when the budget is disabled"

# Session policy wins over the environment and is read again for each cycle,
# so an agent can adjust a running lifecycle without relaunching its provider.
dx_override_set "$SESSION" watch.cycle-timeout 10 session - agent \
  "Take over a wedged watcher sooner" 0
write_lease "$(( $(date +%s) - 20 ))" "$$"
acquires "a live owner beyond the dynamic session override"
dx_override_set "$SESSION" watch.cycle-timeout 0 session - agent \
  "Keep the current watcher owner until it exits" 0
write_lease "$(( $(date +%s) - 300 ))" "$$"
refuses "a live owner under a dynamically disabled budget"

# Releasing lets the next cycle straight in.
write_lease "$(date +%s)" "$$"
dx_watch_lock_release "$SESSION" "$WATCH"
[[ ! -e "$LOCK" ]] || {
  printf 'releasing left the lease behind\n' >&2
  exit 1
}
acquires "a lease after release"

printf 'watch lease tests passed\n'
