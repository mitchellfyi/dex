# shellcheck shell=bash
# Dex shared library - optional Dex Factory event sync.

dx_factory_sync_dir() {
  local run_id="$1"
  dx_run_validate_id "$run_id" || return 1
  printf '%s/.factory-sync\n' "$(dx_run_dir "$run_id")"
}

dx_factory_sync_cursor_file() { printf '%s/cursor\n' "$(dx_factory_sync_dir "$1")"; }
dx_factory_sync_status_file() { printf '%s/status.json\n' "$(dx_factory_sync_dir "$1")"; }
__dx_factory_sync_last_log_file() { printf '%s/last-log\n' "$(dx_factory_sync_dir "$1")"; }

dx_factory_sync_requested() {
  local value="${DEX_FACTORY_SYNC:-}"
  case "$value" in
    1|[Tt][Rr][Uu][Ee]|[Yy][Ee][Ss]|[Oo][Nn])
      return 0
      ;;
    0|[Ff][Aa][Ll][Ss][Ee]|[Nn][Oo]|[Oo][Ff][Ff])
      return 1
      ;;
    "")
      [[ -n "${DEX_FACTORY_URL:-}${DEX_FACTORY_EVENTS_ENDPOINT:-}" ]]
      return
      ;;
    *)
      return 1
      ;;
  esac
}

dx_factory_sync_token() {
  if [[ -n "${DEX_RUN_TOKEN:-}" ]]; then
    printf '%s\n' "$DEX_RUN_TOKEN"
  elif [[ -n "${DEX_FACTORY_RUN_TOKEN:-}" ]]; then
    printf '%s\n' "$DEX_FACTORY_RUN_TOKEN"
  elif [[ -n "${DEX_FACTORY_TOKEN:-}" ]]; then
    printf '%s\n' "$DEX_FACTORY_TOKEN"
  else
    return 1
  fi
}

dx_factory_events_endpoint() {
  local run_id="$1" endpoint="${DEX_FACTORY_EVENTS_ENDPOINT:-}" base_url="${DEX_FACTORY_URL:-}"
  dx_run_validate_id "$run_id" || return 1

  if [[ -n "$endpoint" ]]; then
    endpoint="${endpoint//\{run_id\}/$run_id}"
    printf '%s\n' "$endpoint"
    return 0
  fi

  [[ -n "$base_url" ]] || return 1
  base_url="${base_url%/}"
  printf '%s/api/v1/runs/%s/events/batch\n' "$base_url" "$run_id"
}

__dx_factory_nonnegative_int() {
  local value="$1" fallback="$2" maximum="${3:-86400}"
  case "$value" in
    ''|*[!0-9]*|0[0-9]*)
      printf '%s\n' "$fallback"
      ;;
    *)
      if [[ ${#value} -gt 9 || "$value" -gt "$maximum" ]]; then
        printf '%s\n' "$fallback"
      else
        printf '%s\n' "$value"
      fi
      ;;
  esac
}

__dx_factory_positive_int() {
  local value="$1" fallback="$2" maximum="${3:-86400}"
  case "$value" in
    ''|*[!0-9]*|0|0[0-9]*)
      printf '%s\n' "$fallback"
      ;;
    *)
      if [[ ${#value} -gt 9 || "$value" -gt "$maximum" ]]; then
        printf '%s\n' "$fallback"
      else
        printf '%s\n' "$value"
      fi
      ;;
  esac
}

__dx_factory_sync_acquire_lock() {
  local lock_dir="$1" attempts=0 owner_file owner_tmp max_attempts
  owner_file="$lock_dir/owner"
  max_attempts=$(__dx_factory_positive_int "${DEX_FACTORY_LOCK_ATTEMPTS:-40}" 40 1000)
  while ! mkdir "$lock_dir" 2>/dev/null; do
    if __dx_factory_sync_recover_lock "$lock_dir"; then
      continue
    fi
    attempts=$((attempts + 1))
    [[ "$attempts" -lt "$max_attempts" ]] || return 1
    sleep 0.05
  done
  owner_tmp="$lock_dir/.owner.$RANDOM"
  if ! DX_FACTORY_LOCK_OWNER_TMP="$owner_tmp" python3 - <<'PY'
import os
from pathlib import Path

path = Path(os.environ["DX_FACTORY_LOCK_OWNER_TMP"])
fd = os.open(path, os.O_WRONLY | os.O_CREAT | os.O_EXCL, 0o600)
with os.fdopen(fd, "w", encoding="ascii") as fh:
    fh.write(f"{os.getppid()}\n")
PY
  then
    command rm -f "$owner_tmp" 2>/dev/null || true
    command rmdir "$lock_dir" 2>/dev/null || true
    return 1
  fi
  if ! command mv -f "$owner_tmp" "$owner_file"; then
    command rm -f "$owner_tmp" 2>/dev/null || true
    command rmdir "$lock_dir" 2>/dev/null || true
    return 1
  fi
}

__dx_factory_sync_recover_lock() {
  local lock_dir="$1" stale_seconds
  command -v python3 >/dev/null 2>&1 || return 1
  stale_seconds=$(__dx_factory_positive_int "${DEX_FACTORY_LOCK_STALE_SECONDS:-5}" 5 3600)
  DX_FACTORY_LOCK_DIR="$lock_dir" \
  DX_FACTORY_LOCK_STALE_SECONDS="$stale_seconds" \
  python3 - <<'PY'
import os
import re
import stat
import time
from pathlib import Path

lock = Path(os.environ["DX_FACTORY_LOCK_DIR"])
owner = lock / "owner"
claim = lock / ".recovery"
stale_seconds = int(os.environ["DX_FACTORY_LOCK_STALE_SECONDS"])


def read_owner():
    try:
        with owner.open("r", encoding="ascii") as fh:
            raw = fh.read(64)
            if fh.read(1):
                return "invalid", raw
    except (OSError, UnicodeError):
        return "invalid", ""
    stripped = raw.strip()
    if not re.fullmatch(r"[1-9][0-9]{0,9}", stripped):
        return "invalid", raw
    pid = int(stripped)
    try:
        os.kill(pid, 0)
    except ProcessLookupError:
        return "dead", raw
    except PermissionError:
        return "live", raw
    except OSError:
        return "live", raw
    return "live", raw


try:
    lock_stat = lock.lstat()
except OSError:
    raise SystemExit(1)
if not stat.S_ISDIR(lock_stat.st_mode) or lock.is_symlink():
    raise SystemExit(1)

state, owner_raw = read_owner()
if state == "live":
    raise SystemExit(1)
if state == "invalid" and time.time() - lock_stat.st_mtime < stale_seconds:
    raise SystemExit(1)

try:
    claim.mkdir(mode=0o700)
except OSError:
    raise SystemExit(1)

recovered = False
try:
    current_stat = lock.lstat()
    if (current_stat.st_dev, current_stat.st_ino) != (lock_stat.st_dev, lock_stat.st_ino):
        raise SystemExit(1)
    current_state, current_raw = read_owner()
    if current_raw != owner_raw or current_state != state:
        raise SystemExit(1)
    if current_state == "live":
        raise SystemExit(1)
    names = {entry.name for entry in lock.iterdir()}
    if not names.issubset({"owner", ".recovery"}):
        raise SystemExit(1)
    if owner.exists() or owner.is_symlink():
        owner.unlink()
    claim.rmdir()
    lock.rmdir()
    recovered = True
finally:
    if not recovered:
        try:
            claim.rmdir()
        except OSError:
            pass

raise SystemExit(0 if recovered else 1)
PY
}

__dx_factory_sync_release_lock() {
  local lock_dir="$1"
  DX_FACTORY_LOCK_DIR="$lock_dir" python3 - <<'PY' 2>/dev/null || true
import os
from pathlib import Path

lock = Path(os.environ["DX_FACTORY_LOCK_DIR"])
owner = lock / "owner"
try:
    owner_pid = int(owner.read_text(encoding="ascii").strip())
except (OSError, UnicodeError, ValueError):
    raise SystemExit(0)
if owner_pid != os.getppid():
    raise SystemExit(0)
try:
    owner.unlink()
    lock.rmdir()
except OSError:
    pass
PY
}

__dx_factory_sync_read_cursor() {
  local run_id="$1" cursor_file cursor
  cursor_file=$(dx_factory_sync_cursor_file "$run_id") || return 1
  [[ -f "$cursor_file" ]] || {
    printf '0\n'
    return 0
  }
  cursor=$(cat "$cursor_file" 2>/dev/null || true)
  __dx_factory_nonnegative_int "$cursor" 0 999999999
}

__dx_factory_sync_write_cursor() {
  local run_id="$1" sequence="$2" cursor_file tmp_file
  [[ "$(__dx_factory_nonnegative_int "$sequence" invalid 999999999)" != "invalid" ]] || return 1
  cursor_file=$(dx_factory_sync_cursor_file "$run_id") || return 1
  mkdir -p "$(dirname "$cursor_file")"
  tmp_file="${cursor_file}.tmp.$$"
  if ! printf '%s\n' "$sequence" > "$tmp_file" || ! command mv -f "$tmp_file" "$cursor_file"; then
    command rm -f "$tmp_file" 2>/dev/null || true
    return 1
  fi
}

__dx_factory_sync_retry_due() {
  local run_id="$1" status_file
  status_file=$(dx_factory_sync_status_file "$run_id") || return 1
  [[ -f "$status_file" ]] || return 0

  DX_FACTORY_STATUS_FILE="$status_file" python3 - <<'PY'
import json
import os
import time
from pathlib import Path

status_path = Path(os.environ["DX_FACTORY_STATUS_FILE"])
try:
    status = json.loads(status_path.read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    raise SystemExit(0)

try:
    next_retry_at = float(status.get("next_retry_at", 0))
except (TypeError, ValueError):
    next_retry_at = 0

raise SystemExit(0 if time.time() >= next_retry_at else 1)
PY
}

__dx_factory_sync_log_rate_limited() {
  local run_id="$1" level="$2" message="$3" last_log_file interval now last_logged
  last_log_file=$(__dx_factory_sync_last_log_file "$run_id") || return 0
  interval=$(__dx_factory_nonnegative_int "${DEX_FACTORY_RETRY_LOG_INTERVAL_SECONDS:-60}" 60 86400)
  now=$(date +%s)
  last_logged=0
  if [[ -f "$last_log_file" ]]; then
    last_logged=$(cat "$last_log_file" 2>/dev/null || true)
    case "$last_logged" in
      ''|*[!0-9]*)
        last_logged=0
        ;;
    esac
  fi
  if [[ "$interval" -eq 0 || $((now - last_logged)) -ge "$interval" ]]; then
    dx_run_log_append_safe "$run_id" "$level" "factory-sync" "$message"
    mkdir -p "$(dirname "$last_log_file")"
    printf '%s\n' "$now" > "$last_log_file" 2>/dev/null || true
  fi
}

__dx_factory_sync_write_status() {
  local run_id="$1" status_value="$2" message="$3" status_file tmp_file
  local base_delay max_delay
  status_file=$(dx_factory_sync_status_file "$run_id") || return 1
  mkdir -p "$(dirname "$status_file")"
  base_delay=$(__dx_factory_nonnegative_int "${DEX_FACTORY_RETRY_BASE_SECONDS:-1}" 1 86400)
  max_delay=$(__dx_factory_nonnegative_int "${DEX_FACTORY_RETRY_MAX_SECONDS:-60}" 60 86400)

  tmp_file="${status_file}.tmp.$$"
  DX_FACTORY_STATUS_FILE="$status_file" \
  DX_FACTORY_STATUS_TMP_FILE="$tmp_file" \
  DX_FACTORY_STATUS_VALUE="$status_value" \
  DX_FACTORY_STATUS_MESSAGE="$message" \
  DX_FACTORY_RETRY_BASE_SECONDS="$base_delay" \
  DX_FACTORY_RETRY_MAX_SECONDS="$max_delay" \
  python3 - <<'PY'
import json
import os
import time
from datetime import datetime, timezone
from pathlib import Path


def utc_now():
    return datetime.now(timezone.utc).strftime("%Y-%m-%dT%H:%M:%SZ")


status_path = Path(os.environ["DX_FACTORY_STATUS_FILE"])
tmp_path = Path(os.environ["DX_FACTORY_STATUS_TMP_FILE"])
status_value = os.environ["DX_FACTORY_STATUS_VALUE"]
message = os.environ.get("DX_FACTORY_STATUS_MESSAGE", "")
try:
    base_delay = int(os.environ.get("DX_FACTORY_RETRY_BASE_SECONDS", "1"))
except ValueError:
    base_delay = 1
try:
    max_delay = int(os.environ.get("DX_FACTORY_RETRY_MAX_SECONDS", "60"))
except ValueError:
    max_delay = 60
base_delay = min(max(base_delay, 0), 86400)
max_delay = min(max(max_delay, 0), 86400)

previous = {}
if status_path.exists():
    try:
        loaded = json.loads(status_path.read_text(encoding="utf-8"))
        if isinstance(loaded, dict):
            previous = loaded
    except (OSError, json.JSONDecodeError):
        previous = {}

try:
    failure_count = int(previous.get("failure_count", 0) or 0)
except (TypeError, ValueError):
    failure_count = 0
failure_count = min(max(failure_count, 0), 30)
if status_value == "failed":
    failure_count += 1
    delay = min(max_delay, base_delay * (2 ** max(0, failure_count - 1)))
    next_retry_at = time.time() + delay
else:
    next_retry_at = 0

payload = {
    "schema_version": 1,
    "status": status_value,
    "message": message,
    "failure_count": failure_count,
    "updated_at": utc_now(),
    "next_retry_at": next_retry_at,
}

try:
    with tmp_path.open("w", encoding="utf-8") as fh:
        json.dump(payload, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.replace(tmp_path, status_path)
except Exception:
    try:
        tmp_path.unlink()
    except OSError:
        pass
    raise
PY
}

__dx_factory_sync_clear_status() {
  local run_id="$1" status_file
  status_file=$(dx_factory_sync_status_file "$run_id") || return 0
  command rm -f "$status_file" "$(__dx_factory_sync_last_log_file "$run_id")" 2>/dev/null || true
}

__dx_factory_endpoint_label() {
  local endpoint="$1"
  DX_FACTORY_ENDPOINT_LABEL_SOURCE="$endpoint" python3 - <<'PY'
import os
from urllib.parse import urlsplit, urlunsplit

endpoint = os.environ.get("DX_FACTORY_ENDPOINT_LABEL_SOURCE", "")
try:
    parsed = urlsplit(endpoint)
except ValueError:
    print("remote endpoint")
    raise SystemExit(0)

if parsed.scheme and parsed.netloc:
    try:
        port = parsed.port
    except ValueError:
        print("remote endpoint")
        raise SystemExit(0)
    hostname = parsed.hostname or ""
    if ":" in hostname and not hostname.startswith("["):
        hostname = f"[{hostname}]"
    netloc = f"{hostname}:{port}" if port is not None else hostname
    print(urlunsplit((parsed.scheme, netloc, parsed.path or "/", "", "")))
else:
    print(parsed.path or "remote endpoint")
PY
}

__dx_factory_sync_build_payload() {
  local run_id="$1" cursor="$2" payload_file="$3" batch_size events_file
  events_file=$(dx_run_events_file "$run_id") || return 1
  batch_size=$(__dx_factory_positive_int "${DEX_FACTORY_BATCH_SIZE:-50}" 50 10000)
  [[ -f "$events_file" ]] || {
    printf '0 0\n'
    return 0
  }

  DX_FACTORY_EVENTS_FILE="$events_file" \
  DX_FACTORY_PAYLOAD_FILE="$payload_file" \
  DX_FACTORY_CURSOR="$cursor" \
  DX_FACTORY_BATCH_SIZE="$batch_size" \
  python3 - <<'PY'
import json
import os
from pathlib import Path

events_path = Path(os.environ["DX_FACTORY_EVENTS_FILE"])
payload_path = Path(os.environ["DX_FACTORY_PAYLOAD_FILE"])
try:
    cursor = int(os.environ.get("DX_FACTORY_CURSOR", "0"))
except ValueError:
    cursor = 0
try:
    batch_size = int(os.environ.get("DX_FACTORY_BATCH_SIZE", "50"))
except ValueError:
    batch_size = 50
if batch_size <= 0:
    batch_size = 50

selected = []
max_sequence = cursor
with events_path.open("r", encoding="utf-8") as fh:
    for line in fh:
        line = line.strip()
        if not line:
            continue
        event = json.loads(line)
        sequence = event.get("sequence", 0)
        if isinstance(sequence, bool) or not isinstance(sequence, int):
            raise ValueError("event sequence must be an integer")
        if sequence < 1 or sequence > 999999999:
            raise ValueError("event sequence is outside the supported range")
        if sequence <= cursor:
            continue
        selected.append(event)
        max_sequence = max(max_sequence, sequence)
        if len(selected) >= batch_size:
            break

if not selected:
    try:
        payload_path.unlink()
    except OSError:
        pass
    print("0 0")
    raise SystemExit(0)

payload_path.parent.mkdir(parents=True, exist_ok=True)
with payload_path.open("w", encoding="utf-8") as fh:
    json.dump({"events": selected}, fh, sort_keys=True, separators=(",", ":"))
    fh.write("\n")
print(f"{len(selected)} {max_sequence}")
PY
}

__dx_factory_sync_post_payload() {
  local endpoint="$1" token="$2" payload_file="$3" timeout_seconds
  timeout_seconds=$(__dx_factory_positive_int "${DEX_FACTORY_TIMEOUT_SECONDS:-5}" 5 3600)

  DX_FACTORY_ENDPOINT="$endpoint" \
  DX_FACTORY_TOKEN_VALUE="$token" \
  DX_FACTORY_PAYLOAD_FILE="$payload_file" \
  DX_FACTORY_TIMEOUT_SECONDS="$timeout_seconds" \
  python3 - <<'PY'
import os
import re
import sys
import urllib.error
import urllib.request
from pathlib import Path
from urllib.parse import urlsplit

endpoint = os.environ["DX_FACTORY_ENDPOINT"]
token = os.environ["DX_FACTORY_TOKEN_VALUE"]
payload = Path(os.environ["DX_FACTORY_PAYLOAD_FILE"]).read_bytes()
try:
    timeout = int(os.environ.get("DX_FACTORY_TIMEOUT_SECONDS", "5"))
except ValueError:
    timeout = 5

TOKEN_FIELD_RE = re.compile(
    r'("[^"]*(?:token|secret|password|api[_-]?key|authorization|credential)[^"]*"\s*:\s*")[^"]*(")',
    re.I,
)
BEARER_RE = re.compile(r'Bearer\s+[A-Za-z0-9._~+/=-]+', re.I)
SECRET_ASSIGNMENT_RE = re.compile(r'(?i)\b(secret|token|api[_-]?key)=([^\s&;,]+)')
URL_CREDENTIAL_RE = re.compile(r"(?i)(https?://)[^/@\s]+@")


def redact(text):
    if token:
        text = text.replace(token, "[redacted]")
    text = TOKEN_FIELD_RE.sub(r'\1[redacted]\2', text)
    text = BEARER_RE.sub("Bearer [redacted]", text)
    text = SECRET_ASSIGNMENT_RE.sub(lambda match: f"{match.group(1)}=[redacted]", text)
    text = URL_CREDENTIAL_RE.sub(r"\1[redacted]@", text)
    return text


try:
    parsed_endpoint = urlsplit(endpoint)
    _ = parsed_endpoint.port
except ValueError:
    print("invalid HTTP event endpoint", file=sys.stderr)
    raise SystemExit(1)
if (
    any(ord(char) <= 32 or ord(char) == 127 for char in endpoint)
    or parsed_endpoint.scheme.lower() not in {"http", "https"}
    or not parsed_endpoint.hostname
    or parsed_endpoint.username is not None
    or parsed_endpoint.password is not None
    or parsed_endpoint.fragment
):
    print("invalid HTTP event endpoint", file=sys.stderr)
    raise SystemExit(1)
allowed_token_chars = frozenset("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~+/=")
if not token or len(token) > 8192 or any(char not in allowed_token_chars for char in token):
    print("invalid Bearer token", file=sys.stderr)
    raise SystemExit(1)

request = urllib.request.Request(endpoint, data=payload, method="POST")
request.add_header("Authorization", f"Bearer {token}")
request.add_header("Content-Type", "application/json")
request.add_header("User-Agent", "dex-factory-sync/1")


class NoRedirectHandler(urllib.request.HTTPRedirectHandler):
    def redirect_request(self, req, fp, code, msg, headers, newurl):
        return None


def response_excerpt(response):
    try:
        raw = response.read(4097)
        body = raw[:4096].decode("utf-8", errors="replace").strip()
        if len(raw) > 4096:
            body = f"{body}..."
    except Exception:
        body = ""
    if not body:
        return ""
    return f": {redact(body)}"

try:
    opener = urllib.request.build_opener(NoRedirectHandler())
    with opener.open(request, timeout=timeout) as response:
        status = response.getcode()
        if 200 <= status < 300:
            raise SystemExit(0)
        print(f"HTTP {status}{response_excerpt(response)}", file=sys.stderr)
        raise SystemExit(1)
except urllib.error.HTTPError as exc:
    print(f"HTTP {exc.code}{response_excerpt(exc)}", file=sys.stderr)
    raise SystemExit(1) from exc
except urllib.error.URLError as exc:
    print(f"network error: {exc.reason}", file=sys.stderr)
    raise SystemExit(1) from exc
except TimeoutError as exc:
    print("network error: timeout", file=sys.stderr)
    raise SystemExit(1) from exc
PY
}

__dx_factory_sync_record_failure() {
  local run_id="$1" message="$2"
  __dx_factory_sync_write_status "$run_id" "failed" "$message" 2>/dev/null || true
  __dx_factory_sync_log_rate_limited "$run_id" "warn" "Factory sync failed; events remain queued: ${message}"
}

__dx_factory_sync_record_config_issue() {
  local run_id="$1" message="$2"
  __dx_factory_sync_write_status "$run_id" "configuration_error" "$message" 2>/dev/null || true
  __dx_factory_sync_log_rate_limited "$run_id" "warn" "$message"
}

__dx_factory_sync_pending_events_locked() {
  local run_id="$1" sync_dir="$2" endpoint token cursor payload_file build_result
  local count max_sequence post_error first_sequence endpoint_label batch_count max_batches

  if ! endpoint=$(dx_factory_events_endpoint "$run_id" 2>/dev/null); then
    __dx_factory_sync_record_config_issue "$run_id" "Factory sync is enabled but DEX_FACTORY_URL or DEX_FACTORY_EVENTS_ENDPOINT is unset."
    return 0
  fi
  if ! token=$(dx_factory_sync_token 2>/dev/null); then
    __dx_factory_sync_record_config_issue "$run_id" "Factory sync is enabled but DEX_FACTORY_TOKEN, DEX_FACTORY_RUN_TOKEN, or DEX_RUN_TOKEN is unset."
    return 0
  fi
  if ! command -v python3 >/dev/null 2>&1; then
    __dx_factory_sync_record_config_issue "$run_id" "Factory sync is enabled but python3 is unavailable."
    return 0
  fi
  if ! __dx_factory_sync_retry_due "$run_id"; then
    return 0
  fi

  batch_count=0
  max_batches=$(__dx_factory_positive_int "${DEX_FACTORY_MAX_BATCHES_PER_FLUSH:-20}" 20 1000)
  cursor=$(__dx_factory_sync_read_cursor "$run_id" 2>/dev/null || printf '0\n')
  while [[ "$batch_count" -lt "$max_batches" ]]; do
    payload_file="$sync_dir/payload.$$.$RANDOM.json"
    if ! build_result=$(__dx_factory_sync_build_payload "$run_id" "$cursor" "$payload_file" 2>&1); then
      __dx_factory_sync_record_failure "$run_id" "could not build event payload"
      command rm -f "$payload_file" 2>/dev/null || true
      return 0
    fi
    count="${build_result%% *}"
    max_sequence="${build_result##* }"
    if [[ "$count" == "0" ]]; then
      command rm -f "$payload_file" 2>/dev/null || true
      return 0
    fi

    if post_error=$(__dx_factory_sync_post_payload "$endpoint" "$token" "$payload_file" 2>&1); then
      __dx_factory_sync_write_cursor "$run_id" "$max_sequence" || {
        __dx_factory_sync_record_failure "$run_id" "could not update Factory sync cursor"
        command rm -f "$payload_file" 2>/dev/null || true
        return 0
      }
      __dx_factory_sync_clear_status "$run_id"
      cursor="$max_sequence"
      batch_count=$((batch_count + 1))
    else
      [[ -n "$post_error" ]] || post_error="remote collector rejected the event batch"
      first_sequence=$((cursor + 1))
      endpoint_label=$(__dx_factory_endpoint_label "$endpoint" 2>/dev/null || printf 'remote endpoint\n')
      __dx_factory_sync_record_failure "$run_id" "${post_error} while posting event sequences ${first_sequence}-${max_sequence} to ${endpoint_label}"
      command rm -f "$payload_file" 2>/dev/null || true
      return 0
    fi
    command rm -f "$payload_file" 2>/dev/null || true
  done
}

dx_factory_sync_pending_events() {
  local run_id="$1" sync_dir lock_dir
  dx_run_validate_id "$run_id" || return 1
  dx_factory_sync_requested || return 0
  sync_dir=$(dx_factory_sync_dir "$run_id") || return 1
  mkdir -p "$sync_dir"
  lock_dir="$sync_dir/.lock"
  __dx_factory_sync_acquire_lock "$lock_dir" || return 0
  __dx_factory_sync_pending_events_locked "$run_id" "$sync_dir" || true
  __dx_factory_sync_release_lock "$lock_dir"
}

dx_factory_sync_pending_events_safe() {
  dx_factory_sync_pending_events "$@" >/dev/null 2>&1 || true
  return 0
}
