#!/usr/bin/env bash
# Revoking a lost laptop is worth nothing if that laptop still reports itself
# as connected. whoami must say so rather than print the last known details.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-dexcode-revoked-test.XXXXXX")"

cleanup() {
  [[ -n "${SERVER_PID:-}" ]] && kill "$SERVER_PID" 2>/dev/null
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
        status = int((state / "status").read_text().strip())
        self.send_response(status)
        self.send_header("Content-Type", "application/json")
        self.end_headers()
        if status == 200:
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
             "projects": [{"slug": "app", "name": "App", "organisation_slug": "acme"}]}
  },
  "sync": {"factory_url": "$SERVER_URL"}
}
JSON

# --- while the connection is live -------------------------------------------

dx_dexcode_whoami > "$TMP_DIR/live.out" 2>&1
assert_contains "DexCode organisation:" "$TMP_DIR/live.out"

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

# --- offline still shows what is known --------------------------------------

dx_dexcode_whoami --offline > "$TMP_DIR/offline.out" 2>&1
assert_contains "Connected project: App" "$TMP_DIR/offline.out"

printf 'dexcode-revoked-test passed\n'
