#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-lifecycle-terminal-event-test.XXXXXX")"
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
export PATH="$TMP_DIR/bin:$PATH"
mkdir -p "$TMP_DIR/bin"

cat > "$TMP_DIR/server.py" <<'PY'
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

root = Path(sys.argv[1])
requests_file = root / "requests.jsonl"
port_file = root / "port"


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        body = json.loads(raw.decode("utf-8")) if raw else {}
        with requests_file.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({"path": self.path, "body": body}, sort_keys=True, separators=(",", ":")))
            fh.write("\n")

        missing = []
        for event in body.get("events", []):
            if event.get("type") not in {"run.failed", "run.blocked"}:
                continue
            data = event.get("data") or {}
            for key in ("status", "reason", "phase", "phase_name", "resume_command"):
                if not data.get(key):
                    missing.append(key)
            if event.get("type") == "run.failed" and "exit_code" not in data:
                missing.append("exit_code")

        if missing:
            self.send_response(422)
            self.send_header("Content-Type", "application/json")
            self.end_headers()
            self.wfile.write(json.dumps({"ok": False, "missing": sorted(set(missing))}).encode("utf-8"))
            return

        self.send_response(201)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true}\n')

    def log_message(self, _format, *_args):
        return


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
port_file.write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
PY
python3 "$TMP_DIR/server.py" "$TMP_DIR" &
SERVER_PID=$!
for _attempt in {1..100}; do
  [[ -f "$TMP_DIR/port" ]] && break
  sleep 0.05
done
[[ -f "$TMP_DIR/port" ]] || {
  printf '%s\n' "server did not start" >&2
  exit 1
}

export DEX_FACTORY_SYNC=true
DEX_FACTORY_URL="http://127.0.0.1:$(cat "$TMP_DIR/port")"
export DEX_FACTORY_URL
export DEX_FACTORY_TOKEN="factory-test-token"
export DEX_FACTORY_RETRY_BASE_SECONDS=0
export DEX_FACTORY_RETRY_MAX_SECONDS=0
export DEX_FACTORY_BATCH_SIZE=25

zsh -fc '
  source "$DEX_DIR/dx.sh"
  run_id=$(dx_run_prepare "terminal-event-session" "$DEX_DIR" "in-place" "terminal-event-test" "fail setup" "dx")
  dx_run_maybe_emit_started "$run_id" "Dex lifecycle started" "{\"command\":\"dx\"}"
  terminal_data=$(__dx_terminal_event_data "failed" "provider-exit" "0" "Setup" "42" "dx --no-worktree fail setup")
  dx_event_emit "$run_id" "run.failed" "error" "Dex lifecycle exited at Phase 0: Setup" "0" "$terminal_data"
'

python3 - "$TMP_DIR/requests.jsonl" <<'PY'
import json
import sys
from pathlib import Path

events = []
for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    record = json.loads(line)
    events.extend(record.get("body", {}).get("events", []))

failed = [event for event in events if event.get("type") == "run.failed"]
assert failed, events
event = failed[-1]
data = event["data"]
assert data["status"] == "failed", data
assert data["reason"] == "provider-exit", data
assert data["phase"] == "0", data
assert data["phase_name"] == "Setup", data
assert data["exit_code"] == 42, data
assert data["resume_command"] == "dx --no-worktree fail setup", data
PY

printf 'lifecycle terminal event test passed\n'
