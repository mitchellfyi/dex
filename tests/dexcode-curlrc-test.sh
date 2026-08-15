#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-dexcode-curlrc-test.XXXXXX")"
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
export DEXCODE_CONFIG_FILE="$TMP_DIR/dexcode.json"
export DEXCODE_CONTEXT_SYNC=0
mkdir -p "$HOME"

# curl reads this file unless -q is its first option. location-trusted follows
# cross-origin redirects and forwards credentials, which is unsafe for both
# API Bearer tokens and signed artifact uploads.
printf 'location-trusted\n' > "$HOME/.curlrc"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

request_count() {
  local file="$1"
  [[ -f "$file" ]] || {
    printf '0\n'
    return 0
  }
  wc -l < "$file" | tr -d '[:space:]'
}

cat > "$TMP_DIR/server.py" <<'PY'
import base64
import json
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

root = Path(sys.argv[1])
origin_log = root / "origin.jsonl"
sink_log = root / "sink.jsonl"


def record(path, handler, raw):
    with path.open("a", encoding="utf-8") as fh:
        fh.write(json.dumps({
            "method": handler.command,
            "path": handler.path,
            "authorization": handler.headers.get("Authorization", ""),
            "body": base64.b64encode(raw).decode("ascii"),
        }, sort_keys=True, separators=(",", ":")) + "\n")


class SinkHandler(BaseHTTPRequestHandler):
    def _capture(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        record(sink_log, self, raw)
        self.send_response(200)
        self.end_headers()

    do_GET = _capture
    do_POST = _capture
    do_PUT = _capture

    def log_message(self, _format, *_args):
        return


sink = ThreadingHTTPServer(("127.0.0.1", 0), SinkHandler)


class OriginHandler(BaseHTTPRequestHandler):
    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        record(origin_log, self, raw)
        if self.path == "/api/v1/runs":
            self.send_response(307)
            self.send_header("Location", f"http://127.0.0.1:{sink.server_port}/run-leak")
            self.end_headers()
            return
        if self.path.endswith("/artifacts"):
            payload = json.dumps({
                "id": "artifact-safe",
                "upload": {"url": f"http://127.0.0.1:{self.server.server_port}/upload-redirect"},
            }).encode("utf-8")
            self.send_response(201)
            self.send_header("Content-Type", "application/json")
            self.send_header("Content-Length", str(len(payload)))
            self.end_headers()
            self.wfile.write(payload)
            return
        self.send_response(404)
        self.end_headers()

    def do_PUT(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        record(origin_log, self, raw)
        self.send_response(307)
        self.send_header("Location", f"http://127.0.0.1:{sink.server_port}/artifact-leak")
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
  printf 'curlrc fixture did not start\n' >&2
  exit 1
}

origin_url="http://127.0.0.1:$(cat "$TMP_DIR/origin-port")"
cat > "$DEXCODE_CONFIG_FILE" <<JSON
{
  "api_url": "$origin_url",
  "access_token": "curlrc-bearer-secret",
  "account": {"slug": "sample-org", "name": "Sample Organisation"},
  "default_project": {"slug": "sample-project", "organisation_slug": "sample-org"},
  "connections": {"sample-org": {"access_token": "curlrc-bearer-secret", "api_url": "$origin_url"}}
}
JSON

run_id="$(dx_run_prepare "curlrc-contract" "$ROOT" "test" "curlrc" "curlrc" "dx test")"
dx_dexcode_prepare_run_sync "$run_id" "$ROOT" "test" "curlrc" \
  "Do not follow the run redirect" "dx test" > "$TMP_DIR/run.out" 2>&1
grep -Fq -- "run registration failed (HTTP 307)" "$TMP_DIR/run.out"

artifact="$TMP_DIR/artifact.txt"
printf 'artifact bytes must stay on the signed origin\n' > "$artifact"
dx_dexcode_upload_artifact "$run_id" "$artifact" "test_output" "curlrc artifact" \
  > "$TMP_DIR/artifact.out" 2>&1
grep -Fq -- "artifact upload failed (HTTP 307)" "$TMP_DIR/artifact.out"

[[ "$(request_count "$TMP_DIR/sink.jsonl")" == "0" ]] || {
  printf 'a hostile curlrc forwarded a request to the cross-origin sink\n' >&2
  cat "$TMP_DIR/sink.jsonl" >&2
  exit 1
}

python3 - "$TMP_DIR/origin.jsonl" <<'PY'
import base64
import json
import sys
from pathlib import Path

records = [json.loads(line) for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()]
run = next(record for record in records if record["path"] == "/api/v1/runs")
upload = next(record for record in records if record["path"] == "/upload-redirect")
assert run["authorization"] == "Bearer curlrc-bearer-secret", run
assert upload["authorization"] == "", upload
assert base64.b64decode(upload["body"]) == b"artifact bytes must stay on the signed origin\n", upload
PY

# The bearer token must never reach curl's argv, where any local process can
# read it from ps for the life of the request. It travels in a --config read
# from stdin instead.
stub_dir="$TMP_DIR/stub-bin"
mkdir -p "$stub_dir"
cat > "$stub_dir/curl" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$*" > "$CURL_ARGV_LOG"
cat > "$CURL_STDIN_LOG"
printf '200'
STUB
chmod +x "$stub_dir/curl"

export CURL_ARGV_LOG="$TMP_DIR/curl-argv.txt"
export CURL_STDIN_LOG="$TMP_DIR/curl-stdin.txt"
PATH="$stub_dir:$PATH" dx_dexcode_fetch_profile \
  "http://127.0.0.1:1/api" "argv-leak-canary-token" "$TMP_DIR/profile.json" >/dev/null 2>&1 || true

if grep -Fq "argv-leak-canary-token" "$CURL_ARGV_LOG"; then
  printf 'bearer token leaked into curl argv:\n' >&2
  cat "$CURL_ARGV_LOG" >&2
  exit 1
fi
grep -Fq -- '--config -' "$CURL_ARGV_LOG" || {
  printf 'curl was not given a stdin config for authentication:\n' >&2
  cat "$CURL_ARGV_LOG" >&2
  exit 1
}
grep -Fq "header = \"Authorization: Bearer argv-leak-canary-token\"" "$CURL_STDIN_LOG" || {
  printf 'authorization header was not delivered on stdin:\n' >&2
  cat "$CURL_STDIN_LOG" >&2
  exit 1
}

printf 'dexcode-curlrc-test passed\n'
