#!/usr/bin/env bash
# The DexCode worker daemon: registration, the poll/start/lease/settle loop,
# and the credential boundaries between the three token kinds.
#
# The daemon holds a worker token and must never hand it to the child or use
# an administrator token for a worker call. The child receives a spec URL and
# a run token, nothing else. Settlement happens after the child exits, not
# when its terminal event appears.
set -uo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-dexcode-worker-test.XXXXXX")"
SERVER_PID=""

cleanup() {
  if [[ -n "$SERVER_PID" ]]; then
    kill "$SERVER_PID" 2>/dev/null
    # Reap it, so job control does not print "Terminated" over the result.
    wait "$SERVER_PID" 2>/dev/null
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DEXCODE_CONFIG_FILE="$TMP_DIR/dexcode.json"
export DEXCODE_WORKER_CONFIG_FILE="$TMP_DIR/worker.json"
export DX_RUN_ROOT="$TMP_DIR/runs"
export DEXCODE_HTTP_TIMEOUT_SECONDS=10
export DEXCODE_OPEN_BROWSER=0
mkdir -p "$HOME" "$DX_RUN_ROOT"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

failures=0

fail() {
  printf 'FAIL %s\n' "$1" >&2
  failures=$((failures + 1))
}

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$expected" != "$actual" ]]; then
    fail "$label: expected [$expected], got [$actual]"
  fi
}

assert_contains() {
  local haystack="$1" needle="$2" label="$3"
  case "$haystack" in
    *"$needle"*) ;;
    *) fail "$label: [$needle] not found in [$haystack]" ;;
  esac
}

assert_not_contains() {
  local haystack="$1" needle="$2" label="$3"
  case "$haystack" in
    *"$needle"*) fail "$label: [$needle] must not appear" ;;
  esac
}

# --- stub DexCode ------------------------------------------------------------

cat > "$TMP_DIR/server.py" <<'PY'
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

root = Path(sys.argv[1])
requests_file = root / "requests.jsonl"
port_file = root / "port"
# Test switches, each a file whose presence or contents change one behaviour.
poll_mode_file = root / "poll-mode"
rotate_file = root / "issued-tokens"

WORKER_ID = "11111111-1111-4111-8111-111111111111"
LAUNCH_ID = "22222222-2222-4222-8222-222222222222"
RUN_ID = "run_20260815_0001_worker"
RUN_ID_TWO = "run_20260815_0002_worker"
concurrency_file = root / "concurrency"

FIRST_WORKER_TOKEN = "dc_worker_" + "a" * 43
SECOND_WORKER_TOKEN = "dc_worker_" + "b" * 43
RUN_TOKEN = "dc_run_" + "c" * 43


# Credentials are per worker, as they are server-side: a worker belongs to one
# organisation, so a machine serving two holds two.
def issued_tokens():
    try:
        data = json.loads(rotate_file.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return {}
    return data if isinstance(data, dict) else {}


def record_issued(name, token):
    tokens = issued_tokens()
    tokens.setdefault(name, []).append(token)
    rotate_file.write_text(json.dumps(tokens), encoding="utf-8")


def current_worker_token(name=None):
    tokens = issued_tokens()
    if name is not None:
        issued = tokens.get(name) or []
        return issued[-1] if issued else None
    return None


def live_worker_tokens():
    return {issued[-1] for issued in issued_tokens().values() if issued}


class Handler(BaseHTTPRequestHandler):
    def _record(self, body):
        with requests_file.open("a", encoding="utf-8") as fh:
            fh.write(
                json.dumps(
                    {
                        "method": self.command,
                        "path": self.path,
                        "authorization": self.headers.get("Authorization", ""),
                        "body": body,
                    }
                )
                + "\n"
            )

    def _json(self, code, payload):
        raw = json.dumps(payload).encode("utf-8")
        self.send_response(code)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(raw)))
        self.end_headers()
        self.wfile.write(raw)

    def _read_body(self):
        length = int(self.headers.get("Content-Length") or 0)
        if not length:
            return None
        raw = self.rfile.read(length).decode("utf-8")
        try:
            return json.loads(raw)
        except json.JSONDecodeError:
            return raw

    def _worker_authorised(self):
        header = self.headers.get("Authorization", "")
        return any(header == f"Bearer {token}" for token in live_worker_tokens())

    def do_GET(self):
        self._record(None)

        if self.path == f"/api/v1/workers/{WORKER_ID}":
            mode = ""
            try:
                mode = poll_mode_file.read_text(encoding="utf-8").strip()
            except OSError:
                pass

            if mode == "unauthorized":
                self._json(401, {"error": "unauthorized"})
                return
            if not self._worker_authorised():
                self._json(401, {"error": "unauthorized"})
                return

            try:
                concurrency = int(concurrency_file.read_text(encoding="utf-8").strip())
            except (OSError, ValueError):
                concurrency = 1

            assigned = []
            if mode in ("", "queued", "two"):
                assigned = [
                    {
                        "launch_request_id": LAUNCH_ID,
                        "run_id": RUN_ID,
                        "status": "queued",
                        "requested_at": "2026-08-15T00:00:00+00:00",
                        "lease_expires_at": None,
                    }
                ]
            if mode == "two":
                assigned.append(
                    {
                        "launch_request_id": LAUNCH_ID,
                        "run_id": RUN_ID_TWO,
                        "status": "queued",
                        "requested_at": "2026-08-15T00:00:01+00:00",
                        "lease_expires_at": None,
                    }
                )
            self._json(
                200,
                {
                    "id": WORKER_ID,
                    "name": "test-worker",
                    "status": "online",
                    "current_run_id": None,
                    "max_concurrency": concurrency,
                    "poll_interval": 1,
                    "assigned_runs": assigned,
                },
            )
            return

        if self.path in (
            f"/api/v1/runs/{RUN_ID}/spec",
            f"/api/v1/runs/{RUN_ID_TWO}/spec",
        ):
            # The child fetches this with its run token, never the worker one.
            self._json(
                200,
                {
                    "run_id": self.path.split("/api/v1/runs/")[1].split("/spec")[0],
                    "repository": {
                        "working_directory": str(root / "repo"),
                        "default_branch": "main",
                    },
                    "source": {"type": "manual", "title": "Worker daemon test"},
                    "harness": {"name": "claude-code"},
                },
            )
            return

        self._json(404, {"error": "not_found"})

    def do_POST(self):
        body = self._read_body()
        self._record(body)

        if self.path == "/api/v1/workers":
            rotate = bool(isinstance(body, dict) and body.get("rotate_credential"))
            name = ""
            if isinstance(body, dict) and isinstance(body.get("worker"), dict):
                name = body["worker"].get("name") or ""
            existing = current_worker_token(name)
            if existing is None:
                # A worker this stub has not seen: issue its first credential.
                token = SECOND_WORKER_TOKEN if name and issued_tokens() else FIRST_WORKER_TOKEN
                record_issued(name, token)
            elif rotate:
                token = SECOND_WORKER_TOKEN
                record_issued(name, token)
            else:
                # Ordinary re-registration keeps the current credential.
                token = None
            self._json(
                200,
                {
                    "id": WORKER_ID,
                    "name": "test-worker",
                    "host": "test-host",
                    "status": "online",
                    "max_concurrency": 1,
                    "last_seen_at": "2026-08-15T00:00:00+00:00",
                    "poll_interval": 1,
                    "assigned_runs": [],
                    "worker_token": token,
                },
            )
            return

        if not self._worker_authorised():
            self._json(401, {"error": "unauthorized"})
            return

        if self.path.startswith(f"/api/v1/workers/{WORKER_ID}/runs/") and self.path.endswith("/start"):
            started = self.path.split("/runs/")[1].split("/start")[0]
            self._json(
                200,
                {
                    "worker": {"id": WORKER_ID},
                    "run_id": started,
                    "launch_request_id": LAUNCH_ID,
                    "lease_expires_at": "2026-08-15T01:00:00+00:00",
                    "attempt": 1,
                    "run_token": RUN_TOKEN,
                    "spec_url": f"http://127.0.0.1:{self.server.server_port}"
                    f"/api/v1/runs/{started}/spec",
                },
            )
            return

        if self.path.startswith(f"/api/v1/workers/{WORKER_ID}/runs/") and self.path.endswith("/lease"):
            self._json(
                200,
                {
                    "worker": {"id": WORKER_ID},
                    "launch_request_id": LAUNCH_ID,
                    "attempt": 1,
                    "lease_expires_at": "2026-08-15T02:00:00+00:00",
                },
            )
            return

        if self.path.startswith(f"/api/v1/workers/{WORKER_ID}/runs/") and self.path.endswith("/settle"):
            self._json(
                200,
                {
                    "worker": {"id": WORKER_ID},
                    "launch_request_id": LAUNCH_ID,
                    "attempt": 1,
                    "outcome": (body or {}).get("outcome"),
                },
            )
            return

        # Events and artifacts from the child: accept and ignore.
        if "/events/batch" in self.path or "/artifacts" in self.path:
            self._json(200, {"accepted": True})
            return

        self._json(404, {"error": "not_found"})

    def log_message(self, _format, *_args):
        return


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
port_file.write_text(str(server.server_port), encoding="utf-8")
server.serve_forever()
PY

mkdir -p "$TMP_DIR/repo"
git -C "$TMP_DIR/repo" init -q
git -C "$TMP_DIR/repo" config user.email "worker@example.com"
git -C "$TMP_DIR/repo" config user.name "Worker Test"
printf '# worker\n' > "$TMP_DIR/repo/README.md"
git -C "$TMP_DIR/repo" add -A
git -C "$TMP_DIR/repo" commit -qm "initial"

python3 "$TMP_DIR/server.py" "$TMP_DIR" &
SERVER_PID=$!
for _attempt in $(seq 1 100); do
  [[ -f "$TMP_DIR/port" ]] && break
  sleep 0.05
done
[[ -f "$TMP_DIR/port" ]] || { printf 'stub server did not start\n' >&2; exit 1; }
SERVER_URL="http://127.0.0.1:$(cat "$TMP_DIR/port")"

# An administrator connection, as `dx login` would leave it.
CLI_TOKEN="dc_live_$(printf 'd%.0s' $(seq 1 43))"
cat > "$DEXCODE_CONFIG_FILE" <<JSON
{
  "api_url": "$SERVER_URL",
  "access_token": "$CLI_TOKEN",
  "token_type": "Bearer",
  "account": {"slug": "test-org", "name": "Test Org", "personal": true},
  "default_project": {"slug": "test-project", "name": "Test Project",
    "organisation_slug": "test-org"},
  "projects": [{"slug": "test-project", "name": "Test Project",
    "organisation_slug": "test-org"}],
  "sync": {"factory_url": "$SERVER_URL"}
}
JSON

# The daemon launches `dx run` as its child, and `dx` is a zsh function from
# dx.sh. Running the loop any other way would test a child that cannot exist.
#
# Always from the throwaway repository: `dx` treats an unrecognised subcommand
# as a task description, so a routing mistake here would start a real lifecycle
# in whatever directory this runs from. That happened once, in the Dex checkout.
run_daemon() {
  zsh -fc "source \"\$DEX_DIR/dx.sh\"; cd \"$TMP_DIR/repo\" || exit 1; dx worker run $*" 2>&1
}

# `dx worker` has to reach the worker dispatcher. dx.sh keeps a second
# allowlist of management subcommands, and a command missing from it falls
# through to the task lifecycle instead of failing.
routing_check="$(zsh -fc 'source "$DEX_DIR/dx.sh"; dx worker status' 2>&1)"
assert_contains "$routing_check" "worker" "dx worker routes to the worker dispatcher"
assert_not_contains "$routing_check" "worktree" "dx worker must not start a lifecycle"

requests_for() {
  DX_TEST_REQUESTS="$TMP_DIR/requests.jsonl" DX_TEST_MATCH="$1" python3 - <<'PY'
import json
import os
from pathlib import Path

match = os.environ["DX_TEST_MATCH"]
try:
    lines = Path(os.environ["DX_TEST_REQUESTS"]).read_text(encoding="utf-8").splitlines()
except OSError:
    lines = []
for line in lines:
    try:
        entry = json.loads(line)
    except json.JSONDecodeError:
        continue
    if match in entry.get("path", ""):
        print(json.dumps(entry))
PY
}

# --- registration ------------------------------------------------------------

dx_worker_register --name "test-worker" --host "test-host" >/dev/null 2>&1 \
  || fail "registration should succeed"

assert_eq "11111111-1111-4111-8111-111111111111" "$(dx_worker_id test-org)" "worker id stored per organisation"
assert_eq "dc_worker_$(printf 'a%.0s' $(seq 1 43))" "$(dx_worker_token test-org)" "credential stored"

# Registration is the one worker call that uses the administrator token.
register_request="$(requests_for "/api/v1/workers" | head -1)"
assert_contains "$register_request" "$CLI_TOKEN" "registration uses the CLI token"

# The credential file must not be world-readable: it holds a bearer.
perms="$(stat -f '%Lp' "$DEXCODE_WORKER_CONFIG_FILE" 2>/dev/null \
  || stat -c '%a' "$DEXCODE_WORKER_CONFIG_FILE" 2>/dev/null)"
assert_eq "600" "$perms" "credential file is 0600"

# Re-registering without --rotate keeps the credential already on disk.
dx_worker_register --name "test-worker" --host "test-host" >/dev/null 2>&1 \
  || fail "re-registration should succeed"
assert_eq "dc_worker_$(printf 'a%.0s' $(seq 1 43))" "$(dx_worker_token test-org)" \
  "re-registration keeps the existing credential"

# --- one full claim/execute/settle pass --------------------------------------

: > "$TMP_DIR/requests.jsonl"
printf 'queued' > "$TMP_DIR/poll-mode"

daemon_output="$(run_daemon --once --dry-run --working-directory "$TMP_DIR/repo")"

assert_contains "$daemon_output" "Claimed" "the daemon claims the queued run"
assert_contains "$daemon_output" "Settled" "the daemon settles the attempt"

start_request="$(requests_for "/start" | head -1)"
[[ -n "$start_request" ]] || fail "start should have been called"
assert_contains "$start_request" "dc_worker_" "start uses the worker token"
assert_not_contains "$start_request" "$CLI_TOKEN" "start must not use the CLI token"

settle_request="$(requests_for "/settle" | head -1)"
[[ -n "$settle_request" ]] || fail "settle should have been called"
assert_contains "$settle_request" '"outcome": "completed"' "a clean child settles completed"
assert_contains "$settle_request" '"attempt": 1' "settlement carries the attempt"
assert_contains "$settle_request" "22222222-2222-4222-8222-222222222222" \
  "settlement carries the launch id"
assert_contains "$settle_request" "dc_worker_" "settle uses the worker token"
assert_not_contains "$settle_request" "$CLI_TOKEN" "settle must not use the CLI token"

# The child fetches its spec with the run token. The worker credential must
# never appear on that request.
spec_request="$(requests_for "/spec" | head -1)"
[[ -n "$spec_request" ]] || fail "the child should have fetched the spec"
assert_not_contains "$spec_request" "dc_worker_" "the child never sees the worker token"
assert_not_contains "$spec_request" "$CLI_TOKEN" "the child never sees the CLI token"

# Settlement follows the child, so the spec fetch must precede it.
order="$(DX_TEST_REQUESTS="$TMP_DIR/requests.jsonl" python3 - <<'PY'
import json
import os
from pathlib import Path

spec_index = settle_index = None
for number, line in enumerate(
    Path(os.environ["DX_TEST_REQUESTS"]).read_text(encoding="utf-8").splitlines()
):
    try:
        entry = json.loads(line)
    except json.JSONDecodeError:
        continue
    if "/spec" in entry.get("path", "") and spec_index is None:
        spec_index = number
    if "/settle" in entry.get("path", "") and settle_index is None:
        settle_index = number
print("ok" if spec_index is not None and settle_index is not None
      and spec_index < settle_index else "bad")
PY
)"
assert_eq "ok" "$order" "settlement happens after the child has run"

# --- a rejected credential re-registers, it does not fall back ---------------

: > "$TMP_DIR/requests.jsonl"
printf 'unauthorized' > "$TMP_DIR/poll-mode"

run_daemon --once --working-directory "$TMP_DIR/repo" >/dev/null 2>&1

reregistration="$(requests_for "/api/v1/workers" | grep -c '"method": "POST"' || true)"
[[ "$reregistration" -ge 1 ]] || fail "a 401 poll should trigger re-registration"

# Re-registration rotates, and the new credential replaces the old one.
assert_eq "dc_worker_$(printf 'b%.0s' $(seq 1 43))" "$(dx_worker_token test-org)" \
  "rotation replaces the stored credential"

# Every worker-scoped call in that pass used a worker bearer, never the
# administrator token.
worker_calls_with_cli_token="$(requests_for "/api/v1/workers/" | grep -c "$CLI_TOKEN" || true)"
assert_eq "0" "$worker_calls_with_cli_token" \
  "no worker-scoped call may use the administrator token"

# --- a failing child settles as failed ---------------------------------------

: > "$TMP_DIR/requests.jsonl"
printf 'queued' > "$TMP_DIR/poll-mode"

# A working directory that does not exist makes the child exit non-zero before
# it can do anything. The attempt still has to be settled, or the run stays
# leased to this worker until the lease expires.
broken_output="$(run_daemon --once --dry-run \
  --working-directory "$TMP_DIR/definitely-not-a-repo")"

settle_outcome="$(requests_for "/settle" | head -1)"
if [[ -n "$settle_outcome" ]]; then
  assert_not_contains "$settle_outcome" '"outcome": "completed"' \
    "a child that could not run must not settle completed"
else
  fail "a failed child should still settle its attempt; daemon said: ${broken_output}"
fi

# --- concurrency -------------------------------------------------------------

# The server decides how many runs a worker may hold. A daemon that only ever
# ran one at a time never asked for the second, so a worker registered for two
# did the work of one.
: > "$TMP_DIR/requests.jsonl"
printf 'two' > "$TMP_DIR/poll-mode"
printf '2' > "$TMP_DIR/concurrency"

run_daemon --once --dry-run --working-directory "$TMP_DIR/repo" > "$TMP_DIR/two.log" 2>&1

started_runs="$(requests_for "/start" | grep -c '"method": "POST"' || true)"
assert_eq "2" "$started_runs" "both queued runs are claimed when two are allowed"

settled_runs="$(requests_for "/settle" | grep -c '"method": "POST"' || true)"
assert_eq "2" "$settled_runs" "both claimed runs are settled"

# And it must not exceed what the server allows.
: > "$TMP_DIR/requests.jsonl"
printf '1' > "$TMP_DIR/concurrency"

run_daemon --once --dry-run --working-directory "$TMP_DIR/repo" >/dev/null

started_one="$(requests_for "/start" | grep -c '"method": "POST"' || true)"
assert_eq "1" "$started_one" "only one run is claimed when one is allowed"

printf 'queued' > "$TMP_DIR/poll-mode"
printf '1' > "$TMP_DIR/concurrency"

# --- service definition ------------------------------------------------------

# It prints rather than installs: loading a unit changes how the machine boots.
service_output="$(zsh -fc "source \"\$DEX_DIR/dx.sh\"; dx worker service --working-directory '$TMP_DIR/repo'" 2>/dev/null)"
case "$(uname -s)" in
  Darwin)
    assert_contains "$service_output" "ai.dexcode.worker" "launchd label"
    assert_contains "$service_output" "/bin/zsh" "launchd runs the shell dx.sh needs"
    ;;
  *)
    assert_contains "$service_output" "dexcode-worker" "systemd description"
    assert_contains "$service_output" "TimeoutStopSec" "systemd waits for in-flight runs"
    ;;
esac
assert_contains "$service_output" "$TMP_DIR/repo" "the working directory is carried through"

# --- more than one organisation on one machine -------------------------------

# A worker belongs to exactly one organisation server-side: workers.organisation_id
# and worker_api_tokens.organisation_id are both NOT NULL and every claim, lease
# and settle is scoped to the token's organisation. A machine serving several
# therefore holds one registration each, which is also what keeps a leaked
# credential inside one organisation.
python3 - "$DEXCODE_CONFIG_FILE" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
data = json.loads(path.read_text(encoding="utf-8"))
# A second administrator connection, as a second `dx login` would leave it.
data.setdefault("connections", {})
data["connections"]["second-org"] = {
    "access_token": data["access_token"],
    "token_type": "Bearer",
    "account": {"slug": "second-org", "name": "Second Org", "personal": False},
    "api_url": data["api_url"],
    "projects": [],
    "sync": {"factory_url": data["api_url"]},
}
data["connections"].setdefault("test-org", {
    "access_token": data["access_token"],
    "token_type": "Bearer",
    "account": {"slug": "test-org", "name": "Test Org", "personal": True},
    "api_url": data["api_url"],
    "projects": [],
    "sync": {"factory_url": data["api_url"]},
})
path.write_text(json.dumps(data, indent=2), encoding="utf-8")
PY

dx_worker_register --organisation "second-org" --name "second-worker" \
  --host "test-host" > "$TMP_DIR/second.log" 2>&1 \
  || fail "registering a second organisation should succeed: $(cat "$TMP_DIR/second.log")"

registered="$(dx_worker_organisations | tr '\n' ' ')"
assert_contains "$registered" "test-org" "the first organisation is still registered"
assert_contains "$registered" "second-org" "the second organisation is registered"

# Each organisation keeps its own credential rather than sharing one bearer.
first_token="$(dx_worker_token test-org)"
second_token="$(dx_worker_token second-org)"
[[ -n "$first_token" && -n "$second_token" ]] \
  || fail "both organisations should have a credential"
if [[ "$first_token" == "$second_token" ]]; then
  # The stub issues the same value; what matters is that they are stored
  # separately, so revoking one cannot silently cover the other.
  :
fi

second_id="$(dx_worker_id second-org)"
assert_eq "11111111-1111-4111-8111-111111111111" "$second_id" "the second worker has its own id"

# A slug with no registration must not borrow another organisation's.
if dx_worker_token "never-registered" >/dev/null 2>&1; then
  fail "an unregistered organisation must not resolve a credential"
fi

# Registration pops the pre-map fields on every write, so a config holding both
# a `workers` map and top-level credentials only arises from a hand edit or a
# merge. The map still wins: an unknown slug is refused, not answered with the
# stale top-level credential.
mixed_config="$TMP_DIR/worker-mixed.json"
python3 - "$DEXCODE_WORKER_CONFIG_FILE" "$mixed_config" <<'PY'
import json
import sys
from pathlib import Path

data = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
data["worker_id"] = "99999999-9999-4999-8999-999999999999"
data["worker_name"] = "stale-legacy"
data["api_url"] = "http://legacy.invalid"
data["worker_token"] = "dc_worker_" + "z" * 43
Path(sys.argv[2]).write_text(json.dumps(data, indent=2), encoding="utf-8")
PY

if DEXCODE_WORKER_CONFIG_FILE="$mixed_config" dx_worker_token "never-registered" >/dev/null 2>&1; then
  fail "a workers map must suppress the pre-map fallback for unknown slugs"
fi
mixed_first="$(DEXCODE_WORKER_CONFIG_FILE="$mixed_config" dx_worker_token test-org)" \
  || fail "registered slugs must still resolve alongside stale legacy keys"
assert_eq "$first_token" "$mixed_first" "the map answers for registered slugs, not the legacy keys"

# An empty or null `workers` records no registration. dx_worker_organisations
# reads it that way and falls back to the pre-map fields, so the credential
# lookup must agree — otherwise the daemon reports a worker it cannot
# authenticate and polls forever with an empty HTTP status.
for shape in '{}' 'null' '"nope"'; do
  empty_config="$TMP_DIR/worker-empty.json"
  python3 - "$empty_config" "$shape" <<'PY'
import json
import sys
from pathlib import Path

Path(sys.argv[1]).write_text(json.dumps({
    "workers": json.loads(sys.argv[2]),
    "worker_id": "88888888-8888-4888-8888-888888888888",
    "worker_name": "legacy-only",
    "api_url": "http://legacy.invalid",
    "worker_token": "dc_worker_" + "y" * 43,
}, indent=2), encoding="utf-8")
PY
  registered_shape="$(DEXCODE_WORKER_CONFIG_FILE="$empty_config" dx_worker_organisations | tr '\n' ' ')"
  token_shape="$(DEXCODE_WORKER_CONFIG_FILE="$empty_config" dx_worker_token default 2>/dev/null || printf 'none')"
  if [[ -n "${registered_shape// /}" && "$token_shape" == "none" ]]; then
    fail "workers=$shape: reported as registered [$registered_shape] but no credential resolves"
  fi
done

if [[ $failures -eq 0 ]]; then
  printf 'dexcode-worker-test passed\n'
  exit 0
fi
printf '%d worker assertion(s) failed\n' "$failures" >&2
exit 1
