#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
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

assert_file() {
  [[ -f "$1" ]] || {
    printf 'missing file: %s\n' "$1" >&2
    exit 1
  }
}

assert_no_file() {
  [[ ! -f "$1" ]] || {
    printf 'unexpected file: %s\n' "$1" >&2
    exit 1
  }
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [[ "$expected" == "$actual" ]] || {
    printf '%s: expected %s, got %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  }
}

start_server() {
  local server_dir="$TMP_DIR/server"
  mkdir -p "$server_dir"
  printf '200\n' > "$server_dir/status"
  cat > "$server_dir/server.py" <<'PY'
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

root = Path(sys.argv[1])
requests_file = root / "requests.jsonl"
status_file = root / "status"
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
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(
            b'{"ok":true}\n'
            if 200 <= status < 300
            else b'{"ok":false,"error":"validation failed","access_token":"server-secret-token"}\n'
        )

    def log_message(self, _format, *_args):
        return


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
port_file.write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
PY
  python3 "$server_dir/server.py" "$server_dir" &
  SERVER_PID=$!

  local _attempt
  for _attempt in {1..100}; do
    [[ -f "$server_dir/port" ]] && break
    sleep 0.05
  done
  assert_file "$server_dir/port"
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

start_server

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

export DEX_FACTORY_SYNC=true
export DEX_FACTORY_URL="$SERVER_URL"
export DEX_FACTORY_TOKEN="test-token"
export DEX_FACTORY_RETRY_BASE_SECONDS=0
export DEX_FACTORY_RETRY_MAX_SECONDS=0
export DEX_FACTORY_BATCH_SIZE=25

success_run="$(dx_run_prepare "remote-success" "$ROOT" "test" "factory-sync-test" "issue-47" "dx test")"
dx_event_emit "$success_run" "run.started" "info" "Remote sync" "" '{"mode":"remote"}'
assert_file "$(dx_factory_sync_cursor_file "$success_run")"
assert_eq "1" "$(cat "$(dx_factory_sync_cursor_file "$success_run")")" "success cursor"

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
PY

printf '200\n' > "$SERVER_DIR/status"
dx_factory_sync_pending_events "$failure_run"
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

printf 'factory sync tests passed\n'
