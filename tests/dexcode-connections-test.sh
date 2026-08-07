#!/usr/bin/env bash
# A DexCode token reaches exactly one organisation. People work across several
# from one laptop, so the config holds a connection per organisation and a
# second login must add to the set rather than replace it.
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-dexcode-connections-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DEXCODE_CONFIG_FILE="$TMP_DIR/dexcode.json"
mkdir -p "$HOME"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$expected" != "$actual" ]]; then
    printf '%s: expected %s, got %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
}

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
  local token="$1" org_slug="$2" org_name="$3" project_slug="$4"
  local token_file="$TMP_DIR/token.json" profile_file="$TMP_DIR/profile.json"
  cat > "$token_file" <<JSON
{"access_token": "$token", "token_type": "Bearer", "scopes": ["runs:write"]}
JSON
  cat > "$profile_file" <<JSON
{
  "user": {"id": "u1", "email": "person@example.com", "name": "Person"},
  "account": {"slug": "$org_slug", "name": "$org_name", "personal": false},
  "organisations": [
    {"slug": "alpha", "name": "Alpha", "personal": true, "default": false},
    {"slug": "beta", "name": "Beta", "personal": false, "default": false}
  ],
  "projects": [
    {"slug": "$project_slug", "name": "$project_slug", "default_branch": "main",
     "organisation_slug": "$org_slug", "organisation_name": "$org_name", "default": true}
  ],
  "default_project": {"slug": "$project_slug", "name": "$project_slug",
    "default_branch": "main", "organisation_slug": "$org_slug",
    "organisation_name": "$org_name", "default": true},
  "cli_installation": null,
  "sync": {"factory_url": "https://dexcode.example"}
}
JSON
  dx_dexcode_write_login_config "https://dexcode.example" "$token_file" "$profile_file"
}

# --- one organisation -------------------------------------------------------

write_login "dc_live_alpha_token" "alpha" "Alpha" "alpha-project"
assert_eq "['alpha']" "$(config_value "sorted((data.get('connections') or {}).keys())")" "first connection"
assert_eq "dc_live_alpha_token" "$(dx_dexcode_token)" "token after first login"

# --- a second organisation on the same machine ------------------------------

write_login "dc_live_beta_token" "beta" "Beta" "beta-project"
assert_eq "['alpha', 'beta']" "$(config_value "sorted((data.get('connections') or {}).keys())")" "both connections kept"
assert_eq "dc_live_alpha_token" "$(config_value "data['connections']['alpha']['access_token']")" "first token survives"
assert_eq "dc_live_beta_token" "$(config_value "data['connections']['beta']['access_token']")" "second token stored"
assert_eq "2" "$(config_value "len(data['projects'])")" "projects from both organisations"

# The selection made before the second login must not move on its own.
assert_eq "alpha-project" "$(config_value "data['default_project']['slug']")" "selection preserved"
assert_eq "dc_live_alpha_token" "$(dx_dexcode_token)" "token follows the selected project"

# --- selecting the other organisation's project -----------------------------

DX_TEST_CONFIG="$DEXCODE_CONFIG_FILE" python3 - <<'PY'
import json
import os
from pathlib import Path

path = Path(os.environ["DX_TEST_CONFIG"])
data = json.loads(path.read_text(encoding="utf-8"))
project = next(p for p in data["projects"] if p["organisation_slug"] == "beta")
data["default_project"] = dict(project, default=True)
path.write_text(json.dumps(data, indent=2, sort_keys=True), encoding="utf-8")
PY

assert_eq "dc_live_beta_token" "$(dx_dexcode_token)" "token follows a switched project"
assert_eq "dc_live_alpha_token" "$(dx_dexcode_token_for alpha)" "explicit lookup by organisation"

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

write_login "dc_live_beta_token" "beta" "Beta" "beta-project"
assert_eq "['beta', 'legacy']" "$(config_value "sorted((data.get('connections') or {}).keys())")" "legacy carried forward"
assert_eq "dc_live_legacy_token" "$(config_value "data['connections']['legacy']['access_token']")" "legacy token kept"
assert_eq "legacy-project" "$(config_value "data['default_project']['slug']")" "legacy selection kept"

printf 'dexcode-connections-test passed\n'
