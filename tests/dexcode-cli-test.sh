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

hostname_hash="$(dx_dexcode_hostname_hash)"
[[ "$hostname_hash" =~ ^[0-9a-f]{64}$ ]] || {
  printf 'hostname hash was not SHA-256: %s\n' "$hostname_hash" >&2
  exit 1
}

dx_dexcode_prepare_run_sync "run_optional_without_login" "$ROOT" "test" "optional" "Optional sync" "dx test"
DEXCODE_SYNC=false DEXCODE_SYNC_REQUIRED=1 dx_dexcode_prepare_run_sync \
  "run_explicitly_disabled" "$ROOT" "test" "disabled" "Disabled sync" "dx test"
if DEXCODE_SYNC_REQUIRED=1 dx_dexcode_prepare_run_sync \
  "run_required_without_login" "$ROOT" "test" "required" "Required sync" "dx test" \
  > "$TMP_DIR/required-sync.out" 2>&1; then
  printf 'required DexCode sync succeeded without a connection\n' >&2
  exit 1
fi
grep -Fq -- "this machine is not connected" "$TMP_DIR/required-sync.out" || {
  printf 'required DexCode sync did not explain its missing connection\n' >&2
  cat "$TMP_DIR/required-sync.out" >&2
  exit 1
}
required_context_repo="$TMP_DIR/required-context-repo"
mkdir -p "$required_context_repo/.dex"
if DEXCODE_CONTEXT_SYNC=1 DEXCODE_CONTEXT_SYNC_REQUIRED=1 \
  dx_dexcode_sync_project_context "$required_context_repo" \
  > "$TMP_DIR/required-context.out" 2>&1; then
  printf 'required project context sync succeeded without a connection\n' >&2
  exit 1
fi
grep -Fq -- "requires a connected project" "$TMP_DIR/required-context.out" || {
  printf 'required context sync did not explain its missing connection\n' >&2
  cat "$TMP_DIR/required-context.out" >&2
  exit 1
}

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
  grep -Fq -- "$needle" "$file" || {
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
  printf 'approved\n' > "$server_dir/token-mode"
  printf 'ok\n' > "$server_dir/device-mode"
  printf 'ok\n' > "$server_dir/profile-mode"
  printf 'ok\n' > "$server_dir/run-mode"
  printf 'ok\n' > "$server_dir/context-mode"
  printf 'ok\n' > "$server_dir/project-mode"
  printf '1\n' > "$server_dir/poll-interval"
  cat > "$server_dir/server.py" <<'PY'
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

root = Path(sys.argv[1])
requests_file = root / "requests.jsonl"
port_file = root / "port"
token_mode_file = root / "token-mode"
device_mode_file = root / "device-mode"
profile_mode_file = root / "profile-mode"
run_mode_file = root / "run-mode"
context_mode_file = root / "context-mode"
project_mode_file = root / "project-mode"
poll_interval_file = root / "poll-interval"

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
            if profile_mode_file.read_text(encoding="utf-8").strip() == "error":
                self._json(503, {"error": "temporarily_unavailable"})
                return
            self._json(200, PROFILE)
            return
        self._json(404, {"error": "not_found"})

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        body = json.loads(raw.decode("utf-8")) if raw else {}
        self._record(body)
        if self.path == "/api/v1/device_authorizations":
            if device_mode_file.read_text(encoding="utf-8").strip() == "invalid":
                self._json(201, {
                    "device_code": "device-invalid",
                    "user_code": "ABCD-2345",
                    "verification_uri": "ftp://dexcode.example/device",
                    "interval": 1,
                })
                return
            self._json(201, {
                "device_code": "device-test-\"code",
                "user_code": "ABCD-2345",
                "verification_uri": f"http://127.0.0.1:{self.server.server_port}/device",
                "verification_uri_complete": f"http://127.0.0.1:{self.server.server_port}/device?code=ABCD-2345",
                "expires_in": 900,
                "interval": int(poll_interval_file.read_text(encoding="utf-8").strip()),
                "expires_at": "2026-06-15T12:15:00Z",
            })
            return
        if self.path == "/api/v1/device_authorizations/token":
            token_mode = token_mode_file.read_text(encoding="utf-8").strip()
            if token_mode == "pending":
                self._json(202, {"status": "pending"})
                return
            if token_mode == "denied":
                self._json(403, {"error": "access_denied"})
                return
            if token_mode == "invalid":
                self._json(200, {"access_token": "invalid\nheader-value"})
                return
            self._json(200, {
                "access_token": "dc_live_test_token",
                "token_type": "Bearer",
                "expires_at": "2027-06-15T12:00:00Z",
                "scopes": ["runs:write", "artifacts:write"],
                "profile": PROFILE,
            })
            return
        if self.path == "/api/v1/runs":
            if run_mode_file.read_text(encoding="utf-8").strip() == "error":
                self._json(503, {"error": "temporarily_unavailable"})
                return
            self._json(201, {"id": body.get("external_id"), "status": "running"})
            return
        if self.path == "/api/v1/projects":
            name = (body.get("project") or {}).get("name") or "Example Project"
            if project_mode_file.read_text(encoding="utf-8").strip() == "dot-segment":
                self._json(201, {"slug": "..", "name": name})
                return
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
            context_mode = context_mode_file.read_text(encoding="utf-8").strip()
            if context_mode == "error":
                self._json(503, {"error": "temporarily_unavailable"})
                return
            if context_mode == "invalid":
                self.send_response(200)
                self.send_header("Content-Type", "application/json")
                self.end_headers()
                self.wfile.write(b"[]")
                return
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
  git -C "$repo_dir" remote add origin "https://token-user:remote-password@github.com/example/sample-repository.git?access_token=remote-secret#fragment-secret"
}

create_dex_context() {
  local repo_dir="$1"
  mkdir -p "$repo_dir/.dex/rules"
  printf '# Dex\n\nSample project context.\n' > "$repo_dir/.dex/dex.md"
  printf '# Testing\n\nUse sample project fixtures.\n' > "$repo_dir/.dex/rules/testing.md"
  printf '# Outside\n\nnever-sync-this-symlink-target\n' > "$repo_dir/../outside-context.md"
  ln -s "$repo_dir/../outside-context.md" "$repo_dir/.dex/rules/external.md"
  DX_TEST_UNICODE_FILE="$repo_dir/.dex/rules/unicode.md" python3 - <<'PY'
import os
from pathlib import Path

Path(os.environ["DX_TEST_UNICODE_FILE"]).write_text("🙂" * 10000, encoding="utf-8")
PY
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

if dx_dexcode_login --url "ftp://dexcode.example" --no-browser > "$TMP_DIR/login-url.out" 2>&1; then
  printf 'login accepted a non-HTTP API URL\n' >&2
  exit 1
fi
assert_contains "--url must be an HTTP or HTTPS base URL" "$TMP_DIR/login-url.out"

if dx_dexcode_login --url "http://127.0.0.1:9" --no-browser --timeout 0 > "$TMP_DIR/login-timeout.out" 2>&1; then
  printf 'login accepted a zero timeout\n' >&2
  exit 1
fi
assert_contains "--timeout must be a whole number from 1 to 86400 seconds" "$TMP_DIR/login-timeout.out"

dx_dexcode_login --help > "$TMP_DIR/login-help.out"
assert_contains "--timeout SECONDS" "$TMP_DIR/login-help.out"
if dx_dexcode_login --url > "$TMP_DIR/login-missing-url.out" 2>&1; then
  printf 'login accepted --url without a value\n' >&2
  exit 1
fi
assert_contains "--url requires a value" "$TMP_DIR/login-missing-url.out"
if dx_dexcode_login --unexpected > "$TMP_DIR/login-arg.out" 2>&1; then
  printf 'login ignored an unexpected argument\n' >&2
  exit 1
fi
assert_contains "Unknown dx login option" "$TMP_DIR/login-arg.out"

start_server

if dx_dexcode_path_segment_valid "." || dx_dexcode_path_segment_valid ".."; then
  printf 'path segment validation accepted a dot boundary\n' >&2
  exit 1
fi

dx_dexcode_login --url "$SERVER_URL" --no-browser --timeout 10 >/dev/null
assert_file "$DEXCODE_CONFIG_FILE"
assert_eq "dc_live_test_token" "$(json_value "$DEXCODE_CONFIG_FILE" "access_token")" "saved token"
assert_eq "personal" "$(json_value "$DEXCODE_CONFIG_FILE" "default_project.slug")" "saved default project"
assert_eq "2027-06-15T12:00:00Z" "$(json_value "$DEXCODE_CONFIG_FILE" "expires_at")" "saved expiry"
assert_eq "artifacts:write" "$(json_value "$DEXCODE_CONFIG_FILE" "scopes.1")" "saved scopes"

# The successful token response includes a complete profile. If the follow-up
# profile refresh fails, its JSON error body must not replace that profile.
mv "$DEXCODE_CONFIG_FILE" "$DEXCODE_CONFIG_FILE.saved"
printf 'error\n' > "$SERVER_DIR/profile-mode"
dx_dexcode_login --url "$SERVER_URL" --no-browser --timeout 10 >/dev/null
assert_eq "sample-org" "$(json_value "$DEXCODE_CONFIG_FILE" "account.slug")" "token-response profile fallback"
assert_eq "personal" "$(json_value "$DEXCODE_CONFIG_FILE" "default_project.slug")" "token-response default project fallback"
rm -f "$DEXCODE_CONFIG_FILE"
mv "$DEXCODE_CONFIG_FILE.saved" "$DEXCODE_CONFIG_FILE"
printf 'ok\n' > "$SERVER_DIR/profile-mode"

printf 'invalid\n' > "$SERVER_DIR/device-mode"
if dx_dexcode_login --url "$SERVER_URL" --no-browser --timeout 10 > "$TMP_DIR/login-invalid-device.out" 2>&1; then
  printf 'login accepted an invalid device authorization response\n' >&2
  exit 1
fi
assert_contains "invalid device authorization response" "$TMP_DIR/login-invalid-device.out"
printf 'ok\n' > "$SERVER_DIR/device-mode"

printf 'invalid\n' > "$SERVER_DIR/token-mode"
if dx_dexcode_login --url "$SERVER_URL" --no-browser --timeout 10 > "$TMP_DIR/login-invalid-token.out" 2>&1; then
  printf 'login accepted a token containing invalid Bearer characters\n' >&2
  exit 1
fi
assert_contains "returned an invalid access token" "$TMP_DIR/login-invalid-token.out"
printf 'denied\n' > "$SERVER_DIR/token-mode"
if dx_dexcode_login --url "$SERVER_URL" --no-browser --timeout 10 > "$TMP_DIR/login-denied.out" 2>&1; then
  printf 'login accepted a denied device authorization\n' >&2
  exit 1
fi
assert_contains "login was not approved (HTTP 403)" "$TMP_DIR/login-denied.out"
printf 'approved\n' > "$SERVER_DIR/token-mode"
assert_eq "dc_live_test_token" "$(json_value "$DEXCODE_CONFIG_FILE" "access_token")" "failed login preserved config"

boundary_token="$TMP_DIR/boundary-token.json"
boundary_profile="$TMP_DIR/boundary-profile.json"
boundary_config="$TMP_DIR/boundary-dexcode.json"
printf '{"access_token":"boundary-token"}\n' > "$boundary_token"
cat > "$boundary_profile" <<'JSON'
{
  "account": {"slug": ".", "name": "Dot Organisation"},
  "projects": [{"slug": "..", "name": "Parent Project", "organisation_slug": "."}],
  "default_project": {"slug": "..", "name": "Parent Project", "organisation_slug": "."}
}
JSON
DEXCODE_CONFIG_FILE="$boundary_config" \
  dx_dexcode_write_login_config "$SERVER_URL" "$boundary_token" "$boundary_profile"
python3 - "$boundary_config" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert data["account"] == {}, data
assert data["projects"] == [], data
assert data["default_project"] is None, data
assert data["connections"] == {}, data
PY

printf 'dot-segment\n' > "$SERVER_DIR/project-mode"
if dx_dexcode_create_project "Boundary Project" > "$TMP_DIR/project-boundary.out" 2>&1; then
  printf 'project creation accepted a dot-segment slug\n' >&2
  exit 1
fi
assert_contains "returned an invalid project response" "$TMP_DIR/project-boundary.out"
printf 'ok\n' > "$SERVER_DIR/project-mode"

token_request="$TMP_DIR/token-request.json"
python3 - "$SERVER_DIR/requests.jsonl" "$token_request" <<'PY'
import json
import sys
from pathlib import Path

for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    record = json.loads(line)
    if record["path"] == "/api/v1/device_authorizations/token":
        Path(sys.argv[2]).write_text(json.dumps(record, sort_keys=True), encoding="utf-8")
        break
else:
    raise SystemExit("missing device token request")
PY
assert_eq 'device-test-"code' "$(json_value "$token_request" "body.device_code")" "device code JSON encoding"

dx_dexcode_logout --help > "$TMP_DIR/logout-help.out"
assert_file "$DEXCODE_CONFIG_FILE"
if dx_dexcode_logout unexpected > "$TMP_DIR/logout-arg.out" 2>&1; then
  printf 'logout ignored an unexpected argument\n' >&2
  exit 1
fi
assert_file "$DEXCODE_CONFIG_FILE"
assert_contains "Unknown dx logout option" "$TMP_DIR/logout-arg.out"

dx_dexcode_whoami --help > "$TMP_DIR/whoami-help.out"
assert_contains "--offline" "$TMP_DIR/whoami-help.out"
if dx_dexcode_whoami --unexpected > "$TMP_DIR/whoami-arg.out" 2>&1; then
  printf 'whoami ignored an unexpected argument\n' >&2
  exit 1
fi
assert_contains "Unknown dx whoami option" "$TMP_DIR/whoami-arg.out"

dx_dexcode_command --help > "$TMP_DIR/dexcode-help.out"
assert_contains "dx dexcode <login|logout|whoami|use>" "$TMP_DIR/dexcode-help.out"
dx_dexcode_command use --help > "$TMP_DIR/use-help.out"
assert_contains "dx dexcode use" "$TMP_DIR/use-help.out"
if dx_dexcode_command use --unexpected > "$TMP_DIR/use-arg.out" 2>&1; then
  printf 'dexcode use ignored an unexpected argument\n' >&2
  exit 1
fi
assert_contains "Unknown dx dexcode use option" "$TMP_DIR/use-arg.out"

dx_dexcode_whoami --offline > "$TMP_DIR/whoami-personal.out"
# "account" was ambiguous once a machine can hold a connection per
# organisation; the value was always the organisation's name.
assert_contains "DexCode organisation: Sample Organisation" "$TMP_DIR/whoami-personal.out"
assert_contains "Connected organisations: sample-org" "$TMP_DIR/whoami-personal.out"
assert_contains "Connected project: Personal (personal)" "$TMP_DIR/whoami-personal.out"
assert_contains "Session sync: enabled" "$TMP_DIR/whoami-personal.out"
assert_contains "Event sync: enabled" "$TMP_DIR/whoami-personal.out"
assert_contains "Project context sync: disabled" "$TMP_DIR/whoami-personal.out"
DEXCODE_SYNC=off DEXCODE_CONTEXT_SYNC=no dx_dexcode_whoami --offline > "$TMP_DIR/whoami-disabled.out"
assert_contains "Session sync: disabled" "$TMP_DIR/whoami-disabled.out"
assert_contains "Event sync: disabled" "$TMP_DIR/whoami-disabled.out"
assert_contains "Project context sync: disabled" "$TMP_DIR/whoami-disabled.out"
DEX_FACTORY_SYNC=unexpected dx_dexcode_whoami --offline > "$TMP_DIR/whoami-invalid-event-sync.out"
assert_contains "Session sync: enabled" "$TMP_DIR/whoami-invalid-event-sync.out"
assert_contains "Event sync: disabled" "$TMP_DIR/whoami-invalid-event-sync.out"
printf '2\n' | dx_dexcode_select_project --force >/dev/null
assert_eq "sample-repository" "$(json_value "$DEXCODE_CONFIG_FILE" "default_project.slug")" "selected project"
dx_dexcode_whoami > "$TMP_DIR/whoami-sample.out"
assert_eq "sample-repository" "$(json_value "$DEXCODE_CONFIG_FILE" "default_project.slug")" "preserved selected project"
assert_eq "2027-06-15T12:00:00Z" "$(json_value "$DEXCODE_CONFIG_FILE" "expires_at")" "preserved expiry after refresh"
assert_eq "artifacts:write" "$(json_value "$DEXCODE_CONFIG_FILE" "scopes.1")" "preserved scopes after refresh"
assert_contains "Connected project: Sample Repository (sample-repository)" "$TMP_DIR/whoami-sample.out"
assert_contains "DexCode sync URL: $SERVER_URL" "$TMP_DIR/whoami-sample.out"
printf '3\nExample Workspace\n' | dx_dexcode_select_project --force >/dev/null
assert_eq "example-workspace" "$(json_value "$DEXCODE_CONFIG_FILE" "default_project.slug")" "created project selected"
assert_eq "Example Workspace" "$(json_value "$DEXCODE_CONFIG_FILE" "default_project.name")" "created project name"

repo_dir="$TMP_DIR/repo"
create_repo "$repo_dir"
create_dex_context "$repo_dir"
export DEXCODE_CONTEXT_SYNC=1

printf 'error\n' > "$SERVER_DIR/run-mode"
dx_dexcode_prepare_run_sync "run_optional_remote_failure" "$repo_dir" "test" \
  "optional-remote-failure" "Optional remote failure" "dx test" \
  > "$TMP_DIR/optional-run-failure.out" 2>&1
assert_contains "run registration failed (HTTP 503); continuing locally" "$TMP_DIR/optional-run-failure.out"
if DEXCODE_SYNC_REQUIRED=1 dx_dexcode_prepare_run_sync "run_required_remote_failure" \
  "$repo_dir" "test" "required-remote-failure" "Required remote failure" "dx test" \
  > "$TMP_DIR/required-run-failure.out" 2>&1; then
  printf 'required run sync ignored a remote registration failure\n' >&2
  exit 1
fi
assert_contains "run registration failed (HTTP 503)" "$TMP_DIR/required-run-failure.out"
printf 'ok\n' > "$SERVER_DIR/run-mode"

run_id="$(dx_run_prepare "dexcode-cli-session" "$repo_dir" "in-place" "dexcode-cli-test" "Track this run" "dx")"
dx_dexcode_prepare_run_sync "$run_id" "$repo_dir" "in-place" "dexcode-cli-test" "Track this run" "dx" >/dev/null

assert_eq "true" "$DEX_FACTORY_SYNC" "factory sync"
assert_eq "$SERVER_URL" "$DEX_FACTORY_URL" "factory url"
assert_eq "dc_live_test_token" "$DEX_FACTORY_TOKEN" "factory token"
assert_eq "${SERVER_URL}/api/v1/runs/${run_id}/events/batch" "$DEX_FACTORY_EVENTS_ENDPOINT" "events endpoint"

# An explicitly configured event collector takes precedence over the Factory
# base. Dex-generated standard endpoints are still refreshed for each run.
export DEX_FACTORY_EVENTS_ENDPOINT="${SERVER_URL}/custom-events/{run_id}"
dx_dexcode_prepare_run_sync "run_custom_event_endpoint" "$repo_dir" "in-place" \
  "custom-event-endpoint" "Keep the custom event endpoint" "dx" >/dev/null
assert_eq "${SERVER_URL}/custom-events/{run_id}" "$DEX_FACTORY_EVENTS_ENDPOINT" "custom events endpoint"
export DEX_FACTORY_EVENTS_ENDPOINT="${SERVER_URL}/api/v1/runs/run_previous/events/batch"
dx_dexcode_prepare_run_sync "run_refreshed_event_endpoint" "$repo_dir" "in-place" \
  "refreshed-event-endpoint" "Refresh the generated event endpoint" "dx" >/dev/null
assert_eq "${SERVER_URL}/api/v1/runs/run_refreshed_event_endpoint/events/batch" \
  "$DEX_FACTORY_EVENTS_ENDPOINT" "refreshed generated events endpoint"

runs_request="$TMP_DIR/run-request.json"
python3 - "$SERVER_DIR/requests.jsonl" "$runs_request" "$run_id" <<'PY'
import json
import sys
from pathlib import Path

for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines():
    record = json.loads(line)
    if record["path"] == "/api/v1/runs" and record["body"].get("external_id") == sys.argv[3]:
        Path(sys.argv[2]).write_text(json.dumps(record, sort_keys=True), encoding="utf-8")
        break
else:
    raise SystemExit("missing /api/v1/runs request")
PY

assert_eq "Bearer dc_live_test_token" "$(json_value "$runs_request" "authorization")" "run auth"
assert_eq "$run_id" "$(json_value "$runs_request" "body.external_id")" "run id"
assert_eq "Track this run" "$(json_value "$runs_request" "body.task_title")" "run title"
assert_eq "example-workspace" "$(json_value "$runs_request" "body.project.slug")" "run project"
assert_eq "example" "$(json_value "$runs_request" "body.repository.owner")" "repo owner"
assert_eq "sample-repository" "$(json_value "$runs_request" "body.repository.name")" "repo name"
assert_eq "local_cli" "$(json_value "$runs_request" "body.metadata.source_type")" "source type"
if grep -Eq 'remote-password|remote-secret|fragment-secret|token-user' "$runs_request"; then
  printf 'run request leaked credentials from the repository remote\n' >&2
  exit 1
fi

cat > "$TMP_DIR/headless-spec.json" <<JSON
{
  "source": {
    "type": "github_issue",
    "id": "482",
    "title": "Fix artifact sync",
    "body": "Keep the remote artifact contract reliable."
  },
  "workflow": {"name": "ticket_to_pr", "requires_plan_approval": false}
}
JSON
DEX_HEADLESS_RUN=1 \
DEX_HEADLESS_RUN_SPEC_FILE="$TMP_DIR/headless-spec.json" \
DEX_HEADLESS_REQUIRES_PLAN_APPROVAL=false \
  dx_dexcode_create_run_payload "run_headless_contract" "$repo_dir" "in-place" "headless-contract" "Headless task" "dx run" \
  > "$TMP_DIR/headless-payload.json"
assert_eq "github_issue" "$(json_value "$TMP_DIR/headless-payload.json" "metadata.source_type")" "headless source type"
assert_eq "482" "$(json_value "$TMP_DIR/headless-payload.json" "metadata.source_id")" "headless source id"
assert_eq "False" "$(json_value "$TMP_DIR/headless-payload.json" "metadata.requires_plan_approval")" "headless plan approval"
assert_eq "Fix artifact sync" "$(json_value "$TMP_DIR/headless-payload.json" "task_title")" "headless task title"
assert_eq "Keep the remote artifact contract reliable." "$(json_value "$TMP_DIR/headless-payload.json" "task_body")" "headless task body"

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
if grep -Fq "never-sync-this-symlink-target" "$context_request"; then
  printf 'context request followed a symlink outside .dex\n' >&2
  exit 1
fi

python3 - "$context_request" <<'PY'
import json
import sys
from pathlib import Path

request = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
unicode_entry = next(entry for entry in request["body"]["entries"] if entry["path"] == ".dex/rules/unicode.md")
assert len(unicode_entry["body"].encode("utf-8")) <= 20000, len(unicode_entry["body"].encode("utf-8"))
assert unicode_entry["source_byte_size"] == 40000, unicode_entry
assert unicode_entry["body_byte_size"] <= 20000, unicode_entry
assert unicode_entry["truncated"] is True, unicode_entry
truncation = request["body"]["truncation"]
assert truncation["entry_max_bytes"] == 20000, truncation
assert truncation["total_max_bytes"] == 524288, truncation
encoded = json.dumps(request["body"], sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
assert len(encoded) <= truncation["total_max_bytes"], len(encoded)
PY

# Many context files would exceed both common ARG_MAX values and the context
# contract if concatenated without a budget. The file-backed request remains
# within the configured total and reports what it omitted or truncated.
DX_TEST_CONTEXT_RULES="$repo_dir/.dex/rules" python3 - <<'PY'
import os
from pathlib import Path

root = Path(os.environ["DX_TEST_CONTEXT_RULES"])
for index in range(40):
    (root / f"large-{index:02d}.md").write_text(
        f"# Large {index}\n\n" + ("context-data-" * 3000),
        encoding="utf-8",
    )
PY
DEXCODE_CONTEXT_TOTAL_MAX_BYTES=65536 \
DEXCODE_CONTEXT_ENTRY_MAX_BYTES=50000 \
  dx_dexcode_sync_project_context "$repo_dir" >/dev/null
bounded_context_request="$TMP_DIR/bounded-context-request.json"
python3 - "$SERVER_DIR/requests.jsonl" "$bounded_context_request" <<'PY'
import json
import sys
from pathlib import Path

records = [json.loads(line) for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()]
record = next(item for item in reversed(records) if item["path"].endswith("/context"))
Path(sys.argv[2]).write_text(json.dumps(record["body"], ensure_ascii=False), encoding="utf-8")
PY
python3 - "$bounded_context_request" <<'PY'
import json
import sys
from pathlib import Path

body = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
encoded = json.dumps(body, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
assert len(encoded) <= 65536, len(encoded)
truncation = body["truncation"]
assert truncation["total_max_bytes"] == 65536, truncation
assert truncation["entries_omitted"] > 0 or truncation["entries_truncated"] > 0, truncation
PY

printf 'error\n' > "$SERVER_DIR/context-mode"
dx_dexcode_sync_project_context "$repo_dir" > "$TMP_DIR/optional-context-failure.out" 2>&1
assert_contains "context sync failed (HTTP 503); continuing locally" "$TMP_DIR/optional-context-failure.out"
if DEXCODE_CONTEXT_SYNC_REQUIRED=1 dx_dexcode_sync_project_context "$repo_dir" \
  > "$TMP_DIR/required-context-failure.out" 2>&1; then
  printf 'required project context sync ignored a remote failure\n' >&2
  exit 1
fi
assert_contains "context sync failed (HTTP 503)" "$TMP_DIR/required-context-failure.out"

printf 'invalid\n' > "$SERVER_DIR/context-mode"
if DEXCODE_CONTEXT_SYNC_REQUIRED=1 dx_dexcode_sync_project_context "$repo_dir" \
  > "$TMP_DIR/invalid-context-response.out" 2>&1; then
  printf 'required project context sync accepted a non-object response\n' >&2
  exit 1
fi
assert_contains "context sync failed (an invalid response)" "$TMP_DIR/invalid-context-response.out"
printf 'ok\n' > "$SERVER_DIR/context-mode"

export DEX_FACTORY_SYNC=false
dx_dexcode_prepare_run_sync "run_event_sync_disabled" "$repo_dir" "in-place" \
  "event-sync-disabled" "Keep event sync disabled" "dx" >/dev/null
assert_eq "false" "$DEX_FACTORY_SYNC" "explicit event sync disable"
dx_dexcode_whoami --offline > "$TMP_DIR/whoami-event-disabled.out"
assert_contains "Session sync: enabled" "$TMP_DIR/whoami-event-disabled.out"
assert_contains "Event sync: disabled" "$TMP_DIR/whoami-event-disabled.out"
export DEX_FACTORY_SYNC=true

# A multi-megabyte task body is larger than ARG_MAX on supported macOS and
# many Linux configurations. It must travel through a private request file,
# not an environment variable or curl command-line argument.
large_run_body="$(python3 -c 'import sys; sys.stdout.write("x" * (3 * 1024 * 1024))')"
DEXCODE_CONTEXT_SYNC=0 dx_dexcode_prepare_run_sync "run_large_payload" "$repo_dir" \
  "in-place" "large-payload" "$large_run_body" "dx" >/dev/null
python3 - "$SERVER_DIR/requests.jsonl" <<'PY'
import json
import sys
from pathlib import Path

records = [json.loads(line) for line in Path(sys.argv[1]).read_text(encoding="utf-8").splitlines()]
record = next(
    item
    for item in reversed(records)
    if item["path"] == "/api/v1/runs" and item["body"].get("external_id") == "run_large_payload"
)
assert len(record["body"]["task_body"]) == 3 * 1024 * 1024, len(record["body"]["task_body"])
assert len(record["body"]["task_title"]) == 240, len(record["body"]["task_title"])
PY
unset large_run_body

printf 'pending\n' > "$SERVER_DIR/token-mode"
printf '5\n' > "$SERVER_DIR/poll-interval"
timeout_started=$(date +%s)
if (
  # Called indirectly by dx_dexcode_login after the library is sourced.
  # shellcheck disable=SC2329
  sleep() {
    printf '%s\n' "${1:-}" >> "$TMP_DIR/login-sleeps"
    command sleep "$@"
  }
  dx_dexcode_login --url "$SERVER_URL" --no-browser --timeout 1
) > "$TMP_DIR/login-expired.out" 2>&1; then
  printf 'pending login did not time out\n' >&2
  exit 1
fi
timeout_elapsed=$(($(date +%s) - timeout_started))
[[ "$timeout_elapsed" -le 15 ]] || {
  printf 'login timeout exceeded its deadline: %ss\n' "$timeout_elapsed" >&2
  exit 1
}
if [[ -f "$TMP_DIR/login-sleeps" ]] \
  && ! awk '$1 > 1 { exit 1 }' "$TMP_DIR/login-sleeps"; then
  printf 'login slept past its remaining approval deadline\n' >&2
  cat "$TMP_DIR/login-sleeps" >&2 2>/dev/null || true
  exit 1
fi
assert_contains "timed out before browser approval" "$TMP_DIR/login-expired.out"

# A transport failure is reported as HTTP 000, not the concatenated 000000
# produced when curl's write-out and a shell fallback are both printed.
kill "$SERVER_PID"
wait "$SERVER_PID" 2>/dev/null || true
SERVER_PID=""
dx_dexcode_whoami > "$TMP_DIR/whoami-unreachable.out" 2>&1
assert_contains "Could not reach DexCode; showing the last known details" "$TMP_DIR/whoami-unreachable.out"

DX_TEST_CONFIG_FILE="$DEXCODE_CONFIG_FILE" python3 - <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ["DX_TEST_CONFIG_FILE"])
data = json.loads(path.read_text(encoding="utf-8"))
data["api_url"] = "https://api-user:api-password@example.test/api?access_token=api-secret"
data["sync"] = {"factory_url": "https://sync-user:sync-password@sync.example.test/base?token=sync-secret"}
active_slug = data["default_project"]["organisation_slug"]
data["connections"][active_slug]["api_url"] = data["api_url"]
data["connections"][active_slug]["sync"] = data["sync"]
path.write_text(json.dumps(data), encoding="utf-8")
PY
unset DEX_FACTORY_URL DEX_FACTORY_EVENTS_ENDPOINT
dx_dexcode_whoami --offline > "$TMP_DIR/whoami-redacted-url.out" 2>&1
assert_contains "API: https://example.test/api" "$TMP_DIR/whoami-redacted-url.out"
assert_contains "DexCode sync URL: https://sync.example.test/base" "$TMP_DIR/whoami-redacted-url.out"
if grep -Eq 'api-user|api-password|api-secret|sync-user|sync-password|sync-secret' "$TMP_DIR/whoami-redacted-url.out"; then
  printf 'whoami printed credentials from a saved URL\n' >&2
  exit 1
fi

dx_dexcode_logout >/dev/null
[[ ! -e "$DEXCODE_CONFIG_FILE" ]] || {
  printf 'logout left the DexCode config behind\n' >&2
  exit 1
}
dx_dexcode_logout > "$TMP_DIR/logout-again.out"
assert_contains "DexCode is not connected" "$TMP_DIR/logout-again.out"

printf 'dexcode-cli-test passed\n'
