#!/usr/bin/env bash
# shellcheck disable=SC1091
# dx run-gate — run one heavy command under host-wide admission
#
# A project gate, a test suite or a build is the work that takes a shared
# machine down when several sessions start one at the same moment.
# This is the sanctioned way to run one: it takes a `heavy` lease so at most a
# host-appropriate number run at once, waits with a heartbeat that says who is
# ahead and for how long, runs the command at reduced scheduling priority under
# the session's process token, streams its output to a session-owned log, and
# records the result.
#
# It never discards a completed result. A gate that ran is evidence about the
# tree it ran on, whether it passed or failed, and the receipt is what stops
# the next phase paying for the same answer.
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: dx run-gate [options] [--] <command> [args...]

Run one heavy command — a project gate, a test suite, a build — under
host-wide admission, at reduced priority, owned by this session. A dev server
is not a gate: start it directly; it is session-owned without a lease.

At most DEX_MAX_ACTIVE_HEAVY heavy commands run at once across every Dex
session on this host. The default is derived from the host: one per four
cores and per eight gigabytes, whichever is fewer, at least one. While the
pool is full this waits and prints how many owners are ahead and how long the
oldest has been running; waiting never fails the command.

Output streams to a log under this session's temp root and is replayed when
the command finishes, so a long gate can be started from one tool call and
polled from the next. The process dies with the session.

Options:
  --name <name>       Receipt name for this gate (default: derived from the
                      command). One receipt per name per session.
  --timeout <secs>    Stop the command after this many seconds; 0 means no
                      deadline (default: DEX_GATE_TIMEOUT, or 0)
  -h, --help          Show this help

Exit status is the command's own, or:
  2   bad arguments, or an unsafe capacity pool
  70  Dex could not prepare the gate (log, lease, or receipt)
USAGE
}

GATE_NAME=""
GATE_TIMEOUT="${DEX_GATE_TIMEOUT:-0}"
while [[ $# -gt 0 ]]; do
  case "$1" in
    -h|--help)
      usage
      exit 0
      ;;
    --name)
      [[ $# -ge 2 ]] || { dx_error "--name needs a value"; exit 2; }
      GATE_NAME="$2"
      shift 2
      ;;
    --timeout)
      [[ $# -ge 2 ]] || { dx_error "--timeout needs a value"; exit 2; }
      GATE_TIMEOUT="$2"
      shift 2
      ;;
    --)
      shift
      break
      ;;
    -*)
      dx_error "Unknown run-gate option: $1"
      usage >&2
      exit 2
      ;;
    *) break ;;
  esac
done

if [[ $# -eq 0 ]]; then
  dx_error "run-gate needs a command to run"
  usage >&2
  exit 2
fi
if [[ ! "$GATE_TIMEOUT" =~ ^[0-9]{1,6}$ ]]; then
  dx_error "--timeout takes 0 to 999999 seconds"
  exit 2
fi

GATE_SESSION="${DEX_SESSION_ID:-$(dx_session_id)}"
if ! dx_session_id_valid "$GATE_SESSION"; then
  dx_error "run-gate needs a valid session ID; got '${GATE_SESSION}'"
  exit 2
fi

# A gate name has to survive being a filename and has to stay distinct: two
# different commands must not land on one receipt. Deriving it from the whole
# command rather than its first word is what keeps `bash tests/run-all.sh` and
# `bash tests/check.sh` apart.
#
# A derived name never refuses to run the gate. The first version stripped a
# leading `-` but not a leading `.`, so `dx run-gate ./bin/verify` — the most
# ordinary way to name a gate there is — failed argument validation and ran
# nothing. Strip every leading non-alphanumeric character, and if what is left
# still cannot be a receipt slot, fall back to `gate` rather than refusing.
# Only an explicit --name is rejected, because that is the caller's own text.
if [[ -z "$GATE_NAME" ]]; then
  GATE_NAME=$(printf '%s' "$*" \
    | LC_ALL=C sed -E 's#[^A-Za-z0-9._-]+#-#g; s#^[^A-Za-z0-9]+##; s#[^A-Za-z0-9._-]+$##' \
    | cut -c1-64)
  dx_gate_receipt_slot "$GATE_NAME" >/dev/null 2>&1 || GATE_NAME="gate"
elif ! dx_gate_receipt_slot "$GATE_NAME" >/dev/null 2>&1; then
  dx_error "--name must start alphanumeric and use only A-Za-z0-9._- (max 64): ${GATE_NAME}"
  exit 2
fi

if ! GATE_REPO=$(git rev-parse --show-toplevel 2>/dev/null); then
  GATE_REPO="$PWD"
fi

# Logs belong under the session temp root: it goes away when the session ends,
# which is exactly the lifetime of a gate's output.
GATE_TMP="${DX_SESSION_TMP:-$(dx_session_tmp_dir "$GATE_SESSION")}/gates"
if ! mkdir -p "$GATE_TMP"; then
  dx_error "Could not create the gate log directory: ${GATE_TMP}"
  exit 70
fi
chmod 700 "$GATE_TMP" 2>/dev/null || true
GATE_INDEX=1
while [[ -e "$GATE_TMP/$GATE_INDEX.log" ]]; do
  GATE_INDEX=$((GATE_INDEX + 1))
done
GATE_LOG="$GATE_TMP/$GATE_INDEX.log"
if ! : > "$GATE_LOG"; then
  dx_error "Could not create the gate log: ${GATE_LOG}"
  exit 70
fi
chmod 600 "$GATE_LOG" 2>/dev/null || true

# What the project declared about its own resources. Absent section, absent
# file, absent key: nothing changes except that this command still leases.
GATE_PARALLELISM_NAMES=""
GATE_CONTRACT_RC=0
GATE_CONTRACT_VALUES=$(dx_project_contract_values "$GATE_REPO" Resources \
  parallelism_env) || GATE_CONTRACT_RC=$?
if [[ "$GATE_CONTRACT_RC" -eq 2 ]]; then
  dx_warn "Ignoring '## Resources' in ${GATE_REPO}/.dex/dex.md: it is not a flat YAML mapping."
fi
GATE_TEST_JOBS=$(dx_host_test_jobs_effective)
if [[ "$GATE_CONTRACT_RC" -eq 0 ]]; then
  while IFS= read -r GATE_ENV_NAME; do
    [[ -n "$GATE_ENV_NAME" ]] || continue
    if [[ ! "$GATE_ENV_NAME" =~ ^[A-Za-z_][A-Za-z0-9_]*$ ]]; then
      dx_warn "Ignoring declared parallelism variable '${GATE_ENV_NAME}': not an environment variable name."
      continue
    fi
    export "${GATE_ENV_NAME}=${GATE_TEST_JOBS}"
    GATE_PARALLELISM_NAMES="${GATE_PARALLELISM_NAMES}${GATE_PARALLELISM_NAMES:+ }${GATE_ENV_NAME}"
  done <<EOF
$GATE_CONTRACT_VALUES
EOF
fi

# Advisory, and pointed the only direction this process can see: whether the
# command it was handed is one the project declared heavy. The other half —
# advising when a declared heavy command is run *outside* a gate — needs a hook
# on the tool call, not this process.
GATE_DECLARED_RC=0
GATE_DECLARED=$(dx_project_contract_values "$GATE_REPO" Resources \
  heavy_commands) || GATE_DECLARED_RC=$?
if [[ "$GATE_DECLARED_RC" -eq 0 ]]; then
  GATE_IS_DECLARED=0
  while IFS= read -r GATE_DECLARED_COMMAND; do
    [[ -n "$GATE_DECLARED_COMMAND" ]] || continue
    if [[ "$*" == "$GATE_DECLARED_COMMAND" || "$*" == "$GATE_DECLARED_COMMAND "* ]]; then
      GATE_IS_DECLARED=1
    fi
  done <<EOF
$GATE_DECLARED
EOF
  if [[ "$GATE_IS_DECLARED" -eq 1 ]]; then
    dx_info "${GATE_NAME}: declared heavy in .dex/dex.md"
  else
    dx_warn "${GATE_NAME}: not declared heavy in .dex/dex.md; it takes a heavy lease anyway."
  fi
fi

GATE_TOKEN="gate-${$}-${RANDOM}"
GATE_LIMIT=$(dx_host_heavy_limit) || {
  dx_error "Invalid heavy capacity; use DEX_MAX_ACTIVE_HEAVY=1..8"
  exit 2
}
GATE_WRAPPER=$(dx_host_priority_wrapper) || {
  dx_error "Invalid DEX_GATE_PRIORITY; use auto, none, or one of: ${DX_HOST_PRIORITY_WRAPPERS}"
  exit 2
}
GATE_PRIORITY=()
while IFS= read -r GATE_PRIORITY_WORD; do
  [[ -n "$GATE_PRIORITY_WORD" ]] || continue
  GATE_PRIORITY+=("$GATE_PRIORITY_WORD")
done < <(dx_host_priority_prefix "$GATE_WRAPPER")

GATE_LEASED=0
gate_cleanup() {
  [[ "$GATE_LEASED" -eq 1 ]] || return 0
  GATE_LEASED=0
  dx_capacity_pool_release heavy "$GATE_TOKEN" 2>/dev/null || true
}
trap gate_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP

# The heartbeat. It is passed where dx_review_capacity_wait takes a cancel
# callback, and it always returns 1 — waiting for the host is not a failure and
# must never become one. Both destinations matter: stdout for whoever is
# watching, the log for whoever started this in the background and is polling.
GATE_HEARTBEAT_SECONDS="${DEX_GATE_HEARTBEAT_SECONDS:-30}"
[[ "$GATE_HEARTBEAT_SECONDS" =~ ^[1-9][0-9]{0,3}$ ]] || GATE_HEARTBEAT_SECONDS=30
GATE_HEARTBEAT_LAST=0
gate_heartbeat() {
  local now ahead oldest text
  now=$(date +%s)
  if [[ $((now - GATE_HEARTBEAT_LAST)) -lt "$GATE_HEARTBEAT_SECONDS" ]]; then
    return 1
  fi
  GATE_HEARTBEAT_LAST="$now"
  IFS=$'\t' read -r ahead oldest <<EOF
$(dx_capacity_pool_queue_status heavy "$GATE_TOKEN" 2>/dev/null || printf '?\t-\n')
EOF
  if [[ "$oldest" == "-" ]]; then
    text="${GATE_NAME}: queued behind ${ahead}, nothing running yet"
  else
    text="${GATE_NAME}: queued behind ${ahead}, oldest started $(dx_format_duration "$oldest") ago"
  fi
  dx_info "$text"
  printf '[info]  %s\n' "$text" >> "$GATE_LOG" 2>/dev/null || true
  return 1
}

# The command reaches the journal as a JSON string, not through the printf
# template: it is the one field here that came from someone else's argv, and
# an embedded quote would make every gate event unparseable.
GATE_COMMAND_JSON=$(dx_event_json_string "$*" 200) || GATE_COMMAND_JSON='""'

dx_info "${GATE_NAME}: waiting for heavy capacity (limit ${GATE_LIMIT}, priority ${GATE_WRAPPER})"
dx_event_emit_for_session "$GATE_SESSION" "gate.queued" "info" \
  "Heavy gate ${GATE_NAME} is waiting for host capacity" "" \
  "$(printf '{"gate":"%s","pool":"heavy","limit":%s,"priority_wrapper":"%s"}' \
    "$GATE_NAME" "$GATE_LIMIT" "$GATE_WRAPPER")" 2>/dev/null || true
GATE_QUEUE_STARTED=$(date +%s)
GATE_WAIT_RC=0
dx_capacity_pool_wait heavy "$GATE_SESSION" "$GATE_TOKEN" gate_heartbeat \
  || GATE_WAIT_RC=$?
if [[ "$GATE_WAIT_RC" -ne 0 ]]; then
  dx_error "${GATE_NAME}: the heavy queue did not admit the command (${GATE_WAIT_RC})"
  exit 70
fi
GATE_LEASED=1
dx_capacity_pool_mark_started heavy "$GATE_TOKEN" 2>/dev/null || true
GATE_QUEUE_SECONDS=$(( $(date +%s) - GATE_QUEUE_STARTED ))

# The tree this result is about, read the way bin/review-check.sh reads it: the
# checkout fingerprint is HEAD, the working fingerprint is the whole working
# tree including untracked files.
GATE_CHECKOUT=$(git -C "$GATE_REPO" rev-parse --verify HEAD 2>/dev/null) \
  || GATE_CHECKOUT="unborn"
GATE_WORKING_BEFORE=$(dx_review_working_fingerprint "$GATE_REPO" 2>/dev/null) \
  || GATE_WORKING_BEFORE=""

dx_info "${GATE_NAME}: running (queued ${GATE_QUEUE_SECONDS}s, ${GATE_TEST_JOBS} test job(s)); output -> ${GATE_LOG}"
dx_event_emit_for_session "$GATE_SESSION" "gate.started" "info" \
  "Heavy gate ${GATE_NAME} started" "" \
  "$(printf '{"gate":"%s","pool":"heavy","limit":%s,"queue_seconds":%s,"priority_wrapper":"%s","test_jobs":"%s","timeout_seconds":%s,"command":%s}' \
    "$GATE_NAME" "$GATE_LIMIT" "$GATE_QUEUE_SECONDS" "$GATE_WRAPPER" \
    "$GATE_TEST_JOBS" "$GATE_TIMEOUT" "$GATE_COMMAND_JSON")" 2>/dev/null || true

# Redirected straight to the file rather than piped through `tee`: a pipeline
# would run dx_run_with_timeout in a subshell, where its INT/TERM handler can
# no longer reach the supervisor that owns the command tree — and bash defers
# this shell's own handler until the foreground pipeline ends, so a cancelled
# gate would keep running. fd 8 is untouched; the session still owns everything
# this starts, and dx_run_with_timeout keeps its own token on fd 9.
GATE_STARTED=$(date +%s)
GATE_EXIT=0
set +e
if [[ ${#GATE_PRIORITY[@]} -gt 0 ]]; then
  dx_run_with_timeout "$GATE_TIMEOUT" "${GATE_PRIORITY[@]}" "$@" \
    >> "$GATE_LOG" 2>&1
  GATE_EXIT=$?
else
  dx_run_with_timeout "$GATE_TIMEOUT" "$@" >> "$GATE_LOG" 2>&1
  GATE_EXIT=$?
fi
set -e
GATE_DURATION=$(( $(date +%s) - GATE_STARTED ))

# Whether the gate reached the deadline it was given. A gate with no deadline
# — the default, because a completed result is never discarded — is never
# over budget. The flag is recorded beside the real exit code and duration
# rather than replacing them, so a gate that was stopped at its deadline still
# reads as a thing that happened.
GATE_OVER_BUDGET=0
if [[ "$GATE_TIMEOUT" -gt 0 && "$GATE_DURATION" -ge "$GATE_TIMEOUT" ]]; then
  GATE_OVER_BUDGET=1
fi

# Replay the whole log so an interactive caller sees everything, and a caller
# that captured stdout has it too. The file stays put either way.
cat "$GATE_LOG" 2>/dev/null || true

# A tree that moved while the gate ran makes the result real but unattributable:
# it describes neither the tree before nor the tree now. Record it, mark it
# unstable, and never match it from a lookup.
GATE_WORKING_AFTER=$(dx_review_working_fingerprint "$GATE_REPO" 2>/dev/null) \
  || GATE_WORKING_AFTER=""
GATE_STABLE=0
if [[ -n "$GATE_WORKING_BEFORE" && "$GATE_WORKING_BEFORE" == "$GATE_WORKING_AFTER" ]]; then
  GATE_STABLE=1
fi
[[ -n "$GATE_WORKING_BEFORE" ]] || GATE_WORKING_BEFORE="unavailable"

GATE_RECEIPT=""
if ! GATE_RECEIPT=$(dx_gate_receipt_write "$GATE_SESSION" "$GATE_NAME" \
  "$GATE_CHECKOUT" "$GATE_WORKING_BEFORE" "$GATE_STABLE" "$GATE_EXIT" \
  "$GATE_DURATION" "$GATE_QUEUE_SECONDS" "$GATE_WRAPPER" "$GATE_TEST_JOBS" \
  "$GATE_PARALLELISM_NAMES" "$GATE_LOG" "$@"); then
  dx_warn "${GATE_NAME}: could not write the gate receipt; the result above still stands."
fi

# What this session has now spent on heavy work, for the summary line at
# session end. It lives beside the session token, so it dies with the phase
# the way the gate logs do; the receipt is the durable copy.
dx_session_gate_record "$GATE_SESSION" "$GATE_NAME" "$GATE_EXIT" \
  "$GATE_DURATION" "$GATE_QUEUE_SECONDS" "$GATE_OVER_BUDGET" \
  2>/dev/null || true

GATE_RECEIPT_JSON=$(dx_event_json_string "$GATE_RECEIPT" 400) \
  || GATE_RECEIPT_JSON='""'
gate_cleanup
dx_event_emit_for_session "$GATE_SESSION" "gate.finished" "info" \
  "Heavy gate ${GATE_NAME} finished with exit ${GATE_EXIT}" "" \
  "$(printf '{"gate":"%s","pool":"heavy","exit_code":%s,"duration_seconds":%s,"queue_seconds":%s,"priority_wrapper":"%s","test_jobs":"%s","checkout_fingerprint":"%s","working_fingerprint":"%s","stable":%s,"timeout_seconds":%s,"over_budget":%s,"command":%s,"receipt":%s}' \
    "$GATE_NAME" "$GATE_EXIT" "$GATE_DURATION" "$GATE_QUEUE_SECONDS" \
    "$GATE_WRAPPER" "$GATE_TEST_JOBS" "$GATE_CHECKOUT" \
    "$GATE_WORKING_BEFORE" \
    "$([[ "$GATE_STABLE" -eq 1 ]] && printf 'true' || printf 'false')" \
    "$GATE_TIMEOUT" \
    "$([[ "$GATE_OVER_BUDGET" -eq 1 ]] && printf 'true' || printf 'false')" \
    "$GATE_COMMAND_JSON" "$GATE_RECEIPT_JSON")" \
  2>/dev/null || true
dx_run_log_append_for_session "$GATE_SESSION" "info" "run-gate" \
  "gate=${GATE_NAME}; exit=${GATE_EXIT}; duration_s=${GATE_DURATION}; queue_s=${GATE_QUEUE_SECONDS}; priority=${GATE_WRAPPER}" \
  2>/dev/null || true

if [[ "$GATE_EXIT" -eq 0 ]]; then
  dx_ok "${GATE_NAME}: passed in $(dx_format_duration "$GATE_DURATION") (priority ${GATE_WRAPPER})"
else
  dx_warn "${GATE_NAME}: exit ${GATE_EXIT} after $(dx_format_duration "$GATE_DURATION") (log: ${GATE_LOG})"
fi
[[ -z "$GATE_RECEIPT" ]] || dx_info "${GATE_NAME}: receipt ${GATE_RECEIPT}"
exit "$GATE_EXIT"
