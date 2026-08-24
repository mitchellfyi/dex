#!/usr/bin/env bash
# dex-test-lane: serial
# This suite checks bounded supervisor shutdown against wall-clock deadlines.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-session-runtime-owner.XXXXXX")"
TEST_CHILD_PIDS=""

cleanup() {
  local child_pid
  for child_pid in $TEST_CHILD_PIDS; do
    kill -CONT "$child_pid" 2>/dev/null || true
    kill "$child_pid" 2>/dev/null || true
    wait "$child_pid" 2>/dev/null || true
  done
  chmod -R u+w "$TMP_DIR" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

wait_for_value() { # <file> [attempts]
  local target_file="$1" max_attempts="${2:-200}" attempt=0
  while [[ ! -s "$target_file" && "$attempt" -lt "$max_attempts" ]]; do
    sleep 0.05
    attempt=$((attempt + 1))
  done
  assert_file "$target_file"
}

wait_for_runtime_field() { # <session> <field> <expected>
  local session_id="$1" field_name="$2" expected_value="$3" attempt=0
  while [[ "$attempt" -lt 200 ]]; do
    if [[ "$(dx_session_runtime_field "$session_id" "$field_name" 2>/dev/null || true)" == "$expected_value" ]]; then
      return 0
    fi
    sleep 0.05
    attempt=$((attempt + 1))
  done
  assert_eq "$expected_value" \
    "$(dx_session_runtime_field "$session_id" "$field_name" 2>/dev/null || true)" \
    "$session_id runtime $field_name"
}

runtime_private_token() {
  python3 - "$(dx_session_runtime_file "$1")" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["token"])
PY
}

runtime_owner_pid() {
  dx_session_runtime_field "$1" pid
}

assert_token_private() { # <session> <handle> <captured-output>
  local session_id="$1" owner_handle="$2" captured_output="$3"
  local private_token owner_pid owner_directory process_args="" process_env=""
  private_token=$(runtime_private_token "$session_id")
  owner_pid=$(runtime_owner_pid "$session_id")
  owner_directory=$(dx_session_runtime_owner_handle_path "$owner_handle")
  [[ "$private_token" =~ ^[0-9a-f]{64}$ ]] || assert_at $LINENO
  assert_not_contains "$private_token" <(printf '%s\n' "$captured_output")

  process_args=$(ps -o command= -p "$owner_pid" 2>/dev/null || true)
  assert_not_contains "$private_token" <(printf '%s\n' "$process_args")
  if [[ -r "/proc/${owner_pid}/environ" ]]; then
    process_env=$(tr '\0' '\n' < "/proc/${owner_pid}/environ")
    assert_not_contains "$private_token" <(printf '%s\n' "$process_env")
  fi

  if find "$owner_directory" -type f -maxdepth 1 -print0 2>/dev/null | \
      xargs -0 grep -Fq "$private_token" 2>/dev/null; then
    fail "runtime owner handle exposed its lease token"
  fi
}

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_SESSION_RUNTIME_HEARTBEAT_MILLISECONDS=100
export DX_SESSION_RUNTIME_OWNER_START_TIMEOUT_MILLISECONDS=5000
export DX_SESSION_RUNTIME_OWNER_FINISH_TIMEOUT_MILLISECONDS=5000
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR"

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

WORKSPACE="$TMP_DIR/repo"
mkdir -p "$WORKSPACE"

# Shell locals can inherit an export attribute in Bash. Route embedded-Python
# calls through a recorder while hostile exported names are present, then make
# sure real credentials and snapshots never reach argv or the environment.
REAL_PYTHON=$(command -v python3)
RUNTIME_CAPTURE_BIN="$TMP_DIR/runtime-capture-bin"
RUNTIME_CAPTURE_LOG="$TMP_DIR/runtime-capture.log"
mkdir -p "$RUNTIME_CAPTURE_BIN"
printf '%s\n' \
  '#!/usr/bin/env bash' \
  'set -euo pipefail' \
  '{' \
  '  printf "pid=%s argv" "$$"' \
  '  printf " <%s>" "$@"' \
  '  printf "\nenvironment\n"' \
  '  env' \
  '} >> "$DX_TEST_RUNTIME_CAPTURE_LOG"' \
  'exec "$DX_TEST_REAL_PYTHON" "$@"' \
  > "$RUNTIME_CAPTURE_BIN/python3"
chmod 700 "$RUNTIME_CAPTURE_BIN/python3"
export DX_TEST_REAL_PYTHON="$REAL_PYTHON"
export DX_TEST_RUNTIME_CAPTURE_LOG="$RUNTIME_CAPTURE_LOG"
export LEASE_TOKEN="hostile-export-lease"
export RECOVERY_SNAPSHOT="hostile-export-snapshot"
export token_record="hostile-export-token-record"
export lease_token="hostile-export-token-local"
export runtime_snapshot="hostile-export-runtime-snapshot"
export recovery_snapshot="hostile-export-recovery-snapshot"
ORIGINAL_PATH="$PATH"
export PATH="$RUNTIME_CAPTURE_BIN:$PATH"

# The supervisor owns the lease, heartbeats it, and never reveals the token.
SID_OK="runtime-owner-success"
dx_session_runtime_owner_start "$SID_OK" claude "$WORKSPACE" \
  > "$TMP_DIR/start.out" 2> "$TMP_DIR/start.err"
OWNER_HANDLE="$DX_SESSION_RUNTIME_OWNER_HANDLE"
OWNER_PID="$DX_SESSION_RUNTIME_OWNER_PID"
OWNER_DIRECTORY=$(dx_session_runtime_owner_handle_path "$OWNER_HANDLE")
unset DX_SESSION_RUNTIME_OWNER_HANDLE DX_SESSION_RUNTIME_OWNER_PID
assert_file "$OWNER_DIRECTORY/ready"
assert_eq "$OWNER_PID" "$(runtime_owner_pid "$SID_OK")" "runtime supervisor PID"
assert_eq "live" "$(dx_session_runtime_health "$SID_OK")" "supervised runtime health"
assert_eq "running" "$(dx_session_runtime_field "$SID_OK" status)" "supervised runtime status"
OWNER_PRIVATE_TOKEN=$(runtime_private_token "$SID_OK")
assert_token_private "$SID_OK" "$OWNER_HANDLE" \
  "$(cat "$TMP_DIR/start.out" "$TMP_DIR/start.err")"
assert_eq "live" "$(dx_session_runtime_health "$SID_OK" "$OWNER_PRIVATE_TOKEN")" \
  "token-authenticated supervised runtime health"
STARTED_AT=$(dx_session_runtime_field "$SID_OK" started_at)
sleep 1.2
HEARTBEAT_AT=$(dx_session_runtime_field "$SID_OK" heartbeat_at)
[[ "$HEARTBEAT_AT" -gt "$STARTED_AT" ]] || assert_at $LINENO
dx_session_runtime_owner_finish "$OWNER_HANDLE" completed
assert_eq "completed" "$(dx_session_runtime_field "$SID_OK" status)" "completed supervisor"
assert_eq "dead" "$(dx_session_runtime_health "$SID_OK")" "completed supervisor health"
assert_no_file "$OWNER_DIRECTORY"

# Handle fields are untrusted until they match the supervisor's trusted ready
# record. A forged PID or unreadable ready file must not authorize signalling,
# waiting, or cleanup of either the claimed process or the real owner.
SID_FORGED_HANDLE="runtime-owner-forged-handle"
dx_session_runtime_owner_start "$SID_FORGED_HANDLE" claude "$WORKSPACE"
FORGED_REAL_HANDLE="$DX_SESSION_RUNTIME_OWNER_HANDLE"
FORGED_REAL_PID="$DX_SESSION_RUNTIME_OWNER_PID"
FORGED_OWNER_DIRECTORY=$(dx_session_runtime_owner_handle_path \
  "$FORGED_REAL_HANDLE")
unset DX_SESSION_RUNTIME_OWNER_HANDLE DX_SESSION_RUNTIME_OWNER_PID
IFS=$'\t' read -r FORGED_VERSION FORGED_DIRECTORY FORGED_SESSION \
  FORGED_PID FORGED_IDENTITY FORGED_GENERATION FORGED_ROOT_DEVICE \
  FORGED_ROOT_INODE FORGED_DEVICE FORGED_INODE <<EOF
$FORGED_REAL_HANDLE
EOF
assert_eq "$FORGED_REAL_PID" "$FORGED_PID" "parsed owner PID"
case "$FORGED_IDENTITY" in
  linux:*|darwin:*) ;;
  *) fail "parsed owner identity is invalid" ;;
esac
FORGED_HANDLE=$(printf '%s\t%s\t%s\t4242\tdarwin:1:1\t%s\t%s\t%s\t%s\t%s' \
  "$FORGED_VERSION" \
  "$FORGED_DIRECTORY" "$FORGED_SESSION" "$FORGED_GENERATION" \
  "$FORGED_ROOT_DEVICE" "$FORGED_ROOT_INODE" "$FORGED_DEVICE" "$FORGED_INODE")
FORGED_SIGNAL_LOG="$TMP_DIR/forged-handle-signals"
kill() {
  printf 'kill %s\n' "$*" >> "$FORGED_SIGNAL_LOG"
  return 0
}
wait() {
  printf 'wait %s\n' "$*" >> "$FORGED_SIGNAL_LOG"
  return 0
}
FORGED_RESULT=0
dx_session_runtime_owner_finish "$FORGED_HANDLE" completed \
  >/dev/null 2>&1 || FORGED_RESULT=$?
assert_eq "3" "$FORGED_RESULT" "forged-handle finish result"
assert_no_file "$FORGED_SIGNAL_LOG"
assert_file "$FORGED_OWNER_DIRECTORY/ready"

mv "$FORGED_OWNER_DIRECTORY/ready" "$FORGED_OWNER_DIRECTORY/ready.saved"
MISSING_READY_RESULT=0
dx_session_runtime_owner_finish "$FORGED_REAL_HANDLE" completed \
  >/dev/null 2>&1 || MISSING_READY_RESULT=$?
assert_eq "3" "$MISSING_READY_RESULT" "missing-ready finish result"
assert_no_file "$FORGED_SIGNAL_LOG"
assert_file "$FORGED_OWNER_DIRECTORY/ready.saved"
mv "$FORGED_OWNER_DIRECTORY/ready.saved" "$FORGED_OWNER_DIRECTORY/ready"
unset -f kill wait
kill -0 "$FORGED_REAL_PID" 2>/dev/null \
  || fail "forged handle stopped the real supervisor"
assert_eq "live" "$(dx_session_runtime_health "$SID_FORGED_HANDLE")" \
  "runtime health after forged handle"
dx_session_runtime_owner_finish "$FORGED_REAL_HANDLE" stopped
assert_no_file "$FORGED_OWNER_DIRECTORY"

sleep 30 &
UNRELATED_OWNER_PID=$!
TEST_CHILD_PIDS="${TEST_CHILD_PIDS} ${UNRELATED_OWNER_PID}"
UNRELATED_OWNER_IDENTITY=$(dx_session_runtime_process_identity \
  "$UNRELATED_OWNER_PID")
FORGED_OWNER_ROOT=$(dx_session_runtime_owner_root)
FORGED_MATCHING_SESSION="runtime-owner-forged-matching-ready"
FORGED_MATCHING_DIRECTORY=$(mktemp -d \
  "$FORGED_OWNER_ROOT/${FORGED_MATCHING_SESSION}.XXXXXX")
chmod 700 "$FORGED_MATCHING_DIRECTORY"
FORGED_MATCHING_GENERATION="${FORGED_MATCHING_DIRECTORY##*/}"
FORGED_MATCHING_METADATA=$(__dx_session_runtime_owner_metadata \
  "$FORGED_OWNER_ROOT" "$FORGED_MATCHING_DIRECTORY")
IFS=$'\t' read -r FORGED_MATCHING_ROOT_DEVICE FORGED_MATCHING_ROOT_INODE \
  FORGED_MATCHING_DEVICE FORGED_MATCHING_INODE <<EOF
$FORGED_MATCHING_METADATA
EOF
printf 'ready\t%s\t%s\t%s\t%s\n' \
  "$UNRELATED_OWNER_PID" "$FORGED_MATCHING_SESSION" \
  "$UNRELATED_OWNER_IDENTITY" "$FORGED_MATCHING_GENERATION" \
  > "$FORGED_MATCHING_DIRECTORY/ready"
chmod 600 "$FORGED_MATCHING_DIRECTORY/ready"
FORGED_MATCHING_HANDLE=$(printf 'v1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
  "$FORGED_MATCHING_DIRECTORY" "$FORGED_MATCHING_SESSION" \
  "$UNRELATED_OWNER_PID" "$UNRELATED_OWNER_IDENTITY" \
  "$FORGED_MATCHING_GENERATION" "$FORGED_MATCHING_ROOT_DEVICE" \
  "$FORGED_MATCHING_ROOT_INODE" "$FORGED_MATCHING_DEVICE" \
  "$FORGED_MATCHING_INODE")
FORGED_MATCHING_SIGNAL_LOG="$TMP_DIR/forged-matching-ready-signals"
kill() {
  printf 'kill %s\n' "$*" >> "$FORGED_MATCHING_SIGNAL_LOG"
  return 0
}
wait() {
  printf 'wait %s\n' "$*" >> "$FORGED_MATCHING_SIGNAL_LOG"
  return 0
}
FORGED_MATCHING_RESULT=0
dx_session_runtime_owner_finish "$FORGED_MATCHING_HANDLE" completed \
  >/dev/null 2>&1 || FORGED_MATCHING_RESULT=$?
assert_eq "3" "$FORGED_MATCHING_RESULT" \
  "forged matching-ready finish result"
assert_no_file "$FORGED_MATCHING_SIGNAL_LOG"
assert_file "$FORGED_MATCHING_DIRECTORY/ready"
assert_no_file "$FORGED_MATCHING_DIRECTORY/command"
unset -f kill wait
kill -0 "$UNRELATED_OWNER_PID" 2>/dev/null \
  || fail "forged matching ready stopped an unrelated process"

# Recovery transfers an exact dead record to a fresh private supervisor. It can
# close the lease normally for resume work or remove only the runtime record
# through an authenticated cleanup request, even after the workspace is gone.
RECOVERY_WORKSPACE="$TMP_DIR/recovery-repo"
mkdir -p "$RECOVERY_WORKSPACE"
SID_RECOVERY="runtime-owner-recovery"
RECOVERY_OLD_TOKEN=$(dx_session_runtime_start \
  "$SID_RECOVERY" codex "$RECOVERY_WORKSPACE" "$$")
dx_session_runtime_finish \
  "$SID_RECOVERY" "$RECOVERY_OLD_TOKEN" paused "$$"
RECOVERY_PUBLIC_RECORD=$(dx_session_runtime_read "$SID_RECOVERY")
RECOVERY_RUNTIME_FILE=$(dx_session_runtime_file "$SID_RECOVERY")
RECOVERY_RUNTIME_LOCK="${RECOVERY_RUNTIME_FILE}-lock"
rmdir "$RECOVERY_WORKSPACE"

__dx_session_runtime_owner_recovery_start \
  "$SID_RECOVERY" "$RECOVERY_PUBLIC_RECORD" \
  > "$TMP_DIR/recovery-start.out" 2> "$TMP_DIR/recovery-start.err"
RECOVERY_HANDLE="$DX_SESSION_RUNTIME_OWNER_HANDLE"
RECOVERY_OWNER_PID="$DX_SESSION_RUNTIME_OWNER_PID"
RECOVERY_OWNER_DIRECTORY=$(dx_session_runtime_owner_handle_path "$RECOVERY_HANDLE")
unset DX_SESSION_RUNTIME_OWNER_HANDLE DX_SESSION_RUNTIME_OWNER_PID
assert_eq "$RECOVERY_OWNER_PID" "$(runtime_owner_pid "$SID_RECOVERY")" \
  "recovery supervisor PID"
assert_eq "codex" "$(dx_session_runtime_field "$SID_RECOVERY" provider)" \
  "recovery provider"
assert_eq "$RECOVERY_WORKSPACE" \
  "$(dx_session_runtime_field "$SID_RECOVERY" workspace)" \
  "recovery missing workspace"
assert_eq "live" "$(dx_session_runtime_health "$SID_RECOVERY")" \
  "recovery supervisor health"
RECOVERY_PRIVATE_TOKEN=$(runtime_private_token "$SID_RECOVERY")
assert_token_private "$SID_RECOVERY" "$RECOVERY_HANDLE" \
  "$(cat "$TMP_DIR/recovery-start.out" "$TMP_DIR/recovery-start.err")"
assert_not_contains "$RECOVERY_PUBLIC_RECORD" \
  <(cat "$TMP_DIR/recovery-start.out" "$TMP_DIR/recovery-start.err")
dx_session_runtime_owner_finish "$RECOVERY_HANDLE" paused
assert_eq "paused" "$(dx_session_runtime_field "$SID_RECOVERY" status)" \
  "recovery supervisor terminal status"
assert_no_file "$RECOVERY_OWNER_DIRECTORY"

RECOVERY_PURGE_SNAPSHOT=$(dx_session_runtime_read "$SID_RECOVERY")
__dx_session_runtime_owner_recovery_start \
  "$SID_RECOVERY" "$RECOVERY_PURGE_SNAPSHOT" \
  > "$TMP_DIR/recovery-purge-start.out" \
  2> "$TMP_DIR/recovery-purge-start.err"
RECOVERY_PURGE_HANDLE="$DX_SESSION_RUNTIME_OWNER_HANDLE"
RECOVERY_PURGE_DIRECTORY=$(dx_session_runtime_owner_handle_path \
  "$RECOVERY_PURGE_HANDLE")
unset DX_SESSION_RUNTIME_OWNER_HANDLE DX_SESSION_RUNTIME_OWNER_PID
RECOVERY_PURGE_PRIVATE_TOKEN=$(runtime_private_token "$SID_RECOVERY")
assert_token_private "$SID_RECOVERY" "$RECOVERY_PURGE_HANDLE" \
  "$(cat "$TMP_DIR/recovery-purge-start.out" \
    "$TMP_DIR/recovery-purge-start.err")"
assert_not_contains "$RECOVERY_PURGE_SNAPSHOT" \
  <(cat "$TMP_DIR/recovery-purge-start.out" \
    "$TMP_DIR/recovery-purge-start.err")
__dx_session_runtime_owner_purge "$RECOVERY_PURGE_HANDLE"
assert_no_file "$RECOVERY_RUNTIME_FILE"
assert_file "$RECOVERY_RUNTIME_LOCK"
assert_no_file "$RECOVERY_PURGE_DIRECTORY"
assert_eq "legacy-unverifiable" "$(dx_session_runtime_health "$SID_RECOVERY")" \
  "purged recovery health"

SID_EXPORTED_PURGE="runtime-exported-local-purge"
EXPORTED_PURGE_TOKEN=$(dx_session_runtime_start \
  "$SID_EXPORTED_PURGE" claude "$WORKSPACE" "$$")
__dx_session_runtime_purge "$SID_EXPORTED_PURGE" "$EXPORTED_PURGE_TOKEN" "$$"

ZSH_HEARTBEAT_TOKEN=""
ZSH_PURGE_TOKEN=""
if command -v zsh >/dev/null 2>&1; then
  ZSH_TOKEN_FILE="$TMP_DIR/zsh-runtime-tokens"
  ZSH_DOT_DIR="$TMP_DIR/zsh-dot-dir"
  mkdir -p "$ZSH_DOT_DIR"
  ZDOTDIR="$ZSH_DOT_DIR" \
  DX_TEST_ZSH_WORKSPACE="$WORKSPACE" \
  DX_TEST_ZSH_TOKEN_FILE="$ZSH_TOKEN_FILE" \
  zsh -f -c '
    set -eu
    source "$DEX_DIR/lib/session.sh"
    source "$DEX_DIR/lib/session-runtime.sh"
    heartbeat_token=$(dx_session_runtime_start \
      runtime-zsh-export-heartbeat claude "$DX_TEST_ZSH_WORKSPACE" "$$")
    dx_session_runtime_heartbeat \
      runtime-zsh-export-heartbeat "$heartbeat_token" "$$"
    dx_session_runtime_health \
      runtime-zsh-export-heartbeat "$heartbeat_token" >/dev/null
    dx_session_runtime_finish \
      runtime-zsh-export-heartbeat "$heartbeat_token" stopped "$$"
    purge_token=$(dx_session_runtime_start \
      runtime-zsh-export-purge claude "$DX_TEST_ZSH_WORKSPACE" "$$")
    __dx_session_runtime_purge \
      runtime-zsh-export-purge "$purge_token" "$$"
    printf "%s\n%s\n" "$heartbeat_token" "$purge_token" \
      > "$DX_TEST_ZSH_TOKEN_FILE"
  '
  ZSH_HEARTBEAT_TOKEN=$(sed -n '1p' "$ZSH_TOKEN_FILE")
  ZSH_PURGE_TOKEN=$(sed -n '2p' "$ZSH_TOKEN_FILE")
fi

for PRIVATE_VALUE in \
  "$OWNER_PRIVATE_TOKEN" \
  "$RECOVERY_OLD_TOKEN" \
  "$RECOVERY_PRIVATE_TOKEN" \
  "$RECOVERY_PURGE_PRIVATE_TOKEN" \
  "$EXPORTED_PURGE_TOKEN" \
  "$ZSH_HEARTBEAT_TOKEN" \
  "$ZSH_PURGE_TOKEN" \
  "$RECOVERY_PUBLIC_RECORD" \
  "$RECOVERY_PURGE_SNAPSHOT"; do
  [[ -z "$PRIVATE_VALUE" ]] \
    || assert_not_contains "$PRIVATE_VALUE" "$RUNTIME_CAPTURE_LOG"
done
export PATH="$ORIGINAL_PATH"
unset LEASE_TOKEN RECOVERY_SNAPSHOT token_record lease_token
unset runtime_snapshot recovery_snapshot
unset DX_TEST_REAL_PYTHON DX_TEST_RUNTIME_CAPTURE_LOG

# The supervisor repeats the exact-snapshot check under the runtime lock. A
# replacement owner therefore survives a recovery attempt made from stale
# catalog data.
SID_STALE_RECOVERY="runtime-owner-stale-recovery"
STALE_RECOVERY_TOKEN=$(dx_session_runtime_start \
  "$SID_STALE_RECOVERY" claude "$WORKSPACE" "$$")
dx_session_runtime_finish \
  "$SID_STALE_RECOVERY" "$STALE_RECOVERY_TOKEN" paused "$$"
STALE_RECOVERY_SNAPSHOT=$(dx_session_runtime_read "$SID_STALE_RECOVERY")
STALE_REPLACEMENT_TOKEN=$(dx_session_runtime_start \
  "$SID_STALE_RECOVERY" claude "$WORKSPACE" "$$")
STALE_RECOVERY_RESULT=0
__dx_session_runtime_owner_recovery_start \
  "$SID_STALE_RECOVERY" "$STALE_RECOVERY_SNAPSHOT" \
  > "$TMP_DIR/stale-recovery.out" \
  2> "$TMP_DIR/stale-recovery.err" || STALE_RECOVERY_RESULT=$?
assert_eq "2" "$STALE_RECOVERY_RESULT" "stale owner recovery result"
dx_session_runtime_matches "$SID_STALE_RECOVERY" "$STALE_REPLACEMENT_TOKEN" \
  || fail "stale owner recovery disturbed the replacement lease"
dx_session_runtime_finish \
  "$SID_STALE_RECOVERY" "$STALE_REPLACEMENT_TOKEN" stopped "$$"

# Purge is accepted only by a supervisor launched for recovery. Sending that
# internal action to an ordinary lifecycle supervisor fails closed and leaves
# a terminal runtime record.
SID_NORMAL_PURGE="runtime-owner-normal-purge"
dx_session_runtime_owner_start "$SID_NORMAL_PURGE" claude "$WORKSPACE"
NORMAL_PURGE_HANDLE="$DX_SESSION_RUNTIME_OWNER_HANDLE"
NORMAL_PURGE_DIRECTORY=$(dx_session_runtime_owner_handle_path \
  "$NORMAL_PURGE_HANDLE")
unset DX_SESSION_RUNTIME_OWNER_HANDLE DX_SESSION_RUNTIME_OWNER_PID
NORMAL_PURGE_RESULT=0
__dx_session_runtime_owner_purge "$NORMAL_PURGE_HANDLE" \
  >/dev/null 2>&1 || NORMAL_PURGE_RESULT=$?
assert_eq "3" "$NORMAL_PURGE_RESULT" "ordinary owner purge result"
NORMAL_PURGE_STATE=$(dx_session_runtime_field "$SID_NORMAL_PURGE" status)
case "$NORMAL_PURGE_STATE" in
  running)
    assert_eq "live" "$(dx_session_runtime_health "$SID_NORMAL_PURGE")" \
      "ordinary owner health after rejected purge"
    dx_session_runtime_owner_finish "$NORMAL_PURGE_HANDLE" stopped
    ;;
  failed)
    assert_eq "dead" "$(dx_session_runtime_health "$SID_NORMAL_PURGE")" \
      "ordinary owner health after purge request"
    ;;
  *) fail "ordinary owner purge left unexpected state: $NORMAL_PURGE_STATE" ;;
esac
assert_no_file "$NORMAL_PURGE_DIRECTORY"

# A reader may observe the create-once hardlink while its private temporary
# sibling still exists. That is a bounded publication state, not corruption.
PUBLICATION_SITE="$TMP_DIR/publication-site"
PUBLICATION_MARKER="$TMP_DIR/result-publication.marker"
mkdir -p "$PUBLICATION_SITE"
printf '%s\n' \
  'import os' \
  'import time' \
  '' \
  '_real_link = os.link' \
  '_marker = os.environ.get("DX_TEST_RESULT_PUBLICATION_MARKER", "")' \
  '' \
  'def _delayed_link(*args, **kwargs):' \
  '    result = _real_link(*args, **kwargs)' \
  '    destination = args[1] if len(args) > 1 else kwargs.get("dst")' \
  '    if destination == "result" and _marker:' \
  '        with open(_marker, "w", encoding="utf-8") as handle:' \
  '            handle.write("linked\n")' \
  '        time.sleep(0.75)' \
  '    return result' \
  '' \
  'os.link = _delayed_link' \
  > "$PUBLICATION_SITE/sitecustomize.py"
export PYTHONPATH="$PUBLICATION_SITE"
export DX_TEST_RESULT_PUBLICATION_MARKER="$PUBLICATION_MARKER"
SID_PUBLICATION="runtime-owner-publication-window"
dx_session_runtime_owner_start "$SID_PUBLICATION" claude "$WORKSPACE"
PUBLICATION_HANDLE="$DX_SESSION_RUNTIME_OWNER_HANDLE"
unset DX_SESSION_RUNTIME_OWNER_HANDLE DX_SESSION_RUNTIME_OWNER_PID
dx_session_runtime_owner_finish "$PUBLICATION_HANDLE" completed
assert_file "$PUBLICATION_MARKER"
assert_eq "completed" "$(dx_session_runtime_field "$SID_PUBLICATION" status)" \
  "publication-window terminal status"
unset PYTHONPATH DX_TEST_RESULT_PUBLICATION_MARKER

# Stable process identity is checked again before every signal. If a PID is
# replaced after CONT, the replacement never receives TERM or KILL.
IDENTITY_COUNTER="$TMP_DIR/identity-counter"
IDENTITY_SIGNAL_LOG="$TMP_DIR/identity-signals"
printf '0\n' > "$IDENTITY_COUNTER"
__dx_session_runtime_owner_process_state() {
  local identity_count
  identity_count=$(cat "$IDENTITY_COUNTER")
  identity_count=$((identity_count + 1))
  printf '%s\n' "$identity_count" > "$IDENTITY_COUNTER"
  if [[ "$identity_count" -le 2 ]]; then
    printf '%s\n' live
  else
    printf '%s\n' replaced
  fi
}
kill() {
  case "${1:-}" in
    -CONT|-TERM|-KILL)
      printf '%s\n' "$1" >> "$IDENTITY_SIGNAL_LOG"
      return 0
      ;;
    *) builtin kill "$@" ;;
  esac
}
__dx_session_runtime_owner_stop_process 4242 'darwin:100:1'
unset -f kill
# shellcheck source=lib/session-runtime.sh
source "$ROOT/lib/session-runtime.sh"
assert_eq "-CONT" "$(cat "$IDENTITY_SIGNAL_LOG")" \
  "PID replacement signal isolation"

# Startup keeps the identity captured for its direct child. A later lookup that
# reports another generation cannot authorize cleanup signals for that PID.
START_IDENTITY_COUNTER="$TMP_DIR/start-identity-counter"
START_SIGNAL_LOG="$TMP_DIR/start-identity-signals"
printf '0\n' > "$START_IDENTITY_COUNTER"
dx_session_runtime_process_identity() {
  local queried_pid="$1" identity_count
  if [[ "$queried_pid" == "$$" ]]; then
    __dx_session_runtime_call identity "$queried_pid"
    return
  fi
  identity_count=$(cat "$START_IDENTITY_COUNTER")
  identity_count=$((identity_count + 1))
  printf '%s\n' "$identity_count" > "$START_IDENTITY_COUNTER"
  if [[ "$identity_count" -eq 1 ]]; then
    printf '%s\n' 'darwin:300:3'
  else
    printf '%s\n' 'darwin:400:4'
  fi
}
__dx_session_runtime_owner_trusted_read_path() { return 1; }
__dx_session_runtime_owner_result_path() { return 1; }
__dx_session_runtime_owner_process_state() {
  case "$2" in
    darwin:300:3) printf '%s\n' replaced ;;
    darwin:400:4) printf '%s\n' live ;;
    *) printf '%s\n' unverifiable ;;
  esac
}
kill() {
  case "${1:-}" in
    -CONT|-TERM|-KILL)
      printf '%s\n' "$1" >> "$START_SIGNAL_LOG"
      return 0
      ;;
    *) builtin kill "$@" ;;
  esac
}
set +e
DX_SESSION_RUNTIME_OWNER_START_TIMEOUT_MILLISECONDS=50 \
  dx_session_runtime_owner_start \
    runtime-owner-start-replacement claude "$WORKSPACE" >/dev/null 2>&1
START_REPLACEMENT_RESULT=$?
set -e
unset -f kill
# shellcheck source=lib/session-runtime.sh
source "$ROOT/lib/session-runtime.sh"
[[ "$START_REPLACEMENT_RESULT" -ne 0 ]] || \
  fail "replacement-identity startup unexpectedly succeeded"
assert_no_file "$START_SIGNAL_LOG"
wait_for_runtime_field runtime-owner-start-replacement status failed
START_REPLACEMENT_PID=$(dx_session_runtime_field \
  runtime-owner-start-replacement pid 2>/dev/null || true)
if [[ "$START_REPLACEMENT_PID" =~ ^[0-9]+$ ]]; then
  wait "$START_REPLACEMENT_PID" 2>/dev/null || true
fi

# Even an explicitly traced launch switches tracing off before the credential
# exists, so diagnostics cannot reveal it.
SID_XTRACE="runtime-owner-xtrace"
XTRACE_ROOT=$(dx_session_runtime_owner_root)
mkdir -p "$XTRACE_ROOT"
chmod 700 "$XTRACE_ROOT"
XTRACE_DIRECTORY=$(mktemp -d "$XTRACE_ROOT/${SID_XTRACE}.XXXXXX")
chmod 700 "$XTRACE_DIRECTORY"
XTRACE_GENERATION="${XTRACE_DIRECTORY##*/}"
XTRACE_METADATA=$(__dx_session_runtime_owner_metadata "$XTRACE_ROOT" "$XTRACE_DIRECTORY")
IFS=$'\t' read -r XTRACE_ROOT_DEVICE XTRACE_ROOT_INODE \
  XTRACE_DEVICE XTRACE_INODE <<EOF
$XTRACE_METADATA
EOF
MONITOR_IDENTITY=$(dx_session_runtime_process_identity "$$")
LEASE_TOKEN="hostile-xtrace-lease" \
RECOVERY_SNAPSHOT="hostile-xtrace-snapshot" \
token_record="hostile-xtrace-record" \
lease_token="hostile-xtrace-local" \
bash -x "$ROOT/bin/session-runtime-owner.sh" \
  "$SID_XTRACE" claude "$WORKSPACE" "$$" "$MONITOR_IDENTITY" "$XTRACE_DIRECTORY" \
  "$XTRACE_ROOT_DEVICE" "$XTRACE_ROOT_INODE" "$XTRACE_DEVICE" "$XTRACE_INODE" start \
  3</dev/null \
  > "$XTRACE_DIRECTORY/output" 2> "$XTRACE_DIRECTORY/error" &
XTRACE_OWNER_PID=$!
TEST_CHILD_PIDS="${TEST_CHILD_PIDS} ${XTRACE_OWNER_PID}"
wait_for_value "$XTRACE_DIRECTORY/ready"
XTRACE_OWNER_IDENTITY=$(dx_session_runtime_process_identity "$XTRACE_OWNER_PID")
XTRACE_HANDLE=$(printf 'v1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
  "$XTRACE_DIRECTORY" "$SID_XTRACE" "$XTRACE_OWNER_PID" "$XTRACE_OWNER_IDENTITY" \
  "$XTRACE_GENERATION" "$XTRACE_ROOT_DEVICE" "$XTRACE_ROOT_INODE" \
  "$XTRACE_DEVICE" "$XTRACE_INODE")
assert_token_private "$SID_XTRACE" "$XTRACE_HANDLE" \
  "$(cat "$XTRACE_DIRECTORY/output" "$XTRACE_DIRECTORY/error")"
dx_session_runtime_owner_finish "$XTRACE_HANDLE" completed
TEST_CHILD_PIDS="${TEST_CHILD_PIDS/ ${XTRACE_OWNER_PID}/}"
assert_eq "completed" "$(dx_session_runtime_field "$SID_XTRACE" status)" \
  "traced supervisor status"

SID_XTRACE_RECOVERY="runtime-owner-xtrace-recovery"
XTRACE_RECOVERY_TOKEN=$(dx_session_runtime_start \
  "$SID_XTRACE_RECOVERY" codex "$WORKSPACE" "$$")
dx_session_runtime_finish \
  "$SID_XTRACE_RECOVERY" "$XTRACE_RECOVERY_TOKEN" paused "$$"
XTRACE_RECOVERY_RECORD=$(dx_session_runtime_read "$SID_XTRACE_RECOVERY")
XTRACE_RECOVERY_DIRECTORY=$(mktemp -d \
  "$XTRACE_ROOT/${SID_XTRACE_RECOVERY}.XXXXXX")
chmod 700 "$XTRACE_RECOVERY_DIRECTORY"
XTRACE_RECOVERY_GENERATION="${XTRACE_RECOVERY_DIRECTORY##*/}"
XTRACE_RECOVERY_METADATA=$(__dx_session_runtime_owner_metadata \
  "$XTRACE_ROOT" "$XTRACE_RECOVERY_DIRECTORY")
IFS=$'\t' read -r XTRACE_RECOVERY_ROOT_DEVICE XTRACE_RECOVERY_ROOT_INODE \
  XTRACE_RECOVERY_DEVICE XTRACE_RECOVERY_INODE <<EOF
$XTRACE_RECOVERY_METADATA
EOF
LEASE_TOKEN="hostile-xtrace-recovery-lease" \
RECOVERY_SNAPSHOT="hostile-xtrace-recovery-snapshot" \
token_record="hostile-xtrace-recovery-record" \
lease_token="hostile-xtrace-recovery-local" \
bash -x "$ROOT/bin/session-runtime-owner.sh" \
  "$SID_XTRACE_RECOVERY" codex "$WORKSPACE" "$$" "$MONITOR_IDENTITY" \
  "$XTRACE_RECOVERY_DIRECTORY" "$XTRACE_RECOVERY_ROOT_DEVICE" \
  "$XTRACE_RECOVERY_ROOT_INODE" "$XTRACE_RECOVERY_DEVICE" \
  "$XTRACE_RECOVERY_INODE" recover \
  3<<<"$XTRACE_RECOVERY_RECORD" \
  > "$XTRACE_RECOVERY_DIRECTORY/output" \
  2> "$XTRACE_RECOVERY_DIRECTORY/error" &
XTRACE_RECOVERY_OWNER_PID=$!
TEST_CHILD_PIDS="${TEST_CHILD_PIDS} ${XTRACE_RECOVERY_OWNER_PID}"
wait_for_value "$XTRACE_RECOVERY_DIRECTORY/ready"
XTRACE_RECOVERY_OWNER_IDENTITY=$(dx_session_runtime_process_identity \
  "$XTRACE_RECOVERY_OWNER_PID")
XTRACE_RECOVERY_HANDLE=$(printf 'v1\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
  "$XTRACE_RECOVERY_DIRECTORY" "$SID_XTRACE_RECOVERY" \
  "$XTRACE_RECOVERY_OWNER_PID" "$XTRACE_RECOVERY_OWNER_IDENTITY" \
  "$XTRACE_RECOVERY_GENERATION" "$XTRACE_RECOVERY_ROOT_DEVICE" \
  "$XTRACE_RECOVERY_ROOT_INODE" "$XTRACE_RECOVERY_DEVICE" \
  "$XTRACE_RECOVERY_INODE")
assert_token_private "$SID_XTRACE_RECOVERY" "$XTRACE_RECOVERY_HANDLE" \
  "$(cat "$XTRACE_RECOVERY_DIRECTORY/output" \
    "$XTRACE_RECOVERY_DIRECTORY/error")"
assert_not_contains "$XTRACE_RECOVERY_RECORD" \
  <(cat "$XTRACE_RECOVERY_DIRECTORY/output" \
    "$XTRACE_RECOVERY_DIRECTORY/error")
assert_not_contains "$XTRACE_RECOVERY_RECORD" \
  <(ps -o command= -p "$XTRACE_RECOVERY_OWNER_PID" 2>/dev/null || true)
__dx_session_runtime_owner_purge "$XTRACE_RECOVERY_HANDLE"
TEST_CHILD_PIDS="${TEST_CHILD_PIDS/ ${XTRACE_RECOVERY_OWNER_PID}/}"
assert_no_file "$(dx_session_runtime_file "$SID_XTRACE_RECOVERY")"

# A live lease rejects a second supervisor before either caller can launch work.
SID_CONCURRENT="runtime-owner-concurrent"
dx_session_runtime_owner_start "$SID_CONCURRENT" codex "$WORKSPACE"
FIRST_HANDLE="$DX_SESSION_RUNTIME_OWNER_HANDLE"
unset DX_SESSION_RUNTIME_OWNER_HANDLE DX_SESSION_RUNTIME_OWNER_PID
if dx_session_runtime_owner_start "$SID_CONCURRENT" codex "$WORKSPACE" \
    > "$TMP_DIR/concurrent.out" 2> "$TMP_DIR/concurrent.err"; then
  fail "a second runtime supervisor replaced a live owner"
else
  assert_eq "2" "$?" "concurrent supervisor start result"
fi
assert_contains "another process may still own this session" "$TMP_DIR/concurrent.err"
dx_session_runtime_owner_finish "$FIRST_HANDLE" paused
assert_eq "paused" "$(dx_session_runtime_field "$SID_CONCURRENT" status)" \
  "concurrent owner terminal status"

# An unsolicited supervisor signal cannot be mistaken for a later completed
# request, even though the signal handler safely closes the public lease.
SID_SIGNAL_RESULT="runtime-owner-signal-result"
dx_session_runtime_owner_start "$SID_SIGNAL_RESULT" claude "$WORKSPACE"
SIGNAL_HANDLE="$DX_SESSION_RUNTIME_OWNER_HANDLE"
SIGNAL_OWNER_PID="$DX_SESSION_RUNTIME_OWNER_PID"
SIGNAL_DIRECTORY=$(dx_session_runtime_owner_handle_path "$SIGNAL_HANDLE")
unset DX_SESSION_RUNTIME_OWNER_HANDLE DX_SESSION_RUNTIME_OWNER_PID
kill -TERM "$SIGNAL_OWNER_PID"
wait_for_value "$SIGNAL_DIRECTORY/result"
if dx_session_runtime_owner_finish "$SIGNAL_HANDLE" completed \
    > "$TMP_DIR/signal-finish.out" 2> "$TMP_DIR/signal-finish.err"; then
  fail "a stopped supervisor result satisfied a completed request"
fi
assert_eq "stopped" "$(dx_session_runtime_field "$SID_SIGNAL_RESULT" status)" \
  "signalled supervisor terminal status"
assert_eq "dead" "$(dx_session_runtime_health "$SID_SIGNAL_RESULT")" \
  "signalled supervisor health"

# When the launcher dies, its direct child closes the lease as abandoned.
SID_PARENT_DEAD="runtime-owner-parent-dead"
PARENT_INFO="$TMP_DIR/parent-owner.info"
DEX_PARENT_TEST_SESSION="$SID_PARENT_DEAD" \
DEX_PARENT_TEST_WORKSPACE="$WORKSPACE" \
DEX_PARENT_TEST_INFO="$PARENT_INFO" \
bash -c '
  source "$DEX_DIR/lib/common.sh"
  dx_session_runtime_owner_start \
    "$DEX_PARENT_TEST_SESSION" claude "$DEX_PARENT_TEST_WORKSPACE"
  printf "%s\n" "$DX_SESSION_RUNTIME_OWNER_PID" > "$DEX_PARENT_TEST_INFO"
  while true; do sleep 1; done
' &
MONITOR_PID=$!
TEST_CHILD_PIDS="${TEST_CHILD_PIDS} ${MONITOR_PID}"
wait_for_value "$PARENT_INFO"
PARENT_OWNER_PID=$(cat "$PARENT_INFO")
PARENT_OWNER_IDENTITY=$(dx_session_runtime_field \
  "$SID_PARENT_DEAD" process_start)
TEST_CHILD_PIDS="${TEST_CHILD_PIDS} ${PARENT_OWNER_PID}"
kill -KILL "$MONITOR_PID"
wait "$MONITOR_PID" 2>/dev/null || true
wait_for_runtime_field "$SID_PARENT_DEAD" status abandoned
assert_eq "dead" "$(dx_session_runtime_health "$SID_PARENT_DEAD")" \
  "dead launcher runtime health"
PARENT_OWNER_STATE=$(__dx_session_runtime_owner_process_state \
  "$PARENT_OWNER_PID" "$PARENT_OWNER_IDENTITY" 2>/dev/null || true)
case "$PARENT_OWNER_STATE" in
  dead|replaced) ;;
  *) fail "runtime supervisor remained ${PARENT_OWNER_STATE:-unverifiable} after its monitored launcher" ;;
esac

# A heartbeat timeout remains the first failure even if the lock becomes
# available for the EXIT finalizer. A later completed request cannot accept it.
SID_HEARTBEAT_FAIL="runtime-owner-heartbeat-fail"
HEARTBEAT_FAIL_SITE="$TMP_DIR/heartbeat-fail-site"
mkdir -p "$HEARTBEAT_FAIL_SITE"
printf '%s\n' \
  'import errno' \
  'import fcntl' \
  'import sys' \
  '' \
  '_real_flock = fcntl.flock' \
  '_reject_heartbeat = len(sys.argv) > 1 and sys.argv[1] == "heartbeat"' \
  '' \
  'def _runtime_owner_flock(descriptor, operation):' \
  '    if _reject_heartbeat and operation & fcntl.LOCK_EX:' \
  '        raise BlockingIOError(errno.EWOULDBLOCK, "injected heartbeat contention")' \
  '    return _real_flock(descriptor, operation)' \
  '' \
  'fcntl.flock = _runtime_owner_flock' \
  > "$HEARTBEAT_FAIL_SITE/sitecustomize.py"
export DX_SESSION_RUNTIME_HEARTBEAT_MILLISECONDS=500
export DX_SESSION_RUNTIME_LOCK_TIMEOUT_MILLISECONDS=50
export PYTHONPATH="$HEARTBEAT_FAIL_SITE"
dx_session_runtime_owner_start "$SID_HEARTBEAT_FAIL" codex "$WORKSPACE"
HEARTBEAT_HANDLE="$DX_SESSION_RUNTIME_OWNER_HANDLE"
HEARTBEAT_OWNER_PID="$DX_SESSION_RUNTIME_OWNER_PID"
HEARTBEAT_DIRECTORY=$(dx_session_runtime_owner_handle_path "$HEARTBEAT_HANDLE")
unset DX_SESSION_RUNTIME_OWNER_HANDLE DX_SESSION_RUNTIME_OWNER_PID
wait_for_value "$HEARTBEAT_DIRECTORY/result"
HEARTBEAT_RESULT=$(cat "$HEARTBEAT_DIRECTORY/result")
HEARTBEAT_RESULT_CODE="${HEARTBEAT_RESULT%%$'\t'*}"
[[ "$HEARTBEAT_RESULT_CODE" -ne 0 ]] \
  || fail "heartbeat failure was overwritten by successful cleanup"
assert_contains $'\tfailed\theartbeat-failed' <(printf '%s\n' "$HEARTBEAT_RESULT")
if dx_session_runtime_owner_finish "$HEARTBEAT_HANDLE" completed \
    > "$TMP_DIR/heartbeat-finish.out" 2> "$TMP_DIR/heartbeat-finish.err"; then
  fail "heartbeat failure was reported as a successful finish"
fi
assert_eq "failed" "$(dx_session_runtime_field "$SID_HEARTBEAT_FAIL" status)" \
  "heartbeat failure terminal status"
assert_eq "dead" "$(dx_session_runtime_health "$SID_HEARTBEAT_FAIL")" \
  "heartbeat failure health"
if kill -0 "$HEARTBEAT_OWNER_PID" 2>/dev/null; then
  fail "heartbeat-failed supervisor remained alive"
fi
export DX_SESSION_RUNTIME_HEARTBEAT_MILLISECONDS=100
unset DX_SESSION_RUNTIME_LOCK_TIMEOUT_MILLISECONDS
unset PYTHONPATH

# Owner control files are always opened through the descriptor-bound directory
# FD. Special files and substituted generations fail promptly, stop only the
# supervisor, and cannot manufacture a successful terminal result.
run_owner_control_attack() { # <fifo|symlink|directory|handle-swap|result-swap>
  set -euo pipefail
  local attack_kind="$1" attack_session owner_handle owner_pid owner_directory
  local owner_generation real_directory ready_record finish_result=0
  local runtime_health runtime_state
  # shellcheck source=lib/common.sh
  source "$ROOT/lib/common.sh"
  attack_session="runtime-owner-control-${attack_kind//[^A-Za-z0-9._-]/-}-$$"
  export DX_SESSION_RUNTIME_OWNER_FINISH_TIMEOUT_MILLISECONDS=100
  dx_session_runtime_owner_start "$attack_session" claude "$WORKSPACE"
  owner_handle="$DX_SESSION_RUNTIME_OWNER_HANDLE"
  owner_pid="$DX_SESSION_RUNTIME_OWNER_PID"
  owner_directory=$(dx_session_runtime_owner_handle_path "$owner_handle")
  owner_generation="${owner_directory##*/}"
  ready_record=$(cat "$owner_directory/ready")
  unset DX_SESSION_RUNTIME_OWNER_HANDLE DX_SESSION_RUNTIME_OWNER_PID

  case "$attack_kind" in
    fifo)
      rm -f "$owner_directory/ready"
      mkfifo "$owner_directory/ready"
      chmod 600 "$owner_directory/ready"
      ;;
    symlink)
      rm -f "$owner_directory/ready"
      ln -s "$owner_directory/output" "$owner_directory/ready"
      ;;
    directory)
      rm -f "$owner_directory/ready"
      mkdir "$owner_directory/ready"
      chmod 700 "$owner_directory/ready"
      ;;
    handle-swap)
      real_directory="${owner_directory}.real"
      mv "$owner_directory" "$real_directory"
      mkdir "$owner_directory"
      chmod 700 "$owner_directory"
      printf 'ready\t%s\t%s\t%s\t%s\n' \
        "$owner_pid" "$attack_session" \
        "$(dx_session_runtime_field "$attack_session" process_start)" \
        "$owner_generation" > "$owner_directory/ready"
      printf '0\t%s\tcompleted\tforged\n' \
        "$owner_generation" > "$owner_directory/result"
      chmod 600 "$owner_directory/ready" "$owner_directory/result"
      ;;
    result-swap)
      printf '0\t%s\tcompleted\tforged\n' \
        "$owner_generation" > "$owner_directory/result"
      chmod 600 "$owner_directory/result"
      ;;
    *) return 90 ;;
  esac

  dx_session_runtime_owner_finish "$owner_handle" completed \
    >/dev/null 2>&1 || finish_result=$?
  [[ "$finish_result" -ne 0 ]] || return 91
  case "$attack_kind" in
    fifo|symlink|directory)
      rm -rf "$owner_directory/ready"
      printf '%s\n' "$ready_record" > "$owner_directory/ready"
      chmod 600 "$owner_directory/ready"
      DX_SESSION_RUNTIME_OWNER_FINISH_TIMEOUT_MILLISECONDS=5000 \
        dx_session_runtime_owner_finish "$owner_handle" failed \
        >/dev/null 2>&1 || return 94
      ;;
    handle-swap)
      mv "$owner_directory" "${owner_directory}.forged"
      mv "$real_directory" "$owner_directory"
      DX_SESSION_RUNTIME_OWNER_FINISH_TIMEOUT_MILLISECONDS=5000 \
        dx_session_runtime_owner_finish "$owner_handle" failed \
        >/dev/null 2>&1 || return 94
      ;;
  esac
  runtime_health=$(dx_session_runtime_health "$attack_session" 2>/dev/null || true)
  runtime_state=$(dx_session_runtime_field "$attack_session" status 2>/dev/null || true)
  [[ "$runtime_health" == "dead" && "$runtime_state" != "running" ]] || return 92
  ! kill -0 "$owner_pid" 2>/dev/null || return 93
}
export -f run_owner_control_attack
export ROOT WORKSPACE
CONTROL_ATTACK_SENTINEL="$TMP_DIR/owner-control-attacks.passed"
if ! python3 - "$CONTROL_ATTACK_SENTINEL" <<'PY'
from pathlib import Path
import subprocess
import sys

for attack in ("fifo", "symlink", "directory", "handle-swap", "result-swap"):
    try:
        result = subprocess.run(
            ["bash", "-c", 'run_owner_control_attack "$1"', "_", attack],
            check=False,
            capture_output=True,
            text=True,
            timeout=10,
        )
    except subprocess.TimeoutExpired as exc:
        raise SystemExit(f"runtime owner {attack} attack exceeded its hard deadline: {exc}")
    if result.returncode != 0:
        raise SystemExit(
            f"runtime owner {attack} attack failed ({result.returncode}): "
            f"{result.stdout}{result.stderr}"
        )
Path(sys.argv[1]).write_text("passed\n", encoding="utf-8")
PY
then
  fail "runtime owner control attack checks did not complete"
fi
assert_file "$CONTROL_ATTACK_SENTINEL"
export -n ROOT WORKSPACE
unset -f run_owner_control_attack

# An identity probe may be temporarily unavailable while the direct child is
# still alive. Startup returns within its own bound without waiting on or
# signalling that unverifiable process.
START_UNVERIFIABLE_SESSION="runtime-owner-start-unverifiable"
START_UNVERIFIABLE_PID_FILE="$TMP_DIR/start-unverifiable.pid"
START_UNVERIFIABLE_WATCHDOG_PID_FILE="$TMP_DIR/start-unverifiable-watchdog.pid"
export START_UNVERIFIABLE_SESSION START_UNVERIFIABLE_PID_FILE
__dx_session_runtime_owner_trusted_read_path() {
  if [[ "${7:-}" == "ready" ]]; then
    local hidden_owner_pid
    hidden_owner_pid=$(dx_session_runtime_field \
      "$START_UNVERIFIABLE_SESSION" pid 2>/dev/null || true)
    if [[ "$hidden_owner_pid" =~ ^[0-9]+$ ]]; then
      builtin kill -STOP "$hidden_owner_pid" 2>/dev/null || true
      printf '%s\n' "$hidden_owner_pid" > "$START_UNVERIFIABLE_PID_FILE"
    fi
    return 1
  fi
  __dx_session_runtime_call owner-read "$@"
}
__dx_session_runtime_owner_result_path() { return 1; }
__dx_session_runtime_owner_process_state() { printf '%s\n' unverifiable; }
(
  while [[ ! -s "$START_UNVERIFIABLE_PID_FILE" ]]; do sleep 0.05; done
  sleep 10
  builtin kill -CONT "$(cat "$START_UNVERIFIABLE_PID_FILE")" 2>/dev/null || true
) &
START_UNVERIFIABLE_WATCHDOG=$!
printf '%s\n' "$START_UNVERIFIABLE_WATCHDOG" \
  > "$START_UNVERIFIABLE_WATCHDOG_PID_FILE"
TEST_CHILD_PIDS="${TEST_CHILD_PIDS} ${START_UNVERIFIABLE_WATCHDOG}"
SECONDS=0
set +e
DX_SESSION_RUNTIME_OWNER_START_TIMEOUT_MILLISECONDS=500 \
  dx_session_runtime_owner_start \
    "$START_UNVERIFIABLE_SESSION" claude "$WORKSPACE" >/dev/null 2>&1
START_UNVERIFIABLE_RESULT=$?
set -e
START_UNVERIFIABLE_ELAPSED=$SECONDS
[[ "$START_UNVERIFIABLE_RESULT" -ne 0 ]] || \
  fail "unverifiable startup unexpectedly succeeded"
[[ "$START_UNVERIFIABLE_ELAPSED" -lt 10 ]] || \
  fail "unverifiable startup exceeded its bounded wait"
kill "$START_UNVERIFIABLE_WATCHDOG" 2>/dev/null || true
wait "$START_UNVERIFIABLE_WATCHDOG" 2>/dev/null || true
TEST_CHILD_PIDS="${TEST_CHILD_PIDS/ ${START_UNVERIFIABLE_WATCHDOG}/}"
# shellcheck source=lib/session-runtime.sh
source "$ROOT/lib/session-runtime.sh"
if [[ -s "$START_UNVERIFIABLE_PID_FILE" ]]; then
  START_UNVERIFIABLE_PID=$(cat "$START_UNVERIFIABLE_PID_FILE")
  builtin kill -CONT "$START_UNVERIFIABLE_PID" 2>/dev/null || true
  wait_for_runtime_field "$START_UNVERIFIABLE_SESSION" status failed
  wait "$START_UNVERIFIABLE_PID" 2>/dev/null || true
fi
unset START_UNVERIFIABLE_SESSION START_UNVERIFIABLE_PID_FILE

# Finish has the same rule: an unverifiable, stopped owner is left untouched
# and returns non-success before the watchdog would release it.
SID_FINISH_UNVERIFIABLE="runtime-owner-finish-unverifiable"
dx_session_runtime_owner_start "$SID_FINISH_UNVERIFIABLE" claude "$WORKSPACE"
FINISH_UNVERIFIABLE_HANDLE="$DX_SESSION_RUNTIME_OWNER_HANDLE"
FINISH_UNVERIFIABLE_PID="$DX_SESSION_RUNTIME_OWNER_PID"
unset DX_SESSION_RUNTIME_OWNER_HANDLE DX_SESSION_RUNTIME_OWNER_PID
builtin kill -STOP "$FINISH_UNVERIFIABLE_PID"
__dx_session_runtime_owner_process_state() { printf '%s\n' unverifiable; }
(
  sleep 10
  builtin kill -CONT "$FINISH_UNVERIFIABLE_PID" 2>/dev/null || true
) &
FINISH_UNVERIFIABLE_WATCHDOG=$!
TEST_CHILD_PIDS="${TEST_CHILD_PIDS} ${FINISH_UNVERIFIABLE_WATCHDOG}"
SECONDS=0
set +e
DX_SESSION_RUNTIME_OWNER_FINISH_TIMEOUT_MILLISECONDS=100 \
  dx_session_runtime_owner_finish "$FINISH_UNVERIFIABLE_HANDLE" completed \
    >/dev/null 2>&1
FINISH_UNVERIFIABLE_RESULT=$?
set -e
FINISH_UNVERIFIABLE_ELAPSED=$SECONDS
[[ "$FINISH_UNVERIFIABLE_RESULT" -ne 0 ]] || \
  fail "unverifiable finish unexpectedly succeeded"
[[ "$FINISH_UNVERIFIABLE_ELAPSED" -lt 10 ]] || \
  fail "unverifiable finish exceeded its bounded wait"
kill "$FINISH_UNVERIFIABLE_WATCHDOG" 2>/dev/null || true
wait "$FINISH_UNVERIFIABLE_WATCHDOG" 2>/dev/null || true
TEST_CHILD_PIDS="${TEST_CHILD_PIDS/ ${FINISH_UNVERIFIABLE_WATCHDOG}/}"
# shellcheck source=lib/session-runtime.sh
source "$ROOT/lib/session-runtime.sh"
builtin kill -CONT "$FINISH_UNVERIFIABLE_PID" 2>/dev/null || true
wait_for_runtime_field "$SID_FINISH_UNVERIFIABLE" status completed
wait "$FINISH_UNVERIFIABLE_PID" 2>/dev/null || true
__dx_session_runtime_owner_cleanup "$FINISH_UNVERIFIABLE_HANDLE"

# Finish waits are bounded. Timing out stops only the supervisor, leaving an
# unrelated provider-shaped process untouched and the lease provably dead.
SID_FINISH_TIMEOUT="runtime-owner-finish-timeout"
dx_session_runtime_owner_start "$SID_FINISH_TIMEOUT" claude "$WORKSPACE"
TIMEOUT_HANDLE="$DX_SESSION_RUNTIME_OWNER_HANDLE"
TIMEOUT_OWNER_PID="$DX_SESSION_RUNTIME_OWNER_PID"
unset DX_SESSION_RUNTIME_OWNER_HANDLE DX_SESSION_RUNTIME_OWNER_PID
sleep 30 &
UNRELATED_PROVIDER_PID=$!
TEST_CHILD_PIDS="${TEST_CHILD_PIDS} ${UNRELATED_PROVIDER_PID}"
kill -STOP "$TIMEOUT_OWNER_PID"
set +e
DX_SESSION_RUNTIME_OWNER_FINISH_TIMEOUT_MILLISECONDS=100 \
  dx_session_runtime_owner_finish "$TIMEOUT_HANDLE" stopped \
    > "$TMP_DIR/finish-timeout.out" 2> "$TMP_DIR/finish-timeout.err"
FINISH_TIMEOUT_RC=$?
set -e
[[ "$FINISH_TIMEOUT_RC" -ne 0 ]] || assert_at $LINENO
kill -0 "$UNRELATED_PROVIDER_PID" 2>/dev/null \
  || fail "runtime finish timeout signalled an unrelated provider"
assert_eq "dead" "$(dx_session_runtime_health "$SID_FINISH_TIMEOUT")" \
  "finish timeout runtime health"

printf 'session runtime owner tests passed\n'
