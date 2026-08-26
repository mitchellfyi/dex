#!/usr/bin/env bash
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-session-startup-claim.XXXXXX")"
TEST_CHILD_PIDS=""

cleanup() {
  local child_pid
  for child_pid in $TEST_CHILD_PIDS; do
    kill "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  done
  chmod -R u+w "$TMP_DIR" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

wait_for_file() {
  local target_file="$1" attempt=0
  while [[ ! -f "$target_file" && "$attempt" -lt 1000 ]]; do
    sleep 0.01
    attempt=$((attempt + 1))
  done
  if [[ ! -f "$target_file" ]]; then
    for output_file in "$TMP_DIR"/*.out; do
      [[ -f "$output_file" ]] || continue
      printf '%s\n' "--- ${output_file##*/}" >&2
      sed -n '1,160p' "$output_file" >&2
    done
  fi
  assert_file "$target_file"
}

path_identity() {
  python3 - "$1" <<'PY'
import os
import sys


metadata = os.lstat(sys.argv[1])
print(f"{metadata.st_dev}:{metadata.st_ino}")
PY
}

path_link_count() {
  python3 - "$1" <<'PY'
import os
import sys


print(os.lstat(sys.argv[1]).st_nlink)
PY
}

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RUN_ROOT="$TMP_DIR/runs"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$DX_RUN_ROOT"

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

SID="startup-claim-owner"
dx_session_claim_acquire "$SID" startup
CLAIM_DIR="$(dx_session_claim_lock_dir "$SID")"
assert_file "$CLAIM_DIR/owner"
assert_eq "$SID" "$DX_SESSION_CLAIM_SESSION" "claimed session"
assert_eq "$$" "$DX_SESSION_CLAIM_PID" "claim owner pid"

OWNER_RAW="$(cat "$CLAIM_DIR/owner")"
IFS=$'\t' read -r OWNER_EPOCH OWNER_PID OWNER_TOKEN OWNER_EXTRA <<EOF
$OWNER_RAW
EOF
[[ "$OWNER_EPOCH" =~ ^[0-9]+$ ]] || assert_at $LINENO
assert_eq "$$" "$OWNER_PID" "published owner pid"
assert_eq "$DX_SESSION_CLAIM_TOKEN" "$OWNER_TOKEN" "published owner token"
assert_eq "" "${OWNER_EXTRA:-}" "owner field count"

# A competing startup must neither enter the critical section nor remove the
# live owner's claim.
COMPETE_RC=0
DEX_SESSION_CLAIM_ATTEMPTS=2 bash -c '
  source "$DEX_DIR/lib/common.sh"
  dx_session_claim_acquire "$1" startup
' _ "$SID" >/dev/null 2>&1 || COMPETE_RC=$?
[[ "$COMPETE_RC" -ne 0 ]] || assert_at $LINENO
assert_file "$CLAIM_DIR/owner"
assert_eq "$OWNER_RAW" "$(cat "$CLAIM_DIR/owner")" "foreign owner preserved"

# Release validates the exact local PID/token pair and fails closed without
# deleting another generation.
SAVED_TOKEN="$DX_SESSION_CLAIM_TOKEN"
DX_SESSION_CLAIM_TOKEN="wrong-token"
assert_rejected "wrong token release" dx_session_claim_release_checked "$SID"
assert_file "$CLAIM_DIR/owner"
DX_SESSION_CLAIM_TOKEN="$SAVED_TOKEN"
dx_session_claim_release_checked "$SID"
assert_no_file "$CLAIM_DIR/owner"
[[ ! -e "$CLAIM_DIR" && ! -L "$CLAIM_DIR" ]] || assert_at $LINENO

# The shared root is also a no-follow, current-user 0700 boundary.
CLAIM_ROOT="$(dx_session_claim_root)"
rmdir "$CLAIM_ROOT"
ROOT_VICTIM="$TMP_DIR/root-symlink-victim"
mkdir -m 700 "$ROOT_VICTIM"
printf 'root victim\n' > "$ROOT_VICTIM/sentinel"
ln -s "$ROOT_VICTIM" "$CLAIM_ROOT"
ROOT_SYMLINK_RESULT=0
DEX_SESSION_CLAIM_ATTEMPTS=1 \
  dx_session_claim_acquire root-symlink cleanup \
  > "$TMP_DIR/root-symlink.out" 2>&1 || ROOT_SYMLINK_RESULT=$?
assert_eq "2" "$ROOT_SYMLINK_RESULT" "symlink claim root result"
assert_eq "root victim" "$(cat "$ROOT_VICTIM/sentinel")" \
  "symlink claim root victim preserved"
[[ -L "$CLAIM_ROOT" ]] || assert_at $LINENO
rm -f "$CLAIM_ROOT"

printf 'root file sentinel\n' > "$CLAIM_ROOT"
ROOT_FILE_RESULT=0
DEX_SESSION_CLAIM_ATTEMPTS=1 \
  dx_session_claim_acquire root-file cleanup \
  > "$TMP_DIR/root-file.out" 2>&1 || ROOT_FILE_RESULT=$?
assert_eq "2" "$ROOT_FILE_RESULT" "regular claim root result"
assert_eq "root file sentinel" "$(cat "$CLAIM_ROOT")" \
  "regular claim root preserved"
rm -f "$CLAIM_ROOT"

mkdir -m 755 "$CLAIM_ROOT"
ROOT_MODE_RESULT=0
DEX_SESSION_CLAIM_ATTEMPTS=1 \
  dx_session_claim_acquire root-mode cleanup \
  > "$TMP_DIR/root-mode.out" 2>&1 || ROOT_MODE_RESULT=$?
assert_eq "2" "$ROOT_MODE_RESULT" "public claim root result"
assert_eq "755" "$(dx_path_mode "$CLAIM_ROOT")" \
  "public claim root mode preserved"
chmod 700 "$CLAIM_ROOT"

# Unsafe claim leaves fail closed before stale recovery and remain untouched.
DEAD_OWNER_PID="99999999"

SYMLINK_SID="startup-claim-symlink"
SYMLINK_CLAIM_DIR="$(dx_session_claim_lock_dir "$SYMLINK_SID")"
SYMLINK_VICTIM="$TMP_DIR/symlink-victim"
mkdir -m 700 "$SYMLINK_VICTIM"
printf '1\t%s\tvictim-token\n' "$DEAD_OWNER_PID" \
  > "$SYMLINK_VICTIM/owner"
chmod 600 "$SYMLINK_VICTIM/owner"
SYMLINK_OWNER_RAW="$(cat "$SYMLINK_VICTIM/owner")"
ln -s "$SYMLINK_VICTIM" "$SYMLINK_CLAIM_DIR"
SYMLINK_RESULT=0
DEX_SESSION_CLAIM_ATTEMPTS=1 \
  dx_session_claim_acquire "$SYMLINK_SID" cleanup \
  >/dev/null 2>&1 || SYMLINK_RESULT=$?
assert_eq "2" "$SYMLINK_RESULT" "symlink claim result"
assert_eq "$SYMLINK_OWNER_RAW" "$(cat "$SYMLINK_VICTIM/owner")" \
  "symlink victim owner preserved"
[[ -L "$SYMLINK_CLAIM_DIR" ]] || assert_at $LINENO
rm -f "$SYMLINK_CLAIM_DIR"

REGULAR_SID="startup-claim-regular-leaf"
REGULAR_CLAIM_DIR="$(dx_session_claim_lock_dir "$REGULAR_SID")"
printf 'claim leaf sentinel\n' > "$REGULAR_CLAIM_DIR"
REGULAR_RESULT=0
DEX_SESSION_CLAIM_ATTEMPTS=1 \
  dx_session_claim_acquire "$REGULAR_SID" cleanup \
  >/dev/null 2>&1 || REGULAR_RESULT=$?
assert_eq "2" "$REGULAR_RESULT" "regular claim leaf result"
assert_eq "claim leaf sentinel" "$(cat "$REGULAR_CLAIM_DIR")" \
  "regular claim leaf preserved"
rm -f "$REGULAR_CLAIM_DIR"

MALFORMED_SID="startup-claim-malformed-directory"
MALFORMED_CLAIM_DIR="$(dx_session_claim_lock_dir "$MALFORMED_SID")"
mkdir -m 700 "$MALFORMED_CLAIM_DIR"
printf 'malformed owner\n' > "$MALFORMED_CLAIM_DIR/owner"
chmod 600 "$MALFORMED_CLAIM_DIR/owner"
MALFORMED_RESULT=0
DEX_SESSION_CLAIM_ATTEMPTS=1 \
  dx_session_claim_acquire "$MALFORMED_SID" cleanup \
  >/dev/null 2>&1 || MALFORMED_RESULT=$?
assert_eq "2" "$MALFORMED_RESULT" "malformed claim directory result"
assert_eq "malformed owner" "$(cat "$MALFORMED_CLAIM_DIR/owner")" \
  "malformed claim owner preserved"
rm -f "$MALFORMED_CLAIM_DIR/owner"
rmdir "$MALFORMED_CLAIM_DIR"

HARDLINK_SID="startup-claim-hardlink-owner"
HARDLINK_CLAIM_DIR="$(dx_session_claim_lock_dir "$HARDLINK_SID")"
HARDLINK_VICTIM="$TMP_DIR/hardlink-victim-owner"
mkdir -m 700 "$HARDLINK_CLAIM_DIR"
printf '1\t%s\tvictim-token\n' "$DEAD_OWNER_PID" > "$HARDLINK_VICTIM"
chmod 600 "$HARDLINK_VICTIM"
ln "$HARDLINK_VICTIM" "$HARDLINK_CLAIM_DIR/owner"
HARDLINK_RESULT=0
DEX_SESSION_CLAIM_ATTEMPTS=1 \
  dx_session_claim_acquire "$HARDLINK_SID" cleanup \
  >/dev/null 2>&1 || HARDLINK_RESULT=$?
assert_eq "2" "$HARDLINK_RESULT" "hardlinked claim owner result"
assert_eq "2" "$(path_link_count "$HARDLINK_VICTIM")" \
  "hardlink fixture remains linked through claim owner"
assert_file "$HARDLINK_CLAIM_DIR/owner"
rm -f "$HARDLINK_CLAIM_DIR/owner" "$HARDLINK_VICTIM"
rmdir "$HARDLINK_CLAIM_DIR"

OWNER_SYMLINK_SID="startup-claim-owner-symlink"
OWNER_SYMLINK_CLAIM_DIR="$(dx_session_claim_lock_dir "$OWNER_SYMLINK_SID")"
OWNER_SYMLINK_VICTIM="$TMP_DIR/owner-symlink-victim"
mkdir -m 700 "$OWNER_SYMLINK_CLAIM_DIR"
printf '1\t%s\tvictim-token\n' "$DEAD_OWNER_PID" \
  > "$OWNER_SYMLINK_VICTIM"
chmod 600 "$OWNER_SYMLINK_VICTIM"
OWNER_SYMLINK_RAW="$(cat "$OWNER_SYMLINK_VICTIM")"
ln -s "$OWNER_SYMLINK_VICTIM" "$OWNER_SYMLINK_CLAIM_DIR/owner"
OWNER_SYMLINK_RESULT=0
DEX_SESSION_CLAIM_ATTEMPTS=1 \
  dx_session_claim_acquire "$OWNER_SYMLINK_SID" cleanup \
  > "$TMP_DIR/owner-symlink.out" 2>&1 || OWNER_SYMLINK_RESULT=$?
assert_eq "2" "$OWNER_SYMLINK_RESULT" "symlink claim owner result"
assert_eq "$OWNER_SYMLINK_RAW" "$(cat "$OWNER_SYMLINK_VICTIM")" \
  "symlink claim owner victim preserved"
[[ -L "$OWNER_SYMLINK_CLAIM_DIR/owner" ]] || assert_at $LINENO
rm -f "$OWNER_SYMLINK_CLAIM_DIR/owner" "$OWNER_SYMLINK_VICTIM"
rmdir "$OWNER_SYMLINK_CLAIM_DIR"

PUBLIC_LEAF_SID="startup-claim-public-leaf"
PUBLIC_LEAF_DIR="$(dx_session_claim_lock_dir "$PUBLIC_LEAF_SID")"
mkdir -m 755 "$PUBLIC_LEAF_DIR"
printf '1\t%s\tvictim-token\n' "$DEAD_OWNER_PID" \
  > "$PUBLIC_LEAF_DIR/owner"
chmod 600 "$PUBLIC_LEAF_DIR/owner"
PUBLIC_LEAF_RAW="$(cat "$PUBLIC_LEAF_DIR/owner")"
PUBLIC_LEAF_RESULT=0
DEX_SESSION_CLAIM_ATTEMPTS=1 \
  dx_session_claim_acquire "$PUBLIC_LEAF_SID" cleanup \
  > "$TMP_DIR/public-leaf.out" 2>&1 || PUBLIC_LEAF_RESULT=$?
assert_eq "2" "$PUBLIC_LEAF_RESULT" "public claim leaf result"
assert_eq "$PUBLIC_LEAF_RAW" "$(cat "$PUBLIC_LEAF_DIR/owner")" \
  "public claim leaf owner preserved"
assert_eq "755" "$(dx_path_mode "$PUBLIC_LEAF_DIR")" \
  "public claim leaf mode preserved"
rm -f "$PUBLIC_LEAF_DIR/owner"
rmdir "$PUBLIC_LEAF_DIR"

FOREIGN_SID="startup-claim-foreign-live"
FOREIGN_CLAIM_DIR="$(dx_session_claim_lock_dir "$FOREIGN_SID")"
mkdir -m 700 "$FOREIGN_CLAIM_DIR"
printf '%s\t%s\tforeign-live-token\n' "$(date +%s)" "$$" \
  > "$FOREIGN_CLAIM_DIR/owner"
chmod 600 "$FOREIGN_CLAIM_DIR/owner"
FOREIGN_OWNER_RAW="$(cat "$FOREIGN_CLAIM_DIR/owner")"
FOREIGN_RESULT=0
DEX_SESSION_CLAIM_ATTEMPTS=1 \
  dx_session_claim_acquire "$FOREIGN_SID" cleanup \
  >/dev/null 2>&1 || FOREIGN_RESULT=$?
assert_eq "75" "$FOREIGN_RESULT" "foreign live claim result"
assert_eq "$FOREIGN_OWNER_RAW" "$(cat "$FOREIGN_CLAIM_DIR/owner")" \
  "foreign live owner preserved"
rm -f "$FOREIGN_CLAIM_DIR/owner"
rmdir "$FOREIGN_CLAIM_DIR"

# A dead owner is reclaimed through the shared stale-owner protocol.
STALE_SID="startup-claim-stale"
bash -c '
  source "$DEX_DIR/lib/common.sh"
  dx_session_claim_acquire "$1" startup
' _ "$STALE_SID"
dx_session_claim_acquire "$STALE_SID" cleanup
assert_eq "$STALE_SID" "$DX_SESSION_CLAIM_SESSION" "reclaimed session"
assert_eq "$$" "$DX_SESSION_CLAIM_PID" "reclaimed owner pid"
dx_session_claim_release_checked "$STALE_SID"

# The shell checkpoints make directory-entry replacement deterministic. The
# inode binding must reject both swaps without deleting either directory.
CLAIM_CHECKPOINT_DEFINITION="$(declare -f __dx_session_claim_checkpoint)"

ACQUIRE_SWAP_SID="startup-claim-acquire-swap"
ACQUIRE_SWAP_DIR="$(dx_session_claim_lock_dir "$ACQUIRE_SWAP_SID")"
ACQUIRE_SWAP_MOVED="$TMP_DIR/acquire-swap-original"
ACQUIRE_SWAP_VICTIM_RAW="$(printf '%s\t%s\t%s' \
  "$(date +%s)" "$$" "acquire-swap-victim")"
export ACQUIRE_SWAP_SID ACQUIRE_SWAP_DIR ACQUIRE_SWAP_MOVED
export ACQUIRE_SWAP_VICTIM_RAW
__dx_session_claim_checkpoint() {
  if [[ "$1" == startup && "$2" == acquired \
    && "$3" == "$ACQUIRE_SWAP_SID" ]]; then
    mv "$ACQUIRE_SWAP_DIR" "$ACQUIRE_SWAP_MOVED"
    mkdir -m 700 "$ACQUIRE_SWAP_DIR"
    printf '%s\n' "$ACQUIRE_SWAP_VICTIM_RAW" \
      > "$ACQUIRE_SWAP_DIR/owner"
    chmod 600 "$ACQUIRE_SWAP_DIR/owner"
  fi
}
ACQUIRE_SWAP_RESULT=0
dx_session_claim_acquire "$ACQUIRE_SWAP_SID" startup \
  > "$TMP_DIR/acquire-swap.out" 2>&1 || ACQUIRE_SWAP_RESULT=$?
assert_eq "2" "$ACQUIRE_SWAP_RESULT" "acquire pathname replacement result"
assert_eq "$ACQUIRE_SWAP_VICTIM_RAW" "$(cat "$ACQUIRE_SWAP_DIR/owner")" \
  "acquire pathname replacement victim preserved"
assert_file "$ACQUIRE_SWAP_MOVED/owner"
assert_eq "" "$(cat "$TMP_DIR/acquire-swap.out")" \
  "acquire does not print its token"
assert_eq "" "${DX_SESSION_CLAIM_TOKEN:-}" \
  "failed acquire clears the local token"
rm -f "$ACQUIRE_SWAP_DIR/owner" "$ACQUIRE_SWAP_MOVED/owner"
rmdir "$ACQUIRE_SWAP_DIR" "$ACQUIRE_SWAP_MOVED"
eval "$CLAIM_CHECKPOINT_DEFINITION"

RELEASE_SWAP_SID="startup-claim-release-swap"
RELEASE_SWAP_DIR="$(dx_session_claim_lock_dir "$RELEASE_SWAP_SID")"
RELEASE_SWAP_MOVED="$TMP_DIR/release-swap-original"
RELEASE_SWAP_VICTIM_RAW="$(printf '%s\t%s\t%s' \
  "$(date +%s)" "$$" "release-swap-victim")"
dx_session_claim_acquire "$RELEASE_SWAP_SID" cleanup
RELEASE_SWAP_OWNER_RAW="$(cat "$RELEASE_SWAP_DIR/owner")"
export RELEASE_SWAP_SID RELEASE_SWAP_DIR RELEASE_SWAP_MOVED
export RELEASE_SWAP_VICTIM_RAW
__dx_session_claim_checkpoint() {
  if [[ "$1" == cleanup && "$2" == releasing \
    && "$3" == "$RELEASE_SWAP_SID" ]]; then
    mv "$RELEASE_SWAP_DIR" "$RELEASE_SWAP_MOVED"
    mkdir -m 700 "$RELEASE_SWAP_DIR"
    printf '%s\n' "$RELEASE_SWAP_VICTIM_RAW" \
      > "$RELEASE_SWAP_DIR/owner"
    chmod 600 "$RELEASE_SWAP_DIR/owner"
  fi
}
RELEASE_SWAP_RESULT=0
dx_session_claim_release_checked "$RELEASE_SWAP_SID" \
  > "$TMP_DIR/release-swap.out" 2>&1 || RELEASE_SWAP_RESULT=$?
assert_eq "2" "$RELEASE_SWAP_RESULT" "release pathname replacement result"
assert_eq "$RELEASE_SWAP_VICTIM_RAW" "$(cat "$RELEASE_SWAP_DIR/owner")" \
  "release pathname replacement victim preserved"
assert_eq "$RELEASE_SWAP_OWNER_RAW" "$(cat "$RELEASE_SWAP_MOVED/owner")" \
  "release pathname replacement owner preserved"
assert_eq "" "$(cat "$TMP_DIR/release-swap.out")" \
  "release does not print its token"
assert_eq "" "${DX_SESSION_CLAIM_TOKEN:-}" \
  "failed release clears the local token"
rm -f "$RELEASE_SWAP_DIR/owner" "$RELEASE_SWAP_MOVED/owner"
rmdir "$RELEASE_SWAP_DIR" "$RELEASE_SWAP_MOVED"
eval "$CLAIM_CHECKPOINT_DEFINITION"

# A finish failure after the owner name is detached restores the same inode.
# The first checked release reports the failure and leaves a retryable claim;
# a later checked release can then remove it cleanly.
RELEASE_FAULT_SID="startup-claim-release-fault"
RELEASE_FAULT_DIR="$(dx_session_claim_lock_dir "$RELEASE_FAULT_SID")"
RELEASE_FAULT_MARKER="$TMP_DIR/release-finish-failed"
export RELEASE_FAULT_SID RELEASE_FAULT_DIR RELEASE_FAULT_MARKER
dx_session_claim_acquire "$RELEASE_FAULT_SID" cleanup
RELEASE_FAULT_RAW="$(cat "$RELEASE_FAULT_DIR/owner")"
RELEASE_FAULT_INODE="$(path_identity "$RELEASE_FAULT_DIR/owner")"
CLAIM_FILESYSTEM_DEFINITION="$(declare -f __dx_session_claim_filesystem)"
eval "$(declare -f __dx_session_claim_filesystem | \
  sed '1s/^__dx_session_claim_filesystem /__test_claim_filesystem_original /')"
__dx_session_claim_filesystem() {
  if [[ "$1" == release-finish && "$2" == "$RELEASE_FAULT_SID" \
    && ! -e "$RELEASE_FAULT_MARKER" ]]; then
    [[ ! -e "$RELEASE_FAULT_DIR/owner" \
      && -f "$RELEASE_FAULT_DIR/.owner-releasing" ]] || return 90
    touch "$RELEASE_FAULT_MARKER"
    return 1
  fi
  __test_claim_filesystem_original "$@"
}
RELEASE_FAULT_RESULT=0
dx_session_claim_release_checked "$RELEASE_FAULT_SID" \
  > "$TMP_DIR/release-fault.out" 2>&1 || RELEASE_FAULT_RESULT=$?
assert_eq "1" "$RELEASE_FAULT_RESULT" "owner-unlinked release failure"
assert_file "$RELEASE_FAULT_MARKER"
assert_eq "$RELEASE_FAULT_RAW" "$(cat "$RELEASE_FAULT_DIR/owner")" \
  "release failure restores exact owner payload"
assert_eq "$RELEASE_FAULT_INODE" \
  "$(path_identity "$RELEASE_FAULT_DIR/owner")" \
  "release failure restores exact owner inode"
assert_eq "600" "$(dx_path_mode "$RELEASE_FAULT_DIR/owner")" \
  "release failure restores private owner mode"
assert_eq "1" "$(path_link_count "$RELEASE_FAULT_DIR/owner")" \
  "release failure restores single-link owner"
assert_eq "$RELEASE_FAULT_SID" "$DX_SESSION_CLAIM_SESSION" \
  "release failure retains local session binding"
dx_session_claim_owned "$RELEASE_FAULT_SID"
assert_no_file "$RELEASE_FAULT_DIR/.owner-releasing"
dx_session_claim_release_checked "$RELEASE_FAULT_SID"
[[ ! -e "$RELEASE_FAULT_DIR" && ! -L "$RELEASE_FAULT_DIR" ]] \
  || assert_at $LINENO
assert_eq "" "${DX_SESSION_CLAIM_TOKEN:-}" \
  "successful checked retry clears the local token"
eval "$CLAIM_FILESYSTEM_DEFINITION"

# Once the canonical leaf is gone, a staging-unlink error is a semantic
# release success. The self-bound staging inode is retired before the next
# acquire; a replacement at the same pathname is rejected and preserved.
RETIRE_EIO_SID="startup-claim-retire-eio"
RETIRE_EIO_DIR="$(dx_session_claim_lock_dir "$RETIRE_EIO_SID")"
RETIRE_EIO_MARKER="$TMP_DIR/retire-eio-stage"
export RETIRE_EIO_SID RETIRE_EIO_DIR RETIRE_EIO_MARKER
dx_session_claim_acquire "$RETIRE_EIO_SID" cleanup
CLAIM_FILESYSTEM_DEFINITION="$(declare -f __dx_session_claim_filesystem)"
eval "$(declare -f __dx_session_claim_filesystem | \
  sed '1s/^__dx_session_claim_filesystem /__test_claim_filesystem_original /')"
__dx_session_claim_filesystem() {
  if [[ "$1" == release-retire && "$2" == "$RETIRE_EIO_SID" \
    && ! -e "$RETIRE_EIO_MARKER" ]]; then
    [[ ! -e "$RETIRE_EIO_DIR" && "$4" == .claim-release-* \
      && -f "$(dx_session_claim_root)/$4" ]] || return 90
    printf '%s\n' "$4" > "$RETIRE_EIO_MARKER"
    return 1
  fi
  __test_claim_filesystem_original "$@"
}
dx_session_claim_release_checked "$RETIRE_EIO_SID"
assert_file "$RETIRE_EIO_MARKER"
RETIRE_EIO_STAGE="$(cat "$RETIRE_EIO_MARKER")"
RETIRE_EIO_STAGE_FILE="$(dx_session_claim_root)/$RETIRE_EIO_STAGE"
assert_file "$RETIRE_EIO_STAGE_FILE"
[[ ! -e "$RETIRE_EIO_DIR" && ! -L "$RETIRE_EIO_DIR" ]] \
  || assert_at $LINENO
assert_eq "" "${DX_SESSION_CLAIM_TOKEN:-}" \
  "semantic release clears the local token"
assert_eq "600" "$(dx_path_mode "$RETIRE_EIO_STAGE_FILE")" \
  "recoverable staging owner remains private"
assert_eq "1" "$(path_link_count "$RETIRE_EIO_STAGE_FILE")" \
  "recoverable staging owner remains single-link"

RETIRE_EIO_SAVED="$TMP_DIR/retire-eio-exact"
mv "$RETIRE_EIO_STAGE_FILE" "$RETIRE_EIO_SAVED"
printf 'foreign staging sentinel\n' > "$RETIRE_EIO_STAGE_FILE"
chmod 600 "$RETIRE_EIO_STAGE_FILE"
RETIRE_FOREIGN_RESULT=0
DEX_SESSION_CLAIM_ATTEMPTS=1 \
  dx_session_claim_acquire "$RETIRE_EIO_SID" cleanup \
  > "$TMP_DIR/retire-foreign.out" 2>&1 || RETIRE_FOREIGN_RESULT=$?
assert_eq "2" "$RETIRE_FOREIGN_RESULT" \
  "replacement release staging result"
assert_eq "foreign staging sentinel" "$(cat "$RETIRE_EIO_STAGE_FILE")" \
  "replacement release staging preserved"
rm -f "$RETIRE_EIO_STAGE_FILE"
mv "$RETIRE_EIO_SAVED" "$RETIRE_EIO_STAGE_FILE"

dx_session_claim_acquire "$RETIRE_EIO_SID" cleanup
assert_no_file "$RETIRE_EIO_STAGE_FILE"
dx_session_claim_release_checked "$RETIRE_EIO_SID"
assert_no_file "$RETIRE_EIO_STAGE_FILE"
[[ ! -e "$RETIRE_EIO_DIR" && ! -L "$RETIRE_EIO_DIR" ]] \
  || assert_at $LINENO
eval "$CLAIM_FILESYSTEM_DEFINITION"

REPO="$TMP_DIR/repo"
mkdir -p "$REPO/.dex/worktrees"
git -C "$REPO" init -q
git -C "$REPO" config user.email dex@example.test
git -C "$REPO" config user.name "Dex Test"
printf 'base\n' > "$REPO/file.txt"
git -C "$REPO" add file.txt
git -C "$REPO" commit -q -m "test: initialize repo"
git -C "$REPO" branch -m main

# Worktree setup takes the claim before its first metadata write and leaves it
# held for the runtime publication boundary.
WORKTREE_NAME="task-worktree-claim"
WORKTREE_DIR="$REPO/.dex/worktrees/$WORKTREE_NAME"
git -C "$REPO" worktree add -q "$WORKTREE_DIR" \
  -b "worktree-${WORKTREE_NAME}" main
TEST_WORKTREE_SID="$(cd "$REPO" && dx_session_id "$WORKTREE_NAME")"
TEST_REPO="$REPO" TEST_WORKTREE_SID="$TEST_WORKTREE_SID" zsh -fc '
  source "$DEX_DIR/dx.sh"
  set -e
  cd "$TEST_REPO"
  [[ ! -e "$(dx_meta_file "$TEST_WORKTREE_SID")" ]] || return 89
  __dx_session_claim_checkpoint() {
    if [[ "$1" == startup && "$2" == acquired ]]; then
      [[ ! -e "$(dx_meta_file "$3")" ]] || return 90
    fi
  }
  __dx_setup_worktree worktree-claim
  dx_session_claim_owned "$TEST_WORKTREE_SID"
  [[ -e "$(dx_meta_file "$TEST_WORKTREE_SID")" ]] || return 91
  __dx_startup_claim_release
'
assert_no_file "$(dx_session_claim_lock_dir "$TEST_WORKTREE_SID")/owner"
# --git-path may be relative to REPO, not the shell's current directory. The
# latter can itself be a linked worktree where `.git` is a pointer file.
printf '.dex/\n' >> "$(git -C "$REPO" rev-parse --absolute-git-dir)/info/exclude"

# If cleanup owns the claim first, a launcher that observed that generation
# must abort after cleanup commits instead of recreating the deleted SID.
RACE_NAME="task-cleanup-wins"
RACE_BRANCH="worktree-${RACE_NAME}"
RACE_SID="$(cd "$REPO" && dx_scoped_session_id "inplace-${RACE_NAME}")"
git -C "$REPO" branch "$RACE_BRANCH" main
git -C "$REPO" switch -q "$RACE_BRANCH"
dx_record_session_branch "$RACE_SID" "$REPO"
git -C "$REPO" switch -q main
dx_meta_write "$RACE_SID" \
  "wt_name=${RACE_NAME}" \
  "wt_dir=${REPO}" \
  "workspace_mode=in-place" \
  "raw_input=cleanup-wins"
printf '3\n' > "$(dx_state_file "$RACE_SID")"
RACE_TOKEN="$(dx_session_runtime_start "$RACE_SID" codex "$REPO" "$$")"
dx_session_runtime_finish "$RACE_SID" "$RACE_TOKEN" paused "$$"

CLEANUP_ACQUIRED="$TMP_DIR/cleanup-acquired"
CLEANUP_CONTINUE="$TMP_DIR/cleanup-continue"
CLEANUP_COMMITTED="$TMP_DIR/cleanup-committed"
LAUNCH_CONTENDED="$TMP_DIR/launch-contended"
export TEST_REPO="$REPO" TEST_RACE_SID="$RACE_SID"
export CLEANUP_ACQUIRED CLEANUP_CONTINUE CLEANUP_COMMITTED LAUNCH_CONTENDED
bash -c '
  set -euo pipefail
  source "$DEX_DIR/lib/common.sh"
  source "$DEX_DIR/lib/session-management.sh"
  __dx_session_claim_checkpoint() {
    if [[ "$1" == cleanup && "$2" == acquired && "$3" == "$TEST_RACE_SID" ]]; then
      touch "$CLEANUP_ACQUIRED"
      while [[ ! -f "$CLEANUP_CONTINUE" ]]; do sleep 0.01; done
    elif [[ "$1" == cleanup && "$2" == released && "$3" == "$TEST_RACE_SID" ]]; then
      [[ ! -e "$(dx_session_cleanup_journal_file "$TEST_RACE_SID")" \
        && ! -L "$(dx_session_cleanup_journal_file "$TEST_RACE_SID")" ]] \
        || return 91
      touch "$CLEANUP_COMMITTED"
    fi
  }
  __dx_session_management_cleanup_exact "$TEST_REPO" "$TEST_RACE_SID"
' > "$TMP_DIR/cleanup-wins.cleanup.out" 2>&1 &
CLEANUP_PID=$!
TEST_CHILD_PIDS="$TEST_CHILD_PIDS $CLEANUP_PID"
wait_for_file "$CLEANUP_ACQUIRED"

zsh -fc '
  source "$DEX_DIR/dx.sh"
  cd "$TEST_REPO"
  __dx_session_claim_checkpoint() {
    if [[ "$1" == startup && "$2" == contended && "$3" == "$TEST_RACE_SID" ]]; then
      touch "$LAUNCH_CONTENDED"
    fi
  }
  __dx_setup_in_place cleanup-wins
' > "$TMP_DIR/cleanup-wins.launch.out" 2>&1 &
LAUNCH_PID=$!
TEST_CHILD_PIDS="$TEST_CHILD_PIDS $LAUNCH_PID"
wait_for_file "$LAUNCH_CONTENDED"
touch "$CLEANUP_CONTINUE"

set +e
wait "$CLEANUP_PID"
CLEANUP_RESULT=$?
wait "$LAUNCH_PID"
LAUNCH_RESULT=$?
set -e
TEST_CHILD_PIDS=""
assert_eq "0" "$CLEANUP_RESULT" "cleanup winner result"
assert_file "$CLEANUP_COMMITTED"
[[ "$LAUNCH_RESULT" -ne 0 ]] || assert_at $LINENO
assert_contains "Run the command again to use fresh state" \
  "$TMP_DIR/cleanup-wins.launch.out"
assert_no_file "$(dx_meta_file "$RACE_SID")"
assert_no_file "$(dx_state_file "$RACE_SID")"
assert_no_file "$(dx_session_runtime_file "$RACE_SID")"
assert_no_file "$(dx_session_cleanup_journal_file "$RACE_SID")"
assert_no_file "$(dx_session_claim_lock_dir "$RACE_SID")/owner"

# If startup owns the claim first, cleanup cannot inspect half-written setup
# state. Runtime publication wins the claim handoff and cleanup rejects the
# resulting live lease.
START_REPO="$TMP_DIR/start-repo"
git -C "$TMP_DIR" init -q start-repo
git -C "$START_REPO" config user.email dex@example.test
git -C "$START_REPO" config user.name "Dex Test"
printf 'base\n' > "$START_REPO/file.txt"
mkdir -p "$START_REPO/.dex"
printf '*\n!.gitignore\n' > "$START_REPO/.dex/.gitignore"
git -C "$START_REPO" add file.txt .dex/.gitignore
git -C "$START_REPO" commit -q -m "test: initialize startup race repo"
git -C "$START_REPO" branch -m main
START_NAME="task-startup-wins"
START_BRANCH="worktree-${START_NAME}"
START_SID="$(cd "$START_REPO" && dx_scoped_session_id "inplace-${START_NAME}")"
git -C "$START_REPO" branch "$START_BRANCH" main
START_ACQUIRED="$TMP_DIR/startup-acquired"
START_CONTINUE="$TMP_DIR/startup-continue"
RUNTIME_READY="$TMP_DIR/runtime-ready"
RUNTIME_FINISH="$TMP_DIR/runtime-finish"
export TEST_REPO="$START_REPO" TEST_START_SID="$START_SID"
export START_ACQUIRED START_CONTINUE
export RUNTIME_READY RUNTIME_FINISH
zsh -fc '
  source "$DEX_DIR/dx.sh"
  cd "$TEST_REPO"
  __dx_resolved_provider_agent() { print -r -- claude; }
  __dx_session_claim_checkpoint() {
    if [[ "$1" == startup && "$2" == acquired && "$3" == "$TEST_START_SID" ]]; then
      touch "$START_ACQUIRED"
      while [[ ! -f "$START_CONTINUE" ]]; do sleep 0.01; done
    fi
  }
  __test_startup_callback() {
    touch "$RUNTIME_READY"
    while [[ ! -f "$RUNTIME_FINISH" ]]; do sleep 0.01; done
    __dx_runtime_set_terminal paused
  }
  __dx_setup_in_place startup-wins || return 92
  __dx_run_with_runtime "$TEST_START_SID" "$TEST_REPO" \
    __test_startup_callback
' > "$TMP_DIR/startup-wins.launch.out" 2>&1 &
START_PID=$!
TEST_CHILD_PIDS="$TEST_CHILD_PIDS $START_PID"
wait_for_file "$START_ACQUIRED"

bash -c '
  set -euo pipefail
  source "$DEX_DIR/lib/common.sh"
  source "$DEX_DIR/lib/session-management.sh"
  __dx_session_management_cleanup_exact "$TEST_REPO" "$TEST_START_SID"
' > "$TMP_DIR/startup-wins.cleanup.out" 2>&1 &
START_CLEANUP_PID=$!
TEST_CHILD_PIDS="$TEST_CHILD_PIDS $START_CLEANUP_PID"
sleep 0.1
touch "$START_CONTINUE"
wait_for_file "$RUNTIME_READY"

set +e
wait "$START_CLEANUP_PID"
START_CLEANUP_RESULT=$?
set -e
[[ "$START_CLEANUP_RESULT" -ne 0 ]] || assert_at $LINENO
touch "$RUNTIME_FINISH"
wait "$START_PID"
TEST_CHILD_PIDS=""
assert_file "$(dx_meta_file "$START_SID")"
assert_eq "paused" "$(dx_session_runtime_field "$START_SID" status)" \
  "startup winner runtime status"
assert_no_file "$(dx_session_cleanup_journal_file "$START_SID")"
assert_no_file "$(dx_session_claim_lock_dir "$START_SID")/owner"

# Even when the underlying checked release removes the exact claim on its
# retry, a reported release failure cannot be turned into cleanup success.
RELEASE_NAME="task-release-failure"
RELEASE_BRANCH="worktree-${RELEASE_NAME}"
RELEASE_SID="$(cd "$REPO" && dx_scoped_session_id "inplace-${RELEASE_NAME}")"
git -C "$REPO" branch "$RELEASE_BRANCH" main
git -C "$REPO" switch -q "$RELEASE_BRANCH"
dx_record_session_branch "$RELEASE_SID" "$REPO"
git -C "$REPO" switch -q main
dx_meta_write "$RELEASE_SID" \
  "wt_name=${RELEASE_NAME}" \
  "wt_dir=${REPO}" \
  "workspace_mode=in-place" \
  "raw_input=release-failure"
printf '3\n' > "$(dx_state_file "$RELEASE_SID")"
RELEASE_TOKEN="$(dx_session_runtime_start \
  "$RELEASE_SID" codex "$REPO" "$$")"
dx_session_runtime_finish "$RELEASE_SID" "$RELEASE_TOKEN" paused "$$"
export TEST_REPO="$REPO" TEST_RELEASE_SID="$RELEASE_SID"
RELEASE_RESULT=0
bash -c '
  set -euo pipefail
  source "$DEX_DIR/lib/common.sh"
  source "$DEX_DIR/lib/session-management.sh"
  eval "$(declare -f __dx_session_claim_release_once | \
    sed "1s/^__dx_session_claim_release_once /__test_claim_release_original /")"
  __dx_session_claim_release_once() {
    __test_claim_release_original "$@" || return $?
    return 1
  }
  __dx_session_management_cleanup_exact "$TEST_REPO" "$TEST_RELEASE_SID"
' > "$TMP_DIR/release-failure.out" 2>&1 || RELEASE_RESULT=$?
[[ "$RELEASE_RESULT" -ne 0 ]] || assert_at $LINENO
assert_no_file "$(dx_meta_file "$RELEASE_SID")"
assert_no_file "$(dx_session_cleanup_journal_file "$RELEASE_SID")"
assert_no_file "$(dx_session_claim_lock_dir "$RELEASE_SID")/owner"

printf 'session startup claim tests passed\n'
