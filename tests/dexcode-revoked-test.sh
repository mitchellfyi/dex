#!/usr/bin/env bash
# Revoking a lost laptop is worth nothing if that laptop still reports itself
# as connected. whoami must say so rather than print the last known details.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-dexcode-revoked-test.XXXXXX")"

cleanup() {
  if [[ -n "${SERVER_PID:-}" ]]; then
    kill "$SERVER_PID" 2>/dev/null || true
    wait "$SERVER_PID" 2>/dev/null || true
  fi
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DEXCODE_CONFIG_FILE="$TMP_DIR/dexcode.json"
mkdir -p "$HOME"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

assert_contains() {
  local needle="$1" file="$2"
  grep -qF -- "$needle" "$file" || {
    printf 'expected output to contain: %s\ngot:\n' "$needle" >&2
    cat "$file" >&2
    exit 1
  }
}

# A server that answers the profile with whatever status the test asks for.
cat > "$TMP_DIR/server.py" <<'PYEOF'
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

state = Path(sys.argv[1])


class Handler(BaseHTTPRequestHandler):
    def do_GET(self):
        configured = (state / "status").read_text().strip()
        invalid = configured == "invalid"
        status = 200 if invalid else int(configured)
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        if invalid:
            self.wfile.write(b'{not-json')
        elif status == 200:
            project = ('{"slug":"app","name":"App","default_branch":"main",'
                       '"organisation_slug":"acme","organisation_name":"Acme","default":true}')
            self.wfile.write(
                ('{"user":{"id":"u","email":"e","name":"n"},'
                 '"account":{"slug":"acme","name":"Acme","personal":false},'
                 '"organisations":[{"slug":"acme","name":"Acme","personal":false,"default":true}],'
                 f'"projects":[{project}],"default_project":{project},'
                 '"cli_installation":null,"sync":{"factory_url":"http://x"}}').encode()
            )
        else:
            self.wfile.write(b'{"error":"unauthorized"}')

    def log_message(self, *args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
(state / "port").write_text(str(server.server_address[1]))
server.serve_forever()
PYEOF

printf '200' > "$TMP_DIR/status"
python3 "$TMP_DIR/server.py" "$TMP_DIR" &
SERVER_PID=$!
for _ in $(seq 1 50); do [[ -s "$TMP_DIR/port" ]] && break; sleep 0.1; done
SERVER_URL="http://127.0.0.1:$(cat "$TMP_DIR/port")"

cat > "$DEXCODE_CONFIG_FILE" <<JSON
{
  "api_url": "$SERVER_URL",
  "access_token": "dc_live_still_valid",
  "token_type": "Bearer",
  "account": {"slug": "acme", "name": "Acme", "personal": false},
  "default_project": {"slug": "app", "name": "App", "organisation_slug": "acme"},
  "projects": [{"slug": "app", "name": "App", "organisation_slug": "acme"}],
  "connections": {
    "acme": {"access_token": "dc_live_still_valid", "account": {"slug": "acme", "name": "Acme"},
             "projects": [{"slug": "app", "name": "App", "organisation_slug": "acme"}],
             "api_url": "$SERVER_URL", "sync": {"factory_url": "$SERVER_URL"}}
  },
  "sync": {"factory_url": "$SERVER_URL"}
}
JSON

# --- while the connection is live -------------------------------------------

dx_dexcode_whoami > "$TMP_DIR/live.out" 2>&1
assert_contains "DexCode organisation:" "$TMP_DIR/live.out"

# A temporary server failure keeps the saved details but labels them as stale.
printf '500' > "$TMP_DIR/status"
dx_dexcode_whoami > "$TMP_DIR/server-error.out" 2>&1
assert_contains "profile refresh failed (HTTP 500); showing the last known details" "$TMP_DIR/server-error.out"
assert_contains "Connected project: App" "$TMP_DIR/server-error.out"

printf 'invalid' > "$TMP_DIR/status"
dx_dexcode_whoami > "$TMP_DIR/invalid-response.out" 2>&1
assert_contains "returned an invalid profile response; showing the last known details" "$TMP_DIR/invalid-response.out"
assert_contains "Connected project: App" "$TMP_DIR/invalid-response.out"

# --- after the machine is revoked -------------------------------------------

printf '401' > "$TMP_DIR/status"
if dx_dexcode_whoami > "$TMP_DIR/revoked.out" 2>&1; then
  printf 'whoami reported success for a revoked machine\n' >&2
  cat "$TMP_DIR/revoked.out" >&2
  exit 1
fi
assert_contains "no longer connected" "$TMP_DIR/revoked.out"

# Stale details must not be presented as current.
if grep -qF "Connected project: App" "$TMP_DIR/revoked.out"; then
  printf 'whoami printed stale details for a revoked machine\n' >&2
  exit 1
fi

# A forbidden profile response also means the saved machine credential is no
# longer usable; it must not fall back to stale details that look current.
printf '403' > "$TMP_DIR/status"
if dx_dexcode_whoami > "$TMP_DIR/forbidden.out" 2>&1; then
  printf 'whoami reported success for a forbidden machine credential\n' >&2
  cat "$TMP_DIR/forbidden.out" >&2
  exit 1
fi
assert_contains "no longer connected" "$TMP_DIR/forbidden.out"

# --- offline still shows what is known --------------------------------------

dx_dexcode_whoami --offline > "$TMP_DIR/offline.out" 2>&1
assert_contains "Connected project: App" "$TMP_DIR/offline.out"

printf 'dexcode-revoked-test passed\n'
