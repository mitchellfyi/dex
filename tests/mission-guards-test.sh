#!/usr/bin/env bash
set -euo pipefail

# Two advisory guards fence mission helpers. mission-write-lease warns when a
# file edit comes from anyone but the current lease holder; mission-git-mutation
# warns when a subagent runs a git command that moves the tree, the index or a
# branch. Both only evaluate inside a mission (DX_MISSION_ACTIVE=1), both
# record every warning in the ledger directory, and neither blocks.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-mission-guards-test.XXXXXX")"
cleanup() { chmod -R u+w "$TMP_DIR" 2>/dev/null || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RUN_ROOT="$TMP_DIR/runs"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$DX_RUN_ROOT"
HANDLER="$ROOT/hooks/guard-handler.py"

REPO="$TMP_DIR/repo"
mkdir -p "$REPO/.dex"
git init -q "$REPO"
git -C "$REPO" config user.email "dex@example.com"
git -C "$REPO" config user.name "Dex Test"
printf 'project\n' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" -c commit.gpgsign=false commit -q -m "init"

SID="mission-guards-session"
LEDGER="$DX_STATE_DIR/$SID.mission"
printf 'Build the widget.\n' > "$TMP_DIR/brief.md"
bash "$ROOT/bin/mission.sh" "$SID" init --mission-id m-1 --brief-file "$TMP_DIR/brief.md" \
  --workspace "$REPO" --branch main --base-revision "$(git -C "$REPO" rev-parse HEAD)" > /dev/null
bash "$ROOT/bin/mission.sh" "$SID" lease acquire --holder impl-1 --scope lib/ \
  --revision "$(git -C "$REPO" rev-parse HEAD)" > /dev/null

# run_guard <event> <payload-json> [mission:0|1] -> GUARD_OUT, GUARD_RC
run_guard() {
  local event="$1" payload="$2" mission="${3:-1}"
  set +e
  if [[ "$mission" == 1 ]]; then
    GUARD_OUT="$(cd "$REPO" && printf '%s' "$payload" | env DEX_GUARD_EVENT="$event" DX_MISSION_ACTIVE=1 DEX_SESSION_ID="$SID" python3 "$HANDLER" 2>&1)"
  else
    GUARD_OUT="$(cd "$REPO" && printf '%s' "$payload" | env DEX_GUARD_EVENT="$event" DEX_SESSION_ID="$SID" python3 "$HANDLER" 2>&1)"
  fi
  GUARD_RC=$?
  set -e
}
edit_payload() {
  # edit_payload <agent_id|""> <agent_type|""> <path>
  python3 -c 'import json,sys
p={"session_id":"c1","hook_event_name":"PreToolUse","tool_name":"Edit","tool_input":{"file_path":sys.argv[3],"old_string":"a","new_string":"b"}}
if sys.argv[1]: p["agent_id"]=sys.argv[1]; p["agent_type"]=sys.argv[2]
print(json.dumps(p))' "$1" "$2" "$3"
}
bash_payload() {
  python3 -c 'import json,sys
p={"session_id":"c1","hook_event_name":"PreToolUse","tool_name":"Bash","tool_input":{"command":sys.argv[3]}}
if sys.argv[1]: p["agent_id"]=sys.argv[1]; p["agent_type"]=sys.argv[2]
print(json.dumps(p))' "$1" "$2" "$3"
}
violations() { [[ -f "$LEDGER/violations.jsonl" ]] && wc -l < "$LEDGER/violations.jsonl" | tr -d ' ' || echo 0; }

# ── the lease holder edits freely ──────────────────────────────────────────
run_guard file "$(edit_payload impl-1 dx-implementer "$REPO/lib/a.sh")"
[[ "$GUARD_RC" == 0 ]] || assert_at $LINENO
[[ "$GUARD_OUT" != *mission-write-lease* ]] || assert_at $LINENO
[[ "$(violations)" == 0 ]] || assert_at $LINENO

# ── another helper editing is warned, by name, and the attempt is recorded ─
run_guard file "$(edit_payload impl-2 dx-implementer "$REPO/lib/a.sh")"
[[ "$GUARD_RC" == 0 ]] || assert_at $LINENO
[[ "$GUARD_OUT" == *mission-write-lease* ]] || assert_at $LINENO
[[ "$GUARD_OUT" == *"held by impl-1"* ]] || assert_at $LINENO
[[ "$(violations)" == 1 ]] || assert_at $LINENO
python3 - "$LEDGER/violations.jsonl" <<'PY'
import json, sys
row = json.loads(open(sys.argv[1]).readline())
assert row["guard"] == "mission-write-lease", row
assert row["actor"] == "impl-2" and row["holder"] == "impl-1", row
assert row["tool"] == "Edit" and row["detail"].endswith("lib/a.sh"), row
PY

# ── the lead editing while a helper holds the lease is warned too ──────────
run_guard file "$(edit_payload "" "" "$REPO/lib/a.sh")"
[[ "$GUARD_OUT" == *mission-write-lease* ]] || assert_at $LINENO
[[ "$(violations)" == 2 ]] || assert_at $LINENO

# ── a subagent's git mutation is warned; a read-only git command is not ────
run_guard bash "$(bash_payload impl-1 dx-implementer "git commit -m 'wip'")"
[[ "$GUARD_RC" == 0 ]] || assert_at $LINENO
[[ "$GUARD_OUT" == *mission-git-mutation* ]] || assert_at $LINENO
[[ "$(violations)" == 3 ]] || assert_at $LINENO
run_guard bash "$(bash_payload impl-1 dx-implementer "git status && git diff --stat")"
[[ "$GUARD_OUT" != *mission-git-mutation* ]] || assert_at $LINENO
run_guard bash "$(bash_payload inv-1 dx-investigator "cd lib && git -C .. stash")"
[[ "$GUARD_OUT" == *mission-git-mutation* ]] || assert_at $LINENO
run_guard bash "$(bash_payload inv-1 dx-investigator "git checkout -- README.md")"
[[ "$GUARD_OUT" == *mission-git-mutation* ]] || assert_at $LINENO
[[ "$(violations)" == 5 ]] || assert_at $LINENO

# ── the lead's own git commands are its business ───────────────────────────
run_guard bash "$(bash_payload "" "" "git commit -m 'checkpoint'")"
[[ "$GUARD_OUT" != *mission-git-mutation* ]] || assert_at $LINENO
[[ "$(violations)" == 5 ]] || assert_at $LINENO

# ── with no lease held, nobody is warned about editing ─────────────────────
bash "$ROOT/bin/mission.sh" "$SID" lease release --holder impl-1 > /dev/null
run_guard file "$(edit_payload impl-2 dx-implementer "$REPO/lib/a.sh")"
[[ "$GUARD_OUT" != *mission-write-lease* ]] || assert_at $LINENO

# ── outside a mission neither guard evaluates ──────────────────────────────
bash "$ROOT/bin/mission.sh" "$SID" lease acquire --holder impl-1 --scope lib/ --revision x > /dev/null
run_guard file "$(edit_payload impl-2 dx-implementer "$REPO/lib/a.sh")" 0
[[ "$GUARD_OUT" != *mission-* ]] || assert_at $LINENO
run_guard bash "$(bash_payload impl-1 dx-implementer "git commit -m x")" 0
[[ "$GUARD_OUT" != *mission-* ]] || assert_at $LINENO
[[ "$(violations)" == 5 ]] || assert_at $LINENO

# ── the guard files are advisory and scoped ────────────────────────────────
for g in mission-write-lease mission-git-mutation; do
  grep -q '^action: warn$' "$ROOT/hooks/guards/$g.md" || assert_at $LINENO
  grep -q '^env_var: DX_MISSION_ACTIVE$' "$ROOT/hooks/guards/$g.md" || assert_at $LINENO
done

# Every warning the agent saw is logged for the lifecycle harvest.
WARNINGS_LOG="$DX_LOOP_DIR"/"$SID.guard-warnings.jsonl"
[[ -s "$WARNINGS_LOG" ]] || assert_at $LINENO
grep -q '"guard":"mission-' "$WARNINGS_LOG" || assert_at $LINENO
python3 -c 'import json,sys; [json.loads(l) for l in open(sys.argv[1]) if l.strip()]' "$WARNINGS_LOG" || assert_at $LINENO

echo "mission-guards-test: ok"
