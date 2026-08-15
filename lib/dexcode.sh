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

dx_dexcode_http_timeout() {
  local value="${DEXCODE_HTTP_TIMEOUT_SECONDS:-15}"
  if [[ "$value" =~ ^[1-9][0-9]*$ && ${#value} -le 4 && "$value" -le 3600 ]]; then
    printf '%s\n' "$value"
  else
    printf '15\n'
  fi
}

dx_dexcode_http_success() {
  case "${1:-}" in
    2[0-9][0-9]) return 0 ;;
    *) return 1 ;;
  esac
}

__dx_dexcode_bounded_positive_int() {
  local value="$1" fallback="$2" minimum="$3" maximum="$4"
  if [[ "$value" =~ ^[1-9][0-9]*$ \
    && ${#value} -le 9 \
    && "$value" -ge "$minimum" \
    && "$value" -le "$maximum" ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "$fallback"
  fi
}

__dx_dexcode_write_private_value() {
  local file="$1" value="$2"
  (umask 077; printf '%s' "$value" > "$file")
}

dx_dexcode_value_disabled() {
  case "${1:-}" in
    0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff]) return 0 ;;
    *) return 1 ;;
  esac
}

dx_dexcode_factory_sync_disabled() {
  case "${DEX_FACTORY_SYNC:-}" in
    ""|1|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|[Oo][Nn]) return 1 ;;
    *) return 0 ;;
  esac
}

dx_dexcode_path_segment_valid() {
  local value="${1:-}"
  [[ -n "$value" && ${#value} -le 255 ]] || return 1
  [[ "$value" != "." && "$value" != ".." ]] || return 1
  [[ "$value" != *[!A-Za-z0-9._-]* ]]
}

# Emit a curl config carrying the Authorization header. Passing the bearer
# token through curl's stdin keeps it out of argv, where any local process can
# read it from ps for the life of the request; lib/factory.sh already avoids
# argv for the same reason. Returns non-zero for an invalid token, which fails
# the pipeline rather than sending an unauthenticated request.
__dx_dexcode_auth_config() {
  local token="${1:-}"
  dx_dexcode_bearer_token_valid "$token" || return 1
  printf 'header = "Authorization: Bearer %s"\n' "$token"
}

dx_dexcode_bearer_token_valid() {
  local token="${1:-}"
  [[ -n "$token" && ${#token} -le 8192 ]] || return 1
  DX_DEXCODE_BEARER_TOKEN="$token" python3 - <<'PY'
import os

token = os.environ["DX_DEXCODE_BEARER_TOKEN"]
allowed = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~+/=")
raise SystemExit(0 if all(char in allowed for char in token) else 1)
PY
}

dx_dexcode_http_url_valid() {
  local url="${1:-}"
  [[ -n "$url" ]] || return 1
  DX_DEXCODE_HTTP_URL="$url" python3 - <<'PY'
import os
from urllib.parse import urlsplit

try:
    parsed = urlsplit(os.environ["DX_DEXCODE_HTTP_URL"])
    _ = parsed.port
except ValueError:
    raise SystemExit(1)

valid = (
    all(ord(char) > 32 and ord(char) != 127 for char in os.environ["DX_DEXCODE_HTTP_URL"])
    and parsed.scheme.lower() in {"http", "https"}
    and bool(parsed.hostname)
    and parsed.username is None
    and parsed.password is None
    and not parsed.fragment
)
raise SystemExit(0 if valid else 1)
PY
}

dx_dexcode_api_url_valid() {
  local url="${1:-}"
  dx_dexcode_http_url_valid "$url" || return 1
  DX_DEXCODE_API_URL_TO_VALIDATE="$url" python3 - <<'PY'
import os
from urllib.parse import urlsplit

parsed = urlsplit(os.environ["DX_DEXCODE_API_URL_TO_VALIDATE"])
raise SystemExit(0 if not parsed.query and not parsed.fragment else 1)
PY
}

dx_dexcode_url_label() {
  local url="${1:-}"
  DX_DEXCODE_URL_LABEL_SOURCE="$url" python3 - <<'PY'
import os
from urllib.parse import urlsplit, urlunsplit

try:
    parsed = urlsplit(os.environ.get("DX_DEXCODE_URL_LABEL_SOURCE", ""))
    port = parsed.port
except ValueError:
    print("invalid URL")
    raise SystemExit(0)
if parsed.scheme.lower() not in {"http", "https"} or not parsed.hostname:
    print("invalid URL")
    raise SystemExit(0)
hostname = parsed.hostname
if ":" in hostname and not hostname.startswith("["):
    hostname = f"[{hostname}]"
netloc = f"{hostname}:{port}" if port is not None else hostname
print(urlunsplit((parsed.scheme.lower(), netloc, parsed.path or "", "", "")))
PY
}

dx_dexcode_json_object_valid() {
  local file="${1:-}"
  [[ -f "$file" ]] || return 1
  DX_DEXCODE_JSON_FILE="$file" python3 - <<'PY'
import json
import os
from pathlib import Path

try:
    data = json.loads(Path(os.environ["DX_DEXCODE_JSON_FILE"]).read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)
raise SystemExit(0 if isinstance(data, dict) else 1)
PY
}

# Copies one regular artifact into a private file while holding no-follow file
# descriptors for every path component below the supplied root. The reported
# size and digest therefore describe the exact bytes in the snapshot, even if
# the original path changes after this function returns.
__dx_dexcode_snapshot_artifact() {
  local artifact_root="$1" rel_path="$2" snapshot_file="$3"
  DX_DEXCODE_ARTIFACT_ROOT="$artifact_root" \
  DX_DEXCODE_ARTIFACT_REL_PATH="$rel_path" \
  DX_DEXCODE_ARTIFACT_SNAPSHOT="$snapshot_file" \
  python3 - <<'PY'
import hashlib
import os
import stat
from pathlib import Path

root = Path(os.environ["DX_DEXCODE_ARTIFACT_ROOT"]).resolve(strict=True)
rel_raw = os.environ["DX_DEXCODE_ARTIFACT_REL_PATH"]
snapshot = Path(os.environ["DX_DEXCODE_ARTIFACT_SNAPSHOT"])
parts = rel_raw.split("/")
if rel_raw.startswith("/") or not parts or any(part in {"", ".", ".."} for part in parts):
    raise SystemExit(1)
if not root.is_dir():
    raise SystemExit(1)

no_follow = getattr(os, "O_NOFOLLOW", 0)
directory = getattr(os, "O_DIRECTORY", 0)
root_fd = os.open(root, os.O_RDONLY | directory | no_follow)
current_fd = root_fd
source_fd = None
try:
    for component in parts[:-1]:
        next_fd = os.open(component, os.O_RDONLY | directory | no_follow, dir_fd=current_fd)
        if current_fd != root_fd:
            os.close(current_fd)
        current_fd = next_fd
    source_fd = os.open(
        parts[-1],
        os.O_RDONLY | no_follow | getattr(os, "O_NONBLOCK", 0),
        dir_fd=current_fd,
    )
    source_stat = os.fstat(source_fd)
    if not stat.S_ISREG(source_stat.st_mode):
        raise SystemExit(1)

    output_fd = os.open(
        snapshot,
        os.O_WRONLY | os.O_CREAT | os.O_EXCL | no_follow,
        0o600,
    )
    digest = hashlib.sha256()
    size = 0
    try:
        with os.fdopen(output_fd, "wb", closefd=True) as output:
            while True:
                chunk = os.read(source_fd, 1024 * 1024)
                if not chunk:
                    break
                output.write(chunk)
                digest.update(chunk)
                size += len(chunk)
            output.flush()
            os.fsync(output.fileno())
    except Exception:
        try:
            snapshot.unlink()
        except OSError:
            pass
        raise
finally:
    if source_fd is not None:
        os.close(source_fd)
    if current_fd != root_fd:
        os.close(current_fd)
    os.close(root_fd)

print(f"{size} {digest.hexdigest()}")
PY
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

# Resolve the active token and its API origins from one config snapshot. Once a
# config has per-organisation connections, the selected connection is
# authoritative; flat compatibility fields must never fill gaps in another
# organisation's record.
dx_dexcode_active_connection() {
  local file default_url
  file=$(dx_dexcode_config_file)
  default_url=$(dx_dexcode_default_url)

  DX_DEXCODE_CONFIG_FILE="$file" \
  DX_DEXCODE_DEFAULT_URL="$default_url" \
  DX_DEXCODE_TOKEN_OVERRIDE="${DEXCODE_TOKEN:-}" \
  DX_DEXCODE_URL_OVERRIDE="${DEXCODE_URL:-}" \
  DX_DEXCODE_FACTORY_URL_OVERRIDE="${DEX_FACTORY_URL:-}" \
  python3 - <<'PY'
import json
import os
from pathlib import Path


def text(value):
    return value if isinstance(value, str) and value else ""


token_override = text(os.environ.get("DX_DEXCODE_TOKEN_OVERRIDE"))
url_override = text(os.environ.get("DX_DEXCODE_URL_OVERRIDE")).rstrip("/")
factory_override = text(os.environ.get("DX_DEXCODE_FACTORY_URL_OVERRIDE")).rstrip("/")
default_url = text(os.environ.get("DX_DEXCODE_DEFAULT_URL")).rstrip("/")

if token_override:
    token = token_override
    api_url = url_override or default_url
    factory_url = factory_override or api_url
else:
    path = Path(os.environ["DX_DEXCODE_CONFIG_FILE"])
    try:
        data = json.loads(path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError):
        raise SystemExit(1)
    if not isinstance(data, dict):
        raise SystemExit(1)

    if "connections" in data:
        connections = data.get("connections")
        selected = data.get("default_project") if isinstance(data.get("default_project"), dict) else {}
        account = data.get("account") if isinstance(data.get("account"), dict) else {}
        slug = text(selected.get("organisation_slug")) or text(account.get("slug"))
        connection = connections.get(slug) if isinstance(connections, dict) and slug else None
        if not isinstance(connection, dict):
            raise SystemExit(1)
        token = text(connection.get("access_token"))
        api_url = text(connection.get("api_url")).rstrip("/")
        sync = connection.get("sync") if isinstance(connection.get("sync"), dict) else {}
    else:
        # A true single-connection legacy file has no connections key. Its flat
        # fields were written as one unit and may be migrated on the next login.
        token = text(data.get("access_token"))
        api_url = text(data.get("api_url")).rstrip("/")
        sync = data.get("sync") if isinstance(data.get("sync"), dict) else {}

    if not token or not api_url:
        raise SystemExit(1)
    api_url = url_override or api_url
    factory_url = factory_override or text(sync.get("factory_url")).rstrip("/") or api_url

values = (token, api_url, factory_url)
if any(not value or any(character in value for character in "\t\r\n") for value in values):
    raise SystemExit(1)
print("\t".join(values))
PY
}

dx_dexcode_api_url() {
  local connection token configured factory_url
  if [[ -n "${DEXCODE_URL:-}" ]]; then
    printf '%s\n' "${DEXCODE_URL%/}"
    return 0
  fi
  if connection=$(dx_dexcode_active_connection 2>/dev/null); then
    IFS=$'\t' read -r token configured factory_url <<< "$connection"
    printf '%s\n' "$configured"
    return 0
  fi
  [[ -f "$(dx_dexcode_config_file)" ]] && return 1
  dx_dexcode_default_url
}

dx_dexcode_factory_url() {
  local connection token api_url configured
  if [[ -n "${DEX_FACTORY_URL:-}" ]]; then
    printf '%s\n' "${DEX_FACTORY_URL%/}"
    return 0
  fi
  if connection=$(dx_dexcode_active_connection 2>/dev/null); then
    IFS=$'\t' read -r token api_url configured <<< "$connection"
    printf '%s\n' "$configured"
    return 0
  fi
  [[ -f "$(dx_dexcode_config_file)" ]] && return 1
  dx_dexcode_default_url
}

# The token for the organisation that owns the selected project. A token
# reaches exactly one organisation, so using the wrong one would create a
# duplicate project in the wrong place rather than fail loudly.
dx_dexcode_token() {
  local connection token api_url factory_url
  connection=$(dx_dexcode_active_connection) || return 1
  IFS=$'\t' read -r token api_url factory_url <<< "$connection"
  printf '%s\n' "$token"
}

# Token for a named organisation, used when work is scoped to one explicitly.
dx_dexcode_token_for() {
  local slug="$1" file
  file=$(dx_dexcode_config_file)
  [[ -f "$file" ]] || return 1
  DX_DEXCODE_CONFIG_FILE="$file" DX_DEXCODE_ORG_SLUG="$slug" python3 - <<'PY'
import json
import os
from pathlib import Path

try:
    data = json.loads(Path(os.environ["DX_DEXCODE_CONFIG_FILE"]).read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)
if not isinstance(data, dict):
    raise SystemExit(1)
slug = os.environ["DX_DEXCODE_ORG_SLUG"]
if "connections" in data:
    connections = data.get("connections")
    connection = connections.get(slug) if isinstance(connections, dict) else None
    token = connection.get("access_token") if isinstance(connection, dict) else None
    api_url = connection.get("api_url") if isinstance(connection, dict) else None
else:
    account = data.get("account") if isinstance(data.get("account"), dict) else {}
    token = data.get("access_token") if account.get("slug") == slug else None
    api_url = data.get("api_url") if account.get("slug") == slug else None
if not isinstance(token, str) or not token or not isinstance(api_url, str) or not api_url:
    raise SystemExit(1)
print(token)
PY
}

dx_dexcode_artifact_token() {
  if [[ "${DEX_HEADLESS_RUN:-0}" == "1" ]]; then
    if [[ -n "${DEX_RUN_TOKEN:-}" ]]; then
      printf '%s\n' "$DEX_RUN_TOKEN"
      return 0
    fi
    if [[ -n "${DEX_FACTORY_RUN_TOKEN:-}" ]]; then
      printf '%s\n' "$DEX_FACTORY_RUN_TOKEN"
      return 0
    fi
    if [[ -n "${DEX_FACTORY_TOKEN:-}" ]]; then
      printf '%s\n' "$DEX_FACTORY_TOKEN"
      return 0
    fi
  fi
  dx_dexcode_token
}

dx_dexcode_artifact_api_url() {
  if [[ "${DEX_HEADLESS_RUN:-0}" == "1" && -n "${DEX_FACTORY_URL:-}" ]]; then
    printf '%s\n' "${DEX_FACTORY_URL%/}"
    return 0
  fi
  if [[ "${DEX_HEADLESS_RUN:-0}" == "1" && -n "${DEX_FACTORY_EVENTS_ENDPOINT:-}" ]]; then
    local derived
    derived=$(DX_DEXCODE_EVENTS_ENDPOINT="$DEX_FACTORY_EVENTS_ENDPOINT" python3 - <<'PY'
import os
import re
from urllib.parse import urlsplit, urlunsplit

try:
    parsed = urlsplit(os.environ["DX_DEXCODE_EVENTS_ENDPOINT"])
except ValueError:
    raise SystemExit(1)
match = re.fullmatch(r"(?P<base>.*?)/api/v1/runs/[^/]+/events/batch/?", parsed.path)
if not match or not parsed.scheme or not parsed.netloc:
    raise SystemExit(1)
print(urlunsplit((parsed.scheme, parsed.netloc, match.group("base"), "", "")))
PY
    ) || derived=""
    if [[ -n "$derived" ]]; then
      printf '%s\n' "${derived%/}"
      return 0
    fi
  fi
  dx_dexcode_api_url
}

dx_dexcode_artifact_connection() {
  local token api_url
  if [[ "${DEX_HEADLESS_RUN:-0}" == "1" \
    && -n "${DEX_RUN_TOKEN:-}${DEX_FACTORY_RUN_TOKEN:-}${DEX_FACTORY_TOKEN:-}" ]]; then
    token=$(dx_dexcode_artifact_token) || return 1
    api_url=$(dx_dexcode_artifact_api_url) || return 1
    case "${token}${api_url}" in
      *$'\t'*|*$'\r'*|*$'\n'*) return 1 ;;
    esac
    printf '%s\t%s\t%s\n' "$token" "$api_url" "$api_url"
    return 0
  fi
  dx_dexcode_active_connection
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
  DX_DEXCODE_HOSTNAME="$host" python3 - <<'PY'
import hashlib
import os

print(hashlib.sha256(os.environ["DX_DEXCODE_HOSTNAME"].encode("utf-8")).hexdigest())
PY
}

__dx_dexcode_artifact_idempotency_key() {
  local run_id="$1" local_artifact_id="$2" fingerprint="$3"
  dx_run_validate_id "$run_id" 2>/dev/null || return 1
  dx_dexcode_path_segment_valid "$local_artifact_id" || return 1
  [[ "$fingerprint" =~ ^[a-f0-9]{64}$ ]] || return 1

  DX_DEXCODE_RUN_ID="$run_id" \
  DX_DEXCODE_LOCAL_ARTIFACT_ID="$local_artifact_id" \
  DX_DEXCODE_ARTIFACT_FINGERPRINT="$fingerprint" python3 - <<'PY'
import hashlib
import json
import os

source = json.dumps({
    "artifact_id": os.environ["DX_DEXCODE_LOCAL_ARTIFACT_ID"],
    "fingerprint": os.environ["DX_DEXCODE_ARTIFACT_FINGERPRINT"],
    "run_id": os.environ["DX_DEXCODE_RUN_ID"],
}, sort_keys=True, separators=(",", ":")).encode("utf-8")
print("dex-artifact-v1-" + hashlib.sha256(source).hexdigest())
PY
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
import re
import tempfile
from datetime import datetime, timezone
from pathlib import Path

config_file = Path(os.environ["DX_DEXCODE_CONFIG_FILE"])
incoming_api_url = os.environ["DX_DEXCODE_API_URL"].rstrip("/")
token_response = json.loads(Path(os.environ["DX_DEXCODE_TOKEN_FILE"]).read_text(encoding="utf-8"))
if not isinstance(token_response, dict) or not isinstance(token_response.get("access_token"), str) or not token_response["access_token"]:
    raise SystemExit("DexCode token response is missing access_token")
profile_path = os.environ.get("DX_DEXCODE_PROFILE_FILE", "")
existing = {}
if config_file.exists():
    try:
        existing = json.loads(config_file.read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        existing = {}
if not isinstance(existing, dict):
    existing = {}
token_profile = token_response.get("profile") or {}
if not isinstance(token_profile, dict):
    token_profile = {}
profile = token_profile
if profile_path and Path(profile_path).exists():
    try:
        profile = json.loads(Path(profile_path).read_text(encoding="utf-8"))
    except json.JSONDecodeError:
        profile = token_profile
if not isinstance(profile, dict):
    profile = token_profile
now = datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")
segment_re = re.compile(r"^[A-Za-z0-9._-]{1,255}$")
incoming_sync = profile.get("sync") or token_profile.get("sync") or {}
if not isinstance(incoming_sync, dict):
    incoming_sync = {}


def valid_segment(value):
    return isinstance(value, str) and value not in {".", ".."} and bool(segment_re.fullmatch(value))

# A DexCode token reaches exactly one organisation, by design. People work
# across several from one laptop, so the config keeps a connection per
# organisation and logging into a second one adds to the set rather than
# replacing the first. The flat fields below still describe the active
# connection, so anything reading access_token or account keeps working.
account = profile.get("account") if isinstance(profile.get("account"), dict) else {}
account_slug = account.get("slug") if valid_segment(account.get("slug")) else ""
if account.get("slug") and not account_slug:
    account = {}
profile_projects = profile.get("projects") if isinstance(profile.get("projects"), list) else []
if not profile_projects and isinstance(profile.get("default_project"), dict):
    profile_projects = [profile["default_project"]]
own_projects = [
    dict(project)
    for project in profile_projects
    if isinstance(project, dict) and valid_segment(project.get("slug"))
]
for project in own_projects:
    if not valid_segment(project.get("organisation_slug")):
        project["organisation_slug"] = account_slug
    project.setdefault("organisation_name", account.get("name") or account_slug)

raw_connections = existing.get("connections")
if isinstance(raw_connections, dict):
    connections = {
        slug: dict(connection)
        for slug, connection in raw_connections.items()
        if valid_segment(slug) and isinstance(connection, dict)
    }
else:
    connections = {}
    # An older single-connection config becomes the first entry, so nothing is
    # lost on the upgrade.
    previous_account = existing.get("account") if isinstance(existing.get("account"), dict) else {}
    previous_slug = previous_account.get("slug") if valid_segment(previous_account.get("slug")) else ""
    if previous_slug and existing.get("access_token"):
        connections[previous_slug] = {
            "access_token": existing["access_token"],
            "token_type": existing.get("token_type", "Bearer"),
            "expires_at": existing.get("expires_at"),
            "scopes": existing.get("scopes", []),
            "account": previous_account,
            "projects": existing.get("projects") or [],
            "api_url": existing.get("api_url") or "",
            "sync": existing.get("sync") if isinstance(existing.get("sync"), dict) else {},
            "updated_at": existing.get("updated_at") or now,
        }

for slug, connection in connections.items():
    normalized_projects = []
    for project in connection.get("projects") or []:
        if not isinstance(project, dict) or not valid_segment(project.get("slug")):
            continue
        normalized = dict(project)
        if not valid_segment(normalized.get("organisation_slug")):
            normalized["organisation_slug"] = slug
        normalized_projects.append(normalized)
    connection["projects"] = normalized_projects

# Older multi-connection files did not bind an origin to each token. Only the
# connection that already owns the active top-level fields can inherit them;
# assigning those fields to every connection would recreate the token leak this
# mapping is meant to prevent.
existing_account = existing.get("account") if isinstance(existing.get("account"), dict) else {}
existing_token = existing.get("access_token") if isinstance(existing.get("access_token"), str) else ""
token_owners = [
    slug
    for slug, connection in connections.items()
    if existing_token and connection.get("access_token") == existing_token
]
existing_active_slug = token_owners[0] if len(token_owners) == 1 else ""
if existing_active_slug:
    legacy_active = connections[existing_active_slug]
    if not legacy_active.get("api_url") and isinstance(existing.get("api_url"), str):
        legacy_active["api_url"] = existing["api_url"]
    if (not isinstance(legacy_active.get("sync"), dict) or not legacy_active.get("sync")) and isinstance(existing.get("sync"), dict):
        legacy_active["sync"] = existing["sync"]

if account_slug:
    previous_connection = connections.get(account_slug) or {}
    connection_sync = incoming_sync or previous_connection.get("sync") or {}
    if not isinstance(connection_sync, dict):
        connection_sync = {}
    connections[account_slug] = {
        "access_token": token_response["access_token"],
        "token_type": token_response.get("token_type", previous_connection.get("token_type", "Bearer")),
        "expires_at": token_response.get("expires_at", previous_connection.get("expires_at")),
        "scopes": token_response.get("scopes", previous_connection.get("scopes", [])),
        "account": account,
        "projects": own_projects,
        "api_url": incoming_api_url,
        "sync": connection_sync,
        "updated_at": now,
    }

# Every project the machine can reach, labelled with the organisation that
# owns it so the picker can tell two similarly named ones apart.
projects = []
seen = set()
for slug, connection in connections.items():
    for project in connection.get("projects") or []:
        if not isinstance(project, dict):
            continue
        project_slug = project.get("slug")
        if not valid_segment(project_slug):
            continue
        project_org = project.get("organisation_slug")
        if not valid_segment(project_org):
            project_org = slug
        key = (project_org, project_slug)
        if key in seen:
            continue
        seen.add(key)
        entry = dict(project)
        if not valid_segment(entry.get("organisation_slug")):
            entry["organisation_slug"] = slug
        projects.append(entry)

default_project = profile.get("default_project")
if isinstance(default_project, dict) and valid_segment(default_project.get("slug")):
    default_project = dict(default_project)
    if not valid_segment(default_project.get("organisation_slug")):
        default_project["organisation_slug"] = account_slug
else:
    default_project = None
selected = existing.get("default_project") if isinstance(existing.get("default_project"), dict) else {}
selected_slug = selected.get("slug") if valid_segment(selected.get("slug")) else ""
if selected_slug:
    # Keep the user's choice even when this login was for a different
    # organisation; re-authenticating one connection should not silently move
    # them to another organisation's project.
    preserved = next(
        (
            project
            for project in projects
            if project.get("slug") == selected_slug
            and (
                not selected.get("organisation_slug")
                or project.get("organisation_slug") == selected.get("organisation_slug")
            )
        ),
        None,
    )
    if preserved:
        default_project = dict(preserved, default=True)

# The flat fields describe whichever connection owns the selected project, so
# a plain read of access_token stays correct for the work in hand.
active_slug = (default_project or {}).get("organisation_slug") or account_slug
active = connections.get(active_slug) or connections.get(account_slug) or {}
active_api_url = active.get("api_url") if isinstance(active.get("api_url"), str) else ""
active_sync = active.get("sync") if isinstance(active.get("sync"), dict) else {}

profile_organisations = profile.get("organisations")
if not isinstance(profile_organisations, list):
    profile_organisations = []
profile_organisations = [
    item
    for item in profile_organisations
    if isinstance(item, dict) and valid_segment(item.get("slug"))
]
existing_organisations = existing.get("organisations")
if not isinstance(existing_organisations, list):
    existing_organisations = []
existing_organisations = [
    item
    for item in existing_organisations
    if isinstance(item, dict) and valid_segment(item.get("slug"))
]

config = {
    "api_url": active_api_url,
    "access_token": active.get("access_token") if isinstance(active.get("access_token"), str) else "",
    "token_type": active.get("token_type", "Bearer"),
    "expires_at": active.get("expires_at", token_response.get("expires_at", existing.get("expires_at"))),
    "scopes": active.get("scopes", []),
    "account": active.get("account") or account,
    "organisations": profile_organisations or existing_organisations or ([account] if account else []),
    "connections": connections,
    "default_project": default_project,
    "projects": projects,
    "sync": active_sync,
    "updated_at": now,
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

# Records the status in DX_DEXCODE_LAST_HTTP_STATUS so callers can tell a
# revoked machine from an unreachable server.
dx_dexcode_fetch_profile() {
  local api_url="$1" token="$2" out_file="$3" http_status timeout_seconds
  dx_dexcode_bearer_token_valid "$token" || {
    DX_DEXCODE_LAST_HTTP_STATUS="invalid_token"
    return 1
  }
  timeout_seconds=$(dx_dexcode_http_timeout)
  if ! http_status=$(__dx_dexcode_auth_config "$token" | command curl -q -sS --config - -o "$out_file" -w "%{http_code}" \
    --max-time "$timeout_seconds" \
    --proto '=http,https' \
    -H "Accept: application/json" \
    "${api_url}/api/v1/profile" 2>/dev/null); then
    http_status="000"
  fi
  DX_DEXCODE_LAST_HTTP_STATUS="$http_status"
  [[ "$http_status" == "200" ]] || return 1
  if ! dx_dexcode_json_object_valid "$out_file"; then
    DX_DEXCODE_LAST_HTTP_STATUS="invalid_response"
    return 1
  fi
  return 0
}

dx_dexcode_login() {
  local api_url open_browser=1 timeout_seconds=900 arg request_timeout
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
  dx login [--url https://dexcode.ai] [--no-browser] [--timeout SECONDS]

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
  if ! dx_dexcode_api_url_valid "$api_url"; then
    dx_error "--url must be an HTTP or HTTPS base URL without credentials, a query, or a fragment."
    return 1
  fi
  if [[ ! "$timeout_seconds" =~ ^[1-9][0-9]*$ || ${#timeout_seconds} -gt 5 || "$timeout_seconds" -gt 86400 ]]; then
    dx_error "--timeout must be a whole number from 1 to 86400 seconds."
    return 1
  fi
  request_timeout=$(dx_dexcode_http_timeout)
  if [[ "$request_timeout" -gt "$timeout_seconds" ]]; then
    request_timeout="$timeout_seconds"
  fi
  [[ "${DEXCODE_OPEN_BROWSER:-1}" == "0" ]] && open_browser=0

  local tmp_dir device_file token_file profile_file http_status payload device_code user_code verify_url interval start now remaining sleep_seconds
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

  if ! http_status=$(command curl -q -sS -o "$device_file" -w "%{http_code}" \
    --max-time "$request_timeout" \
    --proto '=http,https' \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "$payload" \
    "${api_url}/api/v1/device_authorizations" 2>/dev/null); then
    http_status="000"
  fi
  if [[ "$http_status" != "201" ]]; then
    dx_error "DexCode login could not start against ${api_url} (HTTP ${http_status})."
    command rm -rf "$tmp_dir"
    return 1
  fi

  device_code=$(dx_dexcode_json_field "$device_file" "device_code" 2>/dev/null || true)
  user_code=$(dx_dexcode_json_field "$device_file" "user_code" 2>/dev/null || true)
  verify_url=$(dx_dexcode_json_field "$device_file" "verification_uri_complete" 2>/dev/null || dx_dexcode_json_field "$device_file" "verification_uri" 2>/dev/null || true)
  if [[ -z "$device_code" || ${#device_code} -gt 4096 ]] \
    || ! dx_dexcode_path_segment_valid "$user_code" \
    || ! dx_dexcode_http_url_valid "$verify_url"; then
    dx_error "DexCode returned an invalid device authorization response."
    command rm -rf "$tmp_dir"
    return 1
  fi
  interval=$(dx_dexcode_json_field "$device_file" "interval" 2>/dev/null || printf '5')
  if [[ ! "$interval" =~ ^[1-9][0-9]*$ || ${#interval} -gt 4 || "$interval" -gt 3600 ]]; then
    interval=5
  fi

  dx_info "Open ${verify_url}"
  dx_info "Enter code ${user_code}"
  if [[ "$open_browser" -eq 1 && "$(uname -s 2>/dev/null)" == "Darwin" ]] && command -v open >/dev/null 2>&1; then
    open "$verify_url" >/dev/null 2>&1 || true
  fi

  start=$(date +%s)
  while true; do
    now=$(date +%s)
    remaining=$((timeout_seconds - (now - start)))
    if [[ "$remaining" -le 0 ]]; then
      dx_error "DexCode login timed out before browser approval."
      command rm -rf "$tmp_dir"
      return 1
    fi
    request_timeout=$(dx_dexcode_http_timeout)
    if [[ "$request_timeout" -gt "$remaining" ]]; then
      request_timeout="$remaining"
    fi
    payload=$(DX_DEXCODE_DEVICE_CODE="$device_code" python3 - <<'PY'
import json
import os

print(json.dumps({"device_code": os.environ["DX_DEXCODE_DEVICE_CODE"]}, separators=(",", ":")))
PY
    ) || {
      command rm -rf "$tmp_dir"
      return 1
    }
    if ! http_status=$(command curl -q -sS -o "$token_file" -w "%{http_code}" \
      --max-time "$request_timeout" \
      --proto '=http,https' \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      -d "$payload" \
      "${api_url}/api/v1/device_authorizations/token" 2>/dev/null); then
      http_status="000"
    fi

    case "$http_status" in
      200)
        local access_token
        access_token=$(dx_dexcode_json_field "$token_file" "access_token") || {
          dx_error "DexCode returned a token response without an access token."
          command rm -rf "$tmp_dir"
          return 1
        }
        if ! dx_dexcode_bearer_token_valid "$access_token"; then
          dx_error "DexCode returned an invalid access token."
          command rm -rf "$tmp_dir"
          return 1
        fi
        if ! dx_dexcode_fetch_profile "$api_url" "$access_token" "$profile_file"; then
          # A non-2xx profile response can still leave a JSON error body in the
          # output file. Do not mistake that body for the profile already
          # included in the successful token response.
          profile_file=""
        fi
        if ! dx_dexcode_write_login_config "$api_url" "$token_file" "$profile_file"; then
          dx_error "DexCode connected, but its login response could not be saved."
          command rm -rf "$tmp_dir"
          return 1
        fi
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
    remaining=$((timeout_seconds - (now - start)))
    if [[ "$remaining" -le 0 ]]; then
      dx_error "DexCode login timed out before browser approval."
      command rm -rf "$tmp_dir"
      return 1
    fi
    sleep_seconds="$interval"
    if [[ "$sleep_seconds" -gt "$remaining" ]]; then
      sleep_seconds="$remaining"
    fi
    sleep "$sleep_seconds"
  done
}

dx_dexcode_logout() {
  local file arg
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      -h|--help)
        cat <<'USAGE'
Usage:
  dx logout

Remove this machine's local DexCode connection.
USAGE
        return 0
        ;;
      *)
        dx_error "Unknown dx logout option: ${arg}"
        return 1
        ;;
    esac
  done

  file=$(dx_dexcode_config_file)
  if [[ -f "$file" ]]; then
    command rm -f "$file"
    dx_done "DexCode disconnected."
  else
    dx_skip "DexCode is not connected."
  fi
}

dx_dexcode_whoami() {
  local offline=0 arg
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --offline)
        offline=1
        shift
        ;;
      -h|--help)
        cat <<'USAGE'
Usage:
  dx whoami [--offline]

Show the active DexCode organisation, project, and sync settings. Use
--offline to skip the profile refresh and show the last saved details.
USAGE
        return 0
        ;;
      *)
        dx_error "Unknown dx whoami option: ${arg}"
        return 1
        ;;
    esac
  done

  local connection token api_url sync_url api_label sync_label tmp_dir profile_file account project project_slug session_sync event_sync context_sync
  if ! connection=$(dx_dexcode_active_connection 2>/dev/null); then
    dx_warn "DexCode is not connected. Run 'dx login' to sync local sessions."
    return 1
  fi
  IFS=$'\t' read -r token api_url sync_url <<< "$connection"
  if ! dx_dexcode_bearer_token_valid "$token"; then
    dx_warn "DexCode is not connected. Run 'dx login' to sync local sessions."
    return 1
  fi

  if [[ "$offline" -eq 0 ]]; then
    if ! dx_dexcode_api_url_valid "$api_url"; then
      dx_error "The saved DexCode API URL is invalid. Run 'dx login --url URL' to reconnect."
      return 1
    fi
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
      if ! dx_dexcode_write_login_config "$api_url" "$token_file" "$profile_file"; then
        dx_warn "DexCode profile refresh could not be saved; showing the last known details."
      fi
    elif [[ "${DX_DEXCODE_LAST_HTTP_STATUS:-}" == "401" || "${DX_DEXCODE_LAST_HTTP_STATUS:-}" == "403" ]]; then
      # Revoking a lost laptop is worth nothing if that laptop still
      # reports itself as connected. Say so instead of showing stale
      # details that look healthy.
      command rm -rf "$tmp_dir"
      dx_error "This machine is no longer connected to DexCode. Run 'dx login' to reconnect."
      return 1
    elif [[ "${DX_DEXCODE_LAST_HTTP_STATUS:-}" == "000" ]]; then
      dx_warn "Could not reach DexCode; showing the last known details."
    elif [[ "${DX_DEXCODE_LAST_HTTP_STATUS:-}" == "invalid_response" ]]; then
      dx_warn "DexCode returned an invalid profile response; showing the last known details."
    else
      dx_warn "DexCode profile refresh failed (HTTP ${DX_DEXCODE_LAST_HTTP_STATUS:-unknown}); showing the last known details."
    fi
    command rm -rf "$tmp_dir"
  fi

  api_label=$(dx_dexcode_url_label "$api_url")
  sync_label=$(dx_dexcode_url_label "$sync_url")
  account=$(dx_dexcode_config_value "account.name" 2>/dev/null || dx_dexcode_config_value "account.slug" 2>/dev/null || printf 'unknown')
  project=$(dx_dexcode_config_value "default_project.name" 2>/dev/null || dx_dexcode_config_value "default_project.slug" 2>/dev/null || printf 'unknown')
  project_slug=$(dx_dexcode_config_value "default_project.slug" 2>/dev/null || true)
  session_sync="enabled"
  event_sync="enabled"
  context_sync="enabled"
  if dx_dexcode_value_disabled "${DEXCODE_SYNC:-1}"; then
    session_sync="disabled"
    event_sync="disabled"
  elif dx_dexcode_factory_sync_disabled; then
    event_sync="disabled"
  fi
  if dx_dexcode_value_disabled "${DEXCODE_CONTEXT_SYNC:-1}"; then
    context_sync="disabled"
  fi
  dx_info "DexCode organisation: ${account}"
  if [[ -n "$project_slug" && "$project_slug" != "$project" ]]; then
    dx_info "Connected project: ${project} (${project_slug})"
  elif [[ "$project" == "unknown" ]]; then
    dx_info "Connected project: none selected yet (run 'dx dexcode use')"
  else
    dx_info "Connected project: ${project}"
  fi
  # A token reaches one organisation, so a machine holds one connection per
  # organisation. Say which ones, and what to do about the rest.
  DX_DEXCODE_CONFIG_FILE="$(dx_dexcode_config_file)" python3 - <<'PY' 2>/dev/null || true
import json
import os
import re
from pathlib import Path

try:
    data = json.loads(Path(os.environ["DX_DEXCODE_CONFIG_FILE"]).read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    raise SystemExit(0)

connected = sorted((data.get("connections") or {}).keys())
if not connected:
    raise SystemExit(0)
known = {(o or {}).get("slug") for o in (data.get("organisations") or [])}
missing = sorted(slug for slug in known if slug and slug not in connected)
print("[info]  Connected organisations: " + ", ".join(connected))
if missing:
    print(
        "[info]  Not connected on this machine: "
        + ", ".join(missing)
        + " (run 'dx login' and pick it to add)"
    )
PY
  dx_info "API: ${api_label}"
  dx_info "DexCode sync URL: ${sync_label}"
  dx_info "Session sync: ${session_sync}"
  dx_info "Event sync: ${event_sync}"
  dx_info "Project context sync: ${context_sync}"
}

dx_dexcode_project_count() {
  local file
  file=$(dx_dexcode_config_file)
  [[ -f "$file" ]] || return 1
  DX_DEXCODE_CONFIG_FILE="$file" python3 - <<'PY'
import json
import os
import re
from pathlib import Path

data = json.loads(Path(os.environ["DX_DEXCODE_CONFIG_FILE"]).read_text(encoding="utf-8"))
projects = data.get("projects")
if not isinstance(projects, list):
    projects = []
projects = [
    project
    for project in projects
    if isinstance(project, dict)
    and isinstance(project.get("slug"), str)
    and project["slug"] not in {".", ".."}
    and re.fullmatch(r"[A-Za-z0-9._-]{1,255}", project["slug"])
]
print(len(projects))
PY
}

dx_dexcode_refresh_profile() {
  local connection api_url token factory_url tmp_dir profile_file token_file
  connection=$(dx_dexcode_active_connection 2>/dev/null) || return 1
  IFS=$'\t' read -r token api_url factory_url <<< "$connection"
  dx_dexcode_bearer_token_valid "$token" || return 1

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
  local project_name="$1" connection token api_url factory_url payload tmp_dir response_file http_status config_file timeout_seconds project_slug
  project_name="${project_name#"${project_name%%[![:space:]]*}"}"
  project_name="${project_name%"${project_name##*[![:space:]]}"}"
  [[ -n "$project_name" ]] || {
    dx_error "Project name cannot be blank."
    return 1
  }

  connection=$(dx_dexcode_active_connection 2>/dev/null || true)
  IFS=$'\t' read -r token api_url factory_url <<< "$connection"
  if ! dx_dexcode_bearer_token_valid "$token"; then
    dx_warn "DexCode is not connected. Run 'dx login' first."
    return 1
  fi

  if ! dx_dexcode_api_url_valid "$api_url"; then
    dx_error "The saved DexCode API URL is invalid. Run 'dx login --url URL' to reconnect."
    return 1
  fi
  timeout_seconds=$(dx_dexcode_http_timeout)
  payload=$(DX_DEXCODE_PROJECT_NAME="$project_name" python3 - <<'PY'
import json
import os

print(json.dumps({"project": {"name": os.environ["DX_DEXCODE_PROJECT_NAME"]}}, sort_keys=True, separators=(",", ":")))
PY
  ) || return 1
  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/dexcode-project.XXXXXX") || return 1
  response_file="$tmp_dir/project.json"

  if ! http_status=$(__dx_dexcode_auth_config "$token" | command curl -q -sS --config - -o "$response_file" -w "%{http_code}" \
    --max-time "$timeout_seconds" \
    --proto '=http,https' \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "$payload" \
    "${api_url}/api/v1/projects" 2>/dev/null); then
    http_status="000"
  fi

  if ! dx_dexcode_http_success "$http_status"; then
    dx_error "DexCode project creation failed (HTTP ${http_status})."
    command rm -rf "$tmp_dir"
    return 1
  fi

  project_slug=$(dx_dexcode_json_field "$response_file" "slug" 2>/dev/null || true)
  if ! dx_dexcode_path_segment_valid "$project_slug"; then
    dx_error "DexCode returned an invalid project response."
    command rm -rf "$tmp_dir"
    return 1
  fi

  config_file=$(dx_dexcode_config_file)
  if ! DX_DEXCODE_CONFIG_FILE="$config_file" DX_DEXCODE_PROJECT_FILE="$response_file" python3 - <<'PY'
import json
import os
import tempfile
from pathlib import Path

config_path = Path(os.environ["DX_DEXCODE_CONFIG_FILE"])
project = json.loads(Path(os.environ["DX_DEXCODE_PROJECT_FILE"]).read_text(encoding="utf-8"))
data = json.loads(config_path.read_text(encoding="utf-8"))
projects = data.get("projects") or []
if not isinstance(projects, list):
    projects = []
projects = [
    existing
    for existing in projects
    if isinstance(existing, dict) and existing.get("slug") != project.get("slug")
]
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
  then
    dx_error "DexCode created the project, but the local selection could not be saved."
    command rm -rf "$tmp_dir"
    return 1
  fi
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

  DX_DEXCODE_CONFIG_FILE="$config_file" python3 - <<'PY'
import json
import os
import re
from pathlib import Path

data = json.loads(Path(os.environ["DX_DEXCODE_CONFIG_FILE"]).read_text(encoding="utf-8"))
selected = data.get("default_project") if isinstance(data.get("default_project"), dict) else {}
connections = data.get("connections") if isinstance(data.get("connections"), dict) else {}
# Only worth naming the organisation when more than one is connected.
show_org = len(connections) > 1
projects = [
    project
    for project in (data.get("projects") or [])
    if isinstance(project, dict)
    and isinstance(project.get("slug"), str)
    and project["slug"] not in {".", ".."}
    and re.fullmatch(r"[A-Za-z0-9._-]{1,255}", project["slug"])
]
for index, project in enumerate(projects, start=1):
    current = (
        project.get("slug") == selected.get("slug")
        and project.get("organisation_slug") == selected.get("organisation_slug")
    )
    suffix = " (default)" if current else ""
    org = project.get("organisation_name") or project.get("organisation_slug") or ""
    prefix = f"{org} / " if show_org and org else ""
    print(f"  {index}. {prefix}{project.get('name') or project.get('slug')}{suffix}")
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

  if ! DX_DEXCODE_CONFIG_FILE="$config_file" DX_DEXCODE_PROJECT_INDEX="$answer" python3 - <<'PY'
import json
import os
import re
import tempfile
from pathlib import Path

path = Path(os.environ["DX_DEXCODE_CONFIG_FILE"])
data = json.loads(path.read_text(encoding="utf-8"))
projects = [
    project
    for project in (data.get("projects") or [])
    if isinstance(project, dict)
    and isinstance(project.get("slug"), str)
    and project["slug"] not in {".", ".."}
    and re.fullmatch(r"[A-Za-z0-9._-]{1,255}", project["slug"])
]
project = projects[int(os.environ["DX_DEXCODE_PROJECT_INDEX"]) - 1]
data["default_project"] = dict(project, default=True)

# Follow the project to its organisation: the flat fields describe the active
# connection, and syncing with another organisation's token would create a
# duplicate project there instead of failing.
organisation_slug = project.get("organisation_slug")
if not isinstance(organisation_slug, str):
    organisation_slug = ""
connections = data.get("connections") if isinstance(data.get("connections"), dict) else {}
connection = connections.get(organisation_slug)
if not isinstance(connection, dict):
    raise SystemExit("selected project has no saved organisation connection")
api_url = connection.get("api_url")
access_token = connection.get("access_token")
if not isinstance(api_url, str) or not api_url or not isinstance(access_token, str) or not access_token:
    raise SystemExit("selected organisation must be reconnected before use")
sync = connection.get("sync")
if not isinstance(sync, dict):
    sync = {}
data["access_token"] = access_token
data["token_type"] = connection.get("token_type", data.get("token_type"))
data["scopes"] = connection.get("scopes", data.get("scopes"))
data["account"] = connection.get("account", data.get("account"))
data["api_url"] = api_url
data["sync"] = sync
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
  then
    dx_error "That DexCode organisation must be reconnected before it can be selected. Run 'dx login' and choose it again."
    return 1
  fi
  account=$(dx_dexcode_config_value "account.name" 2>/dev/null || dx_dexcode_config_value "account.slug" 2>/dev/null || printf 'DexCode')
  current=$(dx_dexcode_config_value "default_project.name" 2>/dev/null || dx_dexcode_config_value "default_project.slug" 2>/dev/null || printf 'Personal')
  dx_info "Using ${account} / ${current}."
  dx_dexcode_sync_project_context
}

dx_dexcode_repo_json() {
  local repo_dir="$1" output_file="${2:-}" remote_url tmp_dir status=0 owned_output=0
  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/dexcode-repo-payload.XXXXXX") || return 1
  chmod 700 "$tmp_dir" 2>/dev/null || {
    command rm -rf "$tmp_dir"
    return 1
  }
  if [[ -z "$output_file" ]]; then
    output_file="$tmp_dir/repository.json"
    owned_output=1
  fi
  remote_url=$(git -C "$repo_dir" remote get-url origin 2>/dev/null || true)
  __dx_dexcode_write_private_value "$tmp_dir/remote-url" "$remote_url" || {
    command rm -rf "$tmp_dir"
    return 1
  }
  if DX_DEXCODE_REMOTE_URL_FILE="$tmp_dir/remote-url" \
    DX_DEXCODE_REPO_OUTPUT="$output_file" python3 - <<'PY'
import json
import os
import re
from pathlib import Path
from urllib.parse import unquote, urlsplit

url = Path(os.environ["DX_DEXCODE_REMOTE_URL_FILE"]).read_text(encoding="utf-8")
owner = name = ""
provider = "github"

scp_match = re.fullmatch(r"(?:[^@/:]+@)?github\.com:(?P<path>[^?#]+)", url, re.I)
if scp_match:
    repo_path = scp_match.group("path")
else:
    try:
        parsed = urlsplit(url)
    except ValueError:
        parsed = None
    repo_path = parsed.path.lstrip("/") if parsed and (parsed.hostname or "").lower() == "github.com" else ""

parts = [unquote(part) for part in repo_path.rstrip("/").split("/") if part]
if len(parts) == 2:
    candidate_owner, candidate_name = parts
    if candidate_name.endswith(".git"):
        candidate_name = candidate_name[:-4]
    safe = re.compile(r"^[A-Za-z0-9_.-]+$")
    if safe.fullmatch(candidate_owner) and safe.fullmatch(candidate_name):
        owner, name = candidate_owner, candidate_name
payload = json.dumps({
    "provider": provider,
    "owner": owner,
    "name": name,
}, sort_keys=True, separators=(",", ":")).encode("utf-8")
output = Path(os.environ["DX_DEXCODE_REPO_OUTPUT"])
fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "wb") as fh:
    fh.write(payload)
PY
  then
    :
  else
    status=$?
  fi
  if [[ "$status" -eq 0 && "$owned_output" -eq 1 ]]; then
    command cat "$output_file" || status=$?
  fi
  command rm -rf "$tmp_dir"
  return "$status"
}

dx_dexcode_context_payload() {
  local repo_dir="$1" output_file="${2:-}" owned_tmp_dir=""
  local entry_max_bytes total_max_bytes max_entries status=0
  if [[ -z "$output_file" ]]; then
    owned_tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/dexcode-context-payload.XXXXXX") || return 1
    chmod 700 "$owned_tmp_dir" 2>/dev/null || {
      command rm -rf "$owned_tmp_dir"
      return 1
    }
    output_file="$owned_tmp_dir/context.json"
  fi
  entry_max_bytes=$(__dx_dexcode_bounded_positive_int \
    "${DEXCODE_CONTEXT_ENTRY_MAX_BYTES:-20000}" 20000 1024 1048576)
  total_max_bytes=$(__dx_dexcode_bounded_positive_int \
    "${DEXCODE_CONTEXT_TOTAL_MAX_BYTES:-524288}" 524288 65536 16777216)
  max_entries=$(__dx_dexcode_bounded_positive_int \
    "${DEXCODE_CONTEXT_MAX_ENTRIES:-100}" 100 1 1000)

  if DX_DEXCODE_REPO_DIR="$repo_dir" \
    DX_DEXCODE_CONTEXT_OUTPUT="$output_file" \
    DX_DEXCODE_CONTEXT_ENTRY_MAX_BYTES="$entry_max_bytes" \
    DX_DEXCODE_CONTEXT_TOTAL_MAX_BYTES="$total_max_bytes" \
    DX_DEXCODE_CONTEXT_MAX_ENTRIES="$max_entries" \
    python3 - <<'PY'
import codecs
import hashlib
import json
import os
import stat
from pathlib import Path

repo = Path(os.environ["DX_DEXCODE_REPO_DIR"]).resolve()
output = Path(os.environ["DX_DEXCODE_CONTEXT_OUTPUT"])
entry_max_bytes = int(os.environ["DX_DEXCODE_CONTEXT_ENTRY_MAX_BYTES"])
total_max_bytes = int(os.environ["DX_DEXCODE_CONTEXT_TOTAL_MAX_BYTES"])
max_entries = int(os.environ["DX_DEXCODE_CONTEXT_MAX_ENTRIES"])
body_budget = max(0, total_max_bytes - 32768)


def utf8_prefix(raw, byte_limit):
    return raw[:byte_limit].decode("utf-8", errors="ignore")


def open_regular_below(root_fd, relative_path):
    parts = relative_path.parts
    if not parts or any(part in {"", ".", ".."} for part in parts):
        raise OSError("unsafe context path")
    no_follow = getattr(os, "O_NOFOLLOW", 0)
    directory = getattr(os, "O_DIRECTORY", 0)
    current_fd = os.dup(root_fd)
    try:
        for component in parts[:-1]:
            before = os.stat(component, dir_fd=current_fd, follow_symlinks=False)
            if not stat.S_ISDIR(before.st_mode):
                raise OSError("context parent is not a directory")
            next_fd = os.open(component, os.O_RDONLY | directory | no_follow, dir_fd=current_fd)
            after = os.fstat(next_fd)
            if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
                os.close(next_fd)
                raise OSError("context parent changed while opening")
            os.close(current_fd)
            current_fd = next_fd

        before = os.stat(parts[-1], dir_fd=current_fd, follow_symlinks=False)
        if not stat.S_ISREG(before.st_mode):
            raise OSError("context entry is not a regular file")
        source_fd = os.open(
            parts[-1],
            os.O_RDONLY | no_follow | getattr(os, "O_NONBLOCK", 0),
            dir_fd=current_fd,
        )
        after = os.fstat(source_fd)
        if (
            not stat.S_ISREG(after.st_mode)
            or (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino)
        ):
            os.close(source_fd)
            raise OSError("context entry changed while opening")
        return source_fd
    finally:
        os.close(current_fd)


def read_entry(root_fd, relative_path, byte_limit):
    digest = hashlib.sha256()
    prefix = bytearray()
    decoder = codecs.getincrementaldecoder("utf-8")()
    source_bytes = 0
    try:
        source_fd = open_regular_below(root_fd, relative_path)
        with os.fdopen(source_fd, "rb") as fh:
            for chunk in iter(lambda: fh.read(1024 * 1024), b""):
                digest.update(chunk)
                decoder.decode(chunk, final=False)
                source_bytes += len(chunk)
                if len(prefix) < byte_limit:
                    prefix.extend(chunk[: byte_limit - len(prefix)])
        decoder.decode(b"", final=True)
    except (OSError, UnicodeDecodeError):
        return None
    body = utf8_prefix(bytes(prefix), byte_limit)
    body_bytes = len(body.encode("utf-8"))
    return body, digest.hexdigest(), source_bytes, body_bytes


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
    try:
        before = dex_dir.lstat()
    except OSError:
        return [], 0
    if not stat.S_ISDIR(before.st_mode):
        return [], 0
    no_follow = getattr(os, "O_NOFOLLOW", 0)
    directory = getattr(os, "O_DIRECTORY", 0)
    try:
        root_fd = os.open(dex_dir, os.O_RDONLY | directory | no_follow)
    except OSError:
        return [], 0
    try:
        after = os.fstat(root_fd)
        if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
            return [], 0

        candidates = []

        def walk(directory_fd, prefix=Path()):
            try:
                names = os.listdir(directory_fd)
            except OSError:
                return
            for name in names:
                if name in {"", ".", ".."}:
                    continue
                relative = prefix / name
                if relative.parts and relative.parts[0] == "worktrees":
                    continue
                try:
                    entry_before = os.stat(name, dir_fd=directory_fd, follow_symlinks=False)
                except OSError:
                    continue
                if stat.S_ISREG(entry_before.st_mode):
                    if relative.suffix.lower() == ".md":
                        candidates.append(relative)
                    continue
                if not stat.S_ISDIR(entry_before.st_mode):
                    continue
                try:
                    child_fd = os.open(
                        name,
                        os.O_RDONLY | directory | no_follow,
                        dir_fd=directory_fd,
                    )
                except OSError:
                    continue
                try:
                    entry_after = os.fstat(child_fd)
                    if (entry_before.st_dev, entry_before.st_ino) != (
                        entry_after.st_dev,
                        entry_after.st_ino,
                    ):
                        continue
                    walk(child_fd, relative)
                finally:
                    os.close(child_fd)

        walk(root_fd)

        entries = []
        included_body_bytes = 0
        for relative_to_dex in sorted(candidates)[:max_entries]:
            remaining = body_budget - included_body_bytes
            if remaining <= 0:
                break
            entry = read_entry(root_fd, relative_to_dex, min(entry_max_bytes, remaining))
            if not entry:
                continue
            body, sha256, source_bytes, body_bytes = entry
            if not body:
                continue
            relative = Path(".dex") / relative_to_dex
            entries.append({
                "path": str(relative),
                "title": title_for(relative),
                "category": category_for(relative),
                "body": body,
                "sha256": sha256,
                "source_byte_size": source_bytes,
                "body_byte_size": body_bytes,
                "truncated": body_bytes < source_bytes,
            })
            included_body_bytes += body_bytes
        return entries, len(candidates)
    finally:
        os.close(root_fd)


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


def read_json_below(root_fd, relative_path, byte_limit):
    try:
        source_fd = open_regular_below(root_fd, relative_path)
        with os.fdopen(source_fd, "rb") as fh:
            raw = fh.read(byte_limit + 1)
        if len(raw) > byte_limit:
            return None
        return json.loads(raw.decode("utf-8"))
    except (OSError, UnicodeDecodeError, json.JSONDecodeError):
        return None


def mcp_servers_from(root_fd, relative_path):
    data = read_json_below(root_fd, relative_path, 2 * 1024 * 1024)
    if not isinstance(data, dict):
        return []
    servers = data.get("mcpServers") or {}
    if not isinstance(servers, dict):
        return []
    records = []
    for server_name, config in sorted(servers.items())[:25]:
        if not isinstance(config, dict):
            config = {}
        server_name = str(server_name)[:128]
        provider = provider_for(server_name)
        command = config.get("command")
        command_name = Path(command).name[:128] if isinstance(command, str) and command else ""
        env = config.get("env") if isinstance(config.get("env"), dict) else {}
        args = config.get("args") if isinstance(config.get("args"), list) else []
        metadata = {
            "name": f"MCP: {server_name}",
            "server_name": server_name,
            "source_file": str(relative_path)[:512],
            "transport": "http" if config.get("url") else "stdio",
            "command": command_name,
            "args_count": len(args),
            "env_keys": sorted(str(key)[:128] for key in env.keys())[:25],
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
    no_follow = getattr(os, "O_NOFOLLOW", 0)
    directory = getattr(os, "O_DIRECTORY", 0)
    try:
        before = repo.lstat()
        if not stat.S_ISDIR(before.st_mode):
            return []
        repo_fd = os.open(repo, os.O_RDONLY | directory | no_follow)
    except OSError:
        return []
    try:
        after = os.fstat(repo_fd)
        if (before.st_dev, before.st_ino) != (after.st_dev, after.st_ino):
            return []
        for candidate in [Path(".mcp.json"), Path(".claude/settings.json")]:
            for record in mcp_servers_from(repo_fd, candidate):
                key = (record["name"], record["metadata"].get("source_file", ""))
                if key in seen:
                    continue
                seen.add(key)
                records.append(record)
    finally:
        os.close(repo_fd)
    return records[:25]


entries, candidate_count = collect_entries()
integrations = collect_integrations()


def build_payload():
    included_body_bytes = sum(entry["body_byte_size"] for entry in entries)
    return {
        "entries": entries,
        "integrations": integrations,
        "truncation": {
            "entry_max_bytes": entry_max_bytes,
            "total_max_bytes": total_max_bytes,
            "max_entries": max_entries,
            "candidate_entries": candidate_count,
            "entries_included": len(entries),
            "entries_omitted": max(0, candidate_count - len(entries)),
            "entries_truncated": sum(1 for entry in entries if entry["truncated"]),
            "included_body_bytes": included_body_bytes,
        },
    }


def encoded_payload():
    return json.dumps(
        build_payload(),
        sort_keys=True,
        separators=(",", ":"),
        ensure_ascii=False,
    ).encode("utf-8")


payload = encoded_payload()
while len(payload) > total_max_bytes and entries:
    entry = entries[-1]
    body_raw = entry["body"].encode("utf-8")
    overage = len(payload) - total_max_bytes
    keep = max(0, len(body_raw) - overage - 1024)
    entry["body"] = utf8_prefix(body_raw, keep)
    entry["body_byte_size"] = len(entry["body"].encode("utf-8"))
    entry["truncated"] = entry["body_byte_size"] < entry["source_byte_size"]
    if not entry["body"]:
        entries.pop()
    payload = encoded_payload()

while len(payload) > total_max_bytes and integrations:
    integrations.pop()
    payload = encoded_payload()

if len(payload) > total_max_bytes:
    raise SystemExit("DexCode context metadata exceeds the configured payload limit")

output.parent.mkdir(parents=True, exist_ok=True)
fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "wb") as fh:
    fh.write(payload)

PY
  then
    :
  else
    status=$?
  fi
  if [[ "$status" -eq 0 && -n "$owned_tmp_dir" ]]; then
    command cat "$output_file" || status=$?
  fi
  if [[ -n "$owned_tmp_dir" ]]; then
    command rm -rf "$owned_tmp_dir"
  fi
  return "$status"
}

dx_dexcode_create_run_payload() {
  local run_id="$1" repo_dir="$2" workspace_mode="$3" workspace_name="$4" raw_input="$5" command_name="$6"
  local output_file="${7:-}" project_slug project_name default_branch provider branch
  local tmp_dir input_dir repo_file spec_file status=0 owned_output=0
  project_slug=$(dx_dexcode_config_value "default_project.slug" 2>/dev/null || printf 'personal')
  project_name=$(dx_dexcode_config_value "default_project.name" 2>/dev/null || printf 'Personal')
  dx_dexcode_path_segment_valid "$project_slug" || project_slug="personal"
  default_branch=$(dx_default_branch "$repo_dir" 2>/dev/null || true)
  default_branch="${default_branch:-main}"
  provider="${DX_PROVIDER_AGENT:-claude}"
  branch=$(git -C "$repo_dir" branch --show-current 2>/dev/null || true)
  spec_file="${DEX_HEADLESS_RUN_SPEC_FILE:-}"

  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/dexcode-run-payload.XXXXXX") || return 1
  chmod 700 "$tmp_dir" 2>/dev/null || {
    command rm -rf "$tmp_dir"
    return 1
  }
  input_dir="$tmp_dir/input"
  mkdir -m 700 "$input_dir" || {
    command rm -rf "$tmp_dir"
    return 1
  }
  if [[ -z "$output_file" ]]; then
    output_file="$tmp_dir/run.json"
    owned_output=1
  fi
  repo_file="$tmp_dir/repository.json"
  dx_dexcode_repo_json "$repo_dir" "$repo_file" || {
    command rm -rf "$tmp_dir"
    return 1
  }

  if ! {
    __dx_dexcode_write_private_value "$input_dir/run_id" "$run_id" \
      && __dx_dexcode_write_private_value "$input_dir/repo_dir" "$repo_dir" \
      && __dx_dexcode_write_private_value "$input_dir/workspace_mode" "$workspace_mode" \
      && __dx_dexcode_write_private_value "$input_dir/workspace_name" "$workspace_name" \
      && __dx_dexcode_write_private_value "$input_dir/raw_input" "$raw_input" \
      && __dx_dexcode_write_private_value "$input_dir/command_name" "$command_name" \
      && __dx_dexcode_write_private_value "$input_dir/project_slug" "$project_slug" \
      && __dx_dexcode_write_private_value "$input_dir/project_name" "$project_name" \
      && __dx_dexcode_write_private_value "$input_dir/default_branch" "$default_branch" \
      && __dx_dexcode_write_private_value "$input_dir/provider" "$provider" \
      && __dx_dexcode_write_private_value "$input_dir/branch" "$branch" \
      && __dx_dexcode_write_private_value "$input_dir/spec_file" "$spec_file"
  }; then
    command rm -rf "$tmp_dir"
    return 1
  fi
  __dx_dexcode_write_private_value "$input_dir/headless" "${DEX_HEADLESS_RUN:-0}" || {
    command rm -rf "$tmp_dir"
    return 1
  }
  __dx_dexcode_write_private_value "$input_dir/requires_plan_approval" \
    "${DEX_HEADLESS_REQUIRES_PLAN_APPROVAL:-true}" || {
    command rm -rf "$tmp_dir"
    return 1
  }

  if DX_DEXCODE_RUN_INPUT_DIR="$input_dir" \
    DX_DEXCODE_REPO_JSON_FILE="$repo_file" \
    DX_DEXCODE_RUN_PAYLOAD_OUTPUT="$output_file" \
    python3 - <<'PY'
import json
import os
import re
from pathlib import Path

input_dir = Path(os.environ["DX_DEXCODE_RUN_INPUT_DIR"])
output = Path(os.environ["DX_DEXCODE_RUN_PAYLOAD_OUTPUT"])


def read(name):
    return (input_dir / name).read_text(encoding="utf-8")


def clipped(value, limit):
    return value[:limit]


repo = json.loads(Path(os.environ["DX_DEXCODE_REPO_JSON_FILE"]).read_text(encoding="utf-8"))
workspace_name = read("workspace_name")
raw_input = read("raw_input")
source_type = "local_cli"
source_id = workspace_name
workflow_name = "ticket_to_pr"
task_body = raw_input
task_title = raw_input.splitlines()[0] if raw_input.splitlines() else workspace_name
requires_plan_approval = True

if read("headless") == "1":
    plan_value = read("requires_plan_approval").strip().lower()
    requires_plan_approval = plan_value not in {"false", "0", "no", "off"}
    spec_path = read("spec_file")
    try:
        spec = json.loads(Path(spec_path).read_text(encoding="utf-8")) if spec_path else {}
    except (OSError, json.JSONDecodeError):
        spec = {}
    if not isinstance(spec, dict):
        spec = {}
    source = spec.get("source") if isinstance(spec.get("source"), dict) else {}
    workflow = spec.get("workflow") if isinstance(spec.get("workflow"), dict) else {}
    source_type = source.get("type") if isinstance(source.get("type"), str) else "headless"
    source_id = source.get("id") if isinstance(source.get("id"), str) else workspace_name
    source_title = source.get("title") if isinstance(source.get("title"), str) else ""
    source_body = source.get("body") if isinstance(source.get("body"), str) else ""
    workflow_name = workflow.get("name") if isinstance(workflow.get("name"), str) else "ticket_to_pr"
    task_title = source_title or f"{source_type} {source_id}"
    task_body = source_body

task_title = " ".join(task_title.split())
project_slug = read("project_slug")
if not re.fullmatch(r"(?!\.{1,2}$)[A-Za-z0-9._-]{1,255}", project_slug):
    project_slug = "personal"
payload = {
    # agent_runs.external_id is constrained to 128 characters server-side.
    "external_id": clipped(read("run_id"), 128),
    "task_title": clipped(task_title or workspace_name, 240),
    "task_body": task_body,
    "provider": clipped(read("provider"), 64),
    "branch_name": clipped(read("branch"), 255),
    "project": {
        "slug": project_slug,
        "name": clipped(read("project_name"), 240),
        "default_branch": clipped(read("default_branch"), 255),
    },
    "metadata": {
        "working_directory": clipped(read("repo_dir"), 4096),
        "source_type": clipped(source_type, 128),
        "source_id": clipped(source_id, 512),
        "workflow_name": clipped(workflow_name, 128),
        "requires_plan_approval": requires_plan_approval,
        "workspace_mode": clipped(read("workspace_mode"), 64),
        "command": clipped(read("command_name"), 128),
    },
}
if repo.get("owner") and repo.get("name"):
    payload["repository"] = repo
encoded = json.dumps(payload, sort_keys=True, separators=(",", ":"), ensure_ascii=False).encode("utf-8")
fd = os.open(output, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "wb") as fh:
    fh.write(encoded)
PY
  then
    :
  else
    status=$?
  fi
  if [[ "$status" -eq 0 && "$owned_output" -eq 1 ]]; then
    command cat "$output_file" || status=$?
  fi
  command rm -rf "$tmp_dir"
  return "$status"
}

dx_dexcode_prepare_run_sync() {
  local run_id="$1" repo_dir="$2" workspace_mode="$3" workspace_name="$4" raw_input="$5" command_name="${6:-dx}"
  dx_dexcode_value_disabled "${DEXCODE_SYNC:-1}" && return 0

  local connection token api_url factory_url event_endpoint tmp_dir payload_file response_file http_status timeout_seconds
  dx_run_validate_id "$run_id" 2>/dev/null || return 1
  if [[ "${DEX_HEADLESS_RUN:-0}" == "1" \
    && -n "${DEX_RUN_TOKEN:-}${DEX_FACTORY_RUN_TOKEN:-}" ]]; then
    token=$(dx_dexcode_artifact_token 2>/dev/null || true)
    if ! dx_dexcode_bearer_token_valid "$token"; then
      if [[ "${DEXCODE_SYNC_REQUIRED:-0}" == "1" ]]; then
        dx_error "DexCode run sync requires a valid run token."
        return 1
      fi
      return 0
    fi
    export DEX_FACTORY_RUN_TOKEN="$token"
    if [[ -n "${DEX_FACTORY_URL:-}${DEX_FACTORY_EVENTS_ENDPOINT:-}" ]] \
      && ! dx_dexcode_factory_sync_disabled; then
      export DEX_FACTORY_SYNC=true
    fi
    return 0
  fi

  connection=$(dx_dexcode_active_connection 2>/dev/null || true)
  IFS=$'\t' read -r token api_url factory_url <<< "$connection"
  if ! dx_dexcode_bearer_token_valid "$token"; then
    if [[ "${DEXCODE_SYNC_REQUIRED:-0}" == "1" ]]; then
      dx_error "DexCode run sync is required, but this machine is not connected."
      return 1
    fi
    return 0
  fi

  if ! dx_dexcode_api_url_valid "$api_url" || ! dx_dexcode_api_url_valid "$factory_url"; then
    if [[ "${DEXCODE_SYNC_REQUIRED:-0}" == "1" ]]; then
      dx_error "DexCode run sync has an invalid API or Factory URL."
      return 1
    fi
    dx_warn "DexCode run sync has an invalid API or Factory URL; continuing locally."
    return 0
  fi
  timeout_seconds=$(dx_dexcode_http_timeout)
  if ! tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/dexcode-run.XXXXXX"); then
    if [[ "${DEXCODE_SYNC_REQUIRED:-0}" == "1" ]]; then
      dx_error "DexCode run sync could not prepare its temporary request files."
      return 1
    fi
    return 0
  fi
  if ! chmod 700 "$tmp_dir" 2>/dev/null; then
    command rm -rf "$tmp_dir"
    if [[ "${DEXCODE_SYNC_REQUIRED:-0}" == "1" ]]; then
      dx_error "DexCode run sync could not secure its temporary request files."
      return 1
    fi
    return 0
  fi
  payload_file="$tmp_dir/request.json"
  response_file="$tmp_dir/run.json"
  if ! dx_dexcode_create_run_payload "$run_id" "$repo_dir" "$workspace_mode" \
    "$workspace_name" "$raw_input" "$command_name" "$payload_file"; then
    command rm -rf "$tmp_dir"
    if [[ "${DEXCODE_SYNC_REQUIRED:-0}" == "1" ]]; then
      dx_error "DexCode run sync could not build the registration payload."
      return 1
    fi
    return 0
  fi

  if ! http_status=$(__dx_dexcode_auth_config "$token" | command curl -q -sS --config - -o "$response_file" -w "%{http_code}" \
    --max-time "$timeout_seconds" \
    --proto '=http,https' \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    --data-binary @"$payload_file" \
    "${api_url}/api/v1/runs" 2>/dev/null); then
    http_status="000"
  fi

  if dx_dexcode_http_success "$http_status"; then
    export DEX_RUN_TOKEN="$token"
    export DEX_FACTORY_TOKEN="$token"
    export DEX_FACTORY_URL="$factory_url"
    event_endpoint="${DEX_FACTORY_EVENTS_ENDPOINT:-}"
    case "$event_endpoint" in
      ""|"$factory_url"/api/v1/runs/run_*/events/batch)
        event_endpoint="${factory_url}/api/v1/runs/${run_id}/events/batch"
        ;;
    esac
    export DEX_FACTORY_EVENTS_ENDPOINT="$event_endpoint"
    if ! dx_dexcode_factory_sync_disabled; then
      export DEX_FACTORY_SYNC=true
    fi
    dx_info "DexCode tracking enabled for ${run_id}."
    if ! dx_dexcode_sync_project_context "$repo_dir"; then
      command rm -rf "$tmp_dir"
      return 1
    fi
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

# Uploads a locally captured artifact to DexCode.
#
# Three steps, because the bytes never pass through the API: register to get a
# signed URL, PUT the file straight to storage, then confirm. Until that last
# call lands the artifact counts as unfinished and DexCode refuses to serve it,
# so a half-finished upload is invisible rather than broken.
#
# Prints the DexCode artifact id on success. Never fails a run: no token, sync
# disabled, or an unreachable server all leave the local artifact untouched.
# A manifest artifact id and sync fingerprint enable retry-safe registration.
dx_dexcode_upload_artifact() {
  local run_id="$1" file_path="$2" kind="$3" title="$4"
  local connection token api_url factory_url tmp_dir response_file http_status artifact_id upload_url artifact_state
  local filename="${5:-}" content_type size sha file_stats timeout_seconds snapshot_file source_root source_name
  local local_artifact_id="${6:-}" sync_fingerprint="${7:-}" idempotency_key=""

  dx_dexcode_value_disabled "${DEXCODE_SYNC:-1}" && return 0
  dx_run_validate_id "$run_id" 2>/dev/null || return 0
  [[ -n "$file_path" ]] || return 0

  connection=$(dx_dexcode_artifact_connection 2>/dev/null || true)
  IFS=$'\t' read -r token api_url factory_url <<< "$connection"
  dx_dexcode_bearer_token_valid "$token" || return 0

  if ! dx_dexcode_api_url_valid "$api_url"; then
    dx_warn "DexCode artifact upload skipped an invalid API URL; keeping it locally."
    return 0
  fi
  [[ -n "$filename" ]] || filename=$(basename "$file_path")
  content_type=$(dx_dexcode_content_type "$filename")
  timeout_seconds=$(dx_dexcode_http_timeout)
  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/dexcode-artifact.XXXXXX") || return 0
  chmod 700 "$tmp_dir" 2>/dev/null || {
    command rm -rf "$tmp_dir"
    return 0
  }
  snapshot_file="$tmp_dir/artifact.snapshot"
  source_root=$(dirname "$file_path")
  source_name=$(basename "$file_path")
  if ! file_stats=$(__dx_dexcode_snapshot_artifact "$source_root" "$source_name" "$snapshot_file" 2>/dev/null); then
    dx_warn "DexCode artifact upload skipped a non-regular or symlinked file; keeping it locally."
    command rm -rf "$tmp_dir"
    return 0
  fi
  size="${file_stats%% *}"
  sha="${file_stats#* }"
  response_file="$tmp_dir/artifact.json"
  if [[ -n "$local_artifact_id" && -n "$sync_fingerprint" ]]; then
    idempotency_key=$(__dx_dexcode_artifact_idempotency_key \
      "$run_id" "$local_artifact_id" "$sync_fingerprint" 2>/dev/null || true)
  fi

  local payload
  payload=$(DX_ARTIFACT_KIND="$kind" DX_ARTIFACT_TITLE="$title" \
    DX_ARTIFACT_FILENAME="$filename" DX_ARTIFACT_CONTENT_TYPE="$content_type" \
    DX_ARTIFACT_SIZE="$size" DX_ARTIFACT_SHA="$sha" \
    python3 - <<'PY'
import json
import os

print(json.dumps({
    "byte_size": int(os.environ["DX_ARTIFACT_SIZE"]),
    "kind": os.environ["DX_ARTIFACT_KIND"],
    "title": os.environ["DX_ARTIFACT_TITLE"],
    "filename": os.environ["DX_ARTIFACT_FILENAME"],
    "content_type": os.environ["DX_ARTIFACT_CONTENT_TYPE"],
    "sha256": os.environ["DX_ARTIFACT_SHA"],
}, sort_keys=True, separators=(",", ":")))
PY
  ) || { command rm -rf "$tmp_dir"; return 0; }

  if [[ -n "$idempotency_key" ]]; then
    if ! http_status=$(__dx_dexcode_auth_config "$token" | command curl -q -sS --config - -o "$response_file" -w "%{http_code}" \
      --max-time "$timeout_seconds" \
      --proto '=http,https' \
        -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      -H "Idempotency-Key: ${idempotency_key}" \
      -d "$payload" \
      "${api_url}/api/v1/runs/${run_id}/artifacts" 2>/dev/null); then
      http_status="000"
    fi
  else
    if ! http_status=$(__dx_dexcode_auth_config "$token" | command curl -q -sS --config - -o "$response_file" -w "%{http_code}" \
      --max-time "$timeout_seconds" \
      --proto '=http,https' \
        -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      -d "$payload" \
      "${api_url}/api/v1/runs/${run_id}/artifacts" 2>/dev/null); then
      http_status="000"
    fi
  fi
  if ! dx_dexcode_http_success "$http_status"; then
    dx_warn "DexCode artifact registration failed (HTTP ${http_status}); keeping it locally."
    command rm -rf "$tmp_dir"
    return 0
  fi

  artifact_id=$(dx_dexcode_json_field "$response_file" "id" 2>/dev/null || true)
  artifact_state=$(dx_dexcode_json_field "$response_file" "state" 2>/dev/null || true)
  upload_url=$(dx_dexcode_json_field "$response_file" "upload.url" 2>/dev/null || true)
  if ! dx_dexcode_path_segment_valid "$artifact_id"; then
    dx_warn "DexCode artifact registration did not include an artifact id and HTTP upload URL; keeping it locally."
    command rm -rf "$tmp_dir"
    return 0
  fi
  if [[ "$artifact_state" == "completed" ]]; then
    command rm -rf "$tmp_dir"
    printf '%s\n' "$artifact_id"
    return 0
  fi
  if [[ -n "$artifact_state" && "$artifact_state" != "pending" ]] \
    || ! dx_dexcode_http_url_valid "$upload_url"; then
    dx_warn "DexCode artifact registration did not include an artifact id and HTTP upload URL; keeping it locally."
    command rm -rf "$tmp_dir"
    return 0
  fi

  if ! http_status=$(command curl -q -sS -o /dev/null -w "%{http_code}" \
    --max-time "$timeout_seconds" \
    --proto '=http,https' \
    -X PUT \
    -H "Content-Type: ${content_type}" \
    --data-binary @"$snapshot_file" \
    "$upload_url" 2>/dev/null); then
    http_status="000"
  fi
  if ! dx_dexcode_http_success "$http_status"; then
    # The registration row stays with no upload recorded, which DexCode treats
    # as unfinished rather than serving an empty file.
    dx_warn "DexCode artifact upload failed (HTTP ${http_status}); keeping it locally."
    command rm -rf "$tmp_dir"
    return 0
  fi

  local complete_payload
  complete_payload=$(DX_ARTIFACT_SIZE="${size:-0}" DX_ARTIFACT_SHA="${sha:-}" \
    DX_ARTIFACT_CONTENT_TYPE="$content_type" python3 - <<'PY'
import json
import os

body = {
    "byte_size": int(os.environ.get("DX_ARTIFACT_SIZE") or 0),
    "content_type": os.environ["DX_ARTIFACT_CONTENT_TYPE"],
}
sha = os.environ.get("DX_ARTIFACT_SHA") or ""
if len(sha) == 64:
    body["sha256"] = sha
print(json.dumps(body, sort_keys=True, separators=(",", ":")))
PY
  ) || { command rm -rf "$tmp_dir"; return 0; }

  if ! http_status=$(__dx_dexcode_auth_config "$token" | command curl -q -sS --config - -o /dev/null -w "%{http_code}" \
    --max-time "$timeout_seconds" \
    --proto '=http,https' \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    -d "$complete_payload" \
    "${api_url}/api/v1/runs/${run_id}/artifacts/${artifact_id}" 2>/dev/null); then
    http_status="000"
  fi
  if ! dx_dexcode_http_success "$http_status"; then
    dx_warn "DexCode artifact was uploaded but not confirmed (HTTP ${http_status})."
    command rm -rf "$tmp_dir"
    return 0
  fi

  command rm -rf "$tmp_dir"
  printf '%s\n' "$artifact_id"
  return 0
}

# Only what the CLI actually captures; anything else is left to the server.
dx_dexcode_content_type() {
  local extension
  extension=$(printf '%s' "${1##*.}" | tr '[:upper:]' '[:lower:]')
  case "$extension" in
    md) printf 'text/markdown\n' ;;
    json) printf 'application/json\n' ;;
    txt|log) printf 'text/plain\n' ;;
    diff|patch) printf 'text/x-diff\n' ;;
    html) printf 'text/html\n' ;;
    png) printf 'image/png\n' ;;
    jpg|jpeg) printf 'image/jpeg\n' ;;
    gif) printf 'image/gif\n' ;;
    webp) printf 'image/webp\n' ;;
    svg) printf 'image/svg+xml\n' ;;
    webm) printf 'video/webm\n' ;;
    mp4) printf 'video/mp4\n' ;;
    zip) printf 'application/zip\n' ;;
    pdf) printf 'application/pdf\n' ;;
    *) printf 'application/octet-stream\n' ;;
  esac
}

dx_dexcode_sync_project_context() {
  local repo_dir="${1:-}" connection token api_url factory_url project_slug tmp_dir payload_file response_file http_status timeout_seconds failure_label response_valid=0
  dx_dexcode_value_disabled "${DEXCODE_CONTEXT_SYNC:-1}" && return 0
  [[ -n "$repo_dir" ]] || repo_dir=$(git rev-parse --show-toplevel 2>/dev/null || true)
  [[ -n "$repo_dir" && -d "$repo_dir/.dex" ]] || return 0

  connection=$(dx_dexcode_active_connection 2>/dev/null || true)
  IFS=$'\t' read -r token api_url factory_url <<< "$connection"
  project_slug=$(dx_dexcode_config_value "default_project.slug" 2>/dev/null || true)
  if ! dx_dexcode_bearer_token_valid "$token" || [[ -z "$project_slug" ]]; then
    if [[ "${DEXCODE_CONTEXT_SYNC_REQUIRED:-0}" == "1" ]]; then
      dx_error "DexCode project context sync requires a connected project."
      return 1
    fi
    return 0
  fi
  if ! dx_dexcode_path_segment_valid "$project_slug"; then
    if [[ "${DEXCODE_CONTEXT_SYNC_REQUIRED:-0}" == "1" ]]; then
      dx_error "DexCode project context sync has an invalid project slug."
      return 1
    fi
    dx_warn "DexCode project context sync skipped an invalid project slug."
    return 0
  fi

  if ! dx_dexcode_api_url_valid "$api_url"; then
    if [[ "${DEXCODE_CONTEXT_SYNC_REQUIRED:-0}" == "1" ]]; then
      dx_error "DexCode project context sync has an invalid API URL."
      return 1
    fi
    dx_warn "DexCode project context sync skipped an invalid API URL."
    return 0
  fi
  timeout_seconds=$(dx_dexcode_http_timeout)
  if ! tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/dexcode-context.XXXXXX"); then
    if [[ "${DEXCODE_CONTEXT_SYNC_REQUIRED:-0}" == "1" ]]; then
      dx_error "DexCode project context sync could not prepare its temporary request files."
      return 1
    fi
    return 0
  fi
  if ! chmod 700 "$tmp_dir" 2>/dev/null; then
    command rm -rf "$tmp_dir"
    if [[ "${DEXCODE_CONTEXT_SYNC_REQUIRED:-0}" == "1" ]]; then
      dx_error "DexCode project context sync could not secure its temporary request files."
      return 1
    fi
    return 0
  fi
  payload_file="$tmp_dir/request.json"
  response_file="$tmp_dir/context.json"
  if ! dx_dexcode_context_payload "$repo_dir" "$payload_file"; then
    command rm -rf "$tmp_dir"
    if [[ "${DEXCODE_CONTEXT_SYNC_REQUIRED:-0}" == "1" ]]; then
      dx_error "DexCode project context sync could not build its payload."
      return 1
    fi
    return 0
  fi

  if ! http_status=$(__dx_dexcode_auth_config "$token" | command curl -q -sS --config - -o "$response_file" -w "%{http_code}" \
    --max-time "$timeout_seconds" \
    --proto '=http,https' \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    --data-binary @"$payload_file" \
    "${api_url}/api/v1/projects/${project_slug}/context" 2>/dev/null); then
    http_status="000"
  fi

  failure_label="HTTP ${http_status}"
  if dx_dexcode_http_success "$http_status"; then
    if dx_dexcode_json_object_valid "$response_file"; then
      response_valid=1
    else
      failure_label="an invalid response"
    fi
  fi

  if [[ "$response_valid" -eq 1 ]]; then
    DX_DEXCODE_CONTEXT_RESPONSE="$response_file" python3 - <<'PY'
import json
import os
from pathlib import Path

try:
    data = json.loads(Path(os.environ["DX_DEXCODE_CONTEXT_RESPONSE"]).read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    raise SystemExit(0)
synced = data.get("synced", 0)
integrations = data.get("integrations_synced", 0)
if not isinstance(synced, int) or isinstance(synced, bool):
    synced = 0
if not isinstance(integrations, int) or isinstance(integrations, bool):
    integrations = 0
print(f"DexCode project context synced: {synced} knowledge entries, {integrations} integrations.")
PY
  elif [[ "${DEXCODE_CONTEXT_SYNC_REQUIRED:-0}" == "1" ]]; then
    dx_error "DexCode project context sync failed (${failure_label})."
    command rm -rf "$tmp_dir"
    return 1
  else
    dx_warn "DexCode project context sync failed (${failure_label}); continuing locally."
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
    use|project)
      if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
        cat <<'USAGE'
Usage:
  dx dexcode use

Select or create the DexCode project used for new runs.
USAGE
        return 0
      fi
      if [[ $# -gt 0 ]]; then
        dx_error "Unknown dx dexcode use option: $1"
        return 1
      fi
      dx_dexcode_select_project --force
      ;;
    help|-h|--help)
      cat <<'USAGE'
Usage:
  dx dexcode <login|logout|whoami|use>

Commands:
  login    Connect this machine with the browser device flow
  logout   Remove the local connection
  whoami   Show the active organisation, project, and sync settings
  use      Select or create the project used for new runs
USAGE
      ;;
    *)
      dx_error "Unknown DexCode command: ${cmd}"
      dx_info "Usage: dx dexcode <login|logout|whoami|use>"
      return 1
      ;;
  esac
}
