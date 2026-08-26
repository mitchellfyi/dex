#!/usr/bin/env bash
# dex-test-lane: service
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-dexcode-artifact-test.XXXXXX")"
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

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"


json_value() {
  local file="$1" expression="$2"
  DX_TEST_JSON_FILE="$file" DX_TEST_JSON_EXPRESSION="$expression" python3 - <<'PY'
import json
import os
from pathlib import Path

data = json.loads(Path(os.environ["DX_TEST_JSON_FILE"]).read_text(encoding="utf-8"))
print(eval(os.environ["DX_TEST_JSON_EXPRESSION"], {"data": data, "next": next}))
PY
}

request_count() {
  local requests_file="$TMP_DIR/server/requests.jsonl"
  [[ -f "$requests_file" ]] || {
    printf '0\n'
    return 0
  }
  wc -l < "$requests_file" | tr -d '[:space:]'
}

start_server() {
  local server_dir="$TMP_DIR/server"
  mkdir -p "$server_dir"
  printf 'ok\n' > "$server_dir/mode"
  printf '0\n' > "$server_dir/counter"
  cat > "$server_dir/server.py" <<'PY'
import base64
import json
import sys
from http.server import BaseHTTPRequestHandler
from pathlib import Path

from dex_test_http import LocalThreadingHTTPServer

root = Path(sys.argv[1])
requests_file = root / "requests.jsonl"
mode_file = root / "mode"
counter_file = root / "counter"
registrations = {}
completed_artifacts = set()


class Handler(BaseHTTPRequestHandler):
    def _body(self):
        return self.rfile.read(int(self.headers.get("Content-Length", "0")))

    def _record(self, raw):
        try:
            body = json.loads(raw.decode("utf-8")) if raw else {}
        except (UnicodeDecodeError, json.JSONDecodeError):
            body = {"base64": base64.b64encode(raw).decode("ascii")}
        record = {
            "method": self.command,
            "path": self.path,
            "authorization": self.headers.get("Authorization", ""),
            "content_type": self.headers.get("Content-Type", ""),
            "idempotency_key": self.headers.get("Idempotency-Key", ""),
            "body": body,
        }
        with requests_file.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps(record, sort_keys=True, separators=(",", ":")) + "\n")

    def _json(self, status, payload):
        encoded = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(encoded)))
        self.end_headers()
        self.wfile.write(encoded)

    def do_POST(self):
        raw = self._body()
        self._record(raw)
        mode = mode_file.read_text(encoding="utf-8").strip()
        if self.path.endswith("/artifacts"):
            if mode == "registration-failure":
                self._json(503, {"error": "unavailable"})
                return
            body = json.loads(raw.decode("utf-8"))
            idempotency_key = self.headers.get("Idempotency-Key", "")
            registration = registrations.get(idempotency_key) if idempotency_key else None
            if registration is not None and registration["body"] != body:
                self._json(409, {"error": "idempotency_key_reused"})
                return
            if registration is None:
                count = int(counter_file.read_text(encoding="utf-8").strip()) + 1
                counter_file.write_text(str(count), encoding="utf-8")
                artifact_id = ".." if mode == "invalid-artifact-id" else f"remote-art-{count}"
                if idempotency_key:
                    registrations[idempotency_key] = {"body": body, "id": artifact_id}
            else:
                artifact_id = registration["id"]
            if mode == "missing-upload-url":
                self._json(201, {"id": artifact_id, "upload": {}})
                return
            if idempotency_key and artifact_id in completed_artifacts:
                self._json(201, {"id": artifact_id, "state": "completed", "upload": None})
                return
            upload_url = (
                "ftp://storage.example.invalid/upload"
                if mode == "unsafe-upload-url"
                else f"http://127.0.0.1:{self.server.server_port}/uploads/{artifact_id}"
            )
            response = {"id": artifact_id, "upload": {"url": upload_url}}
            if idempotency_key:
                response["state"] = "pending"
            self._json(201, response)
            return
        if "/artifacts/" in self.path:
            artifact_id = self.path.rsplit("/", 1)[-1]
            if mode == "confirmation-response-lost":
                completed_artifacts.add(artifact_id)
                self._json(503, {"error": "response_lost"})
                return
            if mode == "confirmation-failure":
                self._json(503, {"error": "unavailable"})
                return
            completed_artifacts.add(artifact_id)
            self.send_response(204)
            self.end_headers()
            return
        self._json(404, {"error": "not_found"})

    def do_PUT(self):
        raw = self._body()
        self._record(raw)
        mode = mode_file.read_text(encoding="utf-8").strip()
        if mode == "upload-failure":
            self._json(503, {"error": "unavailable"})
            return
        self.send_response(204)
        self.end_headers()

    def log_message(self, _format, *_args):
        return


server = LocalThreadingHTTPServer(("127.0.0.1", 0), Handler)
(root / "port").write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
PY
  PYTHONPATH="$ROOT/tests${PYTHONPATH:+:$PYTHONPATH}" \
    python3 "$server_dir/server.py" "$server_dir" &
  SERVER_PID=$!
  wait_for_process_files "$SERVER_PID" "$server_dir/port"
  SERVER_URL="http://127.0.0.1:$(cat "$server_dir/port")"
}

start_server

cat > "$DEXCODE_CONFIG_FILE" <<JSON
{
  "api_url": "$SERVER_URL",
  "access_token": "dc_live_artifact_token",
  "account": {"slug": "sample-org", "name": "Sample Organisation"},
  "default_project": {"slug": "sample-project", "organisation_slug": "sample-org"},
  "connections": {
    "sample-org": {
      "access_token": "dc_live_artifact_token",
      "account": {"slug": "sample-org", "name": "Sample Organisation"},
      "projects": [{"slug": "sample-project", "organisation_slug": "sample-org"}],
      "api_url": "$SERVER_URL"
    }
  }
}
JSON

run_id="$(dx_run_prepare "artifact-contract" "$ROOT" "test" "artifact-contract" "artifact upload" "dx test")"
artifact_file="$(dx_run_artifact_file "$run_id" "reports/result.txt")"
mkdir -p "$(dirname "$artifact_file")"
printf 'artifact body one\n' > "$artifact_file"

# Registration, direct upload, and confirmation must all complete before the
# remote id is attached to the local manifest.
dx_run_register_artifact "$run_id" "test_output" "reports/result.txt" "Test output" \
  '{"producer":"test"}'
assert_eq "3" "$(request_count)" "three-step request count"

python3 - "$TMP_DIR/server/requests.jsonl" "$run_id" "$artifact_file" <<'PY'
import base64
import hashlib
import json
import sys
from pathlib import Path

records = [json.loads(line) for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()]
run_id = sys.argv[2]
artifact = Path(sys.argv[3]).read_bytes()
register, upload, confirm = records

assert register["method"] == "POST", register
assert register["path"] == f"/api/v1/runs/{run_id}/artifacts", register
assert register["authorization"] == "Bearer dc_live_artifact_token", register
assert register["idempotency_key"].startswith("dex-artifact-v1-"), register
assert register["body"] == {
    "byte_size": len(artifact),
    "content_type": "text/plain",
    "filename": "result.txt",
    "kind": "test_output",
    "metadata": {"producer": "test"},
    "sha256": hashlib.sha256(artifact).hexdigest(),
    "title": "Test output",
}, register

assert upload["method"] == "PUT", upload
assert upload["path"] == "/uploads/remote-art-1", upload
assert upload["authorization"] == "", upload
assert upload["content_type"] == "text/plain", upload
assert base64.b64decode(upload["body"]["base64"]) == artifact, upload

assert confirm["method"] == "POST", confirm
assert confirm["path"] == f"/api/v1/runs/{run_id}/artifacts/remote-art-1", confirm
assert confirm["authorization"] == "Bearer dc_live_artifact_token", confirm
assert confirm["body"] == {
    "byte_size": len(artifact),
    "content_type": "text/plain",
    "sha256": hashlib.sha256(artifact).hexdigest(),
}, confirm
PY

manifest_file="$(dx_run_artifact_manifest_file "$run_id")"
assert_eq "remote-art-1" "$(json_value "$manifest_file" "next(item for item in data['artifacts'] if item['path'] == 'reports/result.txt')['dexcode_artifact_id']")" "manifest remote id"
first_hash="$(json_value "$manifest_file" "next(item for item in data['artifacts'] if item['path'] == 'reports/result.txt')['sha256']")"
assert_eq "$first_hash" "$(json_value "$manifest_file" "next(item for item in data['artifacts'] if item['path'] == 'reports/result.txt')['dexcode_artifact_sha256']")" "manifest uploaded hash"

disabled_file="$(dx_run_artifact_file "$run_id" "reports/local-only.txt")"
printf 'keep this artifact local\n' > "$disabled_file"
before_disabled_requests="$(request_count)"
DEXCODE_SYNC=off dx_run_register_artifact "$run_id" "test_output" \
  "reports/local-only.txt" "Local-only artifact"
assert_eq "$before_disabled_requests" "$(request_count)" "disabled artifact sync request count"

# An unchanged registration is idempotent.
dx_run_register_artifact "$run_id" "test_output" "reports/result.txt" "Test output" \
  '{"producer":"test"}'
assert_eq "3" "$(request_count)" "unchanged artifact request count"

# If the local file changes, the old remote id no longer describes it. Upload
# the new bytes and replace the manifest's remote identity.
printf 'artifact body two, now changed\n' > "$artifact_file"
dx_run_register_artifact "$run_id" "test_output" "reports/result.txt" "Updated test output" \
  '{"producer":"test"}'
assert_eq "6" "$(request_count)" "changed artifact request count"
assert_eq "remote-art-2" "$(json_value "$manifest_file" "next(item for item in data['artifacts'] if item['path'] == 'reports/result.txt')['dexcode_artifact_id']")" "updated manifest remote id"
second_hash="$(json_value "$manifest_file" "next(item for item in data['artifacts'] if item['path'] == 'reports/result.txt')['sha256']")"
assert_eq "$second_hash" "$(json_value "$manifest_file" "next(item for item in data['artifacts'] if item['path'] == 'reports/result.txt')['dexcode_artifact_sha256']")" "updated manifest hash"
[[ "$first_hash" != "$second_hash" ]] || {
  printf 'artifact hash did not change with file contents\n' >&2
  exit 1
}

# Remote metadata follows the manifest too. A title-only update needs a new
# registration even though the bytes and digest did not change.
dx_run_register_artifact "$run_id" "test_output" "reports/result.txt" "Retitled test output" \
  '{"producer":"test"}'
assert_eq "9" "$(request_count)" "retitled artifact request count"
assert_eq "remote-art-3" "$(json_value "$manifest_file" "next(item for item in data['artifacts'] if item['path'] == 'reports/result.txt')['dexcode_artifact_id']")" "retitled manifest remote id"
python3 - "$TMP_DIR/server/requests.jsonl" <<'PY'
import json
import sys
from pathlib import Path

records = [json.loads(line) for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()]
assert records[-3]["body"]["title"] == "Retitled test output", records[-3]
assert records[-3]["body"]["metadata"] == {"producer": "test"}, records[-3]
PY

# A malformed registration and a non-HTTP upload URL remain non-fatal, but the
# CLI explains why it kept the local copy.
printf 'missing-upload-url\n' > "$TMP_DIR/server/mode"
dx_dexcode_upload_artifact "$run_id" "$artifact_file" "test_output" "Malformed registration" > "$TMP_DIR/malformed.out" 2>&1
assert_contains "did not include an artifact id and HTTP upload URL" "$TMP_DIR/malformed.out"

printf 'unsafe-upload-url\n' > "$TMP_DIR/server/mode"
dx_dexcode_upload_artifact "$run_id" "$artifact_file" "test_output" "Unsafe URL" > "$TMP_DIR/unsafe.out" 2>&1
assert_contains "did not include an artifact id and HTTP upload URL" "$TMP_DIR/unsafe.out"

# Each network stage is best effort. A failure stops that upload at the
# affected stage, explains what happened, and leaves the local artifact alone.
printf 'registration-failure\n' > "$TMP_DIR/server/mode"
before_failure_requests="$(request_count)"
dx_dexcode_upload_artifact "$run_id" "$artifact_file" "test_output" "Registration failure" > "$TMP_DIR/registration-failure.out" 2>&1
assert_eq "$((before_failure_requests + 1))" "$(request_count)" "registration failure request count"
assert_contains "artifact registration failed (HTTP 503)" "$TMP_DIR/registration-failure.out"

printf 'upload-failure\n' > "$TMP_DIR/server/mode"
before_failure_requests="$(request_count)"
dx_dexcode_upload_artifact "$run_id" "$artifact_file" "test_output" "Upload failure" > "$TMP_DIR/upload-failure.out" 2>&1
assert_eq "$((before_failure_requests + 2))" "$(request_count)" "upload failure request count"
assert_contains "artifact upload failed (HTTP 503)" "$TMP_DIR/upload-failure.out"

printf 'confirmation-failure\n' > "$TMP_DIR/server/mode"
before_failure_requests="$(request_count)"
dx_dexcode_upload_artifact "$run_id" "$artifact_file" "test_output" "Confirmation failure" > "$TMP_DIR/confirmation-failure.out" 2>&1
assert_eq "$((before_failure_requests + 3))" "$(request_count)" "confirmation failure request count"
assert_contains "uploaded but not confirmed (HTTP 503)" "$TMP_DIR/confirmation-failure.out"

# A remotely started headless run uses its scoped run token and Factory base
# URL even when this worker has no saved DexCode login.
printf 'ok\n' > "$TMP_DIR/server/mode"
mv "$DEXCODE_CONFIG_FILE" "$DEXCODE_CONFIG_FILE.saved"
before_headless_requests="$(request_count)"
headless_artifact_id=$(DEX_HEADLESS_RUN=1 \
  DEX_RUN_TOKEN="dc_run_scoped_artifact_token" \
  DEX_FACTORY_URL="" \
  DEX_FACTORY_EVENTS_ENDPOINT="$SERVER_URL/api/v1/runs/$run_id/events/batch" \
  dx_dexcode_upload_artifact "$run_id" "$artifact_file" "test_output" "Headless artifact")
assert_eq "remote-art-8" "$headless_artifact_id" "headless artifact id"
assert_eq "$((before_headless_requests + 3))" "$(request_count)" "headless three-step request count"
mv "$DEXCODE_CONFIG_FILE.saved" "$DEXCODE_CONFIG_FILE"

python3 - "$TMP_DIR/server/requests.jsonl" <<'PY'
import json
import sys
from pathlib import Path

records = [json.loads(line) for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()]
register, upload, confirm = records[-3:]
assert register["authorization"] == "Bearer dc_run_scoped_artifact_token", register
assert register["idempotency_key"] == "", register
assert upload["authorization"] == "", upload
assert confirm["authorization"] == "Bearer dc_run_scoped_artifact_token", confirm
PY

assert_eq "video/webm" "$(dx_dexcode_content_type capture.webm)" "WebM content type"
assert_eq "text/vtt" "$(dx_dexcode_content_type captions.vtt)" "VTT content type"
assert_eq "application/zip" "$(dx_dexcode_content_type trace.zip)" "ZIP content type"
assert_eq "image/png" "$(dx_dexcode_content_type SCREENSHOT.PNG)" "case-insensitive content type"

printf 'invalid-artifact-id\n' > "$TMP_DIR/server/mode"
before_invalid_id_requests="$(request_count)"
dx_dexcode_upload_artifact "$run_id" "$artifact_file" "test_output" "Invalid artifact id" \
  > "$TMP_DIR/invalid-id.out" 2>&1
assert_eq "$((before_invalid_id_requests + 1))" "$(request_count)" "invalid artifact id request count"
assert_contains "did not include an artifact id and HTTP upload URL" "$TMP_DIR/invalid-id.out"
printf 'ok\n' > "$TMP_DIR/server/mode"

# Registration accepts only a regular file reached without symlinks below the
# run's artifact root. An existing link to an external file is rejected before
# metadata or bytes reach DexCode.
external_file="$TMP_DIR/external-secret.txt"
printf 'external bytes must never upload\n' > "$external_file"
external_link="$(dx_run_artifact_file "$run_id" "reports/external-link.txt")"
ln -s "$external_file" "$external_link"
before_symlink_requests="$(request_count)"
if dx_run_register_artifact "$run_id" "test_output" \
  "reports/external-link.txt" "External symlink" > "$TMP_DIR/symlink.out" 2>&1; then
  printf 'artifact registration accepted an external symlink\n' >&2
  exit 1
fi
assert_eq "$before_symlink_requests" "$(request_count)" "external symlink request count"

# Snapshotting happens before artifact.created is emitted. Simulate a callback
# that swaps the original path at that exact boundary; the upload and digest
# must still describe the bytes captured before the swap.
swap_file="$(dx_run_artifact_file "$run_id" "reports/swap-race.txt")"
printf 'safe bytes captured before event\n' > "$swap_file"
before_swap_requests="$(request_count)"
(
  # Called indirectly by dx_run_register_artifact after this override is defined.
  # shellcheck disable=SC2329
  dx_event_emit_safe() {
    if [[ "${2:-}" == "artifact.created" ]]; then
      rm -f "$swap_file"
      ln -s "$external_file" "$swap_file"
    fi
    dx_event_emit "$@" 2>/dev/null || true
    return 0
  }
  dx_run_register_artifact "$run_id" "test_output" \
    "reports/swap-race.txt" "Swap-resistant artifact"
)
assert_eq "$((before_swap_requests + 3))" "$(request_count)" "swap-race request count"
[[ -L "$swap_file" ]] || {
  printf 'artifact swap fixture did not replace the original path\n' >&2
  exit 1
}
python3 - "$TMP_DIR/server/requests.jsonl" <<'PY'
import base64
import hashlib
import json
import sys
from pathlib import Path

records = [json.loads(line) for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()]
register, upload, confirm = records[-3:]
expected = b"safe bytes captured before event\n"
assert register["body"]["filename"] == "swap-race.txt", register
assert base64.b64decode(upload["body"]["base64"]) == expected, upload
assert confirm["body"]["byte_size"] == len(expected), confirm
assert confirm["body"]["sha256"] == hashlib.sha256(expected).hexdigest(), confirm
PY

# A failed PUT leaves a pending registration. Retrying the same local artifact
# reuses its key and remote id, then completes the original registration.
pending_file="$(dx_run_artifact_file "$run_id" "reports/pending-replay.txt")"
printf 'pending replay bytes\n' > "$pending_file"
printf 'upload-failure\n' > "$TMP_DIR/server/mode"
before_pending_requests="$(request_count)"
dx_run_register_artifact "$run_id" "test_output" \
  "reports/pending-replay.txt" "Pending replay"
assert_eq "$((before_pending_requests + 2))" "$(request_count)" "pending first-attempt request count"

printf 'ok\n' > "$TMP_DIR/server/mode"
dx_run_register_artifact "$run_id" "test_output" \
  "reports/pending-replay.txt" "Pending replay"
assert_eq "$((before_pending_requests + 5))" "$(request_count)" "pending replay request count"

python3 - "$TMP_DIR/server/requests.jsonl" "$manifest_file" "$run_id" <<'PY'
import hashlib
import json
import sys
from pathlib import Path

records = [json.loads(line) for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()]
manifest = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
run_id = sys.argv[3]
first_register, first_upload, replay_register, replay_upload, replay_confirm = records[-5:]
artifact = next(item for item in manifest["artifacts"] if item["path"] == "reports/pending-replay.txt")
fingerprint_source = json.dumps({
    "metadata": artifact["metadata"],
    "path": artifact["path"],
    "sha256": artifact["sha256"],
    "title": artifact["title"],
    "type": artifact["type"],
}, sort_keys=True, separators=(",", ":")).encode("utf-8")
fingerprint = hashlib.sha256(fingerprint_source).hexdigest()
key_source = json.dumps({
    "artifact_id": artifact["id"],
    "fingerprint": fingerprint,
    "run_id": run_id,
}, sort_keys=True, separators=(",", ":")).encode("utf-8")
expected_key = "dex-artifact-v1-" + hashlib.sha256(key_source).hexdigest()

assert first_register["idempotency_key"] == expected_key, first_register
assert replay_register["idempotency_key"] == expected_key, replay_register
assert first_register["body"] == replay_register["body"], (first_register, replay_register)
assert first_upload["path"] == replay_upload["path"], (first_upload, replay_upload)
remote_id = replay_upload["path"].rsplit("/", 1)[-1]
assert replay_confirm["path"].endswith(f"/artifacts/{remote_id}"), replay_confirm
assert artifact["dexcode_artifact_id"] == remote_id, artifact
assert artifact["dexcode_artifact_sha256"] == artifact["sha256"], artifact
assert artifact["dexcode_artifact_fingerprint"] == fingerprint, artifact
PY

# If confirmation succeeded but its response was lost, the next registration
# returns the completed artifact. The CLI must persist it without another PUT.
completed_file="$(dx_run_artifact_file "$run_id" "reports/completed-replay.txt")"
printf 'completed replay bytes\n' > "$completed_file"
printf 'confirmation-response-lost\n' > "$TMP_DIR/server/mode"
before_completed_requests="$(request_count)"
dx_run_register_artifact "$run_id" "test_output" \
  "reports/completed-replay.txt" "Completed replay"
assert_eq "$((before_completed_requests + 3))" "$(request_count)" "completed first-attempt request count"

printf 'ok\n' > "$TMP_DIR/server/mode"
dx_run_register_artifact "$run_id" "test_output" \
  "reports/completed-replay.txt" "Completed replay"
assert_eq "$((before_completed_requests + 4))" "$(request_count)" "completed replay skips upload"

python3 - "$TMP_DIR/server/requests.jsonl" "$manifest_file" <<'PY'
import json
import sys
from pathlib import Path

records = [json.loads(line) for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()]
manifest = json.loads(Path(sys.argv[2]).read_text(encoding="utf-8"))
first_register, first_upload, first_confirm, replay_register = records[-4:]
artifact = next(item for item in manifest["artifacts"] if item["path"] == "reports/completed-replay.txt")

assert first_register["idempotency_key"], first_register
assert replay_register["idempotency_key"] == first_register["idempotency_key"], replay_register
remote_id = first_upload["path"].rsplit("/", 1)[-1]
assert first_confirm["path"].endswith(f"/artifacts/{remote_id}"), first_confirm
assert replay_register["path"].endswith("/artifacts"), replay_register
assert artifact["dexcode_artifact_id"] == remote_id, artifact
assert artifact["dexcode_artifact_sha256"] == artifact["sha256"], artifact
assert artifact["dexcode_artifact_fingerprint"], artifact
PY

conflict_fingerprint="aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"
conflict_artifact_id=$(dx_dexcode_upload_artifact \
  "$run_id" "$artifact_file" "test_output" "Conflict original" \
  "result.txt" "art_conflict" "$conflict_fingerprint")
[[ -n "$conflict_artifact_id" ]] || {
  printf 'initial conflict fixture upload did not complete\n' >&2
  exit 1
}
dx_dexcode_upload_artifact "$run_id" "$artifact_file" "test_output" \
  "Conflict changed" "result.txt" "art_conflict" "$conflict_fingerprint" \
  > "$TMP_DIR/idempotency-conflict.out" 2>&1
assert_contains "artifact registration failed (HTTP 409)" "$TMP_DIR/idempotency-conflict.out"

# Registering an artifact and sending its bytes are not the same request, and
# they were sharing one 15s budget. dx_dexcode_content_type names webm, mp4 and
# zip, so the bytes can be a captured video or a Playwright trace — which does
# not cross a home upstream in fifteen seconds, and used to fail by the clock
# with the artifact left sitting locally.
timeout_stub_dir="$TMP_DIR/timeout-stub-bin"
mkdir -p "$timeout_stub_dir"
cat > "$timeout_stub_dir/curl" <<'STUB'
#!/usr/bin/env bash
# Drain stdin first and always: the caller pipes the auth config in, and a stub
# that exits without reading it kills that printf with SIGPIPE, failing the
# pipeline and reporting HTTP 000 on whichever call loses the race.
cat > /dev/null
printf '%s\n' "$*" >> "$DX_TEST_CURL_ARGV_LOG"
output=""
previous=""
for argument in "$@"; do
  [[ "$previous" == "-o" ]] && output="$argument"
  previous="$argument"
done
if [[ "$*" != *"-X PUT"* && -n "$output" ]]; then
  printf '{"id":"art_stub","state":"pending","upload":{"url":"http://127.0.0.1:1/put"}}' > "$output"
fi
printf '200'
STUB
chmod +x "$timeout_stub_dir/curl"

export DX_TEST_CURL_ARGV_LOG="$TMP_DIR/timeout-argv.txt"
: > "$DX_TEST_CURL_ARGV_LOG"
PATH="$timeout_stub_dir:$PATH" dx_dexcode_upload_artifact \
  "$run_id" "$artifact_file" "test_output" "Timeout budget" "capture.webm" >/dev/null 2>&1 || true

assert_eq "3" "$(wc -l < "$DX_TEST_CURL_ARGV_LOG" | tr -d '[:space:]')" "artifact upload curl calls"
put_budget="$(grep -F -- '-X PUT' "$DX_TEST_CURL_ARGV_LOG" | sed -n 's/.*--max-time \([0-9]*\).*/\1/p')"
assert_eq "300" "$put_budget" "artifact body --max-time"
api_budgets="$(grep -Fv -- '-X PUT' "$DX_TEST_CURL_ARGV_LOG" | sed -n 's/.*--max-time \([0-9]*\).*/\1/p' | sort -u)"
assert_eq "15" "$api_budgets" "artifact API --max-time"

: > "$DX_TEST_CURL_ARGV_LOG"
PATH="$timeout_stub_dir:$PATH" DEXCODE_UPLOAD_TIMEOUT_SECONDS=42 dx_dexcode_upload_artifact \
  "$run_id" "$artifact_file" "test_output" "Timeout override" "capture.webm" >/dev/null 2>&1 || true
put_budget="$(grep -F -- '-X PUT' "$DX_TEST_CURL_ARGV_LOG" | sed -n 's/.*--max-time \([0-9]*\).*/\1/p')"
assert_eq "42" "$put_budget" "overridden artifact body --max-time"

printf 'dexcode-artifact-test passed\n'
