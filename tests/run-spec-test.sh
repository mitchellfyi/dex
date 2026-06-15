#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-run-spec-test.XXXXXX")"
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

assert_file() {
  [[ -f "$1" ]] || {
    printf 'missing file: %s\n' "$1" >&2
    exit 1
  }
}

assert_contains() {
  local needle="$1" file="$2"
  grep -qF "$needle" "$file" || {
    printf 'expected %s to contain %s\n' "$file" "$needle" >&2
    exit 1
  }
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
}

write_spec() {
  local path="$1" run_id="$2" repo_dir="$3" sync_url="${4:-}"
  python3 - "$path" "$run_id" "$repo_dir" "$sync_url" <<'PY'
import json
import sys
from pathlib import Path

path, run_id, repo_dir, sync_url = sys.argv[1:5]
spec = {
    "run_id": run_id,
    "company": {"slug": "materials-market", "name": "Materials Market"},
    "project": {"slug": "web", "name": "Web App"},
    "repository": {
        "provider": "github",
        "full_name": "org/repo",
        "default_branch": "main",
        "working_directory": repo_dir,
    },
    "source": {
        "type": "github_issue",
        "id": "123",
        "url": "https://github.com/org/repo/issues/123",
        "title": "Example task",
        "body": "Task details from the run spec.",
    },
    "harness": {"name": "claude-code", "model": None},
    "workflow": {
        "name": "ticket_to_pr",
        "version": "v1",
        "requires_plan_approval": False,
        "requires_ui_evidence": "auto",
        "auto_merge": False,
    },
    "sync": {},
}
if sync_url:
    spec["sync"] = {
        "factory_url": sync_url,
    }
Path(path).write_text(json.dumps(spec, indent=2, sort_keys=True) + "\n", encoding="utf-8")
PY
}

start_server() {
  local server_dir="$TMP_DIR/server"
  mkdir -p "$server_dir"
  cp "$REMOTE_SPEC" "$server_dir/spec.json"
  cat > "$server_dir/server.py" <<'PY'
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

root = Path(sys.argv[1])
headers_file = root / "headers.jsonl"
events_file = root / "events.jsonl"
port_file = root / "port"


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        headers_file.open("a", encoding="utf-8").write(json.dumps({
            "method": "GET",
            "path": self.path,
            "authorization": self.headers.get("Authorization", ""),
        }, sort_keys=True) + "\n")
        if self.path != "/spec":
            self.send_response(404)
            self.end_headers()
            return
        raw = (root / "spec.json").read_bytes()
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def do_POST(self):
        raw = self.rfile.read(int(self.headers.get("Content-Length", "0")))
        events_file.open("a", encoding="utf-8").write(json.dumps({
            "method": "POST",
            "path": self.path,
            "authorization": self.headers.get("Authorization", ""),
            "body": json.loads(raw.decode("utf-8")),
        }, sort_keys=True) + "\n")
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        self.wfile.write(b'{"ok":true}\n')

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
  SERVER_DIR="$server_dir"
  SERVER_URL="http://127.0.0.1:$(cat "$server_dir/port")"
}

REPO_DIR="$TMP_DIR/repo"
create_repo "$REPO_DIR"

LOCAL_SPEC="$TMP_DIR/local-run-spec.json"
write_spec "$LOCAL_SPEC" "run_test_local" "$REPO_DIR"

NORMALIZED_SPEC="$TMP_DIR/normalized.json"
dx_run_spec_normalize "$LOCAL_SPEC" "$NORMALIZED_SPEC"
python3 - "$NORMALIZED_SPEC" "$REPO_DIR" <<'PY'
import json
import sys
from pathlib import Path

spec = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
assert spec["schema_version"] == 1
assert spec["run_id"] == "run_test_local"
assert spec["company_slug"] == "materials-market"
assert spec["project_slug"] == "web"
assert spec["repo"] == "org/repo"
assert spec["repo_path"] == sys.argv[2]
assert spec["workflow"]["requires_plan_approval"] is False
assert "Task details from the run spec." in spec["input"]
assert spec["workspace_name"] == "headless run_test_local"
assert "Example task" not in spec["workspace_name"]
PY

export SPEC="$LOCAL_SPEC"
zsh -fc 'source "$DEX_DIR/dx.sh"; dx run --spec "$SPEC" --validate-only' > "$TMP_DIR/validate.out"
assert_contains "Run spec is valid: run_test_local" "$TMP_DIR/validate.out"

zsh -fc 'source "$DEX_DIR/dx.sh"; dx run --spec "$SPEC" --dry-run' > "$TMP_DIR/dry-run.out"
assert_contains "Run spec startup is valid: run_test_local" "$TMP_DIR/dry-run.out"
assert_file "$DX_RUN_ROOT/run_test_local/spec.json"
assert_file "$DX_RUN_ROOT/run_test_local/events.jsonl"

python3 - "$DX_RUN_ROOT/run_test_local" <<'PY'
import json
import sys
from pathlib import Path

run_dir = Path(sys.argv[1])
events = [json.loads(line) for line in (run_dir / "events.jsonl").read_text(encoding="utf-8").splitlines() if line.strip()]
types = [event["type"] for event in events]
assert "run.started" in types
assert "run.blocked" in types
assert any(event["message"] == "Dex headless dry run completed before lifecycle launch" for event in events)
spec = json.loads((run_dir / "spec.json").read_text(encoding="utf-8"))
assert spec["headless"] is True
assert spec["source"]["id"] == "123"
summary = json.loads((run_dir / "summary.json").read_text(encoding="utf-8"))
assert summary["status"] == "blocked"
PY

INVALID_SPEC="$TMP_DIR/invalid-run-spec.json"
python3 - "$INVALID_SPEC" <<'PY'
import json
import sys
from pathlib import Path

Path(sys.argv[1]).write_text(json.dumps({
    "run_id": "run_invalid",
    "repository": {"working_directory": "/tmp/example", "token": "not-allowed"},
    "source": {"type": "task", "title": "Bad spec"},
}) + "\n", encoding="utf-8")
PY

export INVALID_SPEC
if zsh -fc 'source "$DEX_DIR/dx.sh"; dx run --spec "$INVALID_SPEC" --dry-run' > "$TMP_DIR/invalid.out" 2>&1; then
  printf 'invalid run spec unexpectedly passed\n' >&2
  exit 1
fi
assert_contains "run specs must not contain secrets" "$TMP_DIR/invalid.out"
python3 - "$DX_RUN_ROOT" <<'PY'
import json
import sys
from pathlib import Path

root = Path(sys.argv[1])
events = []
for path in root.glob("*/events.jsonl"):
    events.extend(json.loads(line) for line in path.read_text(encoding="utf-8").splitlines() if line.strip())
assert any(event["type"] == "run.failed" and event["data"].get("stage") == "validation" for event in events)
PY

RELATIVE_SPEC="$TMP_DIR/relative-run-spec.json"
write_spec "$RELATIVE_SPEC" "run_test_relative" "relative/repo"
if dx_run_spec_normalize "$RELATIVE_SPEC" "$TMP_DIR/relative-normalized.json" > "$TMP_DIR/relative.out" 2>&1; then
  printf 'relative working directory unexpectedly passed\n' >&2
  exit 1
fi
assert_contains "repository.working_directory must be an absolute path" "$TMP_DIR/relative.out"

DIRTY_REPO="$TMP_DIR/dirty-repo"
create_repo "$DIRTY_REPO"
printf 'dirty\n' > "$DIRTY_REPO/dirty.txt"
DIRTY_SPEC="$TMP_DIR/dirty-run-spec.json"
write_spec "$DIRTY_SPEC" "run_test_setup_failure" "$DIRTY_REPO"
export DIRTY_SPEC
if zsh -fc 'source "$DEX_DIR/dx.sh"; dx run --spec "$DIRTY_SPEC"' > "$TMP_DIR/setup-failure.out" 2>&1; then
  printf 'dirty checkout setup unexpectedly passed\n' >&2
  exit 1
fi
assert_contains "Cannot create branch" "$TMP_DIR/setup-failure.out"
python3 - "$DX_RUN_ROOT/run_test_setup_failure" <<'PY'
import json
import sys
from pathlib import Path

run_dir = Path(sys.argv[1])
events = [json.loads(line) for line in (run_dir / "events.jsonl").read_text(encoding="utf-8").splitlines() if line.strip()]
assert any(event["type"] == "run.started" for event in events)
assert any(event["type"] == "run.failed" and event["data"].get("stage") == "startup" for event in events)
summary = json.loads((run_dir / "summary.json").read_text(encoding="utf-8"))
assert summary["status"] == "failed"
PY

REMOTE_SPEC="$TMP_DIR/remote-run-spec.json"
write_spec "$REMOTE_SPEC" "run_test_remote" "$REPO_DIR" "placeholder"
start_server
write_spec "$REMOTE_SPEC" "run_test_remote" "$REPO_DIR" "$SERVER_URL"
cp "$REMOTE_SPEC" "$SERVER_DIR/spec.json"

export REMOTE_URL="$SERVER_URL/spec"
if zsh -fc 'source "$DEX_DIR/dx.sh"; dx run --spec-url "${REMOTE_URL}?run_token=bad" --dry-run' > "$TMP_DIR/remote-query-secret.out" 2>&1; then
  printf 'remote URL query secret unexpectedly passed\n' >&2
  exit 1
fi
assert_contains "use --run-token instead" "$TMP_DIR/remote-query-secret.out"

zsh -fc 'source "$DEX_DIR/dx.sh"; dx run --spec-url "$REMOTE_URL" --run-token remote-token --dry-run' > "$TMP_DIR/remote.out"
assert_contains "Run spec startup is valid: run_test_remote" "$TMP_DIR/remote.out"

python3 - "$SERVER_DIR" "$DX_RUN_ROOT/run_test_remote" <<'PY'
import json
import sys
from pathlib import Path

server_dir = Path(sys.argv[1])
run_dir = Path(sys.argv[2])
headers = [json.loads(line) for line in (server_dir / "headers.jsonl").read_text(encoding="utf-8").splitlines()]
assert headers[-1]["authorization"] == "Bearer remote-token"
posts = [json.loads(line) for line in (server_dir / "events.jsonl").read_text(encoding="utf-8").splitlines()]
assert posts
assert all(post["authorization"] == "Bearer remote-token" for post in posts)
assert any(post["path"].endswith("/api/v1/runs/run_test_remote/events/batch") for post in posts)
events = [json.loads(line) for line in (run_dir / "events.jsonl").read_text(encoding="utf-8").splitlines() if line.strip()]
assert any(event["type"] == "run.started" for event in events)
PY

zsh -fc 'source "$DEX_DIR/dx.sh"; unset DEX_RUN_TOKEN DEX_FACTORY_RUN_TOKEN DEX_FACTORY_URL DEX_FACTORY_EVENTS_ENDPOINT DEX_FACTORY_SYNC DX_AGENT_OVERRIDE DX_MODEL_OVERRIDE DEX_HEADLESS_REQUIRES_PLAN_APPROVAL; dx run --spec-url "$REMOTE_URL" --run-token scoped-token --dry-run >/dev/null; [[ -z "${DEX_RUN_TOKEN:-}" && -z "${DEX_FACTORY_RUN_TOKEN:-}" && -z "${DEX_FACTORY_URL:-}" && -z "${DEX_FACTORY_EVENTS_ENDPOINT:-}" && -z "${DEX_FACTORY_SYNC:-}" && -z "${DX_AGENT_OVERRIDE:-}" && -z "${DX_MODEL_OVERRIDE:-}" && -z "${DEX_HEADLESS_REQUIRES_PLAN_APPROVAL:-}" ]]'

zsh -fc 'source "$DEX_DIR/dx.sh"; dx help' > "$TMP_DIR/help.out"
assert_contains "dx run --spec FILE" "$TMP_DIR/help.out"

printf 'run spec tests passed\n'
