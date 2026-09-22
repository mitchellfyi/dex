#!/usr/bin/env bash
set -euo pipefail

# Session process ownership: a process started inside a session cannot outlive
# it, however it was launched. A fake provider stands in for the lifecycle
# provider — it takes ownership the way dx.sh does at its launch site — and
# then leaves work behind the three ways an agent actually does: a backgrounded
# `nohup` that is then disowned, a new session started by a runtime that closes
# inherited descriptors, and `setsid` where the host has it.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-session-process-test.XXXXXX")"

cleanup() {
  local stray
  if [[ -d "$TMP_DIR" ]]; then
    while IFS= read -r stray; do
      [[ "$stray" =~ ^[0-9]+$ ]] || continue
      kill -KILL "$stray" 2>/dev/null || true
    done < <(find "$TMP_DIR" -type f -name '*.pid' -exec cat {} \; 2>/dev/null || true)
    rm -rf "$TMP_DIR"
  fi
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$DX_RUN_ROOT"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

wait_for_file() {
  local file="$1" label="$2" attempt=0
  while [[ ! -s "$file" && $attempt -lt 200 ]]; do
    /bin/sleep 0.05
    attempt=$((attempt + 1))
  done
  [[ -s "$file" ]] || fail "$label: $file was never written"
}

assert_gone() {
  local pid="$1" label="$2" attempt=0
  while kill -0 "$pid" 2>/dev/null && [[ $attempt -lt 200 ]]; do
    /bin/sleep 0.05
    attempt=$((attempt + 1))
  done
  if kill -0 "$pid" 2>/dev/null; then
    kill -KILL "$pid" 2>/dev/null || true
    fail "$label: process $pid survived the session"
  fi
}

carries() {
  local session_id="$1" pid="$2"
  case " $(dx_session_process_carriers "$session_id" | tr '\n' ' ') " in
    *" $pid "*) return 0 ;;
  esac
  return 1
}

# A provider stand-in. It owns its descendants the same way the lifecycle
# launch site does: attach inside the subshell that runs the session, so the
# token descriptor and the exported variable reach every child.
FAKE_PROVIDER="$TMP_DIR/fake-provider.sh"
cat > "$FAKE_PROVIDER" <<'PROVIDER'
#!/usr/bin/env bash
set -euo pipefail
# shellcheck disable=SC1091
source "$DEX_DIR/lib/common.sh"
provider_session="$1"
report_dir="$2"
(
  dx_session_process_token_attach "$provider_session"
  printf '%s\n' "$DX_SESSION_TMP" > "$report_dir/session-tmp"
  printf '%s\n' "$DX_SESSION_PROCESS_TOKEN" > "$report_dir/token-in-env"
  nohup /bin/sleep 300 > /dev/null 2>&1 &
  printf '%s\n' "$!" > "$report_dir/nohup.pid"
  disown 2>/dev/null || true
  # A runtime that starts a new session and closes inherited descriptors. The
  # exported token is the channel that still reaches it.
  python3 -c 'import subprocess, sys; print(subprocess.Popen([sys.executable, "-c", "import time; time.sleep(300)"], start_new_session=True).pid)' \
    > "$report_dir/new-session.pid"
  if command -v setsid > /dev/null 2>&1; then
    setsid /bin/sleep 300 > /dev/null 2>&1 &
    printf '%s\n' "$!" > "$report_dir/setsid.pid"
  else
    printf 'skip: setsid is not installed on this host; the nohup and new-session cases still cover detachment\n'
  fi
  /bin/sleep 300
) &
printf '%s\n' "$!" > "$report_dir/holder.pid"
PROVIDER
chmod +x "$FAKE_PROVIDER"

SESSION_ID="process-ownership-test"
RUN_ID="$(dx_run_prepare "$SESSION_ID" "$ROOT" "test" "session-process-ownership" \
  "issue-1" "dx test")"
[[ -n "$RUN_ID" ]] || assert_at $LINENO
printf '0:100\n' > "$(dx_times_file "$SESSION_ID")"

bash "$FAKE_PROVIDER" "$SESSION_ID" "$TMP_DIR" > "$TMP_DIR/provider.out" 2>&1
wait_for_file "$TMP_DIR/holder.pid" "fake provider"
wait_for_file "$TMP_DIR/nohup.pid" "nohup survivor"
wait_for_file "$TMP_DIR/new-session.pid" "new-session survivor"
wait_for_file "$TMP_DIR/session-tmp" "session temp root"

HOLDER_PID="$(cat "$TMP_DIR/holder.pid")"
NOHUP_PID="$(cat "$TMP_DIR/nohup.pid")"
NEW_SESSION_PID="$(cat "$TMP_DIR/new-session.pid")"
SETSID_PID=""
if [[ -s "$TMP_DIR/setsid.pid" ]]; then
  SETSID_PID="$(cat "$TMP_DIR/setsid.pid")"
else
  printf 'skip: no setsid on this host, so the setsid spawn form is not exercised\n'
fi

# The token lives where the SessionEnd hook can find it from the session ID
# alone, and the temp root lives beside it.
TOKEN_FILE="$(dx_session_process_token_file "$SESSION_ID")"
assert_file "$TOKEN_FILE"
assert_dir "$(dx_session_tmp_dir "$SESSION_ID")"
assert_eq "$(dx_session_tmp_dir "$SESSION_ID")" "$(cat "$TMP_DIR/session-tmp")" \
  "DX_SESSION_TMP"
assert_eq "$(cat "$TOKEN_FILE")" "$(cat "$TMP_DIR/token-in-env")" \
  "DX_SESSION_PROCESS_TOKEN"
assert_eq "$HOLDER_PID" "$(dx_session_process_holder_pid "$SESSION_ID")" "holder pid"

# Which channel the host used is recorded, so a Linux box quietly falling back
# to `lsof` — which a headless server often does not have — fails here rather
# than in production.
dx_session_process_carriers "$SESSION_ID" "$TMP_DIR/method" > /dev/null
assert_file "$TMP_DIR/method"
SCAN_METHOD="$(cat "$TMP_DIR/method")"
case "$(uname -s)" in
  Linux) assert_eq "proc" "$SCAN_METHOD" "Linux ownership scan method" ;;
  Darwin) assert_eq "libproc" "$SCAN_METHOD" "macOS ownership scan method" ;;
  *)
    printf 'skip: %s has no first-choice scan; expecting the lsof fallback\n' \
      "$(uname -s)"
    assert_eq "lsof" "$SCAN_METHOD" "fallback ownership scan method"
    ;;
esac

carries "$SESSION_ID" "$NOHUP_PID" || assert_at $LINENO
carries "$SESSION_ID" "$NEW_SESSION_PID" || assert_at $LINENO
carries "$SESSION_ID" "$HOLDER_PID" || assert_at $LINENO
if [[ -n "$SETSID_PID" ]]; then
  carries "$SESSION_ID" "$SETSID_PID" || assert_at $LINENO
fi

# Every owned process is described before anything is signalled, because the
# reap log is the only record of what was stopped.
dx_session_process_describe "$NOHUP_PID" > "$TMP_DIR/describe.tsv"
assert_contains "$NOHUP_PID" "$TMP_DIR/describe.tsv"
assert_contains "sleep" "$TMP_DIR/describe.tsv"

# ── Session end stops all of it ─────────────────────────────────────────────
printf '%s\n' '{"session_id":"process-ownership-provider"}' \
  | env DEX_SESSION_ID="$SESSION_ID" bash "$ROOT/hooks/session-end.sh" \
    > "$TMP_DIR/session-end.out" 2>&1

assert_gone "$NOHUP_PID" "nohup survivor"
assert_gone "$NEW_SESSION_PID" "new-session survivor"
assert_gone "$HOLDER_PID" "provider holder"
[[ -n "$SETSID_PID" ]] && assert_gone "$SETSID_PID" "setsid survivor"

# The temp root goes with the session, and only after the reaper has run.
[[ ! -d "$(dx_session_process_dir "$SESSION_ID")" ]] || assert_at $LINENO
grep -q '^end:[0-9][0-9]*$' "$(dx_times_file "$SESSION_ID")" || assert_at $LINENO

# ── The reap is in the session's event log ──────────────────────────────────
EVENTS_FILE="$(dx_run_events_file "$RUN_ID")"
assert_file "$EVENTS_FILE"
assert_contains '"type":"session.reaped"' "$EVENTS_FILE"
assert_contains '"type":"session.reap.completed"' "$EVENTS_FILE"
assert_contains '"reason":"session-end"' "$EVENTS_FILE"
REAPED_COUNT=$(grep -c '"type":"session.reaped"' "$EVENTS_FILE" | tr -d '[:space:]')
[[ "$REAPED_COUNT" -ge 3 ]] || fail "expected at least 3 reap events, got $REAPED_COUNT"
# pid, command, age, RSS and the scan method, per reaped process.
python3 - "$EVENTS_FILE" <<'PY'
import json
import sys

required = {"pid", "ppid", "age_seconds", "rss_kb", "cwd", "command", "method", "reason"}
methods = {"proc", "libproc", "lsof"}
seen = 0
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        event = json.loads(line)
        if event.get("type") != "session.reaped":
            continue
        seen += 1
        data = event.get("data", {})
        missing = required - set(data)
        assert not missing, f"session.reaped is missing {sorted(missing)}"
        assert isinstance(data["pid"], int), data
        assert data["command"], data
        assert data["method"] in methods, data
assert seen, "no session.reaped events were emitted"
summary_total = 0
with open(sys.argv[1], encoding="utf-8") as handle:
    for line in handle:
        line = line.strip()
        if not line:
            continue
        event = json.loads(line)
        if event.get("type") != "session.reap.completed":
            continue
        data = event.get("data", {})
        assert data.get("scope") == "session", data
        assert data.get("reaped", 0) >= 1, data
        assert data.get("candidates", 0) >= data.get("reaped", 0), data
        summary_total += 1
assert summary_total == 1, f"expected one summary event, got {summary_total}"
print("reap events carry pid, command, age, RSS and scan method")
PY

# ── A reap pass never stops itself ──────────────────────────────────────────
# The SessionEnd hook, the provider above it, and the shell holding the token
# all carry the token. Excluding the caller's own ancestry is what keeps the
# pass from ending before it finishes.
SELF_SESSION="process-ownership-self-test"
(
  dx_session_process_token_attach "$SELF_SESSION"
  nohup /bin/sleep 300 > /dev/null 2>&1 &
  printf '%s\n' "$!" > "$TMP_DIR/self-child.pid"
  disown 2>/dev/null || true
  /bin/sleep 0.3
  dx_session_reap_processes "$SELF_SESSION" session-end > "$TMP_DIR/self-reap.out"
  printf 'survived\n' > "$TMP_DIR/self-alive"
)
assert_contains "survived" "$TMP_DIR/self-alive"
assert_contains "reaped pid=$(cat "$TMP_DIR/self-child.pid")" "$TMP_DIR/self-reap.out"
assert_gone "$(cat "$TMP_DIR/self-child.pid")" "self-reap child"

# ── The per-command timeout token does not disturb the session token ────────
# dx_run_with_timeout re-opens fd 9 for every command it supervises. The
# session owns fd 8 instead, so a timed command inside a session cannot take
# the session's processes with it when it cleans up after itself.
TIMEOUT_SESSION="process-ownership-timeout-test"
(
  dx_session_process_token_attach "$TIMEOUT_SESSION"
  nohup /bin/sleep 300 > /dev/null 2>&1 &
  printf '%s\n' "$!" > "$TMP_DIR/session-child.pid"
  disown 2>/dev/null || true
  /bin/sleep 0.3
  dx_run_with_timeout 10 /bin/sh -c \
    'nohup /bin/sleep 300 >/dev/null 2>&1 & printf "%s\n" "$!" > "$1"; exit 0' \
    _ "$TMP_DIR/timeout-child.pid"
  printf '%s\n' "${DX_SESSION_PROCESS_TOKEN:-unset}" > "$TMP_DIR/token-after-timeout"
  printf '%s\n' "${DX_TIMEOUT_PROCESS_TOKEN:-unset}" > "$TMP_DIR/timeout-token-leak"
)
wait_for_file "$TMP_DIR/timeout-child.pid" "timed command child"
assert_eq "$(cat "$(dx_session_process_token_file "$TIMEOUT_SESSION")")" \
  "$(cat "$TMP_DIR/token-after-timeout")" "session token after a timed command"
assert_eq "unset" "$(cat "$TMP_DIR/timeout-token-leak")" "timeout token scope"
# The timed command's own leftover is the timeout's to stop.
assert_gone "$(cat "$TMP_DIR/timeout-child.pid")" "timed command child"
# The session's process is not, and is still owned.
SESSION_CHILD="$(cat "$TMP_DIR/session-child.pid")"
kill -0 "$SESSION_CHILD" 2>/dev/null || fail "the timed command reaped a session process"
carries "$TIMEOUT_SESSION" "$SESSION_CHILD" || assert_at $LINENO
dx_session_reap_processes "$TIMEOUT_SESSION" session-end > "$TMP_DIR/timeout-reap.out"
assert_gone "$SESSION_CHILD" "session process after its own reap"

# ── A process that will not stop keeps its token ────────────────────────────
# Reporting a survivor as stopped and then deleting the token throws away the
# only way to find that process again. KILL cannot be ignored, so the
# terminator is stubbed out to produce a survivor deterministically.
SURVIVOR_SESSION="process-ownership-survivor-test"
(
  dx_session_process_token_attach "$SURVIVOR_SESSION"
  nohup /bin/sleep 300 > /dev/null 2>&1 &
  printf '%s\n' "$!" > "$TMP_DIR/survivor-child.pid"
  disown 2>/dev/null || true
  /bin/sleep 0.3
)
wait_for_file "$TMP_DIR/survivor-child.pid" "survivor child"
SURVIVOR_PID="$(cat "$TMP_DIR/survivor-child.pid")"
(
  __dx_timeout_terminate_processes() { return 0; }
  survivor_status=0
  dx_session_finish_processes "$SURVIVOR_SESSION" session-end \
    > "$TMP_DIR/survivor.out" 2> "$TMP_DIR/survivor.err" || survivor_status=$?
  printf '%s\n' "$survivor_status" > "$TMP_DIR/survivor.status"
)
assert_eq "1" "$(cat "$TMP_DIR/survivor.status")" "finish status with a survivor"
assert_contains "survived pid=$SURVIVOR_PID" "$TMP_DIR/survivor.err"
assert_contains "keeping its process token" "$TMP_DIR/survivor.err"
assert_not_contains "reaped pid=$SURVIVOR_PID" "$TMP_DIR/survivor.out"
assert_file "$(dx_session_process_token_file "$SURVIVOR_SESSION")"
assert_dir "$(dx_session_tmp_dir "$SURVIVOR_SESSION")"
# No event for a process that is still running.
assert_not_contains "Reaped session-owned process $SURVIVOR_PID" "$EVENTS_FILE"
# With the real terminator the same session finishes and hands back its token.
dx_session_finish_processes "$SURVIVOR_SESSION" session-end \
  > "$TMP_DIR/survivor-retry.out" 2>&1
assert_contains "reaped pid=$SURVIVOR_PID" "$TMP_DIR/survivor-retry.out"
assert_gone "$SURVIVOR_PID" "survivor child"
[[ ! -d "$(dx_session_process_dir "$SURVIVOR_SESSION")" ]] || assert_at $LINENO

# ── A host that cannot scan keeps the token too ─────────────────────────────
# An empty scan result from a host with no /proc, no libproc and no lsof is
# not "nothing is running". Reading it as clean would delete the token.
UNSCANNABLE_SESSION="process-ownership-unscannable-test"
(
  dx_session_process_token_attach "$UNSCANNABLE_SESSION"
  /bin/sleep 0.2
)
(
  dx_session_process_carriers() {
    [[ -n "${2:-}" ]] && printf 'unavailable\n' > "$2"
    return 0
  }
  unscannable_status=0
  dx_session_finish_processes "$UNSCANNABLE_SESSION" session-end \
    > "$TMP_DIR/unscannable.out" 2> "$TMP_DIR/unscannable.err" \
    || unscannable_status=$?
  printf '%s\n' "$unscannable_status" > "$TMP_DIR/unscannable.status"
)
assert_eq "1" "$(cat "$TMP_DIR/unscannable.status")" "finish status with no scan"
assert_contains "no ownership scan on this host" "$TMP_DIR/unscannable.err"
assert_file "$(dx_session_process_token_file "$UNSCANNABLE_SESSION")"
dx_session_finish_processes "$UNSCANNABLE_SESSION" session-end > /dev/null 2>&1
[[ ! -d "$(dx_session_process_dir "$UNSCANNABLE_SESSION")" ]] || assert_at $LINENO

# ── An lsof that fails is "unavailable", not "nothing is running" ───────────
# The lsof fallback used to hand back an empty set when the command itself
# failed, and the caller then recorded the method as `lsof` and read the empty
# set as a clean host — which deletes the token. DX_TOKEN_SCAN_METHOD=lsof
# reaches the fallback on a host whose first-choice scan works.
LSOF_FAIL_SESSION="process-ownership-lsof-fail-test"
LSOF_FAIL_BIN="$TMP_DIR/lsof-fail-bin"
mkdir -p "$LSOF_FAIL_BIN"
cat > "$LSOF_FAIL_BIN/lsof" <<'STUB'
#!/usr/bin/env bash
printf 'lsof: injected failure\n' >&2
exit 1
STUB
chmod +x "$LSOF_FAIL_BIN/lsof"
(
  dx_session_process_token_attach "$LSOF_FAIL_SESSION"
  nohup /bin/sleep 300 > /dev/null 2>&1 &
  printf '%s\n' "$!" > "$TMP_DIR/lsof-fail-child.pid"
)
wait_for_file "$TMP_DIR/lsof-fail-child.pid" "lsof-fail carrier"
LSOF_FAIL_CHILD=$(cat "$TMP_DIR/lsof-fail-child.pid")
PATH="$LSOF_FAIL_BIN:$PATH" DX_TOKEN_SCAN_METHOD=lsof \
  dx_session_process_carriers "$LSOF_FAIL_SESSION" "$TMP_DIR/lsof-fail.method" \
  > "$TMP_DIR/lsof-fail.pids"
assert_eq "unavailable" "$(cat "$TMP_DIR/lsof-fail.method")" "a failing lsof is not a scan"
[[ ! -s "$TMP_DIR/lsof-fail.pids" ]] || assert_at $LINENO
(
  lsof_fail_status=0
  PATH="$LSOF_FAIL_BIN:$PATH" DX_TOKEN_SCAN_METHOD=lsof \
    dx_session_finish_processes "$LSOF_FAIL_SESSION" session-end \
    > "$TMP_DIR/lsof-fail.out" 2> "$TMP_DIR/lsof-fail.err" || lsof_fail_status=$?
  printf '%s\n' "$lsof_fail_status" > "$TMP_DIR/lsof-fail.status"
)
assert_eq "1" "$(cat "$TMP_DIR/lsof-fail.status")" "finish status with a failing lsof"
assert_contains "no ownership scan on this host" "$TMP_DIR/lsof-fail.err"
assert_file "$(dx_session_process_token_file "$LSOF_FAIL_SESSION")"
kill -0 "$LSOF_FAIL_CHILD" 2>/dev/null \
  || fail "the carrier was stopped by a scan that failed"
# The real lsof, when it is the method, finds the carrier and says so.
if command -v lsof >/dev/null 2>&1; then
  DX_TOKEN_SCAN_METHOD=lsof dx_session_process_carriers "$LSOF_FAIL_SESSION" \
    "$TMP_DIR/lsof-real.method" > "$TMP_DIR/lsof-real.pids"
  assert_eq "lsof" "$(cat "$TMP_DIR/lsof-real.method")" "the forced lsof method is recorded"
  assert_contains "$LSOF_FAIL_CHILD" "$TMP_DIR/lsof-real.pids"
else
  printf 'skip: no lsof on this host; the forced-lsof positive case is not exercised\n'
fi
dx_session_finish_processes "$LSOF_FAIL_SESSION" session-end > /dev/null 2>&1 || true
assert_gone "$LSOF_FAIL_CHILD" "lsof-fail carrier"

# ── Removing session state stops nothing ────────────────────────────────────
# dx_cleanup_session has ~20 callers, including a stale-file sweep that can
# name a session which is not finished. It removes files and says what it left.
CLEANUP_SESSION="process-ownership-state-cleanup-test"
(
  dx_session_process_token_attach "$CLEANUP_SESSION"
  nohup /bin/sleep 300 > /dev/null 2>&1 &
  printf '%s\n' "$!" > "$TMP_DIR/cleanup-child.pid"
  disown 2>/dev/null || true
  /bin/sleep 0.3
)
wait_for_file "$TMP_DIR/cleanup-child.pid" "state-cleanup child"
CLEANUP_PID="$(cat "$TMP_DIR/cleanup-child.pid")"
printf '2\n' > "$(dx_state_file "$CLEANUP_SESSION")"
dx_cleanup_session "$CLEANUP_SESSION" > "$TMP_DIR/state-cleanup.out" \
  2> "$TMP_DIR/state-cleanup.err" || true
assert_no_file "$(dx_state_file "$CLEANUP_SESSION")"
kill -0 "$CLEANUP_PID" 2>/dev/null || fail "dx_cleanup_session stopped a process"
assert_file "$(dx_session_process_token_file "$CLEANUP_SESSION")"
assert_contains "may still own processes" "$TMP_DIR/state-cleanup.err"
assert_contains "dx ps" "$TMP_DIR/state-cleanup.err"
dx_session_finish_processes "$CLEANUP_SESSION" session-end > /dev/null 2>&1
assert_gone "$CLEANUP_PID" "state-cleanup child"

# ── A session that never took ownership costs nothing ───────────────────────
dx_session_reap_processes "unowned-session-test" session-end > "$TMP_DIR/unowned.out"
[[ ! -s "$TMP_DIR/unowned.out" ]] || assert_at $LINENO
dx_session_process_cleanup "unowned-session-test"

# Invalid input is rejected rather than guessed at.
assert_rejected "empty session id" dx_session_reap_processes "" session-end
assert_rejected "unsupported scope" \
  dx_session_reap_processes "process-ownership-test" session-end nonsense
assert_rejected "unsafe reason" \
  dx_session_reap_processes "process-ownership-test" "../escape"

# ── The advisory guard reads the launch form, not a keyword ─────────────────
guard_verdict() {
  local command_text="$1" payload guard_out
  payload=$(python3 -c 'import json,sys; print(json.dumps({"tool_input":{"command":sys.argv[1]}}))' \
    "$command_text")
  set +e
  guard_out=$(printf '%s' "$payload" \
    | env DEX_GUARD_EVENT=bash python3 "$ROOT/hooks/guard-handler.py" 2>&1)
  set -e
  case "$guard_out" in
    *warn-detached-processes*) printf 'fires\n' ;;
    *) printf 'quiet\n' ;;
  esac
}

assert_eq "fires" "$(guard_verdict 'nohup npm run dev &')" "nohup advisory"
assert_eq "fires" "$(guard_verdict 'setsid ./server')" "setsid advisory"
assert_eq "fires" "$(guard_verdict 'npm test > log 2>&1 &')" "background advisory"
assert_eq "fires" "$(guard_verdict 'kill %1; disown')" "disown advisory"
assert_eq "fires" "$(guard_verdict 'bash -c "nohup ./server &"')" "nested advisory"
assert_eq "quiet" "$(guard_verdict '/bin/sleep 1 & wait')" "waited background"
assert_eq "quiet" "$(guard_verdict 'echo hi >&2')" "stderr redirect"
assert_eq "quiet" "$(guard_verdict 'npm test &> /tmp/log')" "combined redirect"
assert_eq "quiet" "$(guard_verdict 'echo a && echo b')" "and-list"
assert_eq "quiet" "$(guard_verdict 'grep -r "a&b" .')" "quoted ampersand"
assert_eq "quiet" "$(guard_verdict 'git log --oneline -5')" "ordinary command"

# ── The dx control reap path ────────────────────────────────────────────────
# `stop` and `cancel` end the lifecycle, so they stop what it detached — but
# only that: `detached` scope spares the live provider tree, and the token
# stays because the session still owns it. `pause` and `detach` stop nothing.
CONTROL_REPO="$TMP_DIR/control-repo"
git init -q "$CONTROL_REPO"
git -C "$CONTROL_REPO" config user.email test@example.com
git -C "$CONTROL_REPO" config user.name Test
git -C "$CONTROL_REPO" commit --allow-empty -qm init
cd "$CONTROL_REPO"

control_fixture() { # <session_id> <label>
  local fixture_session="$1" label="$2" generation
  printf '%s\n' 2 > "$(dx_state_file "$fixture_session")"
  printf '%s\n' inline > "$(dx_handoff_mode_file "$fixture_session")"
  generation=$(dx_completion_issue "$fixture_session" lifecycle phase 2)
  printf '2:PHASE_2_COMPLETE:%s/prompts/phase-audits/2-implement.md:1:lifecycle:phase:%s\n' \
    "$ROOT" "$generation" > "$(dx_loop_config_file "$fixture_session")"
  touch "$(dx_active_file "$fixture_session")"
  printf '%s\n' claude-owner > "$(dx_owner_file "$fixture_session")"
  bash "$FAKE_PROVIDER" "$fixture_session" "$TMP_DIR/$label"
  wait_for_file "$TMP_DIR/$label/holder.pid" "$label provider"
  wait_for_file "$TMP_DIR/$label/nohup.pid" "$label detached process"
  wait_for_file "$TMP_DIR/$label/new-session.pid" "$label escaped process"
}

mkdir -p "$TMP_DIR/control-stop" "$TMP_DIR/control-pause"

# control.sh requires a session that belongs to this repository.
STOP_SESSION="$(dx_session_repo_key)-process-control-stop"
control_fixture "$STOP_SESSION" control-stop
STOP_HOLDER="$(cat "$TMP_DIR/control-stop/holder.pid")"
STOP_IN_TREE="$(cat "$TMP_DIR/control-stop/nohup.pid")"
STOP_ESCAPED="$(cat "$TMP_DIR/control-stop/new-session.pid")"
env DEX_SESSION_ID="$STOP_SESSION" bash "$ROOT/bin/control.sh" stop \
  > "$TMP_DIR/control-stop.out" 2>&1
assert_contains "cancel accepted" "$TMP_DIR/control-stop.out"
# What `detached` means, exactly: the process that started its own session is
# outside the provider's tree and stops here.
assert_contains "${STOP_SESSION}: reaped pid=${STOP_ESCAPED}" \
  "$TMP_DIR/control-stop.out"
assert_gone "$STOP_ESCAPED" "control stop escaped process"
# The live provider and the background job still inside its tree are what
# "the workspace and phase state are preserved" means here.
kill -0 "$STOP_HOLDER" 2>/dev/null || fail "dx control stop killed the live provider"
kill -0 "$STOP_IN_TREE" 2>/dev/null \
  || fail "dx control stop killed a job inside the live provider tree"
assert_not_contains "pid=${STOP_HOLDER}" "$TMP_DIR/control-stop.out"
assert_not_contains "pid=${STOP_IN_TREE}" "$TMP_DIR/control-stop.out"
# A detached pass owns processes by definition, so it keeps the token.
assert_file "$(dx_session_process_token_file "$STOP_SESSION")"
# The session's own end still gets the rest.
kill -KILL "$STOP_HOLDER" 2>/dev/null || true
dx_session_finish_processes "$STOP_SESSION" session-end \
  > "$TMP_DIR/control-stop-end.out" 2>&1 || true
assert_contains "reaped pid=${STOP_IN_TREE}" "$TMP_DIR/control-stop-end.out"
assert_gone "$STOP_IN_TREE" "control stop in-tree job at session end"
[[ ! -d "$(dx_session_process_dir "$STOP_SESSION")" ]] || assert_at $LINENO

PAUSE_SESSION="$(dx_session_repo_key)-process-control-pause"
control_fixture "$PAUSE_SESSION" control-pause
PAUSE_HOLDER="$(cat "$TMP_DIR/control-pause/holder.pid")"
PAUSE_IN_TREE="$(cat "$TMP_DIR/control-pause/nohup.pid")"
PAUSE_ESCAPED="$(cat "$TMP_DIR/control-pause/new-session.pid")"
env DEX_SESSION_ID="$PAUSE_SESSION" bash "$ROOT/bin/control.sh" pause \
  > "$TMP_DIR/control-pause.out" 2>&1
assert_contains "pause accepted" "$TMP_DIR/control-pause.out"
assert_not_contains "reaped pid=" "$TMP_DIR/control-pause.out"
# Pause is resumable, so it ends nothing — not even the process that already
# escaped the provider's tree, which `stop` does end.
kill -0 "$PAUSE_ESCAPED" 2>/dev/null || fail "dx control pause stopped an escaped process"
kill -0 "$PAUSE_IN_TREE" 2>/dev/null || fail "dx control pause stopped a process"
kill -0 "$PAUSE_HOLDER" 2>/dev/null || fail "dx control pause stopped the provider"
kill -KILL "$PAUSE_HOLDER" 2>/dev/null || true
dx_session_finish_processes "$PAUSE_SESSION" session-end > /dev/null 2>&1 || true
assert_gone "$PAUSE_ESCAPED" "paused session's escaped process at session end"
assert_gone "$PAUSE_IN_TREE" "paused session's background job at session end"

# ── The phase-exit reap path ────────────────────────────────────────────────
# A provider returning is the normal end of a phase, and it is the path a
# provider with no SessionEnd hook relies on. This drives the real launch
# site: __dx_run_phases_inline attaches the token, the stubbed provider leaves
# a detached process behind, and the reap after the provider returns must stop
# it. dx.sh is zsh-only, so this runs under zsh the way
# tests/lifecycle-progress-test.sh does.
if command -v zsh > /dev/null 2>&1; then
  PHASE_REPO="$TMP_DIR/phase-repo"
  git init -q -b main "$PHASE_REPO"
  git -C "$PHASE_REPO" config user.email test@example.com
  git -C "$PHASE_REPO" config user.name Test
  git -C "$PHASE_REPO" commit --allow-empty -qm init
  mkdir -p "$TMP_DIR/bin"
  # The launcher checks for the provider executable before reaching the stub.
  printf '#!/usr/bin/env bash\nexit 97\n' > "$TMP_DIR/bin/claude"
  chmod +x "$TMP_DIR/bin/claude"

  PHASE_SESSION="phase-exit-reap-test"
  PHASE_STATUS=0
  set +e
  ( cd "$PHASE_REPO" \
    && PATH="$TMP_DIR/bin:$PATH" \
       DEXCODE_SYNC=0 DEX_FACTORY_SYNC=false DX_AGENT_OVERRIDE=claude \
       TEST_REPO="$PHASE_REPO" TEST_SESSION_ID="$PHASE_SESSION" \
       TEST_PID_FILE="$TMP_DIR/phase-exit-child.pid" \
       zsh -fc '
      source "$DEX_DIR/dx.sh"
      __dx_refresh_provider

      unalias __dx_claude 2>/dev/null
      unfunction __dx_claude 2>/dev/null
      __dx_claude() {
        # Runs inside the launch subshell, so it carries the session token the
        # same way a real provider and everything it starts does.
        nohup /bin/sleep 300 > /dev/null 2>&1 &
        print -- "$!" > "$TEST_PID_FILE"
        disown 2>/dev/null || true
        dx_lifecycle_atomic_write "$(dx_paused_file "$TEST_SESSION_ID")" paused
      }

      state_file=$(dx_state_file "$TEST_SESSION_ID")
      times_file=$(dx_times_file "$TEST_SESSION_ID")
      __dx_run_phases_inline \
        "ticket-phase-exit" "$TEST_REPO" main 0 "$state_file" "$times_file" \
        "dx phase-exit-test" worktree "$TEST_SESSION_ID" "phase exit test"
    ' ) > "$TMP_DIR/phase-exit.out" 2>&1
  PHASE_STATUS=$?
  set -e
  if [[ ! -s "$TMP_DIR/phase-exit-child.pid" ]]; then
    printf 'phase-exit harness output (status %s):\n' "$PHASE_STATUS" >&2
    cat "$TMP_DIR/phase-exit.out" >&2
    fail "the stubbed provider never ran, so the phase-exit reap was not exercised"
  fi
  PHASE_CHILD="$(cat "$TMP_DIR/phase-exit-child.pid")"
  assert_gone "$PHASE_CHILD" "phase-exit detached process"
  assert_contains "reaped pid=${PHASE_CHILD}" "$TMP_DIR/phase-exit.out"
  [[ ! -d "$(dx_session_process_dir "$PHASE_SESSION")" ]] || assert_at $LINENO
else
  printf 'skip: zsh is not installed, so the phase-exit reap path is not exercised\n'
fi

printf 'session process ownership tests passed\n'
