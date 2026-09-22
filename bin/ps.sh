#!/usr/bin/env bash
# shellcheck disable=SC1091
# dx ps — what every Dex session on this host currently owns
#
# This is the visible half of session process ownership. Nothing here stops
# anything unless --reap-orphans is passed, and then it names every process it
# stopped. A human should be able to answer "what is running, and whose is it?"
# before deciding to act.
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

usage() {
  cat <<'USAGE'
Usage: dx ps [--reap-orphans]

List the processes each Dex session on this host owns, then the ones whose
session is gone. Read-only by default.

A session owns every process started inside it: each one carries the session
token on a descriptor and in its environment, so it is still identifiable
after a nohup, disown, setsid, or background launch moved it out of the
session's process tree.

Options:
  --reap-orphans  Stop the orphaned processes and print what was stopped
  -h, --help      Show this help
USAGE
}

REAP_ORPHANS=0
for arg in "$@"; do
  case "$arg" in
    -h|--help)
      usage
      exit 0
      ;;
    --reap-orphans) REAP_ORPHANS=1 ;;
    *)
      dx_error "Unknown ps option: $arg"
      usage >&2
      exit 1
      ;;
  esac
done

PS_TEMP_DIR=""
__dx_ps_cleanup() {
  [[ -n "$PS_TEMP_DIR" && -d "$PS_TEMP_DIR" ]] && command rm -rf "$PS_TEMP_DIR"
  return 0
}
trap __dx_ps_cleanup EXIT
PS_TEMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dex-ps.XXXXXX") || {
  dx_error "Could not create temporary space for the process report."
  exit 1
}

# __dx_ps_sessions — session IDs that have taken process ownership
#
# The directory name is the only input, because that is all the SessionEnd
# hook has too: everything about a session's owned processes derives from its
# ID.
__dx_ps_sessions() {
  local entry name
  [[ -d "$DX_LOOP_DIR" ]] || return 0
  while IFS= read -r entry; do
    [[ -n "$entry" ]] || continue
    name="${entry##*/}"
    name="${name%.process}"
    dx_session_id_valid "$name" || continue
    printf '%s\n' "$name"
  done < <(find "$DX_LOOP_DIR" -maxdepth 1 -type d -name '*.process' 2>/dev/null \
    | LC_ALL=C sort)
}

# __dx_ps_render <headers_json> <rows_file>
__dx_ps_render() {
  local headers="$1" rows_file="$2"
  DX_PS_HEADERS="$headers" DX_PS_ROWS_FILE="$rows_file" python3 - <<'PY' | dx_table
import json
import os

headers = json.loads(os.environ["DX_PS_HEADERS"])
rows = []
with open(os.environ["DX_PS_ROWS_FILE"], encoding="utf-8", errors="replace") as handle:
    for line in handle:
        line = line.rstrip("\n")
        if not line:
            continue
        if line == "--":
            rows.append(None)
            continue
        cells = line.split("\t")
        cells = (cells + [""] * len(headers))[:len(headers)]
        rows.append(cells)
print(json.dumps({"headers": headers, "rows": rows, "right_align": [0, 1, 2, 3]}))
PY
}

LIVE_ROWS="$PS_TEMP_DIR/live.tsv"
ORPHAN_ROWS="$PS_TEMP_DIR/orphan.tsv"
: > "$LIVE_ROWS"
: > "$ORPHAN_ROWS"
ORPHAN_SESSIONS="$PS_TEMP_DIR/orphan-sessions"
: > "$ORPHAN_SESSIONS"
LIVE_SESSION_COUNT=0
LIVE_PROCESS_COUNT=0
ORPHAN_SESSION_COUNT=0
ORPHAN_PROCESS_COUNT=0
SCAN_METHODS=""

while IFS= read -r SESSION_ID; do
  [[ -n "$SESSION_ID" ]] || continue
  METHOD_FILE="$PS_TEMP_DIR/method"
  CARRIERS=$(dx_session_process_carriers "$SESSION_ID" "$METHOD_FILE" | tr '\n' ' ')
  # The file is written whenever a scan ran, so its absence means there was
  # no token to scan rather than a host that could not answer.
  METHOD=""
  if [[ -s "$METHOD_FILE" ]]; then
    METHOD=$(cat "$METHOD_FILE" 2>/dev/null || true)
    METHOD="${METHOD%%$'\n'*}"
  fi
  command rm -f "$METHOD_FILE" 2>/dev/null || true
  if [[ -n "$METHOD" ]]; then
    case " $SCAN_METHODS " in
      *" $METHOD "*) ;;
      *) SCAN_METHODS="${SCAN_METHODS}${SCAN_METHODS:+ }${METHOD}" ;;
    esac
  fi

  HOLDER_PID=""
  dx_session_process_holder_pid "$SESSION_ID" >"$PS_TEMP_DIR/holder" 2>/dev/null \
    && HOLDER_PID=$(cat "$PS_TEMP_DIR/holder")
  HOLDER_PID="${HOLDER_PID%%$'\n'*}"

  # A session is live when the shell that opened its token is still one of the
  # processes carrying it. That is PID-reuse safe for free: a recycled PID
  # cannot be holding this session's descriptor.
  SESSION_LIVE=0
  if [[ -n "$HOLDER_PID" ]]; then
    case " $CARRIERS " in
      *" $HOLDER_PID "*) SESSION_LIVE=1 ;;
    esac
  fi

  ROW_COUNT=0
  DESCRIBED="$PS_TEMP_DIR/described.tsv"
  dx_session_process_describe "$CARRIERS" > "$DESCRIBED" 2>/dev/null || : > "$DESCRIBED"
  # PPID is read-only in bash, so none of these reuse a shell name.
  while IFS=$'\t' read -r ROW_PID ROW_PARENT ROW_AGE ROW_RSS ROW_CWD ROW_COMMAND; do
    [[ "$ROW_PID" =~ ^[0-9]+$ ]] || continue
    AGE_TEXT=$(dx_format_duration "$ROW_AGE")
    RSS_TEXT="$ROW_RSS"
    [[ "$ROW_RSS" =~ ^[0-9]+$ ]] && RSS_TEXT="$((ROW_RSS / 1024))M"
    ROW_COUNT=$((ROW_COUNT + 1))
    ROW_TARGET="$ORPHAN_ROWS"
    [[ "$SESSION_LIVE" -eq 1 ]] && ROW_TARGET="$LIVE_ROWS"
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$ROW_PID" "$ROW_PARENT" "$AGE_TEXT" "$RSS_TEXT" "$SESSION_ID" \
      "$ROW_CWD" "$ROW_COMMAND" >> "$ROW_TARGET"
  done < "$DESCRIBED"

  if [[ "$SESSION_LIVE" -eq 1 ]]; then
    LIVE_SESSION_COUNT=$((LIVE_SESSION_COUNT + 1))
    LIVE_PROCESS_COUNT=$((LIVE_PROCESS_COUNT + ROW_COUNT))
    [[ "$ROW_COUNT" -gt 0 ]] && printf -- '--\n' >> "$LIVE_ROWS"
  else
    printf '%s\n' "$SESSION_ID" >> "$ORPHAN_SESSIONS"
    ORPHAN_SESSION_COUNT=$((ORPHAN_SESSION_COUNT + 1))
    ORPHAN_PROCESS_COUNT=$((ORPHAN_PROCESS_COUNT + ROW_COUNT))
    [[ "$ROW_COUNT" -gt 0 ]] && printf -- '--\n' >> "$ORPHAN_ROWS"
  fi
done < <(__dx_ps_sessions)

HEADERS='["PID","PPID","AGE","RSS","SESSION","CWD","COMMAND"]'

printf '%s\n\n' "Dex — session processes"

if [[ -s "$LIVE_ROWS" ]]; then
  printf '%s\n' "Live sessions:"
  __dx_ps_render "$HEADERS" "$LIVE_ROWS"
  printf '\n'
else
  dx_info "No live Dex session owns a process on this host."
  printf '\n'
fi

if [[ -s "$ORPHAN_ROWS" ]]; then
  printf '%s\n' "Orphans (the session that started these is gone):"
  __dx_ps_render "$HEADERS" "$ORPHAN_ROWS"
  printf '\n'
fi

dx_info "$(printf '%s live session(s), %s owned process(es); %s orphaned session(s), %s orphaned process(es)' \
  "$LIVE_SESSION_COUNT" "$LIVE_PROCESS_COUNT" "$ORPHAN_SESSION_COUNT" "$ORPHAN_PROCESS_COUNT")"
[[ -n "$SCAN_METHODS" ]] && dx_info "Ownership scan method: $SCAN_METHODS"

if [[ "$ORPHAN_SESSION_COUNT" -eq 0 ]]; then
  exit 0
fi

if [[ "$REAP_ORPHANS" -eq 0 ]]; then
  dx_info "Read-only. Nothing was stopped. Run 'dx ps --reap-orphans' to stop the orphans."
  exit 0
fi

REAP_EXIT=0
REAPED_TOTAL=0
SURVIVED_TOTAL=0
CLEANED_TOTAL=0
while IFS= read -r SESSION_ID; do
  [[ -n "$SESSION_ID" ]] || continue
  # dx_session_finish_processes prints every line it reaped or failed to reap,
  # keeps the token of a session with survivors, and publishes the counts. Its
  # stderr is left alone: a scan that could not answer must be visible.
  if dx_session_finish_processes "$SESSION_ID" ps-reap-orphans; then
    CLEANED_TOTAL=$((CLEANED_TOTAL + 1))
  else
    REAP_EXIT=1
  fi
  REAPED_TOTAL=$((REAPED_TOTAL + DX_SESSION_REAP_REAPED))
  SURVIVED_TOTAL=$((SURVIVED_TOTAL + DX_SESSION_REAP_SURVIVED))
done < "$ORPHAN_SESSIONS"

if [[ "$REAP_EXIT" -ne 0 ]]; then
  dx_warn "$(printf 'Stopped %s orphaned process(es); %s would not stop or could not be scanned. Those session tokens are kept so %s lists them again.' \
    "$REAPED_TOTAL" "$SURVIVED_TOTAL" "'dx ps'")"
  exit 1
fi
if [[ "$REAPED_TOTAL" -eq 0 ]]; then
  dx_done "Removed ${CLEANED_TOTAL} orphaned session temp root(s); no process was still running."
else
  dx_done "Stopped ${REAPED_TOTAL} orphaned process(es) and removed ${CLEANED_TOTAL} session temp root(s)."
fi
