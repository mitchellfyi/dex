#!/usr/bin/env bash
# dex-test-lane: service
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-factory-sync-test.XXXXXX")"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
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

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

start_server() {
  local server_dir="$TMP_DIR/server"
  mkdir -p "$server_dir"
  printf '200\n' > "$server_dir/status"
  printf 'json\n' > "$server_dir/body-mode"
  cat > "$server_dir/server.py" <<'PY'
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

root = Path(sys.argv[1])
requests_file = root / "requests.jsonl"
status_file = root / "status"
body_mode_file = root / "body-mode"
port_file = root / "port"


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        record = {
            "path": self.path,
            "authorization": self.headers.get("Authorization", ""),
            "content_type": self.headers.get("Content-Type", ""),
            "body": json.loads(raw.decode("utf-8")),
        }
        with requests_file.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, sort_keys=True, separators=(",", ":")))
            fh.write("\n")

        try:
            status = int(status_file.read_text(encoding="utf-8").strip() or "200")
        except ValueError:
            status = 500
        self.send_response(status)
        body_mode = body_mode_file.read_text(encoding="utf-8").strip()
        self.send_header("Content-Type", "text/plain" if body_mode == "text" else "application/json")
        self.end_headers()
        if 200 <= status < 300:
            self.wfile.write(b'{"ok":true}\n')
        elif body_mode == "text":
            active_token = (self.headers.get("Authorization", "").removeprefix("Bearer "))
            # The foreign token is not this run's token and is not attached to
            # any key, header, or assignment, so only the raw-token patterns
            # can catch it.
            self.wfile.write(
                f"collector echoed {active_token} in neutral text "
                f"alongside ghp_forgedcollectortoken1234567890\n".encode("utf-8")
            )
        else:
            active_token = (self.headers.get("Authorization", "").removeprefix("Bearer "))
            self.wfile.write(json.dumps({
                "ok": False,
                "error": "validation failed",
                "access_token": "server-secret-token",
                "password": "server-password",
                "credential": "server-credential",
                "neutral_echo": active_token,
                "remote": "https://worker-user:worker-password@example.test/private",
            }, separators=(",", ":")).encode("utf-8") + b"\n")

    def log_message(self, _format, *_args):
        return


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
port_file.write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
PY
  python3 "$server_dir/server.py" "$server_dir" &
  SERVER_PID=$!
  wait_for_process_files "$SERVER_PID" "$server_dir/port"
  SERVER_URL="http://127.0.0.1:$(cat "$server_dir/port")"
  SERVER_DIR="$server_dir"
}

request_count() {
  local requests_file="$SERVER_DIR/requests.jsonl"
  [[ -f "$requests_file" ]] || {
    printf '0\n'
    return 0
  }
  wc -l < "$requests_file" | tr -d ' '
}

flush_factory_events() {
  local sync_status
  # Bash 3.2 can still apply errexit inside nested lock helpers even when the
  # outer call is in an OR-list. Capture the public result explicitly instead.
  set +e
  dx_factory_sync_pending_events "$@"
  sync_status=$?
  set -e
  if [[ "$sync_status" -ne 0 ]]; then
    printf 'Factory sync returned an unexpected failure for %s\n' "$1" >&2
    return 1
  fi
}

start_server

assert_eq "5" "$(__dx_factory_positive_int "999999999999999999999" 5 3600)" "oversized timeout fallback"
assert_eq "50" "$(__dx_factory_positive_int "08" 50 10000)" "leading-zero batch fallback"
assert_eq "0" "$(__dx_factory_nonnegative_int "0" 1 86400)" "zero retry delay"

cursor_validation_run="run_cursor_validation"
mkdir -p "$(dx_factory_sync_dir "$cursor_validation_run")"
printf '0001\n' > "$(dx_factory_sync_cursor_file "$cursor_validation_run")"
assert_eq "0" "$(__dx_factory_sync_read_cursor "$cursor_validation_run")" "non-canonical cursor fallback"
printf '999999999999999999999\n' > "$(dx_factory_sync_cursor_file "$cursor_validation_run")"
assert_eq "0" "$(__dx_factory_sync_read_cursor "$cursor_validation_run")" "oversized cursor fallback"
if __dx_factory_sync_write_cursor "$cursor_validation_run" "1000000000"; then
  printf 'cursor writer accepted a value outside the supported range\n' >&2
  exit 1
fi

local_run="$(dx_run_prepare "local-only" "$ROOT" "test" "factory-sync-test" "issue-47" "dx test")"
dx_event_emit "$local_run" "run.started" "info" "Local only" "" '{"mode":"local"}'
assert_eq "1" "$(python3 - "$(dx_run_events_file "$local_run")" <<'PY'
import sys
from pathlib import Path
print(len([line for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines() if line.strip()]))
PY
)" "local event count"
assert_no_file "$(dx_factory_sync_cursor_file "$local_run")"
assert_eq "0" "$(request_count)" "local-only requests"

export DEX_FACTORY_TOKEN="machine-token"
export DEX_FACTORY_RUN_TOKEN="factory-run-token"
export DEX_RUN_TOKEN="scoped-run-token"
assert_eq "scoped-run-token" "$(dx_factory_sync_token)" "run token precedence"
unset DEX_FACTORY_RUN_TOKEN DEX_RUN_TOKEN

export DEX_FACTORY_SYNC=true
export DEX_FACTORY_URL="$SERVER_URL"
export DEX_FACTORY_TOKEN="test-token"
export DEX_FACTORY_RETRY_BASE_SECONDS=0
export DEX_FACTORY_RETRY_MAX_SECONDS=0
export DEX_FACTORY_BATCH_SIZE=25

success_run="$(dx_run_prepare "remote-success" "$ROOT" "test" "factory-sync-test" "issue-47" "dx test")"
dx_event_emit "$success_run" "run.started" "info" "Remote sync" "" '{"mode":"remote"}'
success_cursor="$(dx_factory_sync_cursor_file "$success_run")"
if [[ ! -f "$success_cursor" ]]; then
  printf 'Factory sync did not write its cursor. Status:\n' >&2
  cat "$(dx_factory_sync_status_file "$success_run")" >&2 2>/dev/null || printf '(no status file)\n' >&2
  exit 1
fi
assert_eq "1" "$(cat "$success_cursor")" "success cursor"

python3 - "$SERVER_DIR/requests.jsonl" "$success_run" <<'PY'
import json
import sys
from pathlib import Path

records = [json.loads(line) for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()]
record = records[-1]
assert record["path"].endswith(f"/api/v1/runs/{sys.argv[2]}/events/batch"), record["path"]
assert record["authorization"] == "Bearer test-token"
assert record["content_type"] == "application/json"
events = record["body"]["events"]
assert len(events) == 1
assert events[0]["run_id"] == sys.argv[2]
assert events[0]["sequence"] == 1
assert events[0]["type"] == "run.started"
PY

backlog_run="$(dx_run_prepare "remote-backlog" "$ROOT" "test" "factory-sync-test" "issue-48" "dx test")"
export DEX_FACTORY_SYNC=false
dx_event_emit "$backlog_run" "run.started" "info" "Backlog sync" "" '{"mode":"backlog"}'
dx_event_emit "$backlog_run" "phase.started" "info" "Phase 1 started" "1" '{"phase_name":"Plan"}'
dx_event_emit "$backlog_run" "phase.completed" "info" "Phase 1 completed" "1" '{"phase_name":"Plan"}'
dx_event_emit "$backlog_run" "phase.started" "info" "Phase 2 started" "2" '{"phase_name":"Implement"}'
dx_event_emit "$backlog_run" "run.completed" "info" "Backlog run completed" "2" '{"final_phase":2}'
export DEX_FACTORY_SYNC=true
export DEX_FACTORY_BATCH_SIZE=2
before_backlog_requests="$(request_count)"
flush_factory_events "$backlog_run"
after_backlog_requests="$(request_count)"
assert_eq "$((before_backlog_requests + 3))" "$after_backlog_requests" "backlog drained request count"
assert_eq "5" "$(cat "$(dx_factory_sync_cursor_file "$backlog_run")")" "backlog cursor"

python3 - "$SERVER_DIR/requests.jsonl" "$backlog_run" <<'PY'
import json
import sys
from pathlib import Path

records = [json.loads(line) for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()]
events = [
    event
    for record in records
    for event in record["body"].get("events", [])
    if event.get("run_id") == sys.argv[2]
]
assert [event["sequence"] for event in events] == [1, 2, 3, 4, 5], events
assert events[-1]["type"] == "run.completed", events[-1]
PY
export DEX_FACTORY_BATCH_SIZE=25

failure_run="$(dx_run_prepare "remote-failure" "$ROOT" "test" "factory-sync-test" "issue-47" "dx test")"
printf '500\n' > "$SERVER_DIR/status"
before_failure_requests="$(request_count)"
dx_event_emit "$failure_run" "run.started" "info" "Queued sync" "" '{"mode":"queued"}'
after_failure_requests="$(request_count)"
assert_eq "$((before_failure_requests + 1))" "$after_failure_requests" "failure request count"
assert_no_file "$(dx_factory_sync_cursor_file "$failure_run")"
assert_file "$(dx_factory_sync_status_file "$failure_run")"
python3 - "$(dx_factory_sync_status_file "$failure_run")" <<'PY'
import json
import sys
from pathlib import Path

status = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert "validation failed" in status["message"], status
assert "event sequences 1-1" in status["message"], status
assert "/api/v1/runs/" in status["message"], status
assert "server-secret-token" not in status["message"], status
assert '"access_token":"[redacted]"' in status["message"], status
assert "server-password" not in status["message"], status
assert "server-credential" not in status["message"], status
assert "worker-password" not in status["message"], status
assert '"password":"[redacted]"' in status["message"], status
assert "https://[redacted]@example.test/private" in status["message"], status
assert '"neutral_echo":"[redacted]"' in status["message"], status
assert "test-token" not in status["message"], status
PY

printf '200\n' > "$SERVER_DIR/status"
flush_factory_events "$failure_run"
assert_eq "1" "$(cat "$(dx_factory_sync_cursor_file "$failure_run")")" "retry cursor"

python3 - "$SERVER_DIR/requests.jsonl" "$failure_run" <<'PY'
import json
import sys
from pathlib import Path

records = [json.loads(line) for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()]
matching = [
    record["body"]["events"][0]
    for record in records
    if record["body"].get("events")
    and record["body"]["events"][0].get("run_id") == sys.argv[2]
]
assert len(matching) == 2
assert matching[0]["id"] == matching[1]["id"]
assert matching[0]["sequence"] == matching[1]["sequence"] == 1
PY

plain_echo_run="$(dx_run_prepare "plain-token-echo" "$ROOT" "test" "factory-sync-test" "issue-48" "dx test")"
export DEX_FACTORY_SYNC=false
dx_event_emit "$plain_echo_run" "run.started" "info" "Plain token echo" "" '{"mode":"plain-echo"}'
printf '500\n' > "$SERVER_DIR/status"
printf 'text\n' > "$SERVER_DIR/body-mode"
export DEX_FACTORY_SYNC=true
flush_factory_events "$plain_echo_run"
python3 - "$(dx_factory_sync_status_file "$plain_echo_run")" <<'PY'
import json
import sys
from pathlib import Path

status = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert "collector echoed [redacted] in neutral text" in status["message"], status
assert "test-token" not in status["message"], status
# A credential the collector leaked that is not this run's token must also go.
assert "ghp_forgedcollectortoken1234567890" not in status["message"], status
PY
printf '200\n' > "$SERVER_DIR/status"
printf 'json\n' > "$SERVER_DIR/body-mode"
flush_factory_events "$plain_echo_run"

# Factory sync uses lib/lock.sh, which publishes "<epoch>\t<pid>\t<token>".
# A record it cannot parse counts as no record at all and is only reclaimed
# after the grace period; a record naming a dead process is stale right now.
write_lock_owner() {
  printf '%s\t%s\tfactory-test\n' "$(date +%s)" "$2" > "$1/owner"
}

stale_lock_run="$(dx_run_prepare "stale-lock" "$ROOT" "test" "factory-sync-test" "issue-49" "dx test")"
export DEX_FACTORY_SYNC=false
dx_event_emit "$stale_lock_run" "run.started" "info" "Stale lock" "" '{"mode":"stale-lock"}'
stale_lock_dir="$(dx_factory_sync_dir "$stale_lock_run")/.lock"
mkdir -p "$stale_lock_dir"
write_lock_owner "$stale_lock_dir" 999999
export DEX_FACTORY_SYNC=true
flush_factory_events "$stale_lock_run"
assert_eq "1" "$(cat "$(dx_factory_sync_cursor_file "$stale_lock_run")")" "stale-lock cursor"
[[ ! -d "$stale_lock_dir" ]] || {
  printf 'stale Factory sync lock was not released\n' >&2
  exit 1
}
age_lock() {
  DX_TEST_LOCK_DIR="$1" python3 - <<'PY'
import os
import time

path = os.environ["DX_TEST_LOCK_DIR"]
old = time.time() - 60
os.utime(path, (old, old), follow_symlinks=False)
PY
}

missing_owner_run="$(dx_run_prepare "missing-lock-owner" "$ROOT" "test" "factory-sync-test" "issue-49" "dx test")"
export DEX_FACTORY_SYNC=false
dx_event_emit "$missing_owner_run" "run.started" "info" "Missing lock owner" "" '{}'
missing_owner_lock="$(dx_factory_sync_dir "$missing_owner_run")/.lock"
mkdir -p "$missing_owner_lock"
export DEX_FACTORY_SYNC=true
DEX_FACTORY_LOCK_ATTEMPTS=2 flush_factory_events "$missing_owner_run"
[[ -d "$missing_owner_lock" ]] || {
  printf 'Factory stole a fresh lock before its owner could be written\n' >&2
  exit 1
}
age_lock "$missing_owner_lock"
flush_factory_events "$missing_owner_run"
assert_eq "1" "$(cat "$(dx_factory_sync_cursor_file "$missing_owner_run")")" "missing-owner cursor"

corrupt_owner_run="$(dx_run_prepare "corrupt-lock-owner" "$ROOT" "test" "factory-sync-test" "issue-49" "dx test")"
export DEX_FACTORY_SYNC=false
dx_event_emit "$corrupt_owner_run" "run.started" "info" "Corrupt lock owner" "" '{}'
corrupt_owner_lock="$(dx_factory_sync_dir "$corrupt_owner_run")/.lock"
mkdir -p "$corrupt_owner_lock"
printf 'not-a-pid\n' > "$corrupt_owner_lock/owner"
age_lock "$corrupt_owner_lock"
export DEX_FACTORY_SYNC=true
flush_factory_events "$corrupt_owner_run"
assert_eq "1" "$(cat "$(dx_factory_sync_cursor_file "$corrupt_owner_run")")" "corrupt-owner cursor"

interrupted_owner_run="$(dx_run_prepare "interrupted-lock-owner" "$ROOT" "test" "factory-sync-test" "issue-49" "dx test")"
export DEX_FACTORY_SYNC=false
dx_event_emit "$interrupted_owner_run" "run.started" "info" "Interrupted lock owner" "" '{}'
interrupted_owner_lock="$(dx_factory_sync_dir "$interrupted_owner_run")/.lock"
interrupted_ready="$TMP_DIR/interrupted-lock-ready"
mkdir -p "$(dirname "$interrupted_owner_lock")"
DEX_TEST_LOCK_DIR="$interrupted_owner_lock" DEX_TEST_READY="$interrupted_ready" \
  bash -c 'trap "exit 0" TERM; source "$DEX_DIR/lib/common.sh"; __dx_factory_sync_acquire_lock "$DEX_TEST_LOCK_DIR"; printf ready > "$DEX_TEST_READY"; while :; do sleep 1; done' &
interrupted_pid=$!
for _attempt in {1..100}; do
  [[ -f "$interrupted_ready" ]] && break
  sleep 0.05
done
[[ -f "$interrupted_ready" ]] || {
  printf 'interrupted lock owner fixture did not acquire its lock\n' >&2
  kill "$interrupted_pid" 2>/dev/null || true
  wait "$interrupted_pid" 2>/dev/null || true
  exit 1
}
kill "$interrupted_pid" 2>/dev/null || true
wait "$interrupted_pid" 2>/dev/null || true
export DEX_FACTORY_SYNC=true
flush_factory_events "$interrupted_owner_run"
assert_eq "1" "$(cat "$(dx_factory_sync_cursor_file "$interrupted_owner_run")")" "interrupted-owner cursor"

live_owner_run="$(dx_run_prepare "live-lock-owner" "$ROOT" "test" "factory-sync-test" "issue-49" "dx test")"
export DEX_FACTORY_SYNC=false
dx_event_emit "$live_owner_run" "run.started" "info" "Live lock owner" "" '{}'
live_owner_lock="$(dx_factory_sync_dir "$live_owner_run")/.lock"
mkdir -p "$live_owner_lock"
write_lock_owner "$live_owner_lock" "$$"
export DEX_FACTORY_SYNC=true
DEX_FACTORY_LOCK_ATTEMPTS=2 flush_factory_events "$live_owner_run"
[[ -d "$live_owner_lock" ]] || {
  printf 'Factory stole a lock owned by a live process\n' >&2
  exit 1
}
assert_no_file "$(dx_factory_sync_cursor_file "$live_owner_run")"
rm -f "$live_owner_lock/owner"
rmdir "$live_owner_lock"

# lock.sh takes a short-lived `.reap` mutex around every acquisition, so two
# waiters cannot both decide a dead lock is theirs to steal. A process killed
# inside that mutex leaves the directory behind, and because acquiring gives up
# quietly, Factory sync for the run then stops with no cursor movement and
# nothing said. Inside the grace a reaper is a live recoverer and must be left
# alone; past it there is nobody left to wait for.
abandoned_reaper_run="$(dx_run_prepare "abandoned-reaper" "$ROOT" "test" "factory-sync-test" "issue-49" "dx test")"
export DEX_FACTORY_SYNC=false
dx_event_emit "$abandoned_reaper_run" "run.started" "info" "Abandoned reaper" "" '{}'
abandoned_reaper_lock="$(dx_factory_sync_dir "$abandoned_reaper_run")/.lock"
mkdir -p "$abandoned_reaper_lock" "${abandoned_reaper_lock}.reap"
write_lock_owner "$abandoned_reaper_lock" 999999
export DEX_FACTORY_SYNC=true
DEX_FACTORY_LOCK_ATTEMPTS=2 flush_factory_events "$abandoned_reaper_run"
[[ -d "$abandoned_reaper_lock" ]] || {
  printf 'Factory reclaimed a lock while another reaper still held the mutex\n' >&2
  exit 1
}
assert_no_file "$(dx_factory_sync_cursor_file "$abandoned_reaper_run")"
age_lock "${abandoned_reaper_lock}.reap"
flush_factory_events "$abandoned_reaper_run"
assert_eq "1" "$(cat "$(dx_factory_sync_cursor_file "$abandoned_reaper_run")")" "abandoned-reaper cursor"
[[ ! -d "$abandoned_reaper_lock" ]] || {
  printf 'Factory sync stayed wedged behind an abandoned reaper mutex\n' >&2
  exit 1
}

missing_token_run="$(dx_run_prepare "missing-token" "$ROOT" "test" "factory-sync-test" "issue-47" "dx test")"
unset DEX_FACTORY_TOKEN
before_missing_token_requests="$(request_count)"
dx_event_emit "$missing_token_run" "run.started" "info" "Missing token" "" '{"mode":"missing-token"}'
assert_eq "$before_missing_token_requests" "$(request_count)" "missing-token request count"
assert_file "$(dx_run_events_file "$missing_token_run")"
assert_no_file "$(dx_factory_sync_cursor_file "$missing_token_run")"

zsh_missing_token_run="run_factory_zsh_missing_token"
export zsh_missing_token_run
DEX_FACTORY_SYNC=true \
DEX_FACTORY_URL="$SERVER_URL" \
zsh -fc '
  source "$DEX_DIR/lib/common.sh"
  run_id="$zsh_missing_token_run"
  unset DEX_FACTORY_TOKEN DEX_FACTORY_RUN_TOKEN DEX_RUN_TOKEN
  mkdir -p "$(dx_run_dir "$run_id")"
  : > "$(dx_run_logs_file "$run_id")"
  dx_run_artifact_manifest_prepare "$run_id"
  dx_event_emit "$run_id" "run.started" "info" "Zsh missing token" "" "{\"mode\":\"zsh-missing-token\"}"
  test -f "$(dx_run_events_file "$run_id")"
  test -f "$(dx_factory_sync_status_file "$run_id")"
  test ! -f "$(dx_factory_sync_cursor_file "$run_id")"
'
python3 - "$(dx_factory_sync_status_file "$zsh_missing_token_run")" <<'PY'
import json
import sys
from pathlib import Path

status = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert status["status"] == "configuration_error"
assert "TOKEN" in status["message"]
PY

# A corrupt journal line must not wedge sync for the rest of the run: the bad
# line is skipped and later events still reach the collector.
printf '200\n' > "$SERVER_DIR/status"
printf 'json\n' > "$SERVER_DIR/body-mode"
# Earlier cases deliberately clear the credentials; restore them.
export DEX_FACTORY_URL="$SERVER_URL"
export DEX_FACTORY_TOKEN="test-token"
export DEX_FACTORY_SYNC=false
torn_run="$(dx_run_prepare "torn-journal" "$ROOT" "test" "factory-sync-test" "issue-49" "dx test")"
dx_event_emit "$torn_run" "run.started" "info" "before the tear" "" '{}'
printf '{"sequence": 2, "type": "run.tr\n' >> "$(dx_run_events_file "$torn_run")"
dx_event_emit "$torn_run" "run.completed" "info" "after the tear" "" '{}'
export DEX_FACTORY_SYNC=true
flush_factory_events "$torn_run"

if [[ -f "$(dx_factory_sync_status_file "$torn_run")" ]]; then
  printf 'a torn journal line wedged factory sync\n' >&2
  cat "$(dx_factory_sync_status_file "$torn_run")" >&2
  exit 1
fi
python3 - "$(dx_factory_sync_cursor_file "$torn_run")" <<'PY'
import sys
from pathlib import Path

cursor = int(Path(sys.argv[1]).read_text(encoding="utf-8").strip())
assert cursor >= 2, f"sync stopped at the torn line: cursor={cursor}"
PY

# The offset hint lets a later flush resume mid-journal instead of rescanning,
# and must never be trusted when it does not match the current cursor.
offset_file="$(dx_factory_sync_offset_file "$torn_run")"
test -f "$offset_file"
python3 - "$offset_file" "$(dx_run_events_file "$torn_run")" <<'PY'
import sys
from pathlib import Path

recorded_cursor, offset = (int(part) for part in Path(sys.argv[1]).read_text().split())
size = Path(sys.argv[2]).stat().st_size
assert recorded_cursor >= 2, recorded_cursor
assert 0 < offset <= size, (offset, size)
PY

# A hint recorded against a different cursor is ignored, so a reset cursor
# still resends from the beginning rather than skipping events.
printf '99 5\n' > "$offset_file"
printf '0\n' > "$(dx_factory_sync_cursor_file "$torn_run")"
flush_factory_events "$torn_run"
python3 - "$(dx_factory_sync_cursor_file "$torn_run")" <<'PY'
import sys
from pathlib import Path

cursor = int(Path(sys.argv[1]).read_text(encoding="utf-8").strip())
assert cursor >= 2, f"stale offset hint was trusted: cursor={cursor}"
PY

printf 'factory sync tests passed\n'
