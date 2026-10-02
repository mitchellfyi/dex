#!/usr/bin/env bash
set -euo pipefail

# The A/B launcher runs one arm of the comparison from an isolated trial root:
# its own Dex checkout, state, journals, memory store, feedback outbox and
# auto-memory directory, with the arm's settings supplied through a `claude`
# shim so the operator's user settings and global hooks never load. A dry run
# prints that plan without launching anything. The manifest is the frozen
# contract: its hash is recorded, and every task names its protected evaluator.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-ab-launch-test.XXXXXX")"
cleanup() { chmod -R u+w "$TMP_DIR" 2>/dev/null || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT
export HOME="$TMP_DIR/home"
mkdir -p "$HOME"
LAUNCH="$ROOT/research/ab/launch-arm.sh"
MANIFEST="$ROOT/research/ab/manifest.json"
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

# ── the manifest is well-formed and names what the brief requires ──────────
python3 - "$MANIFEST" "$ROOT" <<'PY'
import json, os, sys
m = json.load(open(sys.argv[1]))
root = sys.argv[2]
assert m["schema_version"] == 1
for key in ("tasks", "arms", "budget", "metrics", "stopping_rule", "promotion_criteria", "ordering", "exclusions"):
    assert key in m, key
assert set(m["arms"]) == {"A", "B0"}
assert m["arms"]["B0"]["orchestration_mode"] == "mission" and m["arms"]["A"]["orchestration_mode"] == "legacy"
assert m["budget"]["max_concurrent_sessions_total"] <= 3
for task in m["tasks"]:
    assert os.path.isfile(os.path.join(root, "research/scenarios", task["scenario"], "rubric.sh")), task
    assert task["endpoint"] == "phase-4-verified"
    assert task["max_minutes_per_arm"] > 0
PY

# ── dry run: the plan, no launch ───────────────────────────────────────────
TRIAL="$TMP_DIR/trial"
bash "$LAUNCH" --arm B0 --task buggy-code-fix --trial-root "$TRIAL" --dex-dir "$ROOT" --max-minutes 5 --dry-run > "$TMP_DIR/plan.json"
[[ "$(jget "$TMP_DIR/plan.json" 'd["arm"]')" == "B0" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/plan.json" 'd["env"]["DEX_ORCHESTRATION_MODE"]')" == "mission" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/plan.json" 'd["env"]["DEX_DIR"]')" == "$ROOT" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/plan.json" 'd["env"]["DX_STATE_DIR"]')" == "$TRIAL/buggy-code-fix/B0/state" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/plan.json" 'd["env"]["DX_MEMORY_STORE_DIR"]')" == "$TRIAL/buggy-code-fix/B0/memory" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/plan.json" 'd["env"]["DEX_MAX_ACTIVE_HEAVY"]')" == "1" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/plan.json" 'd["dry_run"]')" == "True" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/plan.json" 'd["manifest_sha256"] != ""')" == "True" ]] || assert_at $LINENO
SPEC="$(jget "$TMP_DIR/plan.json" 'd["spec"]')"
[[ -f "$SPEC" ]] || assert_at $LINENO
[[ "$(jget "$SPEC" 'd["workflow"]["requires_plan_approval"]')" == "False" ]] || assert_at $LINENO
[[ "$(jget "$SPEC" 'd["source"]["type"]')" == "task" ]] || assert_at $LINENO
[[ "$(jget "$SPEC" 'd["repository"]["working_directory"]')" == "$TRIAL/buggy-code-fix/B0/repo" ]] || assert_at $LINENO
assert_contains "5 bugs" "$SPEC"
# The fixture repository exists, has a commit, and a remote default branch.
REPO="$TRIAL/buggy-code-fix/B0/repo"
[[ "$(git -C "$REPO" rev-parse --abbrev-ref HEAD)" == "main" ]] || assert_at $LINENO
git -C "$REPO" rev-parse --verify origin/main > /dev/null || assert_at $LINENO
# The shim wraps the real binary with the arm's settings and excludes user settings.
SHIM="$(jget "$TMP_DIR/plan.json" 'd["shim"]')"
[[ -x "$SHIM" ]] || assert_at $LINENO
assert_contains "setting-sources project,local" "$SHIM"
assert_contains "arm-settings.json" "$SHIM"
ARM_SETTINGS="$(jget "$TMP_DIR/plan.json" 'd["arm_settings"]')"
[[ "$(jget "$ARM_SETTINGS" 'd["autoMemoryDirectory"]')" == "$TRIAL/buggy-code-fix/B0/auto-memory" ]] || assert_at $LINENO
[[ "$(jget "$ARM_SETTINGS" '"SubagentStart" in d["hooks"]')" == "True" ]] || assert_at $LINENO
# Nothing was launched: no logs, no state.
[[ ! -s "$TRIAL/buggy-code-fix/B0/logs/run.out" ]] || assert_at $LINENO
[[ -z "$(ls -A "$TRIAL/buggy-code-fix/B0/state" 2>/dev/null)" ]] || assert_at $LINENO

# A legacy arm opts out explicitly now that mission is the default.
bash "$LAUNCH" --arm A --task buggy-code-fix --trial-root "$TRIAL" --dex-dir "$ROOT" --max-minutes 5 --dry-run > "$TMP_DIR/plan-a.json"
[[ "$(jget "$TMP_DIR/plan-a.json" 'd["env"]["DEX_ORCHESTRATION_MODE"]')" == "legacy" ]] || assert_at $LINENO

# ── the collector reports unknowns, never zeros, for an arm that did not run ─
bash "$ROOT/research/ab/collect.sh" "$TRIAL/buggy-code-fix/B0" > "$TMP_DIR/metrics.json"
[[ "$(jget "$TMP_DIR/metrics.json" 'd["arm"]')" == "B0" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/metrics.json" 'd["status"]')" == "not-run" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/metrics.json" 'd["tokens"]["available"]')" == "False" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/metrics.json" 'd["acceptance"]["available"]')" == "False" ]] || assert_at $LINENO

# ── the memory on/off comparison: one store, retrieval switched, own label ──
STORE_SHARED="$TMP_DIR/shared-store"
mkdir -p "$STORE_SHARED"
bash "$LAUNCH" --arm B0 --task buggy-code-fix --trial-root "$TMP_DIR/trial-mem" --dex-dir "$ROOT" --memory-store "$STORE_SHARED" --retrieval off --label mem-off --dry-run > "$TMP_DIR/plan-off.json" 2>&1 || { cat "$TMP_DIR/plan-off.json" >&2; assert_at $LINENO; }
[[ "$(jget "$TMP_DIR/plan-off.json" 'd["env"]["DX_MEMORY_STORE_DIR"]')" == "$STORE_SHARED" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/plan-off.json" 'd["env"]["DEX_MEMORY_RETRIEVAL"]')" == "0" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/plan-off.json" 'd["arm_dir"]')" == "$TMP_DIR/trial-mem/buggy-code-fix/mem-off" ]] || assert_at $LINENO
bash "$LAUNCH" --arm B0 --task buggy-code-fix --trial-root "$TMP_DIR/trial-mem" --dex-dir "$ROOT" --memory-store "$STORE_SHARED" --retrieval on --label mem-on --dry-run > "$TMP_DIR/plan-on.json" 2>&1 || assert_at $LINENO
[[ "$(jget "$TMP_DIR/plan-on.json" 'd["env"]["DEX_MEMORY_RETRIEVAL"]')" == "1" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/plan-on.json" 'd["arm_dir"]')" == "$TMP_DIR/trial-mem/buggy-code-fix/mem-on" ]] || assert_at $LINENO
if bash "$LAUNCH" --arm B0 --task buggy-code-fix --trial-root "$TMP_DIR/trial-mem" --dex-dir "$ROOT" --retrieval sometimes --dry-run > /dev/null 2>&1; then assert_at $LINENO; fi

echo "ab-launch-test: ok"
