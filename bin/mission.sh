#!/usr/bin/env bash
# Internal: the mission ledger from the shell (hooks, the lead's Bash calls).
# Usage: mission.sh <session-id> <init|record|lease|observe|feedback|show|verify|rebuild> [args]
set -euo pipefail

# shellcheck disable=SC2034  # read by lib/common.sh while it is sourced
DX_COMMON_MODULES="lock session session-process mission memory feedback"
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

if [[ $# -lt 2 ]]; then
  echo "Usage: mission.sh <session-id> <init|record|lease|observe|feedback|show|verify|rebuild> [args]" >&2
  exit 2
fi

SESSION_ID="$1"
shift

case "$1" in
  show|verify|rebuild)
    dx_mission_ledger "$SESSION_ID" "$@"
    ;;
  lease)
    if [[ "${2:-}" == "show" ]]; then
      dx_mission_ledger "$SESSION_ID" "$@"
    else
      dx_mission_write "$SESSION_ID" "$@"
    fi
    ;;
  init|record)
    dx_mission_write "$SESSION_ID" "$@"
    ;;
  observe)
    # observe --json '{"lesson":…,"evidence":…,"scope":…,"type":…}' [--actor WHO]
    # The lead's own observation: into the store now, and a reference in the
    # ledger so the mission record shows what it contributed.
    shift
    OBS_JSON="" OBS_ACTOR="${DX_MISSION_ACTOR:-lead}"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --json) OBS_JSON="${2:-}"; shift 2 ;;
        --actor) OBS_ACTOR="${2:-lead}"; shift 2 ;;
        *) echo "Usage: mission.sh <session-id> observe --json '{...}' [--actor WHO]" >&2; exit 2 ;;
      esac
    done
    [[ -n "$OBS_JSON" ]] || { echo "Usage: mission.sh <session-id> observe --json '{...}' [--actor WHO]" >&2; exit 2; }
    OBS_REPO=$(git rev-parse --show-toplevel 2>/dev/null || pwd)
    OBS_FILE=$(mktemp "${TMPDIR:-/tmp}/dx-observe.XXXXXX")
    printf '%s\n' "$OBS_JSON" > "$OBS_FILE"
    OBS_SUMMARY=$(dx_memory_store "$OBS_REPO" ingest --repo "$OBS_REPO" --source "mission:${SESSION_ID}" --revision "$(git rev-parse HEAD 2>/dev/null || true)" "$OBS_FILE") || { rm -f "$OBS_FILE"; exit 1; }
    rm -f "$OBS_FILE"
    OBS_REF=$(printf '%s' "$OBS_JSON" | python3 -c 'import json, sys
row = json.load(sys.stdin)
print(json.dumps({"lesson": str(row.get("lesson", ""))[:160], "scope": row.get("scope"), "type": row.get("type")}))')
    dx_mission_write "$SESSION_ID" record observation-ref --actor "$OBS_ACTOR" --json "$OBS_REF" >/dev/null
    printf '%s\n' "$OBS_SUMMARY"
    ;;
  feedback)
    # feedback --json '{"mechanism":…,"symptom":…,"evidence_summary":…}' [--patch FILE] [--reproduction FILE] [--actor WHO]
    # A potential Dex-level issue, sanitised, into the outbox the research
    # consumer reads, and a reference in the ledger so the mission shows what
    # it raised.
    shift
    FB_ARGS=() FB_JSON="" FB_ACTOR="${DX_MISSION_ACTOR:-lead}"
    while [[ $# -gt 0 ]]; do
      case "$1" in
        --json) FB_JSON="${2:-}"; FB_ARGS+=(--json "${2:-}"); shift 2 ;;
        --patch|--reproduction) FB_ARGS+=("$1" "${2:-}"); shift 2 ;;
        --actor) FB_ACTOR="${2:-lead}"; shift 2 ;;
        *) echo "Usage: mission.sh <session-id> feedback --json '{...}' [--patch FILE] [--reproduction FILE] [--actor WHO]" >&2; exit 2 ;;
      esac
    done
    [[ -n "$FB_JSON" ]] || { echo "Usage: mission.sh <session-id> feedback --json '{...}' [--patch FILE] [--reproduction FILE] [--actor WHO]" >&2; exit 2; }
    FB_OUT=$(dx_feedback_outbox submit "${FB_ARGS[@]}") || exit $?
    FB_REF=$(printf '%s' "$FB_OUT" | FB_JSON="$FB_JSON" python3 -c 'import json, os, sys
out = json.load(sys.stdin)
fields = json.loads(os.environ["FB_JSON"])
print(json.dumps({"id": out.get("id"), "deduplicated": out.get("deduplicated"), "mechanism": str(fields.get("mechanism", ""))[:160], "state": out.get("state")}))')
    dx_mission_write "$SESSION_ID" record feedback-ref --actor "$FB_ACTOR" --json "$FB_REF" >/dev/null
    printf '%s\n' "$FB_OUT"
    ;;
  *)
    echo "Usage: mission.sh <session-id> <init|record|lease|observe|feedback|show|verify|rebuild> [args]" >&2
    exit 2
    ;;
esac
