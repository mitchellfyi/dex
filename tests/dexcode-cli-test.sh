#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-dexcode-cli-test.XXXXXX")"
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
export DEXCODE_OPEN_BROWSER=0
export DEXCODE_CONTEXT_SYNC=0

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

assert_file() {
  [[ -f "$1" ]] || {
    printf 'missing file: %s\n' "$1" >&2
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

assert_contains() {
  local needle="$1" file="$2"
  grep -Fq "$needle" "$file" || {
    printf 'missing expected text: %s\n' "$needle" >&2
    printf 'output was:\n' >&2
    cat "$file" >&2
    exit 1
  }
}

json_value() {
  local file="$1" key="$2"
  DX_TEST_JSON_FILE="$file" DX_TEST_JSON_KEY="$key" python3 - <<'PY'
import json
import os
from pathlib import Path

value = json.loads(Path(os.environ["DX_TEST_JSON_FILE"]).read_text(encoding="utf-8"))
for part in os.environ["DX_TEST_JSON_KEY"].split("."):
    if part.isdigit():
        value = value[int(part)]
    else:
        value = value[part]
print(value)
PY
}

start_server() {
  local server_dir="$TMP_DIR/server"
  mkdir -p "$server_dir"
  cat > "$server_dir/server.py" <<'PY'
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

root = Path(sys.argv[1])
requests_file = root / "requests.jsonl"
port_file = root / "port"

PROFILE = {
    "account": {"slug": "sample-org", "name": "Sample Organisation", "personal": True},
    "organisations": [{"slug": "sample-org", "name": "Sample Organisation", "personal": True, "default": True}],
    "default_project": {"slug": "personal", "name": "Personal", "default_branch": "main", "default": True},
    "projects": [
        {"slug": "personal", "name": "Personal", "default_branch": "main", "default": True},
        {"slug": "sample-repository", "name": "Sample Repository", "default_branch": "main", "default": False},
    ],
    "sync": {"factory_url": ""},
}


class Handler(BaseHTTPRequestHandler):
    def _record(self, body):
        with requests_file.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({
                "method": self.command,
                "path": self.path,
                "authorization": self.headers.get("Authorization", ""),
                "body": body,
            }, sort_keys=True, separators=(",", ":")))
            fh.write("\n")

    def _json(self, status, payload):
        payload = dict(payload)
        if payload.get("sync", {}).get("factory_url") == "":
            payload["sync"]["factory_url"] = f"http://127.0.0.1:{self.server.server_port}"
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(json.dumps(payload).encode("utf-8"))

    def do_GET(self):
        self._record({})
        if self.path == "/api/v1/profile":
            self._json(200, PROFILE)
            return
        self._json(404, {"error": "not_found"})

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        body = json.loads(raw.decode("utf-8")) if raw else {}
        self._record(body)
        if self.path == "/api/v1/device_authorizations":
            self._json(201, {
                "device_code": "device-test-code",
                "user_code": "ABCD-2345",
                "verification_uri": f"http://127.0.0.1:{self.server.server_port}/device",
                "verification_uri_complete": f"http://127.0.0.1:{self.server.server_port}/device?code=ABCD-2345",
                "expires_in": 900,
                "interval": 1,
                "expires_at": "2026-06-15T12:15:00Z",
            })
            return
        if self.path == "/api/v1/device_authorizations/token":
            self._json(200, {
                "access_token": "dc_live_test_token",
                "token_type": "Bearer",
                "expires_at": "2027-06-15T12:00:00Z",
                "scopes": ["runs:write", "artifacts:write"],
                "profile": PROFILE,
            })
            return
        if self.path == "/api/v1/runs":
            self._json(201, {"id": body.get("external_id"), "status": "running"})
            return
        if self.path == "/api/v1/projects":
            name = (body.get("project") or {}).get("name") or "Example Project"
            slug = name.lower().replace(" ", "-")
            project = {
                "slug": slug,
                "name": name,
                "default_branch": "main",
                "organisation_slug": "sample-org",
                "organisation_name": "Sample Organisation",
                "default": True,
            }
            PROFILE["projects"] = [
                dict(existing, default=False)
                for existing in PROFILE.get("projects", [])
                if existing.get("slug") != slug
            ] + [project]
            PROFILE["default_project"] = project
            self._json(201, project)
            return
        if self.path.startswith("/api/v1/projects/") and self.path.endswith("/context"):
            self._json(201, {
                "project": {"slug": self.path.split("/")[4], "name": "Sample Repository"},
                "synced": len(body.get("entries") or []),
                "stale": 0,
                "integrations_synced": len(body.get("integrations") or []),
            })
            return
        self._json(404, {"error": "not_found"})

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

create_repo() {
  local repo_dir="$1"
  mkdir -p "$repo_dir"
  git -C "$repo_dir" init -q
  git -C "$repo_dir" config user.email "dex@example.test"
  git -C "$repo_dir" config user.name "Dex Test"
  printf '# test repo\n' > "$repo_dir/README.md"
  git -C "$repo_dir" add README.md
  git -C "$repo_dir" commit -q -m "init"
  git -C "$repo_dir" branch -M main
  git -C "$repo_dir" remote add origin git@github.com:example/sample-repository.git
}

create_dex_context() {
  local repo_dir="$1"
  mkdir -p "$repo_dir/.dex/rules"
  printf '# Dex\n\nSample project context.\n' > "$repo_dir/.dex/dex.md"
  printf '# Testing\n\nUse sample project fixtures.\n' > "$repo_dir/.dex/rules/testing.md"
  cat > "$repo_dir/.mcp.json" <<'JSON'
{
  "mcpServers": {
    "sample-browser": {
      "command": "npx",
      "args": ["-y", "@example/sample-browser"],
      "env": {
        "SAMPLE_TOKEN": "do-not-sync-value"
      }
    }
  }
}
JSON
}

start_server

dx_dexcode_login --url "$SERVER_URL" --no-browser --timeout 10 >/dev/null
assert_file "$DEXCODE_CONFIG_FILE"
assert_eq "dc_live_test_token" "$(json_value "$DEXCODE_CONFIG_FILE" "access_token")" "saved token"
assert_eq "personal" "$(json_value "$DEXCODE_CONFIG_FILE" "default_project.slug")" "saved default project"
dx_dexcode_whoami --offline > "$TMP_DIR/whoami-personal.out"
assert_contains "DexCode account: Sample Organisation" "$TMP_DIR/whoami-personal.out"
assert_contains "Connected project: Personal (personal)" "$TMP_DIR/whoami-personal.out"
printf '2\n' | dx_dexcode_select_project --force >/dev/null
assert_eq "sample-repository" "$(json_value "$DEXCODE_CONFIG_FILE" "default_project.slug")" "selected project"
dx_dexcode_whoami > "$TMP_DIR/whoami-sample.out"
assert_eq "sample-repository" "$(json_value "$DEXCODE_CONFIG_FILE" "default_project.slug")" "preserved selected project"
assert_contains "Connected project: Sample Repository (sample-repository)" "$TMP_DIR/whoami-sample.out"
printf '3\nExample Workspace\n' | dx_dexcode_select_project --force >/dev/null
assert_eq "example-workspace" "$(json_value "$DEXCODE_CONFIG_FILE" "default_project.slug")" "created project selected"
assert_eq "Example Workspace" "$(json_value "$DEXCODE_CONFIG_FILE" "default_project.name")" "created project name"

repo_dir="$TMP_DIR/repo"
create_repo "$repo_dir"
create_dex_context "$repo_dir"
export DEXCODE_CONTEXT_SYNC=1

run_id="$(dx_run_prepare "dexcode-cli-session" "$repo_dir" "in-place" "dexcode-cli-test" "Track this run" "dx")"
dx_dexcode_prepare_run_sync "$run_id" "$repo_dir" "in-place" "dexcode-cli-test" "Track this run" "dx" >/dev/null

assert_eq "true" "$DEX_FACTORY_SYNC" "factory sync"
assert_eq "$SERVER_URL" "$DEX_FACTORY_URL" "factory url"
assert_eq "dc_live_test_token" "$DEX_FACTORY_TOKEN" "factory token"
assert_eq "${SERVER_URL}/api/v1/runs/${run_id}/events/batch" "$DEX_FACTORY_EVENTS_ENDPOINT" "events endpoint"

runs_request="$TMP_DIR/run-request.json"
python3 - "$SERVER_DIR/requests.jsonl" "$runs_request" <<'PY'
import json
import sys
from pathlib import Path

for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    record = json.loads(line)
    if record["path"] == "/api/v1/runs":
        Path(sys.argv[2]).write_text(json.dumps(record, sort_keys=True), encoding="utf-8")
        break
else:
    raise SystemExit("missing /api/v1/runs request")
PY

assert_eq "Bearer dc_live_test_token" "$(json_value "$runs_request" "authorization")" "run auth"
assert_eq "$run_id" "$(json_value "$runs_request" "body.external_id")" "run id"
assert_eq "example-workspace" "$(json_value "$runs_request" "body.project.slug")" "run project"
assert_eq "example" "$(json_value "$runs_request" "body.repository.owner")" "repo owner"
assert_eq "sample-repository" "$(json_value "$runs_request" "body.repository.name")" "repo name"
assert_eq "local_cli" "$(json_value "$runs_request" "body.metadata.source_type")" "source type"

context_request="$TMP_DIR/context-request.json"
python3 - "$SERVER_DIR/requests.jsonl" "$context_request" <<'PY'
import json
import sys
from pathlib import Path

records = [
    json.loads(line)
    for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()
    if line.strip()
]
for record in reversed(records):
    if record["path"] == "/api/v1/projects/example-workspace/context":
        Path(sys.argv[2]).write_text(json.dumps(record, sort_keys=True), encoding="utf-8")
        break
else:
    raise SystemExit("missing project context request")
PY

assert_eq "Bearer dc_live_test_token" "$(json_value "$context_request" "authorization")" "context auth"
assert_eq ".dex/dex.md" "$(json_value "$context_request" "body.entries.0.path")" "context entry path"
assert_eq "MCP: sample-browser" "$(json_value "$context_request" "body.integrations.0.name")" "context integration"
assert_eq "sample-browser" "$(json_value "$context_request" "body.integrations.0.metadata.server_name")" "mcp server name"
assert_eq "SAMPLE_TOKEN" "$(json_value "$context_request" "body.integrations.0.metadata.env_keys.0")" "mcp env key"
if grep -Fq "do-not-sync-value" "$context_request"; then
  printf 'context request leaked an MCP env value\n' >&2
  exit 1
fi

printf 'dexcode-cli-test passed\n'
