#!/usr/bin/env bash
set -euo pipefail

# Mission mode is the default for a lifecycle launch; DEX_ORCHESTRATION_MODE=legacy
# opts out. The provider passes the three helper roles with --agents,
# exports DX_MISSION_ACTIVE and the helper caps to the launched process, and
# initialises the mission ledger once for the session. A legacy launch, or a
# session-only launch, gets none of that: same flags, same environment, no
# ledger.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-mission-launch-test.XXXXXX")"
cleanup() { chmod -R u+w "$TMP_DIR" 2>/dev/null || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

mkdir -p "$TMP_DIR/home" "$TMP_DIR/bin" "$TMP_DIR/state" "$TMP_DIR/loops"
cat > "$TMP_DIR/bin/claude" <<'STUB'
#!/usr/bin/env bash
printf '%s\n' "$@" > "$TEST_RECORD.args"
env | sort > "$TEST_RECORD.env"
exit 0
STUB
chmod +x "$TMP_DIR/bin/claude"

REPO="$TMP_DIR/repo"
mkdir -p "$REPO"
git init -q -b main "$REPO"
git -C "$REPO" config user.email "dex@example.com"
git -C "$REPO" config user.name "Dex Test"
printf 'project\n' > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" -c commit.gpgsign=false commit -q -m "init"
HEAD_SHA="$(git -C "$REPO" rev-parse HEAD)"

SID="mission-launch-session"
LEDGER="$TMP_DIR/state/$SID.mission"

cat > "$TMP_DIR/scenario.sh" <<'SH'
set -eu
source "$DEX_DIR/lib/common.sh"
cd "$TEST_REPO"
dx_provider_claude "$@"
SH

launch() {
  # launch <record> [NAME=VALUE…] -- <claude args…>
  local record="$1"; shift
  local -a env_pairs=()
  while [[ $# -gt 0 && "$1" != "--" ]]; do env_pairs+=("$1"); shift; done
  [[ "${1:-}" == "--" ]] && shift
  env -i HOME="$TMP_DIR/home" PATH="$TMP_DIR/bin:/usr/bin:/bin:/usr/sbin:/sbin:/opt/homebrew/bin:/usr/local/bin" \
    DEX_DIR="$ROOT" TMPDIR="$TMP_DIR" DX_STATE_DIR="$TMP_DIR/state" DX_LOOP_DIR="$TMP_DIR/loops" \
    DX_PROVIDER_ENGINE=claude DEX_SESSION_ID="$SID" TEST_REPO="$REPO" TEST_RECORD="$record" \
    "${env_pairs[@]}" bash "$TMP_DIR/scenario.sh" "$@" > "$record.out" 2> "$record.err" \
    || { cat "$record.err" >&2; fail "launch failed: $record"; }
}
has_arg() { grep -qxF -- "$2" "$1.args"; }
agents_json() {
  python3 - "$1.args" <<'PY'
import sys
args = open(sys.argv[1]).read().split("\n")
for index, value in enumerate(args):
    if value == "--agents":
        print(args[index + 1])
        break
PY
}
env_value() { sed -n "s/^$2=//p" "$1.env"; }

# ── a Codex-engine lifecycle is a mission too, without the Claude-only roles ─
(
  # shellcheck disable=SC1091
  source "$ROOT/lib/common.sh"
  DX_PROVIDER_ENGINE=codex DEX_LOOP_ACTIVE=1 DEX_SESSION_ID=s __dx_provider_mission_launch || exit 1
  if DX_PROVIDER_ENGINE=codex __dx_provider_mission_roles_supported; then exit 1; fi
  if DX_PROVIDER_ENGINE=codex-plugin __dx_provider_mission_roles_supported; then exit 1; fi
  DX_PROVIDER_ENGINE=claude __dx_provider_mission_roles_supported || exit 1
  DX_PROVIDER_ENGINE=ccr __dx_provider_mission_roles_supported || exit 1
  DX_PROVIDER_ENGINE=claude DEX_LOOP_ACTIVE=1 DEX_SESSION_ID=s __dx_provider_mission_launch || exit 1
) || assert_at $LINENO

# ── legacy launch, chosen explicitly: nothing changes ──────────────────────
launch "$TMP_DIR/legacy" DEX_ORCHESTRATION_MODE=legacy DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=2 -- --model test "Phase 2"
! has_arg "$TMP_DIR/legacy" "--agents" || assert_at $LINENO
[[ -z "$(env_value "$TMP_DIR/legacy" DX_MISSION_ACTIVE)" ]] || assert_at $LINENO
[[ ! -e "$LEDGER" ]] || assert_at $LINENO
has_arg "$TMP_DIR/legacy" "Phase 2" || assert_at $LINENO

# ── mission launch: roles, flags, caps and a ledger ────────────────────────
# A plain lifecycle launch is a mission launch: no variable needed.
launch "$TMP_DIR/mission" DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=2 -- --model test "Phase 2"
has_arg "$TMP_DIR/mission" "--agents" || assert_at $LINENO
has_arg "$TMP_DIR/mission" "Phase 2" || assert_at $LINENO
AGENTS="$(agents_json "$TMP_DIR/mission")"
[[ -n "$AGENTS" ]] || assert_at $LINENO
python3 - "$AGENTS" <<'PY'
import json, sys
agents = json.loads(sys.argv[1])
assert set(agents) == {"dx-implementer", "dx-investigator", "dx-reviewer"}, set(agents)
for name, spec in agents.items():
    assert spec.get("description") and spec.get("prompt"), name
    assert "mission-delegation.md" in spec["prompt"], name
for name in ("dx-investigator", "dx-reviewer"):
    assert {"Edit", "Write", "NotebookEdit"} <= set(agents[name].get("disallowedTools", [])), name
assert "Edit" not in agents["dx-implementer"].get("disallowedTools", [])
assert "isolation" not in agents["dx-implementer"]
PY
[[ "$(env_value "$TMP_DIR/mission" DX_MISSION_ACTIVE)" == "1" ]] || assert_at $LINENO
[[ "$(env_value "$TMP_DIR/mission" DEX_ORCHESTRATION_MODE)" == "mission" ]] || assert_at $LINENO
[[ "$(env_value "$TMP_DIR/mission" CLAUDE_CODE_MAX_SUBAGENT_SPAWN_DEPTH)" == "1" ]] || assert_at $LINENO
[[ "$(env_value "$TMP_DIR/mission" CLAUDE_CODE_MAX_CONCURRENT_SUBAGENTS)" == "2" ]] || assert_at $LINENO
[[ -f "$LEDGER/current.json" ]] || assert_at $LINENO
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }
[[ "$(jget "$LEDGER/current.json" 'd["mission"]["mission_id"]')" == "$SID" ]] || assert_at $LINENO
[[ "$(jget "$LEDGER/current.json" 'd["mission"]["branch"]')" == "main" ]] || assert_at $LINENO
[[ "$(jget "$LEDGER/current.json" 'd["mission"]["base_revision"]')" == "$HEAD_SHA" ]] || assert_at $LINENO
[[ "$(jget "$LEDGER/current.json" 'd["generation"]')" == "1" ]] || assert_at $LINENO

# ── a later phase of the same mission does not re-initialise the ledger ────
launch "$TMP_DIR/mission3" DEX_ORCHESTRATION_MODE=mission DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=3 -- --model test "Phase 3"
has_arg "$TMP_DIR/mission3" "--agents" || assert_at $LINENO
[[ "$(jget "$LEDGER/current.json" 'd["generation"]')" == "1" ]] || assert_at $LINENO
DX_STATE_DIR="$TMP_DIR/state" DX_LOOP_DIR="$TMP_DIR/loops" HOME="$TMP_DIR/home" DEX_DIR="$ROOT" \
  bash "$ROOT/bin/mission.sh" "$SID" verify > /dev/null

# ── a caller's own --agents is kept, not doubled ───────────────────────────
launch "$TMP_DIR/custom" DEX_ORCHESTRATION_MODE=mission DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=2 -- --agents '{"mine":{"description":"x","prompt":"y"}}' "Phase 2"
[[ "$(grep -cxF -- '--agents' "$TMP_DIR/custom.args")" == "1" ]] || assert_at $LINENO
[[ "$(agents_json "$TMP_DIR/custom")" == '{"mine":{"description":"x","prompt":"y"}}' ]] || assert_at $LINENO

# ── session-only launches are never missions ───────────────────────────────
rm -rf "$LEDGER"
launch "$TMP_DIR/sessiononly" DEX_ORCHESTRATION_MODE=mission DEX_SESSION_ONLY=1 -- "just a chat"
! has_arg "$TMP_DIR/sessiononly" "--agents" || assert_at $LINENO
[[ -z "$(env_value "$TMP_DIR/sessiononly" DX_MISSION_ACTIVE)" ]] || assert_at $LINENO
[[ ! -e "$LEDGER" ]] || assert_at $LINENO

echo "mission-launch-test: ok"
