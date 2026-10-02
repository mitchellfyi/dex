#!/usr/bin/env bash
# SessionEnd hook — records session end time and cleans up ephemeral state files.
# Runs when an interactive provider session ends (cleanly or otherwise).
set -euo pipefail

# Standalone launchers clean only their own temporary files.
[[ "${DEX_TRIAGE_ACTIVE:-0}" == 1 || "${DEX_SESSION_ONLY:-0}" == 1 ]] && exit 0

# shellcheck disable=SC2034  # read by lib/common.sh while it is sourced
DX_COMMON_MODULES="session session-process"
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

SESSION_ID="${DEX_SESSION_ID:-$(dx_session_id)}"

# A checkout-derived Dex session can be visible to more than one provider
# session. Only the session that claimed the active loop may mutate its
# state during SessionEnd. If the payload cannot prove ownership, leave the
# state for the real owner or wrapper to clean up.
# The payload is read once, here: the ownership check needs the provider's
# session id and the usage record at the end needs the transcript path.
HOOK_INPUT=$(cat 2>/dev/null || true)
HOOK_CLAUDE_SESSION_ID=""
HOOK_TRANSCRIPT_PATH=""
if [[ -n "$HOOK_INPUT" ]]; then
  while IFS= read -r HOOK_FIELD; do
    case "$HOOK_FIELD" in
      session_id=*) HOOK_CLAUDE_SESSION_ID="${HOOK_FIELD#session_id=}" ;;
      transcript_path=*) HOOK_TRANSCRIPT_PATH="${HOOK_FIELD#transcript_path=}" ;;
    esac
  done < <(printf '%s' "$HOOK_INPUT" | python3 -c '
import json
import sys

try:
    payload = json.load(sys.stdin)
except Exception:
    payload = {}
if not isinstance(payload, dict):
    payload = {}
for key in ("session_id", "transcript_path"):
    value = payload.get(key, "")
    if isinstance(value, str) and "\n" not in value:
        print(f"{key}={value}")
' 2>/dev/null || true)
fi

OWNER_FILE=$(dx_owner_file "$SESSION_ID")
if [[ -s "$OWNER_FILE" ]]; then
  OWNER_ID=$(cat "$OWNER_FILE" 2>/dev/null || true)
  if [[ -n "$OWNER_ID" && "$HOOK_CLAUDE_SESSION_ID" != "$OWNER_ID" ]]; then
    exit 0
  fi
fi

# Record end time in the times file (complements phase start times written by dx.sh)
TIMES_FILE=$(dx_times_file "$SESSION_ID")
CTX_FILE=$(dx_context_file "$SESSION_ID")

if [[ -f "$TIMES_FILE" || -f "$CTX_FILE" || -f "$(dx_state_file "$SESSION_ID")" || -f "$(dx_active_file "$SESSION_ID")" || -f "$(dx_loop_config_file "$SESSION_ID")" || -f "$(dx_handoff_mode_file "$SESSION_ID")" ]]; then
  dx_record_session_branch "$SESSION_ID" "$(pwd)" 2>/dev/null || true
fi

if [[ -f "$TIMES_FILE" ]]; then
  echo "end:$(date +%s)" >> "$TIMES_FILE"
fi

# Give the project its say before the reap, not after. A session holds things
# the worktree does not own — a port, a lease, a container, a dev server — and
# `## Worktree Hooks` is where a repository declares how to release them. The
# hook runs while this session's ownership token is still live, so whatever it
# starts is reaped below rather than outliving the session that asked for it.
# A failing or slow hook warns and is stepped over, like every other worktree
# hook. In a worktree DX_WORKTREE_NAME is the worktree's name; in an in-place
# session it is the repository directory's own name.
#
# Running it needs three modules the reap does not, and this hook deliberately
# loads only what it calls: it runs under a short host-side deadline, and a
# vendored runtime may carry a subset of lib/. So look for the section with one
# grep first — the same heading shape scripts/project-contract.py matches — and
# pay for the modules only when a repository has actually asked for this.
SESSION_END_REPO=$(dx_repo_root 2>/dev/null || true)
if [[ -n "$SESSION_END_REPO" ]] && grep -qiE \
  '^#{1,6}[[:space:]]+Worktree Hooks[[:space:]]*$' \
  "$SESSION_END_REPO/.dex/dex.md" 2>/dev/null; then
  for SESSION_END_MODULE in output.sh project-state.sh worktree.sh; do
    [[ -f "${DEX_DIR}/lib/${SESSION_END_MODULE}" ]] || continue
    __dx_require_lib "$SESSION_END_MODULE" || true
  done
  if command -v dx_worktree_hook_run >/dev/null 2>&1; then
    # settings.json gives this hook ten seconds of host budget, and what the
    # session actually depends on — the reap and the temp-root removal — is
    # below this line. A project's own 300 s default, or its `0` for "no
    # deadline", would have the host kill the hook script first and take the
    # reap with it, silently. Five seconds leaves the rest of the hook room;
    # a project that asked for less than five still gets what it asked for.
    # shellcheck disable=SC2034  # read by __dx_worktree_hook_timeout in lib/
    DX_WORKTREE_HOOK_CEILING=5
    dx_worktree_hook_run on_session_end "$SESSION_END_REPO" "$(pwd)" || true
    unset DX_WORKTREE_HOOK_CEILING
  fi
fi

# Stop every process this session started, however it was launched, then drop
# the session temp root. The reaper needs the token file to identify what it
# owns, so the token goes only after it has run and only if nothing survived.
# It skips this hook's own ancestry, so it cannot stop itself or the provider
# that is already exiting. A session that never took process ownership returns
# without a scan. Its output is left visible: this is the session-end path the
# design allows to act, and acting has to be logged. The same call emits this
# session's one telemetry summary, after the reap so the counts are final.
dx_session_finish_processes "$SESSION_ID" session-end || true

# What the session's model usage came to, read from the provider transcript the
# payload names and its subagents/ directory, one count per request
# (scripts/usage_collect.py). The full record lands under the run journal and
# the event carries the totals, per agent and per model. No transcript, or a
# collector failure, still produces the event, saying the figure is unavailable:
# an unmeasured session is unknown, not free.
__dx_session_end_usage() {
  local sid="$1" transcript="$2" provider_sid="$3"
  local run_id run_dir usage_dir usage_file data
  # lib/events.sh needs lib/lock.sh; the reaper's loader brings both or neither.
  __dx_session_events_ready || return 0
  run_id=$(dx_run_read_for_session "$sid" 2>/dev/null || true)
  [[ -n "$run_id" ]] || return 0
  if [[ -z "$transcript" || ! -f "$transcript" ]]; then
    dx_event_emit_for_session "$sid" session.usage info \
      "Session usage unavailable: no provider transcript" "${DEX_LOOP_PHASE:-}" \
      "$(python3 -c 'import json, sys; print(json.dumps({"schema_version": 1, "available": False, "provider_session_id": sys.argv[1] or None, "reason": "no transcript"}))' "$provider_sid")"
    return 0
  fi
  run_dir=$(dx_run_dir "$run_id") || return 0
  usage_dir="$run_dir/usage"
  mkdir -p "$usage_dir" || return 0
  usage_file="$usage_dir/${provider_sid:-session}.json"
  if ! python3 "$DEX_DIR/scripts/usage_collect.py" "$transcript" \
      --subagents "${transcript%.jsonl}/subagents" > "$usage_file.tmp.$$" 2>/dev/null; then
    rm -f "$usage_file.tmp.$$"
    dx_event_emit_for_session "$sid" session.usage warning \
      "Session usage unavailable: collector failed" "${DEX_LOOP_PHASE:-}" \
      "$(python3 -c 'import json, sys; print(json.dumps({"schema_version": 1, "available": False, "provider_session_id": sys.argv[1] or None, "reason": "collector failed"}))' "$provider_sid")"
    return 0
  fi
  mv "$usage_file.tmp.$$" "$usage_file" || return 0
  data=$(python3 - "$usage_file" "$provider_sid" "$transcript" <<'PY'
import json
import sys

record = json.load(open(sys.argv[1]))
agent_fields = (
    "agent_type", "requests", "input_tokens", "cache_creation_input_tokens",
    "cache_read_input_tokens", "output_tokens", "thinking_tokens", "prompt_tokens_total",
)
model_fields = ("requests", "prompt_tokens_total", "output_tokens")
print(json.dumps({
    "schema_version": 1,
    "available": True,
    "provider_session_id": sys.argv[2] or None,
    "transcript_path": sys.argv[3],
    "usage_file": sys.argv[1],
    "usage_schema": record["usage_schema"],
    "requests": record["requests"],
    "duplicate_lines_skipped": record["duplicate_lines_skipped"],
    "requests_without_usage": record["requests_without_usage"],
    "malformed_lines": record["malformed_lines"],
    "complete": record["complete"],
    "totals": record["totals"],
    "by_agent": {k: {f: v.get(f) for f in agent_fields} for k, v in record["by_agent"].items()},
    "by_model": {k: {f: v.get(f) for f in model_fields} for k, v in record["by_model"].items()},
}, sort_keys=True))
PY
) || return 0
  dx_event_emit_for_session "$sid" session.usage info "Session model usage" \
    "${DEX_LOOP_PHASE:-}" "$data"
}
__dx_session_end_usage "$SESSION_ID" "$HOOK_TRANSCRIPT_PATH" "$HOOK_CLAUDE_SESSION_ID" || true

# Helpers' observations wait in the mission ledger directory until a safe
# boundary; the end of the session is one. The store validates and dedupes
# them, and a byte cursor stops a second SessionEnd from ingesting them again.
if [[ "${DX_MISSION_ACTIVE:-0}" == 1 ]]; then
  __dx_require_lib mission.sh 2>/dev/null || true
  __dx_require_lib memory.sh 2>/dev/null || true
  if command -v dx_memory_ingest_mission >/dev/null 2>&1; then
    SESSION_END_MEMORY_REPO=$(git rev-parse --show-toplevel 2>/dev/null || true)
    if [[ -n "$SESSION_END_MEMORY_REPO" ]]; then
      dx_memory_ingest_mission "$SESSION_ID" "$SESSION_END_MEMORY_REPO" >/dev/null 2>&1 || true
    fi
  fi
fi

# The store trims itself at the end of every lifecycle or mission session:
# corroborated candidates are promoted, stale, idle and unused entries
# retired. Deterministic, no model call; the critical review runs from the
# lifecycle's completion path (dx_memory_curate_if_due).
if [[ "${DX_MISSION_ACTIVE:-0}" == 1 || "${DEX_LOOP_ACTIVE:-0}" == 1 ]]; then
  __dx_require_lib memory.sh 2>/dev/null || true
  if command -v dx_memory_maintain >/dev/null 2>&1; then
    SESSION_END_MEMORY_REPO="${SESSION_END_MEMORY_REPO:-$(git rev-parse --show-toplevel 2>/dev/null || true)}"
    if [[ -n "$SESSION_END_MEMORY_REPO" ]]; then
      dx_memory_maintain "$SESSION_END_MEMORY_REPO" >/dev/null 2>&1 || true
    fi
  fi
fi

# Clean up the system context file — it's regenerated at each phase start
rm -f "$CTX_FILE" 2>/dev/null || true
