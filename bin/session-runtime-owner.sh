#!/usr/bin/env bash
# The supervisor handles a lease credential. Keep it out of xtrace even when
# the caller launches this script with `bash -x`.
set +x
set -euo pipefail

if [[ $# -ne 10 ]]; then
  printf '%s\n' "dex runtime owner: expected session, provider, workspace, launcher identity, and private owner identity" >&2
  exit 3
fi

SESSION_ID="$1"
PROVIDER_NAME="$2"
WORKSPACE_DIR="$3"
MONITOR_PID="$4"
MONITOR_IDENTITY="$5"
OWNER_HANDLE="$6"
OWNER_ROOT="${OWNER_HANDLE%/*}"
OWNER_ROOT_DEVICE="$7"
OWNER_ROOT_INODE="$8"
OWNER_DEVICE="$9"
OWNER_INODE="${10}"
OWNER_GENERATION="${OWNER_HANDLE##*/}"
LAUNCH_PARENT_PID="$PPID"

# shellcheck source=lib/common.sh
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

LEASE_TOKEN=""
OWNER_FINISHED=0
OWNER_FINAL_RESULT=3
HEARTBEAT_ELAPSED_MS=0
MONITOR_ELAPSED_MS=0
POLL_MILLISECONDS=50

owner_atomic_write() { # <file-name> <content>
  local file_name="$1" file_content="$2"
  case "$file_name" in
    ready|result) ;;
    *) return 1 ;;
  esac
  __dx_session_runtime_owner_trusted_write_path \
    "$OWNER_ROOT" "$OWNER_HANDLE" "$OWNER_ROOT_DEVICE" "$OWNER_ROOT_INODE" \
    "$OWNER_DEVICE" "$OWNER_INODE" "$file_name" create "$file_content"
}

owner_read_command() {
  local command_value command_generation terminal_request command_extra
  command_value=$(__dx_session_runtime_owner_trusted_read_path \
    "$OWNER_ROOT" "$OWNER_HANDLE" "$OWNER_ROOT_DEVICE" "$OWNER_ROOT_INODE" \
    "$OWNER_DEVICE" "$OWNER_INODE" command 512 2>/dev/null) || return $?
  IFS=$'\t' read -r command_generation terminal_request command_extra <<EOF
$command_value
EOF
  [[ "$command_generation" == "$OWNER_GENERATION" && -z "${command_extra:-}" ]] \
    || return 3
  case "$terminal_request" in
    completed|paused|blocked|failed|stopped|abandoned)
      printf '%s\t%s\n' "$command_generation" "$terminal_request"
      ;;
    *) return 3 ;;
  esac
}

owner_monitor_matches() {
  local observed_identity
  [[ "$PPID" == "$MONITOR_PID" ]] || return 1
  observed_identity=$(dx_session_runtime_process_identity "$MONITOR_PID" 2>/dev/null || true)
  [[ "$observed_identity" == "$MONITOR_IDENTITY" ]]
}

owner_finish() { # <terminal-status> <result-detail> <generation> [first-failure]
  local terminal_state="$1" result_detail="$2" result_generation="$3"
  local first_failure="${4:-0}" finish_result=0 final_result final_detail
  if [[ "$OWNER_FINISHED" -eq 1 ]]; then
    return "$OWNER_FINAL_RESULT"
  fi
  OWNER_FINISHED=1
  final_result="$first_failure"
  final_detail="$result_detail"
  if [[ -z "$LEASE_TOKEN" ]]; then
    [[ "$final_result" -ne 0 ]] || final_result=3
    OWNER_FINAL_RESULT="$final_result"
    owner_atomic_write result \
      "${final_result}"$'\t'"$result_generation"$'\t'failed$'\t'lease-not-started \
      2>/dev/null || true
    return "$final_result"
  fi
  dx_session_runtime_finish "$SESSION_ID" "$LEASE_TOKEN" "$terminal_state" "$$" \
    >/dev/null 2>&1 || finish_result=$?
  if [[ "$final_result" -eq 0 && "$finish_result" -ne 0 ]]; then
    final_result="$finish_result"
    final_detail="finish-failed"
  fi
  OWNER_FINAL_RESULT="$final_result"
  if ! owner_atomic_write result \
      "${final_result}"$'\t'"$result_generation"$'\t'"$terminal_state"$'\t'"$final_detail"; then
    [[ "$OWNER_FINAL_RESULT" -ne 0 ]] || OWNER_FINAL_RESULT=3
  fi
  return "$OWNER_FINAL_RESULT"
}

owner_signal() {
  local signal_result="$1"
  trap - INT TERM HUP
  owner_finish stopped "signal-${signal_result}" "$OWNER_GENERATION" \
    "$signal_result" 2>/dev/null || true
  exit "$signal_result"
}

owner_exit() {
  local owner_exit_result=$?
  trap - EXIT INT TERM HUP
  if [[ "$OWNER_FINISHED" -eq 0 && -n "$LEASE_TOKEN" ]]; then
    [[ "$owner_exit_result" -ne 0 ]] || owner_exit_result=3
    owner_finish failed unexpected-exit "$OWNER_GENERATION" \
      "$owner_exit_result" 2>/dev/null || true
  fi
  exit "$owner_exit_result"
}

trap owner_exit EXIT
trap 'owner_signal 130' INT
trap 'owner_signal 143' TERM
trap 'owner_signal 129' HUP

dx_session_id_valid "$SESSION_ID" || exit 3
[[ "$PROVIDER_NAME" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,127}$ ]] || exit 3
[[ "$WORKSPACE_DIR" == /* && -d "$WORKSPACE_DIR" ]] || exit 3
[[ "$MONITOR_PID" =~ ^[0-9]+$ ]] || exit 3
[[ "$LAUNCH_PARENT_PID" == "$MONITOR_PID" ]] || exit 3
case "$MONITOR_IDENTITY" in
  linux:*|darwin:*) ;;
  *) exit 3 ;;
esac
[[ -d "$OWNER_HANDLE" && ! -L "$OWNER_HANDLE" ]] || exit 3
[[ "$(dx_path_mode "$OWNER_HANDLE" 2>/dev/null || true)" == "700" ]] || exit 3
[[ "$OWNER_GENERATION" =~ ^[A-Za-z0-9][A-Za-z0-9._-]{0,255}$ ]] || exit 3
[[ "$OWNER_ROOT_DEVICE" =~ ^[0-9]+$ && "$OWNER_ROOT_INODE" =~ ^[0-9]+$ \
  && "$OWNER_DEVICE" =~ ^[0-9]+$ && "$OWNER_INODE" =~ ^[0-9]+$ ]] || exit 3
owner_metadata=$(__dx_session_runtime_owner_metadata \
  "$OWNER_ROOT" "$OWNER_HANDLE" 2>/dev/null) || exit 3
[[ "$owner_metadata" == "$OWNER_ROOT_DEVICE"$'\t'"$OWNER_ROOT_INODE"$'\t'"$OWNER_DEVICE"$'\t'"$OWNER_INODE" ]] \
  || exit 3
owner_monitor_matches || exit 3

HEARTBEAT_MILLISECONDS="${DX_SESSION_RUNTIME_HEARTBEAT_MILLISECONDS:-30000}"
MONITOR_MILLISECONDS="${DX_SESSION_RUNTIME_MONITOR_MILLISECONDS:-250}"
case "$HEARTBEAT_MILLISECONDS" in
  ""|*[!0-9]*) exit 3 ;;
esac
case "$MONITOR_MILLISECONDS" in
  ""|*[!0-9]*) exit 3 ;;
esac
[[ "$HEARTBEAT_MILLISECONDS" -ge 50 && "$HEARTBEAT_MILLISECONDS" -le 600000 ]] || exit 3
[[ "$MONITOR_MILLISECONDS" -ge 50 && "$MONITOR_MILLISECONDS" -le 60000 ]] || exit 3

start_result=0
token_read_result=0
token_record=""
exec 7< <(
  secure_start_result=0
  __dx_session_runtime_start_secure \
    "$SESSION_ID" "$PROVIDER_NAME" "$WORKSPACE_DIR" "$$" \
    3>&1 1>/dev/null || secure_start_result=$?
  if [[ "$secure_start_result" -ne 0 ]]; then
    printf 'start-failed\t%s\n' "$secure_start_result"
  fi
)
IFS= read -r token_record <&7 || token_read_result=$?
exec 7<&-
if [[ "$token_read_result" -eq 0 && "$token_record" =~ ^[0-9a-f]{64}$ ]]; then
  LEASE_TOKEN="$token_record"
elif [[ "$token_record" =~ ^start-failed$'\t'([0-9]+)$ ]]; then
  start_result="${BASH_REMATCH[1]}"
else
  start_result=3
fi
if [[ "$start_result" -ne 0 ]]; then
  owner_atomic_write result \
    "${start_result}"$'\t'"$OWNER_GENERATION"$'\t'failed$'\t'start-failed \
    2>/dev/null || true
  exit "$start_result"
fi
owner_identity=$(dx_session_runtime_process_identity "$$" 2>/dev/null || true)
case "$owner_identity" in
  linux:*|darwin:*) ;;
  *) owner_finish failed owner-identity-failed "$OWNER_GENERATION" 3 2>/dev/null || true; exit 3 ;;
esac
owner_atomic_write ready \
  "ready"$'\t'"$$"$'\t'"$SESSION_ID"$'\t'"$owner_identity"$'\t'"$OWNER_GENERATION" || {
  owner_finish failed ready-write-failed "$OWNER_GENERATION" 3 2>/dev/null || true
  exit 3
}

while true; do
  command_result=0
  command_record=""
  command_generation=""
  terminal_request=""
  if [[ -e "$OWNER_HANDLE/command" || -L "$OWNER_HANDLE/command" ]]; then
    command_record=$(owner_read_command 2>/dev/null) || command_result=$?
  else
    command_result=1
  fi
  if [[ "$command_result" -eq 0 ]]; then
    IFS=$'\t' read -r command_generation terminal_request <<EOF
$command_record
EOF
    owner_finish "$terminal_request" finished "$command_generation"
    exit $?
  elif [[ "$command_result" -ne 1 ]]; then
    owner_finish failed invalid-control "$OWNER_GENERATION" 3 2>/dev/null || true
    exit 3
  fi

  sleep 0.05
  HEARTBEAT_ELAPSED_MS=$((HEARTBEAT_ELAPSED_MS + POLL_MILLISECONDS))
  MONITOR_ELAPSED_MS=$((MONITOR_ELAPSED_MS + POLL_MILLISECONDS))

  if [[ "$MONITOR_ELAPSED_MS" -ge "$MONITOR_MILLISECONDS" ]]; then
    MONITOR_ELAPSED_MS=0
    if ! owner_monitor_matches; then
      owner_finish abandoned launcher-stopped "$OWNER_GENERATION" \
        2>/dev/null || true
      exit 0
    fi
  fi

  if [[ "$HEARTBEAT_ELAPSED_MS" -ge "$HEARTBEAT_MILLISECONDS" ]]; then
    HEARTBEAT_ELAPSED_MS=0
    heartbeat_result=0
    dx_session_runtime_heartbeat "$SESSION_ID" "$LEASE_TOKEN" "$$" \
      >/dev/null 2>&1 || heartbeat_result=$?
    if [[ "$heartbeat_result" -ne 0 ]]; then
      owner_finish failed heartbeat-failed "$OWNER_GENERATION" \
        "$heartbeat_result" 2>/dev/null || true
      exit "$heartbeat_result"
    fi
  fi
done
