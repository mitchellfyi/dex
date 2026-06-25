# shellcheck shell=bash
# DexCode CLI auth and local-run sync helpers.

dx_dexcode_config_dir() {
  printf '%s\n' "${DEXCODE_CONFIG_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/dex}"
}

dx_dexcode_config_file() {
  printf '%s\n' "${DEXCODE_CONFIG_FILE:-$(dx_dexcode_config_dir)/dexcode.json}"
}

dx_dexcode_default_url() {
  printf '%s\n' "${DEXCODE_URL:-https://dexcode.ai}"
}

dx_dexcode_config_value() {
  local key="$1" file
  file=$(dx_dexcode_config_file)
  [[ -f "$file" ]] || return 1

  DX_DEXCODE_CONFIG_FILE="$file" DX_DEXCODE_CONFIG_KEY="$key" python3 - <<'PY'
import json
import os
from pathlib import Path

data = json.loads(Path(os.environ["DX_DEXCODE_CONFIG_FILE"]).read_text(encoding="utf-8"))
value = data
for part in os.environ["DX_DEXCODE_CONFIG_KEY"].split("."):
    if not isinstance(value, dict) or part not in value:
        raise SystemExit(1)
    value = value[part]
if value is None:
    raise SystemExit(1)
print(value)
PY
}

dx_dexcode_api_url() {
  local configured
  configured=$(dx_dexcode_config_value "api_url" 2>/dev/null || true)
  configured="${DEXCODE_URL:-$configured}"
  configured="${configured:-$(dx_dexcode_default_url)}"
  printf '%s\n' "${configured%/}"
}

dx_dexcode_token() {
  if [[ -n "${DEXCODE_TOKEN:-}" ]]; then
    printf '%s\n' "$DEXCODE_TOKEN"
    return 0
  fi
  dx_dexcode_config_value "access_token"
}

dx_dexcode_machine_name() {
  if command -v scutil >/dev/null 2>&1; then
    scutil --get ComputerName 2>/dev/null && return 0
  fi
  hostname 2>/dev/null || printf 'local machine\n'
}

dx_dexcode_hostname_hash() {
  local host
  host=$(hostname 2>/dev/null || printf 'unknown')
  printf '%s' "$host" | shasum -a 256 | awk '{print $1}'
}

dx_dexcode_version() {
  git -C "$DEX_DIR" describe --tags --always --dirty 2>/dev/null || printf 'local\n'
}

dx_dexcode_json_field() {
  local file="$1" key="$2"
  DX_DEXCODE_JSON_FILE="$file" DX_DEXCODE_JSON_KEY="$key" python3 - <<'PY'
import json
import os
from pathlib import Path

data = json.loads(Path(os.environ["DX_DEXCODE_JSON_FILE"]).read_text(encoding="utf-8"))
value = data
for part in os.environ["DX_DEXCODE_JSON_KEY"].split("."):
    if not isinstance(value, dict) or part not in value:
        raise SystemExit(1)
    value = value[part]
if value is None:
    raise SystemExit(1)
print(value)
PY
}

dx_dexcode_write_login_config() {
  local api_url="$1" token_file="$2" profile_file="${3:-}" config_file config_dir
  config_file=$(dx_dexcode_config_file)
  config_dir=$(dirname "$config_file")
  mkdir -p "$config_dir"

  DX_DEXCODE_CONFIG_FILE="$config_file" \
  DX_DEXCODE_API_URL="$api_url" \
  DX_DEXCODE_TOKEN_FILE="$token_file" \
  DX_DEXCODE_PROFILE_FILE="$profile_file" \
  python3 - <<'PY'
import json
import os
import tempfile
from datetime import datetime, timezone
from pathlib import Path

config_file = Path(os.environ["DX_DEXCODE_CONFIG_FILE"])
token_response = json.loads(Path(os.environ["DX_DEXCODE_TOKEN_FILE"]).read_text(encoding="utf-8"))
profile_path = os.environ.get("DX_DEXCODE_PROFILE_FILE", "")
existing = {}
if config_file.exists():
    try:
        existing = json.loads(config_file.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        existing = {}
token_profile = token_response.get("profile") or {}
profile = token_profile
if profile_path and Path(profile_path).exists():
    try:
        profile = json.loads(Path(profile_path).read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        profile = token_profile
projects = profile.get("projects") or ([profile["default_project"]] if profile.get("default_project") else [])
default_project = profile.get("default_project")
selected_slug = (existing.get("default_project") or {}).get("slug")
if selected_slug:
    preserved_project = next((project for project in projects if project.get("slug") == selected_slug), None)
    if preserved_project:
        default_project = dict(preserved_project, default=True)

config = {
    "api_url": os.environ["DX_DEXCODE_API_URL"].rstrip("/"),
    "access_token": token_response["access_token"],
    "token_type": token_response.get("token_type", "Bearer"),
    "expires_at": token_response.get("expires_at"),
    "scopes": token_response.get("scopes", []),
    "account": profile.get("account"),
    "organisations": profile.get("organisations") or ([profile["account"]] if profile.get("account") else []),
    "default_project": default_project,
    "projects": projects,
    "sync": profile.get("sync") or token_profile.get("sync") or {},
    "updated_at": datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ"),
}
fd, tmp_name = tempfile.mkstemp(prefix=".dexcode.", suffix=".json", dir=str(config_file.parent))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(config, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.chmod(tmp_name, 0o600)
    os.replace(tmp_name, config_file)
finally:
    try:
        if Path(tmp_name).exists():
            os.unlink(tmp_name)
    except OSError:
        pass
PY
  chmod 600 "$config_file" 2>/dev/null || true
}

dx_dexcode_fetch_profile() {
  local api_url="$1" token="$2" out_file="$3" http_status
  http_status=$(curl -sS -o "$out_file" -w "%{http_code}" \
    -H "Authorization: Bearer ${token}" \
    -H "Accept: application/json" \
    "${api_url}/api/v1/profile" 2>/dev/null || printf '000')
  [[ "$http_status" == "200" ]]
}

dx_dexcode_login() {
  local api_url open_browser=1 timeout_seconds=900 arg
  api_url=$(dx_dexcode_default_url)

  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --url)
        [[ $# -ge 2 && -n "${2:-}" ]] || { dx_error "--url requires a value"; return 1; }
        api_url="$2"
        shift 2
        ;;
      --url=*)
        api_url="${arg#--url=}"
        shift
        ;;
      --no-browser)
        open_browser=0
        shift
        ;;
      --timeout)
        [[ $# -ge 2 && -n "${2:-}" ]] || { dx_error "--timeout requires seconds"; return 1; }
        timeout_seconds="$2"
        shift 2
        ;;
      --timeout=*)
        timeout_seconds="${arg#--timeout=}"
        shift
        ;;
      -h|--help)
        cat <<'USAGE'
Usage:
  dx login [--url https://dexcode.ai] [--no-browser]

Connect this machine to DexCode with the browser device flow.
USAGE
        return 0
        ;;
      *)
        dx_error "Unknown dx login option: ${arg}"
        return 1
        ;;
    esac
  done

  api_url="${api_url%/}"
  [[ "${DEXCODE_OPEN_BROWSER:-1}" == "0" ]] && open_browser=0

  local tmp_dir device_file token_file profile_file http_status payload device_code user_code verify_url interval start now
  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/dexcode-login.XXXXXX") || return 1
  device_file="$tmp_dir/device.json"
  token_file="$tmp_dir/token.json"
  profile_file="$tmp_dir/profile.json"

  payload=$(DX_DEXCODE_MACHINE_NAME="$(dx_dexcode_machine_name)" \
    DX_DEXCODE_HOSTNAME_HASH="$(dx_dexcode_hostname_hash)" \
    DX_DEXCODE_OS="$(uname -s 2>/dev/null || printf unknown)" \
    DX_DEXCODE_VERSION="$(dx_dexcode_version)" \
    python3 - <<'PY'
import json
import os

print(json.dumps({
    "machine_name": os.environ["DX_DEXCODE_MACHINE_NAME"],
    "hostname_hash": os.environ["DX_DEXCODE_HOSTNAME_HASH"],
    "os": os.environ["DX_DEXCODE_OS"],
    "dex_version": os.environ["DX_DEXCODE_VERSION"],
}, sort_keys=True, separators=(",", ":")))
PY
  ) || {
    command rm -rf "$tmp_dir"
    return 1
  }

  http_status=$(curl -sS -o "$device_file" -w "%{http_code}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "$payload" \
    "${api_url}/api/v1/device_authorizations" 2>/dev/null || printf '000')
  if [[ "$http_status" != "201" ]]; then
    dx_error "DexCode login could not start against ${api_url} (HTTP ${http_status})."
    command rm -rf "$tmp_dir"
    return 1
  fi

  device_code=$(dx_dexcode_json_field "$device_file" "device_code") || { command rm -rf "$tmp_dir"; return 1; }
  user_code=$(dx_dexcode_json_field "$device_file" "user_code") || { command rm -rf "$tmp_dir"; return 1; }
  verify_url=$(dx_dexcode_json_field "$device_file" "verification_uri_complete" 2>/dev/null || dx_dexcode_json_field "$device_file" "verification_uri")
  interval=$(dx_dexcode_json_field "$device_file" "interval" 2>/dev/null || printf '5')
  [[ "$interval" =~ ^[0-9]+$ ]] || interval=5
  [[ "$interval" -gt 0 ]] || interval=5

  dx_info "Open ${verify_url}"
  dx_info "Enter code ${user_code}"
  if [[ "$open_browser" -eq 1 && "$(uname -s 2>/dev/null)" == "Darwin" ]] && command -v open >/dev/null 2>&1; then
    open "$verify_url" >/dev/null 2>&1 || true
  fi

  start=$(date +%s)
  while true; do
    http_status=$(curl -sS -o "$token_file" -w "%{http_code}" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      -d "{\"device_code\":\"${device_code}\"}" \
      "${api_url}/api/v1/device_authorizations/token" 2>/dev/null || printf '000')

    case "$http_status" in
      200)
        local access_token
        access_token=$(dx_dexcode_json_field "$token_file" "access_token") || {
          dx_error "DexCode returned a token response without an access token."
          command rm -rf "$tmp_dir"
          return 1
        }
        dx_dexcode_fetch_profile "$api_url" "$access_token" "$profile_file" || true
        dx_dexcode_write_login_config "$api_url" "$token_file" "$profile_file"
        dx_done "DexCode connected."
        dx_dexcode_select_project
        dx_dexcode_sync_project_context
        dx_dexcode_whoami --offline
        command rm -rf "$tmp_dir"
        return 0
        ;;
      202)
        ;;
      400|401|403|404|410)
        dx_error "DexCode login was not approved (HTTP ${http_status})."
        command rm -rf "$tmp_dir"
        return 1
        ;;
      *)
        dx_warn "Waiting for DexCode approval failed once (HTTP ${http_status}); retrying."
        ;;
    esac

    now=$(date +%s)
    if [[ $((now - start)) -ge "$timeout_seconds" ]]; then
      dx_error "DexCode login timed out before browser approval."
      command rm -rf "$tmp_dir"
      return 1
    fi
    sleep "$interval"
  done
}

dx_dexcode_logout() {
  local file
  file=$(dx_dexcode_config_file)
  if [[ -f "$file" ]]; then
    command rm -f "$file"
    dx_done "DexCode disconnected."
  else
    dx_skip "DexCode is not connected."
  fi
}

dx_dexcode_whoami() {
  local offline=0
  if [[ "${1:-}" == "--offline" ]]; then
    offline=1
  fi

  local token api_url tmp_dir profile_file account project project_slug
  token=$(dx_dexcode_token 2>/dev/null || true)
  if [[ -z "$token" ]]; then
    dx_warn "DexCode is not connected. Run 'dx login' to sync local sessions."
    return 1
  fi

  api_url=$(dx_dexcode_api_url)
  if [[ "$offline" -eq 0 ]]; then
    tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/dexcode-profile.XXXXXX") || return 1
    profile_file="$tmp_dir/profile.json"
    if dx_dexcode_fetch_profile "$api_url" "$token" "$profile_file"; then
      local token_file
      token_file="$tmp_dir/token.json"
      DX_DEXCODE_TOKEN="$token" python3 - > "$token_file" <<'PY'
import json
import os

print(json.dumps({"access_token": os.environ["DX_DEXCODE_TOKEN"]}))
PY
      dx_dexcode_write_login_config "$api_url" "$token_file" "$profile_file"
    fi
    command rm -rf "$tmp_dir"
  fi

  account=$(dx_dexcode_config_value "account.name" 2>/dev/null || dx_dexcode_config_value "account.slug" 2>/dev/null || printf 'unknown')
  project=$(dx_dexcode_config_value "default_project.name" 2>/dev/null || dx_dexcode_config_value "default_project.slug" 2>/dev/null || printf 'unknown')
  project_slug=$(dx_dexcode_config_value "default_project.slug" 2>/dev/null || true)
  dx_info "DexCode account: ${account}"
  if [[ -n "$project_slug" && "$project_slug" != "$project" ]]; then
    dx_info "Connected project: ${project} (${project_slug})"
  else
    dx_info "Connected project: ${project}"
  fi
  dx_info "API: ${api_url}"
}

dx_dexcode_project_count() {
  local file
  file=$(dx_dexcode_config_file)
  [[ -f "$file" ]] || return 1
  DX_DEXCODE_CONFIG_FILE="$file" python3 - <<'PY'
import json
import os
from pathlib import Path

data = json.loads(Path(os.environ["DX_DEXCODE_CONFIG_FILE"]).read_text(encoding="utf-8"))
print(len(data.get("projects") or []))
PY
}

dx_dexcode_refresh_profile() {
  local api_url token tmp_dir profile_file token_file
  api_url=$(dx_dexcode_api_url)
  token=$(dx_dexcode_token 2>/dev/null || true)
  [[ -n "$token" ]] || return 1

  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/dexcode-profile.XXXXXX") || return 1
  profile_file="$tmp_dir/profile.json"
  token_file="$tmp_dir/token.json"
  if dx_dexcode_fetch_profile "$api_url" "$token" "$profile_file"; then
    DX_DEXCODE_TOKEN="$token" python3 - > "$token_file" <<'PY'
import json
import os

print(json.dumps({"access_token": os.environ["DX_DEXCODE_TOKEN"]}))
PY
    dx_dexcode_write_login_config "$api_url" "$token_file" "$profile_file"
    command rm -rf "$tmp_dir"
    return 0
  fi
  command rm -rf "$tmp_dir"
  return 1
}

dx_dexcode_create_project() {
  local project_name="$1" token api_url payload tmp_dir response_file http_status config_file
  project_name="${project_name#"${project_name%%[![:space:]]*}"}"
  project_name="${project_name%"${project_name##*[![:space:]]}"}"
  [[ -n "$project_name" ]] || {
    dx_error "Project name cannot be blank."
    return 1
  }

  token=$(dx_dexcode_token 2>/dev/null || true)
  [[ -n "$token" ]] || {
    dx_warn "DexCode is not connected. Run 'dx login' first."
    return 1
  }

  api_url=$(dx_dexcode_api_url)
  payload=$(DX_DEXCODE_PROJECT_NAME="$project_name" python3 - <<'PY'
import json
import os

print(json.dumps({"project": {"name": os.environ["DX_DEXCODE_PROJECT_NAME"]}}, sort_keys=True, separators=(",", ":")))
PY
  ) || return 1
  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/dexcode-project.XXXXXX") || return 1
  response_file="$tmp_dir/project.json"

  http_status=$(curl -sS -o "$response_file" -w "%{http_code}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "$payload" \
    "${api_url}/api/v1/projects" 2>/dev/null || printf '000')

  if [[ "$http_status" != "200" && "$http_status" != "201" ]]; then
    dx_error "DexCode project creation failed (HTTP ${http_status})."
    command rm -rf "$tmp_dir"
    return 1
  fi

  config_file=$(dx_dexcode_config_file)
  DX_DEXCODE_CONFIG_FILE="$config_file" DX_DEXCODE_PROJECT_FILE="$response_file" python3 - <<'PY'
import json
import os
import tempfile
from pathlib import Path

config_path = Path(os.environ["DX_DEXCODE_CONFIG_FILE"])
project = json.loads(Path(os.environ["DX_DEXCODE_PROJECT_FILE"]).read_text(encoding="utf-8"))
data = json.loads(config_path.read_text(encoding="utf-8"))
projects = data.get("projects") or []
projects = [existing for existing in projects if existing.get("slug") != project.get("slug")]
projects.append(project)
data["projects"] = projects
data["default_project"] = dict(project, default=True)
fd, tmp_name = tempfile.mkstemp(prefix=".dexcode.", suffix=".json", dir=str(config_path.parent))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.chmod(tmp_name, 0o600)
    os.replace(tmp_name, config_path)
finally:
    try:
        if Path(tmp_name).exists():
            os.unlink(tmp_name)
    except OSError:
        pass
PY
  dx_done "Created DexCode project: ${project_name}"
  dx_dexcode_refresh_profile >/dev/null 2>&1 || true
  command rm -rf "$tmp_dir"
}

dx_dexcode_select_project() {
  local force="${1:-}" count create_option account current answer config_file project_name
  if [[ "$force" != "--force" ]]; then
    [[ -t 0 && -t 1 ]] || return 0
    [[ "${DEXCODE_ASSUME_DEFAULTS:-0}" != "1" ]] || return 0
  fi

  config_file=$(dx_dexcode_config_file)
  [[ -f "$config_file" ]] || {
    dx_warn "DexCode is not connected. Run 'dx login' first."
    return 1
  }

  count=$(dx_dexcode_project_count 2>/dev/null || printf '0')
  [[ "$count" =~ ^[0-9]+$ && "$count" -gt 0 ]] || return 0
  create_option=$((count + 1))

  account=$(dx_dexcode_config_value "account.name" 2>/dev/null || dx_dexcode_config_value "account.slug" 2>/dev/null || printf 'DexCode')
  current=$(dx_dexcode_config_value "default_project.name" 2>/dev/null || dx_dexcode_config_value "default_project.slug" 2>/dev/null || printf 'Personal')

  dx_info "Track sessions to organisation: ${account}"
  DX_DEXCODE_CONFIG_FILE="$config_file" python3 - <<'PY'
import json
import os
from pathlib import Path

data = json.loads(Path(os.environ["DX_DEXCODE_CONFIG_FILE"]).read_text(encoding="utf-8"))
default_slug = (data.get("default_project") or {}).get("slug")
for index, project in enumerate(data.get("projects") or [], start=1):
    suffix = " (default)" if project.get("slug") == default_slug else ""
    print(f"  {index}. {project.get('name') or project.get('slug')}{suffix}")
PY
  printf '  %s. Create a new project\n' "$create_option"
  printf 'Choose project [%s]: ' "$current"
  read -r answer || answer=""
  if [[ -z "$answer" ]]; then
    dx_info "Using ${account} / ${current}."
    return 0
  fi
  [[ "$answer" =~ ^[0-9]+$ && "$answer" -ge 1 && "$answer" -le "$create_option" ]] || {
    dx_error "Choose a number from 1 to ${create_option}."
    return 1
  }
  if [[ "$answer" -eq "$create_option" ]]; then
    printf 'New project name: '
    read -r project_name || project_name=""
    dx_dexcode_create_project "$project_name" || return 1
    current=$(dx_dexcode_config_value "default_project.name" 2>/dev/null || dx_dexcode_config_value "default_project.slug" 2>/dev/null || printf '%s' "$project_name")
    dx_info "Using ${account} / ${current}."
    dx_dexcode_sync_project_context
    return 0
  fi

  DX_DEXCODE_CONFIG_FILE="$config_file" DX_DEXCODE_PROJECT_INDEX="$answer" python3 - <<'PY'
import json
import os
import tempfile
from pathlib import Path

path = Path(os.environ["DX_DEXCODE_CONFIG_FILE"])
data = json.loads(path.read_text(encoding="utf-8"))
project = data["projects"][int(os.environ["DX_DEXCODE_PROJECT_INDEX"]) - 1]
data["default_project"] = dict(project, default=True)
fd, tmp_name = tempfile.mkstemp(prefix=".dexcode.", suffix=".json", dir=str(path.parent))
try:
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.chmod(tmp_name, 0o600)
    os.replace(tmp_name, path)
finally:
    try:
        if Path(tmp_name).exists():
            os.unlink(tmp_name)
    except OSError:
        pass
PY
  current=$(dx_dexcode_config_value "default_project.name" 2>/dev/null || dx_dexcode_config_value "default_project.slug" 2>/dev/null || printf 'Personal')
  dx_info "Using ${account} / ${current}."
  dx_dexcode_sync_project_context
}

dx_dexcode_repo_json() {
  local repo_dir="$1" remote_url
  remote_url=$(git -C "$repo_dir" remote get-url origin 2>/dev/null || true)
  DX_DEXCODE_REMOTE_URL="$remote_url" python3 - <<'PY'
import json
import os
import re

url = os.environ.get("DX_DEXCODE_REMOTE_URL", "")
owner = name = ""
provider = "github"
patterns = [
    r"github\.com[:/](?P<owner>[^/]+)/(?P<name>[^/]+?)(?:\.git)?$",
    r"git@github\.com:(?P<owner>[^/]+)/(?P<name>[^/]+?)(?:\.git)?$",
]
for pattern in patterns:
    match = re.search(pattern, url)
    if match:
        owner = match.group("owner")
        name = match.group("name")
        break
print(json.dumps({
    "provider": provider,
    "owner": owner,
    "name": name,
}, sort_keys=True, separators=(",", ":")))
PY
}

dx_dexcode_context_payload() {
  local repo_dir="$1"
  DX_DEXCODE_REPO_DIR="$repo_dir" python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path

repo = Path(os.environ["DX_DEXCODE_REPO_DIR"])
max_bytes = 20000


def read_text(path):
    try:
        data = path.read_bytes()
    except OSError:
        return None
    try:
        return data.decode("utf-8")
    except UnicodeDecodeError:
        return None


def category_for(path):
    parts = path.parts
    if len(parts) >= 3 and parts[1] == "rules":
        return "rule"
    if len(parts) >= 3 and parts[1] == "guards":
        return "rule"
    if len(parts) >= 3 and parts[1] == "memory":
        return "memory"
    if path.name == "review-rules.md":
        return "review"
    return "architecture"


def title_for(relative_path):
    if relative_path.name == "dex.md":
        return "Dex project context"
    if relative_path.name == "index.md" and "memory" in relative_path.parts:
        return "Dex memory index"
    stem = relative_path.stem.replace("-", " ").replace("_", " ").strip().title()
    return f"Dex {stem}"


def collect_entries():
    dex_dir = repo / ".dex"
    if not dex_dir.is_dir():
        return []
    candidates = []
    for path in dex_dir.rglob("*"):
        if not path.is_file():
            continue
        relative = path.relative_to(repo)
        if "worktrees" in relative.parts:
            continue
        if path.suffix.lower() != ".md":
            continue
        candidates.append(path)

    entries = []
    for path in sorted(candidates):
        body = read_text(path)
        if not body:
            continue
        relative = path.relative_to(repo)
        encoded = body.encode("utf-8")
        entries.append({
            "path": str(relative),
            "title": title_for(relative),
            "category": category_for(relative),
            "body": body[:max_bytes],
            "sha256": hashlib.sha256(encoded).hexdigest(),
        })
    return entries


def provider_for(name):
    lowered = name.lower()
    if "github" in lowered:
        return "github"
    if "google" in lowered or "drive" in lowered:
        return "google_workspace"
    if "slack" in lowered:
        return "slack"
    if "figma" in lowered:
        return "figma"
    if "linear" in lowered:
        return "linear"
    if "sentry" in lowered:
        return "sentry"
    if "notion" in lowered:
        return "notion"
    if "airtable" in lowered:
        return "airtable"
    if "vercel" in lowered:
        return "vercel"
    if "browser" in lowered or "playwright" in lowered or "chrome" in lowered:
        return "browser"
    return "other"


def category_for_provider(provider):
    return {
        "github": "repo",
        "google_workspace": "office_suite",
        "slack": "comms",
        "figma": "design",
        "linear": "project_management",
        "sentry": "observability",
        "notion": "docs",
        "airtable": "docs",
        "vercel": "hosting",
        "browser": "browser",
    }.get(provider, "service")


def mcp_servers_from(path):
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        return []
    servers = data.get("mcpServers") or {}
    if not isinstance(servers, dict):
        return []
    records = []
    for server_name, config in sorted(servers.items()):
        if not isinstance(config, dict):
            config = {}
        provider = provider_for(server_name)
        command = config.get("command")
        command_name = Path(command).name if isinstance(command, str) and command else ""
        env = config.get("env") if isinstance(config.get("env"), dict) else {}
        args = config.get("args") if isinstance(config.get("args"), list) else []
        metadata = {
            "name": f"MCP: {server_name}",
            "server_name": server_name,
            "source_file": str(path.relative_to(repo)),
            "transport": "http" if config.get("url") else "stdio",
            "command": command_name,
            "args_count": len(args),
            "env_keys": sorted(str(key) for key in env.keys()),
        }
        records.append({
            "name": f"MCP: {server_name}",
            "provider": provider,
            "category": category_for_provider(provider),
            "connection_state": "manual",
            "status": "configured",
            "metadata": {key: value for key, value in metadata.items() if value not in ("", [], None)},
        })
    return records


def collect_integrations():
    seen = set()
    records = []
    for candidate in [repo / ".mcp.json", repo / ".claude" / "settings.json"]:
        for record in mcp_servers_from(candidate):
            key = (record["name"], record["metadata"].get("source_file", ""))
            if key in seen:
                continue
            seen.add(key)
            records.append(record)
    return records


print(json.dumps({
    "entries": collect_entries(),
    "integrations": collect_integrations(),
}, sort_keys=True, separators=(",", ":")))
PY
}

dx_dexcode_create_run_payload() {
  local run_id="$1" repo_dir="$2" workspace_mode="$3" workspace_name="$4" raw_input="$5" command_name="$6"
  local project_slug project_name default_branch provider branch repo_json
  project_slug=$(dx_dexcode_config_value "default_project.slug" 2>/dev/null || printf 'personal')
  project_name=$(dx_dexcode_config_value "default_project.name" 2>/dev/null || printf 'Personal')
  default_branch=$(git -C "$repo_dir" rev-parse --abbrev-ref origin/HEAD 2>/dev/null | sed 's#^origin/##' || true)
  default_branch="${default_branch:-main}"
  provider="${DX_PROVIDER_AGENT:-claude}"
  branch=$(git -C "$repo_dir" branch --show-current 2>/dev/null || true)
  repo_json=$(dx_dexcode_repo_json "$repo_dir")

  DX_DEXCODE_RUN_ID="$run_id" \
  DX_DEXCODE_REPO_DIR="$repo_dir" \
  DX_DEXCODE_WORKSPACE_MODE="$workspace_mode" \
  DX_DEXCODE_WORKSPACE_NAME="$workspace_name" \
  DX_DEXCODE_RAW_INPUT="$raw_input" \
  DX_DEXCODE_COMMAND_NAME="$command_name" \
  DX_DEXCODE_PROJECT_SLUG="$project_slug" \
  DX_DEXCODE_PROJECT_NAME="$project_name" \
  DX_DEXCODE_DEFAULT_BRANCH="$default_branch" \
  DX_DEXCODE_PROVIDER="$provider" \
  DX_DEXCODE_BRANCH="$branch" \
  DX_DEXCODE_REPO_JSON="$repo_json" \
  python3 - <<'PY'
import json
import os

raw_input = os.environ["DX_DEXCODE_RAW_INPUT"]
repo = json.loads(os.environ["DX_DEXCODE_REPO_JSON"])
payload = {
    "external_id": os.environ["DX_DEXCODE_RUN_ID"],
    "task_title": raw_input or os.environ["DX_DEXCODE_WORKSPACE_NAME"],
    "task_body": raw_input,
    "provider": os.environ["DX_DEXCODE_PROVIDER"],
    "branch_name": os.environ["DX_DEXCODE_BRANCH"],
    "project": {
        "slug": os.environ["DX_DEXCODE_PROJECT_SLUG"],
        "name": os.environ["DX_DEXCODE_PROJECT_NAME"],
        "default_branch": os.environ["DX_DEXCODE_DEFAULT_BRANCH"],
    },
    "metadata": {
        "working_directory": os.environ["DX_DEXCODE_REPO_DIR"],
        "source_type": "local_cli",
        "source_id": os.environ["DX_DEXCODE_WORKSPACE_NAME"],
        "workflow_name": "ticket_to_pr",
        "requires_plan_approval": True,
        "workspace_mode": os.environ["DX_DEXCODE_WORKSPACE_MODE"],
        "command": os.environ["DX_DEXCODE_COMMAND_NAME"],
    },
}
if repo.get("owner") and repo.get("name"):
    payload["repository"] = repo
print(json.dumps(payload, sort_keys=True, separators=(",", ":")))
PY
}

dx_dexcode_prepare_run_sync() {
  local run_id="$1" repo_dir="$2" workspace_mode="$3" workspace_name="$4" raw_input="$5" command_name="${6:-dx}"
  [[ "${DEXCODE_SYNC:-1}" != "0" ]] || return 0

  local token api_url payload tmp_dir response_file http_status
  token=$(dx_dexcode_token 2>/dev/null || true)
  [[ -n "$token" ]] || return 0

  api_url=$(dx_dexcode_api_url)
  payload=$(dx_dexcode_create_run_payload "$run_id" "$repo_dir" "$workspace_mode" "$workspace_name" "$raw_input" "$command_name") || return 0
  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/dexcode-run.XXXXXX") || return 0
  response_file="$tmp_dir/run.json"

  http_status=$(curl -sS -o "$response_file" -w "%{http_code}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "$payload" \
    "${api_url}/api/v1/runs" 2>/dev/null || printf '000')

  if [[ "$http_status" == "200" || "$http_status" == "201" ]]; then
    export DEX_RUN_TOKEN="$token"
    export DEX_FACTORY_TOKEN="$token"
    export DEX_FACTORY_URL="$api_url"
    export DEX_FACTORY_EVENTS_ENDPOINT="${api_url}/api/v1/runs/${run_id}/events/batch"
    export DEX_FACTORY_SYNC=true
    dx_info "DexCode tracking enabled for ${run_id}."
    dx_dexcode_sync_project_context "$repo_dir"
  elif [[ "${DEXCODE_SYNC_REQUIRED:-0}" == "1" ]]; then
    dx_error "DexCode run registration failed (HTTP ${http_status})."
    command rm -rf "$tmp_dir"
    return 1
  else
    dx_warn "DexCode run registration failed (HTTP ${http_status}); continuing locally."
  fi

  command rm -rf "$tmp_dir"
  return 0
}

dx_dexcode_sync_project_context() {
  local repo_dir="${1:-}" token api_url project_slug payload tmp_dir response_file http_status
  [[ "${DEXCODE_CONTEXT_SYNC:-1}" != "0" ]] || return 0
  [[ -n "$repo_dir" ]] || repo_dir=$(git rev-parse --show-toplevel 2>/dev/null || true)
  [[ -n "$repo_dir" && -d "$repo_dir/.dex" ]] || return 0

  token=$(dx_dexcode_token 2>/dev/null || true)
  project_slug=$(dx_dexcode_config_value "default_project.slug" 2>/dev/null || true)
  [[ -n "$token" && -n "$project_slug" ]] || return 0

  api_url=$(dx_dexcode_api_url)
  payload=$(dx_dexcode_context_payload "$repo_dir") || return 0
  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/dexcode-context.XXXXXX") || return 0
  response_file="$tmp_dir/context.json"

  http_status=$(curl -sS -o "$response_file" -w "%{http_code}" \
    -H "Authorization: Bearer ${token}" \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "$payload" \
    "${api_url}/api/v1/projects/${project_slug}/context" 2>/dev/null || printf '000')

  if [[ "$http_status" == "200" || "$http_status" == "201" ]]; then
    DX_DEXCODE_CONTEXT_RESPONSE="$response_file" python3 - <<'PY'
import json
import os
from pathlib import Path

try:
    data = json.loads(Path(os.environ["DX_DEXCODE_CONTEXT_RESPONSE"]).read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    raise SystemExit(0)
print(f"DexCode project context synced: {data.get('synced', 0)} knowledge entries, {data.get('integrations_synced', 0)} integrations.")
PY
  elif [[ "${DEXCODE_CONTEXT_SYNC_REQUIRED:-0}" == "1" ]]; then
    dx_error "DexCode project context sync failed (HTTP ${http_status})."
    command rm -rf "$tmp_dir"
    return 1
  else
    dx_warn "DexCode project context sync failed (HTTP ${http_status}); continuing locally."
  fi

  command rm -rf "$tmp_dir"
  return 0
}

dx_dexcode_command() {
  local cmd="${1:-whoami}"
  shift 2>/dev/null || true

  case "$cmd" in
    login) dx_dexcode_login "$@" ;;
    logout) dx_dexcode_logout "$@" ;;
    whoami|status) dx_dexcode_whoami "$@" ;;
    use|project) dx_dexcode_select_project --force ;;
    *)
      dx_error "Unknown DexCode command: ${cmd}"
      dx_info "Usage: dx dexcode <login|logout|whoami|use>"
      return 1
      ;;
  esac
}
