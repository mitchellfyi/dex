#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-factory-redirect-test.XXXXXX")"
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
export DEX_FACTORY_RETRY_BASE_SECONDS=0
export DEX_FACTORY_RETRY_MAX_SECONDS=0

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  [[ "$expected" == "$actual" ]] || {
    printf '%s: expected %s, got %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  }
}

request_count() {
  local file="$1"
  [[ -f "$file" ]] || {
    printf '0\n'
    return 0
  }
  wc -l < "$file" | tr -d '[:space:]'
}

cat > "$TMP_DIR/server.py" <<'PY'
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

root = Path(sys.argv[1])
origin_requests = root / "origin-requests.jsonl"
sink_requests = root / "sink-requests.jsonl"


def record(path, handler, body=b""):
    with path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps({
            "method": handler.command,
            "path": handler.path,
            "authorization": handler.headers.get("Authorization", ""),
            "body_size": len(body),
        }, sort_keys=True, separators=(",", ":")) + "\n")


class SinkHandler(BaseHTTPRequestHandler):
    def do_GET(self):
        record(sink_requests, self)
        self.send_response(200)
        self.end_headers()

    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        record(sink_requests, self, body)
        self.send_response(200)
        self.end_headers()

    def log_message(self, _format, *_args):
        return


sink = ThreadingHTTPServer(("127.0.0.1", 0), SinkHandler)


class OriginHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        body = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        record(origin_requests, self, body)
        self.send_response(302)
        self.send_header("Location", f"http://127.0.0.1:{sink.server_port}/captured")
        self.end_headers()

    def log_message(self, _format, *_args):
        return


origin = ThreadingHTTPServer(("127.0.0.1", 0), OriginHandler)
(root / "origin-port").write_text(str(origin.server_port), encoding="utf-8")
(root / "sink-port").write_text(str(sink.server_port), encoding="utf-8")
threading.Thread(target=sink.serve_forever, daemon=True).start()
origin.serve_forever()
PY

python3 "$TMP_DIR/server.py" "$TMP_DIR" &
SERVER_PID=$!
for _attempt in {1..100}; do
  [[ -s "$TMP_DIR/origin-port" && -s "$TMP_DIR/sink-port" ]] && break
  sleep 0.05
done
[[ -s "$TMP_DIR/origin-port" && -s "$TMP_DIR/sink-port" ]] || {
  printf 'redirect fixture did not start\n' >&2
  exit 1
}

origin_url="http://127.0.0.1:$(cat "$TMP_DIR/origin-port")"
run_id="$(dx_run_prepare "factory-redirect" "$ROOT" "test" "factory-redirect" "redirect test" "dx test")"
export DEX_FACTORY_SYNC=false
dx_event_emit "$run_id" "run.started" "info" "Redirect test" "" '{}'

export DEX_FACTORY_SYNC=true
export DEX_FACTORY_EVENTS_ENDPOINT="$origin_url/events"
export DEX_FACTORY_TOKEN="redirect-bearer-secret"
dx_factory_sync_pending_events "$run_id"

assert_eq "1" "$(request_count "$TMP_DIR/origin-requests.jsonl")" "origin request count"
assert_eq "0" "$(request_count "$TMP_DIR/sink-requests.jsonl")" "redirect destination request count"
[[ ! -f "$(dx_factory_sync_cursor_file "$run_id")" ]] || {
  printf 'redirected event batch advanced the sync cursor\n' >&2
  exit 1
}

python3 - "$(dx_factory_sync_status_file "$run_id")" <<'PY'
import json
import sys
from pathlib import Path

status = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert status["status"] == "failed", status
assert "HTTP 302" in status["message"], status
assert "redirect-bearer-secret" not in status["message"], status
PY

# Credential-bearing and non-HTTP collector URLs are rejected before a
# request is made, and their credentials never enter the local status file.
origin_port="$(cat "$TMP_DIR/origin-port")"
export DEX_FACTORY_EVENTS_ENDPOINT="http://worker-user:worker-password@127.0.0.1:${origin_port}/events"
dx_factory_sync_pending_events "$run_id"
assert_eq "1" "$(request_count "$TMP_DIR/origin-requests.jsonl")" "credential URL request count"
python3 - "$(dx_factory_sync_status_file "$run_id")" <<'PY'
import json
import sys
from pathlib import Path

status = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
message = status["message"]
assert "invalid HTTP event endpoint" in message, status
assert "worker-user" not in message, status
assert "worker-password" not in message, status
PY

export DEX_FACTORY_EVENTS_ENDPOINT="file:///tmp/dex-events"
dx_factory_sync_pending_events "$run_id"
assert_eq "1" "$(request_count "$TMP_DIR/origin-requests.jsonl")" "non-HTTP URL request count"

export DEX_FACTORY_EVENTS_ENDPOINT="$origin_url/events"
export DEX_FACTORY_TOKEN=$'invalid\nheader-value'
dx_factory_sync_pending_events "$run_id"
assert_eq "1" "$(request_count "$TMP_DIR/origin-requests.jsonl")" "invalid token request count"
python3 - "$(dx_factory_sync_status_file "$run_id")" <<'PY'
import json
import sys
from pathlib import Path

status = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert "invalid Bearer token" in status["message"], status
assert "header-value" not in status["message"], status
PY

printf 'factory-redirect-test passed\n'
