#!/usr/bin/env bash
set -euo pipefail

# The mission ledger is the durable record a mission is rebuilt from: an
# append-only records.jsonl with a monotonic generation, a current.json
# snapshot derived from it, and an exclusive source-write lease. It is written
# the way completion receipts are (temp file, fsync, replace, mode 0600) and
# read only when the files are still private. Each ledger write that happens
# inside a run also leaves a mission.* event in the run journal.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-mission-ledger-test.XXXXXX")"
cleanup() { chmod -R u+w "$TMP_DIR" 2>/dev/null || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RUN_ROOT="$TMP_DIR/runs"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$DX_RUN_ROOT"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

jget() {
  python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"
}
jline() {
  python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2"
}

SID="mission-ledger-session"
MISSION="bash $ROOT/bin/mission.sh $SID"
LEDGER="$DX_STATE_DIR/$SID.mission"
printf 'Build the widget.\n' > "$TMP_DIR/brief.md"

# ── init writes the mission record and a private snapshot ──────────────────
$MISSION init --mission-id m-1 --brief-file "$TMP_DIR/brief.md" \
  --workspace "$TMP_DIR/repo" --branch worktree-task-1 --base-revision abc123 \
  --source-tickets GH-1,GH-2 > /dev/null
[[ -f "$LEDGER/records.jsonl" ]] || assert_at $LINENO
[[ -f "$LEDGER/current.json" ]] || assert_at $LINENO
[[ "$(stat -f '%Lp' "$LEDGER/current.json" 2>/dev/null || stat -c '%a' "$LEDGER/current.json")" == "600" ]] || assert_at $LINENO
[[ "$(wc -l < "$LEDGER/records.jsonl" | tr -d ' ')" == "1" ]] || assert_at $LINENO
[[ "$(jget "$LEDGER/current.json" 'd["schema_version"]')" == "1" ]] || assert_at $LINENO
[[ "$(jget "$LEDGER/current.json" 'd["mission"]["mission_id"]')" == "m-1" ]] || assert_at $LINENO
[[ "$(jget "$LEDGER/current.json" 'd["mission"]["source_tickets"]')" == "['GH-1', 'GH-2']" ]] || assert_at $LINENO
[[ "$(jget "$LEDGER/current.json" 'd["generation"]')" == "1" ]] || assert_at $LINENO
[[ "$(jline "$(head -1 "$LEDGER/records.jsonl")" 'd["kind"]')" == "mission" ]] || assert_at $LINENO

# ── a decision appends a record and advances the generation ────────────────
$MISSION record decision --actor lead \
  --json '{"summary":"one PR","rationale":"coherent feature","consequences":"larger review"}' > /dev/null
[[ "$(jget "$LEDGER/current.json" 'd["generation"]')" == "2" ]] || assert_at $LINENO
[[ "$(jget "$LEDGER/current.json" 'len(d["decisions"])')" == "1" ]] || assert_at $LINENO
[[ "$(jline "$(tail -1 "$LEDGER/records.jsonl")" 'd["actor"]')" == "lead" ]] || assert_at $LINENO

# An unknown kind is refused and leaves no trace.
set +e
$MISSION record bogus --json '{}' > /dev/null 2>&1
RC=$?
set -e
[[ "$RC" == "2" ]] || assert_at $LINENO
[[ "$(wc -l < "$LEDGER/records.jsonl" | tr -d ' ')" == "2" ]] || assert_at $LINENO

# ── the write lease is exclusive and attributed ────────────────────────────
$MISSION lease acquire --holder lead --scope lib/,tests/ --revision abc123 > /dev/null
[[ "$(jget "$LEDGER/current.json" 'd["lease"]["holder"]')" == "lead" ]] || assert_at $LINENO
set +e
$MISSION lease acquire --holder agent-x --scope lib/ --revision abc123 > "$TMP_DIR/lease.out" 2>&1
RC=$?
set -e
[[ "$RC" == "3" ]] || assert_at $LINENO
assert_contains "held by lead" "$TMP_DIR/lease.out"
set +e
$MISSION lease release --holder agent-x > /dev/null 2>&1
RC=$?
set -e
[[ "$RC" == "3" ]] || assert_at $LINENO
[[ "$(jget "$LEDGER/current.json" 'd["lease"]["holder"]')" == "lead" ]] || assert_at $LINENO
$MISSION lease release --holder lead --revision-after def456 > /dev/null
[[ "$(jget "$LEDGER/current.json" 'd["lease"]')" == "None" ]] || assert_at $LINENO
$MISSION lease acquire --holder agent-x --scope lib/ --revision def456 > /dev/null
[[ "$(jget "$LEDGER/current.json" 'd["lease"]["holder"]')" == "agent-x" ]] || assert_at $LINENO
[[ "$($MISSION lease show | python3 -c 'import json,sys; print(json.load(sys.stdin)["holder"])')" == "agent-x" ]] || assert_at $LINENO

# ── assignments are keyed by id and keep their latest status ───────────────
$MISSION record assignment --actor lead \
  --json '{"id":"a-1","agent_id":"agent-x","agent_type":"dx-implementer","scope":["lib/"],"status":"STARTED"}' > /dev/null
$MISSION record assignment --actor agent-x \
  --json '{"id":"a-1","status":"IMPLEMENTED","result":"done","revision_after":"def456"}' > /dev/null
[[ "$(jget "$LEDGER/current.json" 'd["assignments"]["a-1"]["status"]')" == "IMPLEMENTED" ]] || assert_at $LINENO
[[ "$(jget "$LEDGER/current.json" 'd["assignments"]["a-1"]["agent_type"]')" == "dx-implementer" ]] || assert_at $LINENO

# ── verify and rebuild: the snapshot is derived, the log is the truth ──────
$MISSION verify > /dev/null
cp "$LEDGER/current.json" "$TMP_DIR/current.before"
rm "$LEDGER/current.json"
$MISSION rebuild > /dev/null
python3 - "$TMP_DIR/current.before" "$LEDGER/current.json" <<'PY'
import json, sys
a, b = (json.load(open(p)) for p in sys.argv[1:3])
a.pop("snapshot_at", None); b.pop("snapshot_at", None)
assert a == b, (a, b)
PY
GEN_BEFORE="$(jget "$LEDGER/current.json" 'd["generation"]')"
$MISSION record decision --actor lead --json '{"summary":"after rebuild"}' > /dev/null
[[ "$(jget "$LEDGER/current.json" 'd["generation"]')" == "$((GEN_BEFORE + 1))" ]] || assert_at $LINENO

# A corrupt log line fails verification instead of being skipped quietly.
printf 'not json\n' >> "$LEDGER/records.jsonl"
set +e
$MISSION verify > /dev/null 2>&1
RC=$?
set -e
[[ "$RC" == "1" ]] || assert_at $LINENO

# A snapshot that is no longer private is not trusted.
chmod 644 "$LEDGER/current.json"
set +e
$MISSION show > /dev/null 2>&1
RC=$?
set -e
[[ "$RC" == "2" ]] || assert_at $LINENO
chmod 600 "$LEDGER/current.json"

# ── inside a run, ledger writes leave mission.* events ─────────────────────
SID2="mission-ledger-session-2"
REPO="$TMP_DIR/repo2"
mkdir -p "$REPO"
git init -q "$REPO"
RUN_ID="$(dx_run_prepare "$SID2" "$REPO" "test" "mission-ledger" "issue-1" "dx test")"
bash "$ROOT/bin/mission.sh" "$SID2" init --mission-id m-2 --brief-file "$TMP_DIR/brief.md" \
  --workspace "$REPO" --branch worktree-task-2 --base-revision abc123 > /dev/null
bash "$ROOT/bin/mission.sh" "$SID2" lease acquire --holder lead --scope . --revision abc123 > /dev/null
EVENTS="$(dx_run_events_file "$RUN_ID")"
python3 - "$EVENTS" <<'PY'
import json, sys
types = [json.loads(l)["type"] for l in open(sys.argv[1]) if l.strip()]
assert "mission.started" in types, types
assert "mission.lease.acquired" in types, types
PY

echo "mission-ledger-test: ok"
