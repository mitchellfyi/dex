#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-session-runtime-wiring.XXXXXX")"
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
  while [[ ! -s "$target_file" && "$attempt" -lt 200 ]]; do
    sleep 0.05
    attempt=$((attempt + 1))
  done
  if [[ ! -s "$target_file" && -f "${target_file%.ready}.output" ]]; then
    cat "${target_file%.ready}.output" >&2
  fi
  assert_file "$target_file"
}

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RUN_ROOT="$TMP_DIR/runs"
export DX_SESSION_RUNTIME_HEARTBEAT_MILLISECONDS=100
export DX_SESSION_RUNTIME_OWNER_START_TIMEOUT_MILLISECONDS=5000
export DX_SESSION_RUNTIME_OWNER_FINISH_TIMEOUT_MILLISECONDS=5000
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$DX_RUN_ROOT"

TEST_REPO="$TMP_DIR/repo"
git init -q "$TEST_REPO"
git -C "$TEST_REPO" config user.email test@example.com
git -C "$TEST_REPO" config user.name Test
git -C "$TEST_REPO" commit --allow-empty -qm init
TEST_REPO=$(cd "$TEST_REPO" && pwd -P)
export TEST_REPO

# Both provider routes get one supervisor for the whole callback. The callback
# sees the same public owner through its recursive work, without credentials in
# its environment or command line.
for provider_name in claude codex; do
  session_id="wiring-${provider_name}"
  trace_file="$TMP_DIR/${provider_name}.trace"
  environment_file="$TMP_DIR/${provider_name}.environment"
  arguments_file="$TMP_DIR/${provider_name}.arguments"
  output_file="$TMP_DIR/${provider_name}.output"
  if ! TEST_PROVIDER="$provider_name" TEST_SESSION_ID="$session_id" \
    TEST_TRACE_FILE="$trace_file" TEST_ENVIRONMENT_FILE="$environment_file" \
    TEST_ARGUMENTS_FILE="$arguments_file" \
    zsh -fc '
    source "$DEX_DIR/dx.sh"
    __dx_resolved_provider_agent() { print -r -- "$TEST_PROVIDER"; }
    __test_recursive_work() {
      dx_session_runtime_field "$TEST_SESSION_ID" pid >> "$TEST_TRACE_FILE"
    }
    __test_provider_callback() {
      __test_recursive_work
      __test_recursive_work
      __test_recursive_work
      command env > "$TEST_ENVIRONMENT_FILE"
      command ps -o command= -p $$ > "$TEST_ARGUMENTS_FILE"
      __dx_runtime_set_terminal completed
    }
    __dx_run_with_runtime \
      "$TEST_SESSION_ID" "$TEST_REPO" __test_provider_callback
  ' > "$output_file" 2>&1; then
    cat "$output_file" >&2
    DEX_DIR="$ROOT" DX_STATE_DIR="$DX_STATE_DIR" bash -c '
      source "$DEX_DIR/lib/common.sh"
      printf "runtime status=%s health=%s pid=%s\n" \
        "$(dx_session_runtime_field "$1" status 2>/dev/null || true)" \
        "$(dx_session_runtime_health "$1" 2>/dev/null || true)" \
        "$(dx_session_runtime_field "$1" pid 2>/dev/null || true)" >&2
    ' _ "$session_id"
    fail "$provider_name runtime wrapper fixture failed"
  fi

  owner_pid=$(head -n 1 "$trace_file")
  [[ "$owner_pid" =~ ^[0-9]+$ ]] || assert_at $LINENO
  assert_eq "3" "$(grep -Fxc "$owner_pid" "$trace_file")" \
    "$provider_name recursive owner count"
  assert_eq "$provider_name" \
    "$(DEX_DIR="$ROOT" DX_STATE_DIR="$DX_STATE_DIR" bash -c \
      'source "$DEX_DIR/lib/common.sh"; dx_session_runtime_field "$1" provider' \
      _ "$session_id")" "$provider_name runtime provider"
  assert_eq "completed" \
    "$(DEX_DIR="$ROOT" DX_STATE_DIR="$DX_STATE_DIR" bash -c \
      'source "$DEX_DIR/lib/common.sh"; dx_session_runtime_field "$1" status' \
      _ "$session_id")" "$provider_name terminal status"
  lease_token=$(python3 - "$DX_STATE_DIR/${session_id}.runtime" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as handle:
    print(json.load(handle)["token"])
PY
)
  assert_not_contains "$lease_token" "$output_file"
  assert_not_contains "$lease_token" "$environment_file"
  assert_not_contains "$lease_token" "$arguments_file"
done

# Contention is resolved before the callback can launch any provider work.
CONTENTION_SENTINEL="$TMP_DIR/contention-provider-started"
export CONTENTION_SENTINEL
if TEST_SESSION_ID=wiring-contention zsh -fc '
    source "$DEX_DIR/dx.sh"
    __dx_resolved_provider_agent() { print -r -- claude; }
    __test_must_not_run() { touch "$CONTENTION_SENTINEL"; }
    dx_session_runtime_owner_start "$TEST_SESSION_ID" claude "$TEST_REPO" || return 90
    first_owner_handle="$DX_SESSION_RUNTIME_OWNER_HANDLE"
    unset DX_SESSION_RUNTIME_OWNER_HANDLE DX_SESSION_RUNTIME_OWNER_PID
    wrapper_result=0
    __dx_run_with_runtime \
      "$TEST_SESSION_ID" "$TEST_REPO" __test_must_not_run || wrapper_result=$?
    dx_session_runtime_owner_finish "$first_owner_handle" paused || return 91
    [[ "$wrapper_result" -ne 0 ]] || return 92
  ' > "$TMP_DIR/contention.output" 2>&1; then
  :
else
  cat "$TMP_DIR/contention.output" >&2
  fail "runtime contention fixture failed"
fi
assert_no_file "$CONTENTION_SENTINEL"
assert_contains "Another Dex runtime already owns this checkout" \
  "$TMP_DIR/contention.output"

# Denying writes to the state directory makes terminal publication fail without
# racing the supervisor heartbeat, which can legitimately replace the record.
finish_failure_result=0
TEST_SESSION_ID=wiring-finish-failure zsh -fc '
    source "$DEX_DIR/dx.sh"
    __dx_resolved_provider_agent() { print -r -- codex; }
    __test_deny_terminal_publish() {
      chmod 500 "$DX_STATE_DIR"
      __dx_runtime_set_terminal completed
    }
    __dx_run_with_runtime \
      "$TEST_SESSION_ID" "$TEST_REPO" __test_deny_terminal_publish
  ' > "$TMP_DIR/finish-failure.output" 2>&1 || finish_failure_result=$?
chmod 700 "$DX_STATE_DIR"
if [[ "$finish_failure_result" -eq 0 ]]; then
  fail "runtime finish failure was accepted as success"
fi
assert_contains "could not close the runtime lease safely" \
  "$TMP_DIR/finish-failure.output"

# A TERM delivered after the callback announces readiness must win even when
# the callback's busy loop would otherwise let zsh report success.
# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"
for signal_attempt in 1 2 3 4 5 6 7 8; do
  signal_session_id="wiring-signal-${signal_attempt}"
  SIGNAL_READY="$TMP_DIR/signal-${signal_attempt}.ready"
  export SIGNAL_READY
  TEST_SESSION_ID="$signal_session_id" zsh -fc '
    source "$DEX_DIR/dx.sh"
    __dx_resolved_provider_agent() { print -r -- claude; }
    __test_wait_for_signal() {
      print -r -- ready > "$SIGNAL_READY"
      while true; do :; done
    }
    __dx_run_with_runtime \
      "$TEST_SESSION_ID" "$TEST_REPO" __test_wait_for_signal
  ' > "$TMP_DIR/signal-${signal_attempt}.output" 2>&1 &
  SIGNAL_PID=$!
  TEST_CHILD_PIDS="${TEST_CHILD_PIDS} ${SIGNAL_PID}"
  wait_for_file "$SIGNAL_READY"
  kill -TERM "$SIGNAL_PID"
  set +e
  wait "$SIGNAL_PID"
  SIGNAL_RESULT=$?
  set -e
  assert_eq "143" "$SIGNAL_RESULT" \
    "signalled wrapper result attempt ${signal_attempt}"
  TEST_CHILD_PIDS="${TEST_CHILD_PIDS/ ${SIGNAL_PID}/}"

  assert_eq "stopped" "$(dx_session_runtime_field "$signal_session_id" status)" \
    "signalled wrapper status attempt ${signal_attempt}"
  assert_eq "dead" "$(dx_session_runtime_health "$signal_session_id")" \
    "signalled wrapper health attempt ${signal_attempt}"
done

# Interactive zsh normally announces every background child as "[job] pid".
# The lifecycle wrapper must hide its internal supervisor while preserving the
# caller's job-control setting.
python3 - "$ROOT/dx.sh" <<'PY'
import errno
import os
import pty
import re
import shlex
import sys

dx_path = shlex.quote(sys.argv[1])
command = f'''
source {dx_path}
__dx_resolved_provider_agent() {{ print -r -- codex; }}
__dx_startup_claim_release() {{ return 0; }}
dx_session_runtime_owner_start() {{
  sleep 0.1 &
  DX_SESSION_RUNTIME_OWNER_PID=$!
  DX_SESSION_RUNTIME_OWNER_HANDLE=test-handle
}}
__dx_run_with_runtime_owner_handle() {{
  local owner_pid=$2 callback_name=$3
  shift 3
  "$callback_name" "$@"
  local callback_result=$?
  wait "$owner_pid"
  return "$callback_result"
}}
__test_runtime_callback() {{ print -r -- "inside:$options[monitor]"; }}
print -r -- "before:$options[monitor]"
__dx_run_with_runtime session /tmp __test_runtime_callback
print -r -- "after:$options[monitor]"
'''

child_pid, master_fd = pty.fork()
if child_pid == 0:
    os.execvp("zsh", ["zsh", "-fic", command])

chunks = []
while True:
    try:
        data = os.read(master_fd, 4096)
    except OSError as exc:
        if exc.errno == errno.EIO:
            break
        raise
    if not data:
        break
    chunks.append(data)
os.close(master_fd)
_, wait_status = os.waitpid(child_pid, 0)
output = b"".join(chunks).decode("utf-8", errors="replace")
exit_code = os.waitstatus_to_exitcode(wait_status)

if exit_code != 0:
    raise SystemExit(f"interactive runtime fixture failed ({exit_code}):\n{output}")
if "before:on" not in output or "inside:off" not in output or "after:on" not in output:
    raise SystemExit(f"runtime wrapper did not scope job control correctly:\n{output}")
if re.search(r"(?m)^\[[0-9]+\]", output):
    raise SystemExit(f"runtime wrapper leaked a zsh job notice:\n{output}")
PY

printf 'session runtime wiring tests passed\n'
