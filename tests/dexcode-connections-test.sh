#!/usr/bin/env bash
# A DexCode token reaches exactly one organisation. People work across several
# from one laptop, so the config holds a connection per organisation and a
# second login must add to the set rather than replace it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-dexcode-connections-test.XXXXXX")"

cleanup() {
  [[ -n "${SERVER_A_PID:-}" ]] && kill "$SERVER_A_PID" 2>/dev/null || true
  [[ -n "${SERVER_B_PID:-}" ]] && kill "$SERVER_B_PID" 2>/dev/null || true
  [[ -n "${SERVER_A_PID:-}" ]] && wait "$SERVER_A_PID" 2>/dev/null || true
  [[ -n "${SERVER_B_PID:-}" ]] && wait "$SERVER_B_PID" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DEXCODE_CONFIG_FILE="$TMP_DIR/dexcode.json"
mkdir -p "$HOME"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

cat > "$TMP_DIR/context-server.py" <<'PY'
import json
import sys
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

log_path = Path(sys.argv[1])
port_path = Path(sys.argv[2])


class Handler(BaseHTTPRequestHandler):
    def do_POST(self):
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length)
        with log_path.open("a", encoding="utf-8") as fh:
            fh.write(json.dumps({
                "authorization": self.headers.get("Authorization", ""),
                "body": json.loads(body),
                "path": self.path,
            }, sort_keys=True) + "\n")
        response = b'{"synced":1,"integrations_synced":0}'
        self.send_response(200)
        self.send_header("Content-Type", "application/json")
        self.send_header("Content-Length", str(len(response)))
        self.end_headers()
        self.wfile.write(response)

    def log_message(self, *_args):
        pass


server = ThreadingHTTPServer(("127.0.0.1", 0), Handler)
port_path.write_text(str(server.server_port), encoding="ascii")
server.serve_forever()
PY

SERVER_A_LOG="$TMP_DIR/server-a.log"
SERVER_B_LOG="$TMP_DIR/server-b.log"
SERVER_A_PORT_FILE="$TMP_DIR/server-a.port"
SERVER_B_PORT_FILE="$TMP_DIR/server-b.port"
python3 "$TMP_DIR/context-server.py" "$SERVER_A_LOG" "$SERVER_A_PORT_FILE" &
SERVER_A_PID=$!
python3 "$TMP_DIR/context-server.py" "$SERVER_B_LOG" "$SERVER_B_PORT_FILE" &
SERVER_B_PID=$!
for _ in $(seq 1 100); do
  [[ -s "$SERVER_A_PORT_FILE" && -s "$SERVER_B_PORT_FILE" ]] && break
  sleep 0.05
done
[[ -s "$SERVER_A_PORT_FILE" && -s "$SERVER_B_PORT_FILE" ]] || {
  printf 'context test servers did not start\n' >&2
  exit 1
}
ORIGIN_A="http://127.0.0.1:$(cat "$SERVER_A_PORT_FILE")"
ORIGIN_B="http://127.0.0.1:$(cat "$SERVER_B_PORT_FILE")"


config_value() {
  DX_TEST_CONFIG="$DEXCODE_CONFIG_FILE" DX_TEST_EXPR="$1" python3 - <<'PY'
import json
import os
from pathlib import Path

data = json.loads(Path(os.environ["DX_TEST_CONFIG"]).read_text(encoding="utf-8"))
print(eval(os.environ["DX_TEST_EXPR"], {"data": data, "sorted": sorted, "len": len}))
PY
}

# Stands in for a login: the token response and profile the server returns.
write_login() {
  local token="$1" org_slug="$2" org_name="$3" project_slug="$4" api_url="$5" factory_url="$6"
  # The organisations the server says this account can reach. Defaults to both
  # test organisations; pass a narrower list to stand in for one that has gone
  # away.
  local orgs_json="${7:-$(cat <<'ORGS'
    {"slug": "alpha", "name": "Alpha", "personal": true, "default": false},
    {"slug": "beta", "name": "Beta", "personal": false, "default": false}
ORGS
)}"
  local token_file="$TMP_DIR/token.json" profile_file="$TMP_DIR/profile.json"
  cat > "$token_file" <<JSON
{"access_token": "$token", "token_type": "Bearer", "scopes": ["runs:write"]}
JSON
  cat > "$profile_file" <<JSON
{
  "user": {"id": "u1", "email": "person@example.com", "name": "Person"},
  "account": {"slug": "$org_slug", "name": "$org_name", "personal": false},
  "organisations": [
$orgs_json
  ],
  "projects": [
    {"slug": "$project_slug", "name": "$project_slug", "default_branch": "main",
     "organisation_slug": "$org_slug", "organisation_name": "$org_name", "default": true}
  ],
  "default_project": {"slug": "$project_slug", "name": "$project_slug",
    "default_branch": "main", "organisation_slug": "$org_slug",
    "organisation_name": "$org_name", "default": true},
  "cli_installation": null,
  "sync": {"factory_url": "$factory_url"}
}
JSON
  dx_dexcode_write_login_config "$api_url" "$token_file" "$profile_file"
}

# --- one organisation -------------------------------------------------------

write_login "dc_live_alpha_token" "alpha" "Alpha" "alpha-project" "$ORIGIN_A" "$ORIGIN_A/factory"
assert_eq "['alpha']" "$(config_value "sorted((data.get('connections') or {}).keys())")" "first connection"
assert_eq "dc_live_alpha_token" "$(dx_dexcode_token)" "token after first login"
assert_eq "$ORIGIN_A" "$(dx_dexcode_api_url)" "first API origin"
assert_eq "$ORIGIN_A/factory" "$(dx_dexcode_factory_url)" "first Factory origin"

# --- a second organisation on the same machine ------------------------------

write_login "dc_live_beta_token" "beta" "Beta" "beta-project" "$ORIGIN_B" "$ORIGIN_B/factory"
assert_eq "['alpha', 'beta']" "$(config_value "sorted((data.get('connections') or {}).keys())")" "both connections kept"
assert_eq "dc_live_alpha_token" "$(config_value "data['connections']['alpha']['access_token']")" "first token survives"
assert_eq "dc_live_beta_token" "$(config_value "data['connections']['beta']['access_token']")" "second token stored"
assert_eq "2" "$(config_value "len(data['projects'])")" "projects from both organisations"

# The selection made before the second login must not move on its own.
assert_eq "alpha-project" "$(config_value "data['default_project']['slug']")" "selection preserved"
assert_eq "dc_live_alpha_token" "$(dx_dexcode_token)" "token follows the selected project"
assert_eq "$ORIGIN_A" "$(dx_dexcode_api_url)" "API origin follows the preserved project"
assert_eq "$ORIGIN_A/factory" "$(dx_dexcode_factory_url)" "Factory origin follows the preserved project"

CONTEXT_REPO="$TMP_DIR/context-repo"
mkdir -p "$CONTEXT_REPO/.dex"
printf '# Alpha context\n' > "$CONTEXT_REPO/.dex/dex.md"
DEXCODE_CONTEXT_SYNC_REQUIRED=1 dx_dexcode_sync_project_context "$CONTEXT_REPO" > "$TMP_DIR/context-alpha.out"
DX_TEST_LOG="$SERVER_A_LOG" python3 - <<'PY'
import json
import os
from pathlib import Path

records = [json.loads(line) for line in Path(os.environ["DX_TEST_LOG"]).read_text(encoding="utf-8").splitlines()]
assert len(records) == 1, records
assert records[0]["authorization"] == "Bearer dc_live_alpha_token", records
assert records[0]["path"] == "/api/v1/projects/alpha-project/context", records
PY
[[ ! -s "$SERVER_B_LOG" ]] || {
  printf 'the preserved Alpha token was sent to the Beta origin\n' >&2
  exit 1
}

# --- selecting the other organisation's project -----------------------------

printf '2\n' | DEXCODE_CONTEXT_SYNC=0 dx_dexcode_select_project --force > "$TMP_DIR/select-beta.out"
grep -Fq -- "Using Beta / beta-project" "$TMP_DIR/select-beta.out" || {
  printf 'project selection reported the wrong organisation\n' >&2
  cat "$TMP_DIR/select-beta.out" >&2
  exit 1
}

assert_eq "dc_live_beta_token" "$(dx_dexcode_token)" "token follows a switched project"
assert_eq "dc_live_alpha_token" "$(dx_dexcode_token_for alpha)" "explicit lookup by organisation"
assert_eq "$ORIGIN_B" "$(dx_dexcode_api_url)" "API origin follows a switched project"
assert_eq "$ORIGIN_B/factory" "$(dx_dexcode_factory_url)" "Factory origin follows a switched project"

DEXCODE_CONTEXT_SYNC_REQUIRED=1 dx_dexcode_sync_project_context "$CONTEXT_REPO" > "$TMP_DIR/context-beta.out"
DX_TEST_LOG="$SERVER_B_LOG" python3 - <<'PY'
import json
import os
from pathlib import Path

records = [json.loads(line) for line in Path(os.environ["DX_TEST_LOG"]).read_text(encoding="utf-8").splitlines()]
assert len(records) == 1, records
assert records[0]["authorization"] == "Bearer dc_live_beta_token", records
assert records[0]["path"] == "/api/v1/projects/beta-project/context", records
PY

# --- upgrade a multi-connection config written before origins were bound -----

cat > "$DEXCODE_CONFIG_FILE" <<JSON
{
  "api_url": "$ORIGIN_A",
  "access_token": "dc_live_alpha_token",
  "token_type": "Bearer",
  "account": {"slug": "alpha", "name": "Alpha", "personal": false},
  "default_project": {"slug": "alpha-project", "name": "alpha-project", "organisation_slug": "alpha"},
  "projects": [{"slug": "alpha-project", "name": "alpha-project", "organisation_slug": "alpha"}],
  "connections": {
    "alpha": {
      "access_token": "dc_live_alpha_token",
      "token_type": "Bearer",
      "account": {"slug": "alpha", "name": "Alpha", "personal": false},
      "projects": [{"slug": "alpha-project", "name": "alpha-project", "organisation_slug": "alpha"}]
    }
  },
  "sync": {"factory_url": "$ORIGIN_A/factory"}
}
JSON

write_login "dc_live_beta_token" "beta" "Beta" "beta-project" "$ORIGIN_B" "$ORIGIN_B/factory"
assert_eq "$ORIGIN_A" "$(config_value "data['connections']['alpha']['api_url']")" "upgraded active API origin"
assert_eq "$ORIGIN_A/factory" "$(config_value "data['connections']['alpha']['sync']['factory_url']")" "upgraded active Factory origin"
assert_eq "$ORIGIN_A" "$(dx_dexcode_api_url)" "upgraded selection keeps its API origin"
assert_eq "dc_live_alpha_token" "$(dx_dexcode_token)" "upgraded selection keeps its token"

# A stale selected project must not claim the flat fields that belong to the
# token stored for another organisation during migration.
cat > "$DEXCODE_CONFIG_FILE" <<JSON
{
  "api_url": "$ORIGIN_A",
  "access_token": "dc_live_alpha_token",
  "account": {"slug": "alpha", "name": "Alpha"},
  "default_project": {"slug": "beta-project", "organisation_slug": "beta"},
  "projects": [
    {"slug": "alpha-project", "organisation_slug": ""},
    {"slug": "beta-project", "organisation_slug": "beta"}
  ],
  "connections": {
    "alpha": {
      "access_token": "dc_live_alpha_token",
      "account": {"slug": "alpha", "name": "Alpha"},
      "projects": [{"slug": "alpha-project", "organisation_slug": ""}]
    },
    "beta": {
      "access_token": "dc_live_beta_token",
      "account": {"slug": "beta", "name": "Beta"},
      "projects": [{"slug": "beta-project", "organisation_slug": "beta"}]
    }
  },
  "sync": {"factory_url": "$ORIGIN_A/factory"}
}
JSON

write_login "dc_live_beta_token" "beta" "Beta" "beta-project" "$ORIGIN_B" "$ORIGIN_B/factory"
assert_eq "$ORIGIN_A" "$(config_value "data['connections']['alpha']['api_url']")" "flat origin follows its unique token owner"
assert_eq "$ORIGIN_B" "$(dx_dexcode_api_url)" "selected connection ignores stale flat API fields"
assert_eq "$ORIGIN_B/factory" "$(dx_dexcode_factory_url)" "selected connection ignores stale flat Factory fields"
assert_eq "dc_live_beta_token" "$(dx_dexcode_token)" "selected connection ignores stale flat token fields"
assert_eq "alpha" "$(config_value "data['connections']['alpha']['projects'][0]['organisation_slug']")" "empty project organisation normalized"

# Once connection records exist, a partial selected record cannot borrow a
# credential from the flat compatibility fields.
cat > "$DEXCODE_CONFIG_FILE" <<JSON
{
  "api_url": "$ORIGIN_B",
  "access_token": "dc_live_alpha_token",
  "account": {"slug": "beta", "name": "Beta"},
  "default_project": {"slug": "beta-project", "organisation_slug": "beta"},
  "connections": {
    "beta": {"api_url": "$ORIGIN_B", "sync": {"factory_url": "$ORIGIN_B/factory"}}
  }
}
JSON
if dx_dexcode_active_connection >/dev/null 2>&1 \
  || dx_dexcode_token >/dev/null 2>&1 \
  || dx_dexcode_api_url >/dev/null 2>&1 \
  || dx_dexcode_factory_url >/dev/null 2>&1; then
  printf 'partial selected connection borrowed unrelated flat credentials\n' >&2
  exit 1
fi

# --- a config written before connections existed -----------------------------

cat > "$DEXCODE_CONFIG_FILE" <<'JSON'
{
  "api_url": "https://dexcode.example",
  "access_token": "dc_live_legacy_token",
  "token_type": "Bearer",
  "account": {"slug": "legacy", "name": "Legacy", "personal": true},
  "default_project": {"slug": "legacy-project", "name": "Legacy Project"},
  "projects": [{"slug": "legacy-project", "name": "Legacy Project"}],
  "sync": {"factory_url": "https://dexcode.example"}
}
JSON

assert_eq "dc_live_legacy_token" "$(dx_dexcode_token)" "legacy config still resolves"

write_login "dc_live_beta_token" "beta" "Beta" "beta-project" "$ORIGIN_B" "$ORIGIN_B/factory"
assert_eq "['beta', 'legacy']" "$(config_value "sorted((data.get('connections') or {}).keys())")" "legacy carried forward"
assert_eq "dc_live_legacy_token" "$(config_value "data['connections']['legacy']['access_token']")" "legacy token kept"
assert_eq "https://dexcode.example" "$(config_value "data['connections']['legacy']['api_url']")" "legacy API origin kept"
assert_eq "https://dexcode.example" "$(config_value "data['connections']['legacy']['sync']['factory_url']")" "legacy Factory origin kept"
assert_eq "legacy-project" "$(config_value "data['default_project']['slug']")" "legacy selection kept"
assert_eq "https://dexcode.example" "$(dx_dexcode_api_url)" "legacy API origin remains active"
assert_eq "https://dexcode.example" "$(dx_dexcode_factory_url)" "legacy Factory origin remains active"

# --- an organisation the account can no longer reach -------------------------
# Preserving the previous selection is right until the organisation behind it
# has gone away. Then the flat fields keep describing a connection whose token
# is dead, and every command after a *successful* login reports "This machine
# is no longer connected. Run 'dx login' to reconnect" — which is exactly what
# the person just did. Start from a clean config so the selection carries an
# organisation: the legacy case above deliberately has none, and is untouched.

rm -f "$DEXCODE_CONFIG_FILE"
write_login "dc_live_alpha_token" "alpha" "Alpha" "alpha-project" "$ORIGIN_A" "$ORIGIN_A/factory"
assert_eq "alpha" "$(config_value "data['default_project']['organisation_slug']")" "selection names its organisation"

write_login "dc_live_gamma_token" "gamma" "Gamma" "gamma-project" \
  "$ORIGIN_B" "$ORIGIN_B/factory" \
  '    {"slug": "gamma", "name": "Gamma", "personal": true, "default": true}'
assert_eq "gamma-project" "$(config_value "data['default_project']['slug']")" \
  "selection leaves an organisation the login cannot reach"
assert_eq "dc_live_gamma_token" "$(dx_dexcode_token)" \
  "token follows the organisation the login could reach"
assert_eq "$ORIGIN_B" "$(dx_dexcode_api_url)" \
  "API origin follows the reachable organisation"

printf 'dexcode-connections-test passed\n'
