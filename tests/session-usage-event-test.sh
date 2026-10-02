#!/usr/bin/env bash
set -euo pipefail

# At session end the hook reads the provider transcript named in its payload
# and writes one session.usage event with the deduplicated token totals, per
# agent, into the run journal. When no transcript is available the event still
# appears and says so; it never invents zeros.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-session-usage-event-test.XXXXXX")"
cleanup() { chmod -R u+w "$TMP_DIR" 2>/dev/null || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RUN_ROOT="$TMP_DIR/runs"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$DX_RUN_ROOT"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

REPO="$TMP_DIR/repo"
mkdir -p "$REPO"
git init -q "$REPO"
git -C "$REPO" config user.email "dex@example.com"
git -C "$REPO" config user.name "Dex Test"
printf 'project\n' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" -c commit.gpgsign=false commit -q -m "init"

# A provider transcript with one subagent, laid out the way Claude Code does it.
PROJ="$TMP_DIR/projects/-fake"
mkdir -p "$PROJ/claude-1/subagents"
cp "$ROOT/tests/fixtures/usage/with-subagents/main.jsonl" "$PROJ/claude-1.jsonl"
cp "$ROOT/tests/fixtures/usage/with-subagents/subagents/"* "$PROJ/claude-1/subagents/"

jget() {
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2"
}

run_hook() {
  local sid="$1" payload="$2"
  mkdir -p "$(dirname "$(dx_times_file "$sid")")"
  printf 'start:1\n' > "$(dx_times_file "$sid")"
  (cd "$REPO" && printf '%s' "$payload" | DEX_SESSION_ID="$sid" bash "$ROOT/hooks/session-end.sh")
}

# ── transcript present: totals, dedup, per-agent attribution ───────────────
SID="usage-event-session"
RUN_ID="$(dx_run_prepare "$SID" "$REPO" "test" "session-usage" "issue-1" "dx test")"
[[ -n "$RUN_ID" ]] || assert_at $LINENO
run_hook "$SID" "{\"session_id\":\"claude-1\",\"transcript_path\":\"$PROJ/claude-1.jsonl\",\"hook_event_name\":\"SessionEnd\"}"
EVENTS="$(dx_run_events_file "$RUN_ID")"
[[ -s "$EVENTS" ]] || assert_at $LINENO
USAGE_LINE="$(grep '"type": *"session.usage"' "$EVENTS" | tail -1)"
[[ -n "$USAGE_LINE" ]] || assert_at $LINENO
[[ "$(jget "$USAGE_LINE" 'd["data"]["available"]')" == "True" ]] || assert_at $LINENO
[[ "$(jget "$USAGE_LINE" 'd["data"]["requests"]')" == "2" ]] || assert_at $LINENO
[[ "$(jget "$USAGE_LINE" 'd["data"]["totals"]["output_tokens"]')" == "60" ]] || assert_at $LINENO
[[ "$(jget "$USAGE_LINE" 'd["data"]["totals"]["prompt_tokens_total"]')" == "11502" ]] || assert_at $LINENO
[[ "$(jget "$USAGE_LINE" 'd["data"]["by_agent"]["abc"]["agent_type"]')" == "dx-implementer" ]] || assert_at $LINENO
[[ "$(jget "$USAGE_LINE" 'd["data"]["complete"]')" == "True" ]] || assert_at $LINENO
[[ "$(jget "$USAGE_LINE" 'd["data"]["usage_schema"]')" == "anthropic-exclusive" ]] || assert_at $LINENO
[[ "$(jget "$USAGE_LINE" 'd["data"]["provider_session_id"]')" == "claude-1" ]] || assert_at $LINENO

# The full collector output is kept beside the journal for later analysis.
USAGE_FILE="$(jget "$USAGE_LINE" 'd["data"]["usage_file"]')"
[[ -s "$USAGE_FILE" ]] || assert_at $LINENO
[[ "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["totals"]["output_tokens"])' "$USAGE_FILE")" == "60" ]] || assert_at $LINENO

# ── no transcript: the event says unavailable instead of reporting zero ────
SID2="usage-event-session-2"
RUN_ID2="$(dx_run_prepare "$SID2" "$REPO" "test" "session-usage-2" "issue-2" "dx test")"
run_hook "$SID2" '{"session_id":"claude-2","hook_event_name":"SessionEnd"}'
EVENTS2="$(dx_run_events_file "$RUN_ID2")"
USAGE_LINE2="$(grep '"type": *"session.usage"' "$EVENTS2" | tail -1)"
[[ -n "$USAGE_LINE2" ]] || assert_at $LINENO
[[ "$(jget "$USAGE_LINE2" 'd["data"]["available"]')" == "False" ]] || assert_at $LINENO
[[ "$(jget "$USAGE_LINE2" '"totals" in d["data"]')" == "False" ]] || assert_at $LINENO

# ── lifecycle sessions trim the memory store on the way out ────────────────
export DX_MEMORY_STORE_DIR="$TMP_DIR/memstore"
printf '{"lesson":"README.md is the only file in this fixture","evidence":"README.md","scope":"repo","type":"fact"}\n' > "$TMP_DIR/obs.jsonl"
python3 "$ROOT/scripts/memory_store.py" "$DX_MEMORY_STORE_DIR" ingest --repo "$REPO" --source test "$TMP_DIR/obs.jsonl" > /dev/null
SID3="usage-event-session-3"
RUN_ID3="$(dx_run_prepare "$SID3" "$REPO" "test" "session-usage-3" "issue-3" "dx test")"
[[ -n "$RUN_ID3" ]] || assert_at $LINENO
mkdir -p "$(dirname "$(dx_times_file "$SID3")")"
printf 'start:1\n' > "$(dx_times_file "$SID3")"
(cd "$REPO" && printf '%s' '{"session_id":"claude-3","hook_event_name":"SessionEnd"}' \
  | DEX_SESSION_ID="$SID3" DEX_LOOP_ACTIVE=1 bash "$ROOT/hooks/session-end.sh")
[[ -n "$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1])).get("last_maintained_at",""))' "$DX_MEMORY_STORE_DIR/entries.json")" ]] || assert_at $LINENO
[[ -s "$DX_MEMORY_STORE_DIR/maintenance.log" ]] || assert_at $LINENO
# A plain session (no lifecycle, no mission) leaves the store alone.
rm -f "$DX_MEMORY_STORE_DIR/maintenance.log"
SID4="usage-event-session-4"
RUN_ID4="$(dx_run_prepare "$SID4" "$REPO" "test" "session-usage-4" "issue-4" "dx test")"
[[ -n "$RUN_ID4" ]] || assert_at $LINENO
run_hook "$SID4" '{"session_id":"claude-4","hook_event_name":"SessionEnd"}'
[[ ! -e "$DX_MEMORY_STORE_DIR/maintenance.log" ]] || assert_at $LINENO

echo "session-usage-event-test: ok"
