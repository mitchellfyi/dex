# shellcheck shell=bash
# Dex shared library - the DexCode worker daemon.
#
# A worker pulls: DexCode never dials out to this machine. The daemon polls for
# runs assigned to it, claims one with `start`, launches `dx run` as a child
# holding only a short-lived run token, renews the lease while that child is
# alive, and settles the attempt after the child exits.
#
# Three credentials appear here and are not interchangeable:
#
#   administrator CLI token  dc_live_   registers the worker, queues runs
#   worker token             dc_worker_ this daemon's own control loop
#   run token                dc_run_    handed to one child, for one run
#
# The worker token is read from a 0600 file and passed to curl through
# `--config -` so it never reaches argv, the environment of a child, a log
# line, or an event.

DX_WORKER_DEFAULT_POLL_INTERVAL=15
DX_WORKER_MIN_POLL_INTERVAL=1
DX_WORKER_MAX_POLL_INTERVAL=300
# Renew well inside the server's lease window rather than at its edge.
DX_WORKER_LEASE_RENEW_SECONDS=30

dx_worker_config_file() {
  printf '%s\n' "${DEXCODE_WORKER_CONFIG_FILE:-$(dx_dexcode_config_dir)/worker.json}"
}

# __dx_worker_json_field <file> <dotted.key> — prints the value, or nothing.
__dx_worker_json_field() {
  local file="$1" key="$2"
  [[ -f "$file" ]] || return 1
  DX_WORKER_JSON_FILE="$file" DX_WORKER_JSON_KEY="$key" python3 - <<'PY' 2>/dev/null
import json
import os
from pathlib import Path

try:
    data = json.loads(Path(os.environ["DX_WORKER_JSON_FILE"]).read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    raise SystemExit(1)

for part in os.environ["DX_WORKER_JSON_KEY"].split("."):
    if not isinstance(data, dict) or part not in data:
        raise SystemExit(1)
    data = data[part]

if data is None or isinstance(data, (dict, list)):
    raise SystemExit(1)
if isinstance(data, bool):
    print("true" if data else "false")
else:
    print(data)
PY
}

dx_worker_config_value() {
  __dx_worker_json_field "$(dx_worker_config_file)" "$1"
}

# One machine can serve several organisations. It cannot do so with one
# credential: `workers.organisation_id` and `worker_api_tokens.organisation_id`
# are both NOT NULL, and every claim, lease and settle is scoped to the
# organisation the token belongs to. Spanning organisations with a single
# bearer would mean unpicking that boundary, and would make one leaked token
# reach all of them.
#
# So the daemon does what `dx login` already does for administrator tokens: it
# holds one registration per organisation, keyed by slug. Each organisation
# grants and revokes independently.
__dx_worker_entry_field() {
  local slug="$1" key="$2" value
  value="$(dx_worker_config_value "workers.${slug}.${key}" 2>/dev/null)" || value=""
  if [[ -z "$value" ]]; then
    # A registration made before the map existed. It described the only
    # organisation this machine served, so it answers for any slug until the
    # next registration replaces it.
    dx_worker_config_value "workers" >/dev/null 2>&1 && return 1
    value="$(dx_worker_config_value "$key" 2>/dev/null)" || return 1
  fi
  [[ -n "$value" ]] || return 1
  printf '%s\n' "$value"
}

# Slugs with a stored registration, one per line.
dx_worker_organisations() {
  local file
  file="$(dx_worker_config_file)"
  [[ -f "$file" ]] || return 0
  DX_WORKER_FILE="$file" python3 - <<'PY' 2>/dev/null
import json
import os
from pathlib import Path

try:
    data = json.loads(Path(os.environ["DX_WORKER_FILE"]).read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    raise SystemExit(0)
if not isinstance(data, dict):
    raise SystemExit(0)

workers = data.get("workers")
if isinstance(workers, dict) and workers:
    for slug in sorted(workers):
        if isinstance(workers[slug], dict) and workers[slug].get("worker_id"):
            print(slug)
    raise SystemExit(0)

# Pre-map registration: one unnamed organisation.
if data.get("worker_id"):
    print(data.get("organisation_slug") or "default")
PY
}

# Written 0600 and replaced atomically: it holds a bearer token.
__dx_worker_config_store() {
  local slug="$1" worker_id="$2" worker_name="$3" api_url="$4" token="$5"
  local file
  file="$(dx_worker_config_file)"
  mkdir -p "$(dirname "$file")" 2>/dev/null || return 1
  chmod 700 "$(dirname "$file")" 2>/dev/null || true

  DX_WORKER_FILE="$file" \
  DX_WORKER_SLUG="$slug" \
  DX_WORKER_ID="$worker_id" \
  DX_WORKER_NAME="$worker_name" \
  DX_WORKER_API_URL="$api_url" \
  DX_WORKER_TOKEN="$token" \
  python3 - <<'PY'
import json
import os
import tempfile
from pathlib import Path

target = Path(os.environ["DX_WORKER_FILE"])
try:
    data = json.loads(target.read_text(encoding="utf-8"))
    if not isinstance(data, dict):
        data = {}
except (OSError, json.JSONDecodeError):
    data = {}

slug = os.environ["DX_WORKER_SLUG"]
workers = data.get("workers")
if not isinstance(workers, dict):
    workers = {}

entry = workers.get(slug)
if not isinstance(entry, dict):
    entry = {}

entry["worker_id"] = os.environ["DX_WORKER_ID"]
entry["worker_name"] = os.environ["DX_WORKER_NAME"]
entry["api_url"] = os.environ["DX_WORKER_API_URL"]

# An ordinary re-registration returns no token and the stored one stays valid.
token = os.environ.get("DX_WORKER_TOKEN") or ""
if token:
    entry["worker_token"] = token

workers[slug] = entry
data["workers"] = workers

# The pre-map fields described this same machine; leaving them would give two
# answers to "which credential is this".
for legacy in ("worker_id", "worker_name", "api_url", "worker_token"):
    data.pop(legacy, None)

handle, temporary = tempfile.mkstemp(
    prefix=".worker.", suffix=".json", dir=str(target.parent)
)
try:
    with os.fdopen(handle, "w", encoding="utf-8") as fh:
        json.dump(data, fh, indent=2, sort_keys=True)
        fh.write("\n")
    os.chmod(temporary, 0o600)
    os.replace(temporary, target)
finally:
    try:
        if Path(temporary).exists():
            os.unlink(temporary)
    except OSError:
        pass
PY
}

dx_worker_token() {
  __dx_worker_entry_field "${1:?organisation slug}" "worker_token"
}

dx_worker_id() {
  __dx_worker_entry_field "${1:?organisation slug}" "worker_id"
}

dx_worker_api_url() {
  __dx_worker_entry_field "${1:?organisation slug}" "api_url"
}

# The worker bearer has its own shape; refusing anything else here keeps a
# CLI or run token from being sent to a worker endpoint by accident.
dx_worker_token_valid() {
  case "${1:-}" in
    dc_worker_*) [[ ${#1} -eq 53 ]] ;;
    *) return 1 ;;
  esac
}

__dx_worker_auth_config() {
  local token="${1:-}"
  dx_worker_token_valid "$token" || return 1
  printf 'header = "Authorization: Bearer %s"\n' "$token"
}

# __dx_worker_request <method> <url> <response_file> [payload_file]
# Prints the HTTP status. The token is piped in, never placed in argv.
__dx_worker_request() {
  local slug="$1" method="$2" url="$3" response_file="$4" payload_file="${5:-}"
  local token http_code timeout_seconds
  timeout_seconds="${DEXCODE_HTTP_TIMEOUT_SECONDS:-15}"

  if ! token="$(dx_worker_token "$slug")"; then
    printf '000\n'
    return 1
  fi

  if [[ -n "$payload_file" ]]; then
    http_code="$(__dx_worker_auth_config "$token" | command curl -q -sS --config - \
      -o "$response_file" -w "%{http_code}" \
      --max-time "$timeout_seconds" \
      --proto '=http,https' \
      -X "$method" \
      -H "Content-Type: application/json" \
      -H "Accept: application/json" \
      --data-binary @"$payload_file" \
      "$url" 2>/dev/null)" || http_code="000"
  else
    http_code="$(__dx_worker_auth_config "$token" | command curl -q -sS --config - \
      -o "$response_file" -w "%{http_code}" \
      --max-time "$timeout_seconds" \
      --proto '=http,https' \
      -X "$method" \
      -H "Accept: application/json" \
      "$url" 2>/dev/null)" || http_code="000"
  fi

  printf '%s\n' "$http_code"
}

# dx_worker_register [--name <name>] [--host <host>] [--rotate] [--max-concurrency N]
#
# Uses the administrator CLI token. This is the only worker call that does, and
# the only place a worker token can be issued.
dx_worker_register() {
  local worker_name="" worker_host="" rotate="false" max_concurrency=""
  local working_directory="" worker_status="" organisation="" arg

  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --name) worker_name="${2:-}"; shift 2 || return 1 ;;
      --host) worker_host="${2:-}"; shift 2 || return 1 ;;
      --max-concurrency) max_concurrency="${2:-}"; shift 2 || return 1 ;;
      --working-directory) working_directory="${2:-}"; shift 2 || return 1 ;;
      --organisation) organisation="${2:-}"; shift 2 || return 1 ;;
      --status) worker_status="${2:-}"; shift 2 || return 1 ;;
      --rotate) rotate="true"; shift ;;
      -h|--help)
        cat <<'USAGE'
Usage:
  dx worker register [--organisation <slug>] [--name <name>] [--host <host>]
                     [--rotate] [--max-concurrency <n>]
                     [--working-directory <path>]

Registers this machine as a worker for one organisation and stores that
organisation's worker credential. Run it once per organisation to serve
several from the same machine; `dx worker run` then polls all of them.
Re-registering keeps the existing credential; --rotate replaces it.
USAGE
        return 0
        ;;
      *) dx_error "Unknown dx worker register option: $arg"; return 1 ;;
    esac
  done

  [[ -n "$worker_name" ]] || worker_name="$(__dx_worker_default_name)"
  [[ -n "$worker_host" ]] || worker_host="$(uname -n 2>/dev/null || printf 'localhost')"

  if [[ ! "$worker_name" =~ ^[a-z0-9][a-z0-9-]*$ ]]; then
    dx_error "Worker name must be lowercase letters, digits and hyphens: ${worker_name}"
    return 1
  fi

  local api_url cli_token
  # A worker belongs to exactly one organisation, so registration uses that
  # organisation's administrator token rather than whichever happens to be
  # active.
  if [[ -z "$organisation" ]]; then
    organisation="$(dx_dexcode_config_value 'account.slug' 2>/dev/null || printf '')"
  fi
  if [[ -z "$organisation" ]]; then
    dx_error "Not connected to DexCode. Run 'dx login' first."
    return 1
  fi
  if ! cli_token="$(dx_dexcode_token_for "$organisation" 2>/dev/null)"; then
    dx_error "No DexCode connection for ${organisation}. Run 'dx login' and pick it."
    return 1
  fi
  api_url="$(dx_dexcode_api_url_for "$organisation" 2>/dev/null)" \
    || api_url="$(dx_dexcode_api_url)" || return 1

  local tmp_dir payload_file response_file
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dex-worker-register.XXXXXX")" || return 1
  chmod 700 "$tmp_dir" 2>/dev/null || { command rm -rf "$tmp_dir"; return 1; }
  payload_file="$tmp_dir/request.json"
  response_file="$tmp_dir/response.json"

  DX_WORKER_NAME="$worker_name" \
  DX_WORKER_HOST="$worker_host" \
  DX_WORKER_ROTATE="$rotate" \
  DX_WORKER_STATUS="$worker_status" \
  DX_WORKER_MAX_CONCURRENCY="$max_concurrency" \
  DX_WORKER_WORKING_DIRECTORY="$working_directory" \
  DX_WORKER_PAYLOAD_FILE="$payload_file" \
  python3 - <<'PY' || { command rm -rf "$tmp_dir"; return 1; }
import json
import os
from pathlib import Path

worker = {
    "name": os.environ["DX_WORKER_NAME"],
    "host": os.environ["DX_WORKER_HOST"],
}
concurrency = os.environ.get("DX_WORKER_MAX_CONCURRENCY") or ""
if concurrency:
    try:
        worker["max_concurrency"] = max(1, min(32, int(concurrency)))
    except ValueError:
        raise SystemExit(1)
working_directory = os.environ.get("DX_WORKER_WORKING_DIRECTORY") or ""
if working_directory:
    worker["working_directory"] = working_directory[:512]
status = os.environ.get("DX_WORKER_STATUS") or ""
if status:
    if status not in {"offline", "online", "busy", "disabled", "error"}:
        raise SystemExit(1)
    worker["status"] = status

payload = {"worker": worker}
if os.environ.get("DX_WORKER_ROTATE") == "true":
    payload["rotate_credential"] = True

Path(os.environ["DX_WORKER_PAYLOAD_FILE"]).write_text(
    json.dumps(payload), encoding="utf-8"
)
PY

  local http_code
  http_code="$(__dx_dexcode_auth_config "$cli_token" | command curl -q -sS --config - \
    -o "$response_file" -w "%{http_code}" \
    --max-time "${DEXCODE_HTTP_TIMEOUT_SECONDS:-15}" \
    --proto '=http,https' \
    -H "Content-Type: application/json" \
    -H "Accept: application/json" \
    --data-binary @"$payload_file" \
    "${api_url}/api/v1/workers" 2>/dev/null)" || http_code="000"

  if ! dx_dexcode_http_success "$http_code"; then
    dx_error "Worker registration failed (HTTP ${http_code})."
    command rm -rf "$tmp_dir"
    return 1
  fi

  local worker_id issued_token
  worker_id="$(__dx_worker_json_field "$response_file" "id")" || {
    dx_error "Worker registration returned no worker id."
    command rm -rf "$tmp_dir"
    return 1
  }
  # Absent on an ordinary re-registration, which deliberately keeps the
  # credential already on disk.
  issued_token="$(__dx_worker_json_field "$response_file" "worker_token" 2>/dev/null || printf '')"

  if [[ -n "$issued_token" ]] && ! dx_worker_token_valid "$issued_token"; then
    dx_error "Worker registration returned a credential of an unexpected shape."
    command rm -rf "$tmp_dir"
    return 1
  fi

  __dx_worker_config_store "$organisation" "$worker_id" "$worker_name" \
    "$api_url" "$issued_token" || {
    dx_error "Could not store the worker credential."
    command rm -rf "$tmp_dir"
    return 1
  }
  command rm -rf "$tmp_dir"

  if ! dx_worker_token "$organisation" >/dev/null 2>&1; then
    dx_error "No worker credential is stored. Re-run with --rotate to issue one."
    return 1
  fi

  dx_done "Worker ${worker_name} registered for ${organisation}."
  dx_info "Worker id: ${worker_id}"
  return 0
}

__dx_worker_default_name() {
  local candidate
  candidate="$(uname -n 2>/dev/null || printf 'dex-worker')"
  candidate="$(printf '%s' "$candidate" | tr '[:upper:]' '[:lower:]' | tr -c 'a-z0-9-' '-')"
  candidate="${candidate%%-}"
  candidate="$(printf '%s' "$candidate" | sed -E 's/-+/-/g; s/^-+//; s/-+$//')"
  [[ -n "$candidate" ]] || candidate="dex-worker"
  printf '%s\n' "$candidate"
}

# dx_worker_poll <organisation> <response_file> — prints the HTTP status.
dx_worker_poll() {
  local slug="$1" response_file="$2" api_url worker_id
  api_url="$(dx_worker_api_url "$slug")" || return 1
  worker_id="$(dx_worker_id "$slug")" || return 1
  __dx_worker_request "$slug" GET \
    "${api_url}/api/v1/workers/${worker_id}" "$response_file"
}

# dx_worker_start <organisation> <run_id> <response_file> — claims a run.
dx_worker_start() {
  local slug="$1" run_id="$2" response_file="$3" api_url worker_id
  api_url="$(dx_worker_api_url "$slug")" || return 1
  worker_id="$(dx_worker_id "$slug")" || return 1
  __dx_worker_request "$slug" POST \
    "${api_url}/api/v1/workers/${worker_id}/runs/${run_id}/start" "$response_file"
}

__dx_worker_launch_payload() {
  local payload_file="$1" launch_request_id="$2" attempt="$3" outcome="${4:-}" error_class="${5:-}"
  DX_WORKER_PAYLOAD_FILE="$payload_file" \
  DX_WORKER_LAUNCH_ID="$launch_request_id" \
  DX_WORKER_ATTEMPT="$attempt" \
  DX_WORKER_OUTCOME="$outcome" \
  DX_WORKER_ERROR_CLASS="$error_class" \
  python3 - <<'PY'
import json
import os
from pathlib import Path

payload = {
    "launch_request_id": os.environ["DX_WORKER_LAUNCH_ID"],
    "attempt": int(os.environ["DX_WORKER_ATTEMPT"]),
}
outcome = os.environ.get("DX_WORKER_OUTCOME") or ""
if outcome:
    payload["outcome"] = outcome
error_class = os.environ.get("DX_WORKER_ERROR_CLASS") or ""
if error_class:
    payload["error_class"] = error_class[:120]

Path(os.environ["DX_WORKER_PAYLOAD_FILE"]).write_text(
    json.dumps(payload), encoding="utf-8"
)
PY
}

# dx_worker_lease <run_id> <launch_request_id> <attempt> <response_file>
#
# The launch id and attempt travel on every renewal, so a daemon holding a
# stale claim cannot keep a newer attempt alive.
dx_worker_lease() {
  local slug="$1" run_id="$2" launch_request_id="$3" attempt="$4" response_file="$5"
  local api_url worker_id payload_file rc
  api_url="$(dx_worker_api_url "$slug")" || return 1
  worker_id="$(dx_worker_id "$slug")" || return 1
  payload_file="$(dirname "$response_file")/lease-request.json"
  __dx_worker_launch_payload "$payload_file" "$launch_request_id" "$attempt" || return 1
  __dx_worker_request "$slug" POST \
    "${api_url}/api/v1/workers/${worker_id}/runs/${run_id}/lease" \
    "$response_file" "$payload_file"
  rc=$?
  command rm -f "$payload_file"
  return $rc
}

# dx_worker_settle <run_id> <launch_request_id> <attempt> <outcome> [error_class] <response_file>
dx_worker_settle() {
  local slug="$1" run_id="$2" launch_request_id="$3" attempt="$4" outcome="$5"
  local error_class="$6" response_file="$7"
  local api_url worker_id payload_file rc
  api_url="$(dx_worker_api_url "$slug")" || return 1
  worker_id="$(dx_worker_id "$slug")" || return 1
  payload_file="$(dirname "$response_file")/settle-request.json"
  __dx_worker_launch_payload "$payload_file" "$launch_request_id" "$attempt" \
    "$outcome" "$error_class" || return 1
  __dx_worker_request "$slug" POST \
    "${api_url}/api/v1/workers/${worker_id}/runs/${run_id}/settle" \
    "$response_file" "$payload_file"
  rc=$?
  command rm -f "$payload_file"
  return $rc
}

__dx_worker_bounded_interval() {
  local value="$1"
  case "$value" in
    ''|*[!0-9]*) printf '%s\n' "$DX_WORKER_DEFAULT_POLL_INTERVAL"; return 0 ;;
  esac
  if [[ "$value" -lt "$DX_WORKER_MIN_POLL_INTERVAL" ]]; then
    printf '%s\n' "$DX_WORKER_MIN_POLL_INTERVAL"
  elif [[ "$value" -gt "$DX_WORKER_MAX_POLL_INTERVAL" ]]; then
    printf '%s\n' "$DX_WORKER_MAX_POLL_INTERVAL"
  else
    printf '%s\n' "$value"
  fi
}

# Prints the run ids queued to this worker, one per line.
__dx_worker_queued_runs() {
  local response_file="$1"
  DX_WORKER_RESPONSE_FILE="$response_file" python3 - <<'PY' 2>/dev/null
import json
import os
from pathlib import Path

try:
    data = json.loads(Path(os.environ["DX_WORKER_RESPONSE_FILE"]).read_text(encoding="utf-8"))
except (OSError, json.JSONDecodeError):
    raise SystemExit(0)

for assignment in data.get("assigned_runs") or []:
    if not isinstance(assignment, dict):
        continue
    # Anything already running belongs to a live attempt, possibly this one.
    if assignment.get("status") not in {"queued", "requested", "pending"}:
        continue
    run_id = assignment.get("run_id")
    if isinstance(run_id, str) and run_id:
        print(run_id)
PY
}

# Runs one claimed run to completion: launch the child, hold the lease while it
# lives, settle after it exits. Never settles on the terminal event alone —
# `dx run` emits that before uploading its final summary.
__dx_worker_execute() {
  local slug="$1" run_id="$2" work_dir="$3" scratch_dir="$4" start_file="$5"
  local dry_run="${6:-0}"
  local launch_request_id attempt run_token spec_url
  local child_pid child_rc outcome error_class waited response_file

  launch_request_id="$(__dx_worker_json_field "$start_file" "launch_request_id")" || return 1
  attempt="$(__dx_worker_json_field "$start_file" "attempt")" || return 1
  run_token="$(__dx_worker_json_field "$start_file" "run_token")" || return 1
  spec_url="$(__dx_worker_json_field "$start_file" "spec_url")" || return 1

  # Request and response scratch belongs to the daemon, never to the working
  # directory: that is the user's repository, and it may not even exist — in
  # which case settlement itself would fail and the run would stay leased to
  # this worker until the lease expired.
  response_file="$scratch_dir/lease.json"

  dx_info "Claimed ${run_id} for ${slug} (attempt ${attempt})."

  # Only the spec URL and the run token cross into the child. The worker
  # credential stays in this process.
  if [[ "$dry_run" -eq 1 ]]; then
    (
      cd "$work_dir" 2>/dev/null || exit 1
      dx run --spec-url "$spec_url" --run-token "$run_token" --dry-run
    ) &
  else
    (
      cd "$work_dir" 2>/dev/null || exit 1
      dx run --spec-url "$spec_url" --run-token "$run_token"
    ) &
  fi
  child_pid=$!

  waited=0
  while kill -0 "$child_pid" 2>/dev/null; do
    sleep 1
    waited=$((waited + 1))
    if [[ $((waited % DX_WORKER_LEASE_RENEW_SECONDS)) -eq 0 ]]; then
      local lease_code
      lease_code="$(dx_worker_lease "$slug" "$run_id" "$launch_request_id" "$attempt" "$response_file")"
      if ! dx_dexcode_http_success "$lease_code"; then
        # A refused renewal means this attempt is no longer ours. Stop
        # renewing; the child is still allowed to finish and settle will say
        # whether the result was wanted.
        dx_warn "Lease renewal for ${run_id} refused (HTTP ${lease_code})."
        break
      fi
    fi
  done

  wait "$child_pid"
  child_rc=$?

  if [[ $child_rc -eq 0 ]]; then
    outcome="completed"
    error_class=""
  elif [[ $child_rc -ge 128 ]]; then
    outcome="cancelled"
    error_class="signal_$((child_rc - 128))"
  else
    outcome="failed"
    error_class="exit_${child_rc}"
  fi

  local settle_code
  settle_code="$(dx_worker_settle "$slug" "$run_id" "$launch_request_id" "$attempt" \
    "$outcome" "$error_class" "$scratch_dir/settle.json")"
  if ! dx_dexcode_http_success "$settle_code"; then
    dx_error "Could not settle ${run_id} as ${outcome} (HTTP ${settle_code})."
    return 1
  fi

  dx_done "Settled ${run_id} as ${outcome}."
  return 0
}

# Live children, one per claimed run. A worker may hold as many as its
# `max_concurrency` allows; the server refuses a claim beyond it anyway, but a
# daemon that only ever ran one at a time never asked for the second.
#
# An array, not a space-separated string: zsh does not word-split an unquoted
# parameter, so `for pid in $PIDS` yields one word containing every pid and
# `wait` refuses it. That failed only once there were two children to wait for,
# which is exactly the case this exists for.
DX_WORKER_CHILD_PIDS=()

__dx_worker_reap_children() {
  local pid
  local -a remaining=()
  for pid in ${DX_WORKER_CHILD_PIDS[@]+"${DX_WORKER_CHILD_PIDS[@]}"}; do
    if kill -0 "$pid" 2>/dev/null; then
      remaining+=("$pid")
    else
      wait "$pid" 2>/dev/null || true
    fi
  done
  DX_WORKER_CHILD_PIDS=(${remaining[@]+"${remaining[@]}"})
}

__dx_worker_child_count() {
  printf '%s\n' "${#DX_WORKER_CHILD_PIDS[@]}"
}

__dx_worker_wait_for_children() {
  local pid
  for pid in ${DX_WORKER_CHILD_PIDS[@]+"${DX_WORKER_CHILD_PIDS[@]}"}; do
    wait "$pid" 2>/dev/null || true
  done
  DX_WORKER_CHILD_PIDS=()
}

# Best effort, and deliberately not required. The daemon holds only its worker
# credential, which cannot change the worker's status; re-registering needs the
# administrator token, which a headless worker may not have. When it is absent
# the app still shows the machine as not responding, because it stops checking
# in — so this is a courtesy, not the mechanism.
__dx_worker_mark_offline() {
  local slug worker_name
  while IFS= read -r slug; do
    [[ -n "$slug" ]] || continue
    worker_name="$(__dx_worker_entry_field "$slug" 'worker_name' 2>/dev/null || printf '')"
    [[ -n "$worker_name" ]] || continue
    dx_dexcode_token_for "$slug" >/dev/null 2>&1 || continue
    dx_worker_register --organisation "$slug" --name "$worker_name" \
      --status offline >/dev/null 2>&1 || true
  done <<EOF
$(dx_worker_organisations)
EOF
}

# dx_worker_daemon [--once] [--interval <seconds>] [--working-directory <path>]
dx_worker_daemon() {
  local once=0 interval="" work_dir="$PWD" dry_run=0 concurrency="" arg

  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --once) once=1; shift ;;
      --dry-run) dry_run=1; shift ;;
      --interval) interval="${2:-}"; shift 2 || return 1 ;;
      --concurrency) concurrency="${2:-}"; shift 2 || return 1 ;;
      --working-directory) work_dir="${2:-}"; shift 2 || return 1 ;;
      -h|--help)
        cat <<'USAGE'
Usage:
  dx worker run [--once] [--dry-run] [--interval <seconds>]
                [--concurrency <n>] [--working-directory <path>]

Polls DexCode for runs assigned to this worker in every organisation it is
registered with, claims them, and runs each one to completion, up to each
worker's registered concurrency. --once polls a single
time and exits. --concurrency asks for fewer than the server allows, never
more. --dry-run claims and validates a run, then stops the child before the
lifecycle launches — use it to prove a worker is wired up without doing the
work.

INT or TERM stops it taking new work and waits for the runs it already holds,
so those are settled rather than left for their leases to expire.
USAGE
        return 0
        ;;
      *) dx_error "Unknown dx worker run option: $arg"; return 1 ;;
    esac
  done

  local slugs
  slugs="$(dx_worker_organisations)"
  if [[ -z "$slugs" ]]; then
    dx_error "This machine is not registered as a worker. Run 'dx worker register'."
    return 1
  fi

  local tmp_dir poll_file start_file
  tmp_dir="$(mktemp -d "${TMPDIR:-/tmp}/dex-worker.XXXXXX")" || return 1
  chmod 700 "$tmp_dir" 2>/dev/null || { command rm -rf "$tmp_dir"; return 1; }
  poll_file="$tmp_dir/poll.json"
  start_file="$tmp_dir/start.json"

  local rc=0
  # A signal stops the daemon taking new work; children already running are
  # left to finish so their runs are settled rather than abandoned mid-flight
  # for the lease to expire.
  DX_WORKER_STOPPING=0
  trap 'DX_WORKER_STOPPING=1; dx_info "Finishing in-flight runs before exit."' INT TERM

  while true; do
    __dx_worker_reap_children

    if [[ "${DX_WORKER_STOPPING:-0}" -eq 1 ]]; then
      break
    fi

    # Each organisation is polled with its own credential. One being
    # unreachable, or having revoked this worker, must not stop the others.
    local slug poll_code
    while IFS= read -r slug; do
      [[ -n "$slug" ]] || continue
      [[ "${DX_WORKER_STOPPING:-0}" -eq 1 ]] && break

      poll_code="$(dx_worker_poll "$slug" "$poll_file")"

      if [[ "$poll_code" == "401" || "$poll_code" == "403" ]]; then
        # The credential was rotated or the worker disabled. Re-register with
        # that organisation's administrator token; never fall back to it for
        # worker calls.
        dx_warn "Worker credential for ${slug} rejected (HTTP ${poll_code}); re-registering."
        if ! dx_worker_register --organisation "$slug" \
          --name "$(__dx_worker_entry_field "$slug" 'worker_name')" --rotate; then
          dx_error "Re-registration for ${slug} failed."
          rc=1
        fi
        continue
      fi

      if ! dx_dexcode_http_success "$poll_code"; then
        dx_warn "Worker poll for ${slug} failed (HTTP ${poll_code})."
        [[ $once -eq 1 ]] && rc=1
        continue
      fi

      # The server is the authority on how many runs this worker may hold; a
      # local --concurrency can only ask for fewer.
      local allowed running slots
      allowed="$(__dx_worker_json_field "$poll_file" "max_concurrency" 2>/dev/null || printf '1')"
      case "$allowed" in ''|*[!0-9]*) allowed=1 ;; esac
      [[ "$allowed" -ge 1 ]] || allowed=1
      if [[ -n "$concurrency" && "$concurrency" -lt "$allowed" ]]; then
        allowed="$concurrency"
      fi
      running="$(__dx_worker_child_count)"
      slots=$((allowed - running))

      local queued run_id start_code claim_file
      queued="$(__dx_worker_queued_runs "$poll_file")"
      [[ -n "$queued" && $slots -gt 0 ]] || continue

      while IFS= read -r run_id; do
        [[ -n "$run_id" ]] || continue
        [[ $slots -gt 0 ]] || break
        start_code="$(dx_worker_start "$slug" "$run_id" "$start_file")"
        if ! dx_dexcode_http_success "$start_code"; then
          # 409 is ordinary: another worker took it first.
          dx_info "Could not claim ${run_id} (HTTP ${start_code})."
          continue
        fi
        # Each run gets its own copy of the claim, because the next iteration
        # overwrites the shared start file while this child is still reading it.
        claim_file="${tmp_dir}/start-$(__dx_worker_child_count)-$$.json"
        command cp "$start_file" "$claim_file" 2>/dev/null || continue
        __dx_worker_execute "$slug" "$run_id" "$work_dir" "$tmp_dir" \
          "$claim_file" "$dry_run" &
        DX_WORKER_CHILD_PIDS+=("$!")
        slots=$((slots - 1))
      done <<RUNS
$queued
RUNS
    done <<SLUGS
$slugs
SLUGS

    if [[ $once -eq 1 ]]; then
      break
    fi

    local wait_seconds
    wait_seconds="$(__dx_worker_json_field "$poll_file" "poll_interval" 2>/dev/null || printf '')"
    [[ -n "$interval" ]] && wait_seconds="$interval"
    sleep "$(__dx_worker_bounded_interval "$wait_seconds")"

    # A registration added or removed while running is picked up next round.
    slugs="$(dx_worker_organisations)"
  done

  # Whether this was --once or a signal, the runs already claimed have to be
  # settled before the process goes away.
  __dx_worker_wait_for_children
  trap - INT TERM
  __dx_worker_mark_offline

  command rm -rf "$tmp_dir"
  return $rc
}

# dx_worker_service [--working-directory <path>]
#
# Prints the service definition for this platform. It prints rather than
# installs: putting a unit into launchd or systemd changes how the machine
# boots, which is the operator's decision and not something a CLI should do
# behind their back. The output is ready to redirect into place.
dx_worker_service() {
  local work_dir="$PWD" arg
  while [[ $# -gt 0 ]]; do
    arg="$1"
    case "$arg" in
      --working-directory) work_dir="${2:-}"; shift 2 || return 1 ;;
      -h|--help)
        cat <<'USAGE'
Usage:
  dx worker service [--working-directory <path>]

Prints a launchd agent (macOS) or systemd unit (Linux) that keeps
`dx worker run` alive. Redirect it into place and load it yourself.
USAGE
        return 0
        ;;
      *) dx_error "Unknown dx worker service option: $arg"; return 1 ;;
    esac
  done

  if [[ -z "$(dx_worker_organisations)" ]]; then
    dx_error "This machine is not registered as a worker. Run 'dx worker register' first."
    return 1
  fi

  local dex_dir log_dir worker_name
  dex_dir="${DEX_DIR:-$HOME/work/dex}"
  log_dir="${HOME}/.dex/logs"
  worker_name="$(dx_worker_organisations | head -1)"
  [[ -n "$worker_name" ]] || worker_name="dex-worker"

  case "$(uname -s 2>/dev/null || printf 'Linux')" in
    Darwin)
      cat <<PLIST
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN"
  "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
  <key>Label</key><string>ai.dexcode.worker</string>
  <!-- dx.sh is zsh-only, and -l so the login profile sets DEX_DIR. -->
  <key>ProgramArguments</key>
  <array>
    <string>/bin/zsh</string>
    <string>-lc</string>
    <string>source "${dex_dir}/dx.sh"; cd "${work_dir}"; exec dx worker run</string>
  </array>
  <key>RunAtLoad</key><true/>
  <key>KeepAlive</key><true/>
  <key>WorkingDirectory</key><string>${work_dir}</string>
  <key>StandardOutPath</key><string>${log_dir}/worker.log</string>
  <key>StandardErrorPath</key><string>${log_dir}/worker.log</string>
</dict>
</plist>
PLIST
      dx_info "Save as ~/Library/LaunchAgents/ai.dexcode.worker.plist, then:" >&2
      dx_info "  mkdir -p ${log_dir}" >&2
      dx_info "  launchctl load ~/Library/LaunchAgents/ai.dexcode.worker.plist" >&2
      ;;
    *)
      cat <<UNIT
[Unit]
Description=DexCode worker (${worker_name})
After=network-online.target
Wants=network-online.target

[Service]
Type=simple
# dx.sh is zsh-only, and -l so the login profile sets DEX_DIR.
ExecStart=/bin/zsh -lc 'source "${dex_dir}/dx.sh"; cd "${work_dir}"; exec dx worker run'
WorkingDirectory=${work_dir}
Restart=always
RestartSec=10
# The daemon finishes the runs it holds before exiting, so give it room rather
# than killing it mid-run and leaving the leases to expire.
KillSignal=SIGTERM
TimeoutStopSec=900

[Install]
WantedBy=default.target
UNIT
      dx_info "Save as ~/.config/systemd/user/dexcode-worker.service, then:" >&2
      dx_info "  systemctl --user daemon-reload" >&2
      dx_info "  systemctl --user enable --now dexcode-worker" >&2
      ;;
  esac
  return 0
}

dx_worker_status() {
  local slugs slug worker_id worker_name api_url
  slugs="$(dx_worker_organisations)"
  if [[ -z "$slugs" ]]; then
    dx_info "This machine is not registered as a DexCode worker."
    dx_info "Run 'dx worker register' to register it."
    return 0
  fi

  while IFS= read -r slug; do
    [[ -n "$slug" ]] || continue
    worker_id="$(dx_worker_id "$slug" 2>/dev/null || printf 'unknown')"
    worker_name="$(__dx_worker_entry_field "$slug" 'worker_name' 2>/dev/null || printf 'unknown')"
    api_url="$(dx_worker_api_url "$slug" 2>/dev/null || printf 'unknown')"
    dx_info "${slug}: ${worker_name} (${worker_id}) at ${api_url}"
    if ! dx_worker_token "$slug" >/dev/null 2>&1; then
      dx_warn "  no credential — run 'dx worker register --organisation ${slug} --rotate'"
    fi
  done <<EOF
$slugs
EOF
  return 0
}

dx_worker_command() {
  local cmd="${1:-status}"
  shift 2>/dev/null || true

  case "$cmd" in
    register) dx_worker_register "$@" ;;
    run|daemon) dx_worker_daemon "$@" ;;
    status) dx_worker_status "$@" ;;
    service) dx_worker_service "$@" ;;
    help|-h|--help)
      cat <<'USAGE'
Usage:
  dx worker <register|run|status|service>

Commands:
  register  Register this machine as a DexCode worker and store its credential
  run       Poll for assigned runs and execute them
  status    Show the stored worker registration
  service   Print a launchd agent or systemd unit that keeps the worker running
USAGE
      ;;
    *)
      dx_error "Unknown worker command: ${cmd}"
      dx_info "Usage: dx worker <register|run|status|service>"
      return 1
      ;;
  esac
}
