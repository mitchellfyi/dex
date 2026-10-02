#!/usr/bin/env bash
set -euo pipefail

# In a mission the SessionStart hook tells the lead what the ledger knows:
# the mission, its brief, the lease, the open assignments and where the role
# contract is. The PreCompact hook names the same things so they survive
# compaction. Neither says a word about missions outside one.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-mission-context-test.XXXXXX")"
cleanup() { chmod -R u+w "$TMP_DIR" 2>/dev/null || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RUN_ROOT="$TMP_DIR/runs"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$DX_RUN_ROOT"

REPO="$TMP_DIR/repo"
mkdir -p "$REPO"
git init -q -b worktree-task-widget "$REPO"
git -C "$REPO" config user.email "dex@example.com"
git -C "$REPO" config user.name "Dex Test"
printf 'project\n' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" -c commit.gpgsign=false commit -q -m "init"

SID="mission-context-session"
printf 'Build the widget.\n' > "$TMP_DIR/brief.md"
bash "$ROOT/bin/mission.sh" "$SID" init --mission-id m-ctx --brief-file "$TMP_DIR/brief.md" \
  --workspace "$REPO" --branch worktree-task-widget --base-revision "$(git -C "$REPO" rev-parse HEAD)" > /dev/null
bash "$ROOT/bin/mission.sh" "$SID" lease acquire --holder impl-1 --scope lib/ --revision x > /dev/null
bash "$ROOT/bin/mission.sh" "$SID" record assignment --actor lead \
  --json '{"id":"impl-1","agent_id":"impl-1","agent_type":"dx-implementer","status":"STARTED"}' > /dev/null
bash "$ROOT/bin/mission.sh" "$SID" record assignment --actor lead \
  --json '{"id":"inv-9","agent_id":"inv-9","agent_type":"dx-investigator","status":"INVESTIGATED"}' > /dev/null

run_hook() {
  # run_hook <hook> <mission:0|1>
  if [[ "$2" == 1 ]]; then
    (cd "$REPO" && printf '{}' | DX_MISSION_ACTIVE=1 DEX_SESSION_ID="$SID" bash "$ROOT/hooks/$1")
  else
    (cd "$REPO" && printf '{}' | DEX_SESSION_ID="$SID" bash "$ROOT/hooks/$1")
  fi
}

# ── SessionStart: the mission section ──────────────────────────────────────
run_hook load-ticket-context.sh 1 > "$TMP_DIR/start.out"
assert_contains "Mission m-ctx" "$TMP_DIR/start.out"
assert_contains "$(python3 -c "import os,sys; print(os.path.abspath(sys.argv[1]))" "$TMP_DIR/brief.md")" "$TMP_DIR/start.out"
assert_contains "lease: impl-1" "$TMP_DIR/start.out"
assert_contains "impl-1 (dx-implementer) STARTED" "$TMP_DIR/start.out"
assert_not_contains "inv-9" "$TMP_DIR/start.out"
assert_contains "prompts/mission-delegation.md" "$TMP_DIR/start.out"
assert_contains "bin/mission.sh $SID" "$TMP_DIR/start.out"

run_hook load-ticket-context.sh 0 > "$TMP_DIR/start-legacy.out"
assert_not_contains "Mission" "$TMP_DIR/start-legacy.out"

# ── PreCompact: the same facts, as a compaction instruction ────────────────
run_hook pre-compact.sh 1 > "$TMP_DIR/compact.out"
assert_contains "Mission m-ctx" "$TMP_DIR/compact.out"
assert_contains "lease: impl-1" "$TMP_DIR/compact.out"
assert_contains "current.json" "$TMP_DIR/compact.out"
assert_contains "prompts/mission-delegation.md" "$TMP_DIR/compact.out"

run_hook pre-compact.sh 0 > "$TMP_DIR/compact-legacy.out"
assert_not_contains "Mission" "$TMP_DIR/compact-legacy.out"

# ── a mission with no ledger yet says so instead of inventing state ────────
rm -rf "$DX_STATE_DIR/$SID.mission"
run_hook load-ticket-context.sh 1 > "$TMP_DIR/start-empty.out"
assert_contains "no mission ledger" "$TMP_DIR/start-empty.out"

echo "mission-context-test: ok"
