#!/usr/bin/env bash
set -euo pipefail
umask 077

# The benchmark workflow (run spec workflow.name=benchmark):
#   - the phase table: starts at Phase 1, ends at Phase 3
#   - run spec normalization: no plan approval, no UI proof, Claude only
#   - the Stop hook: benchmark handoff text, the audit addendum, and a terminal
#     transition straight out of Phase 3 with a valid terminal proof
#   - dx.sh: benchmark launch text, and completion leaves the checkout alone

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
HOOK="$ROOT/hooks/phase-loop.sh"
export DEX_DIR="$ROOT"
cd "$ROOT"

# This suite may run inside a Dex lifecycle; strip what the hook reads.
unset DEX_LOOP_ACTIVE DEX_REVIEW_PASS_ACTIVE DEX_PHASE_HANDOFF DEX_LOOP_PHASE \
  DEX_LOOP_PROMISE DEX_LOOP_PROMPT DEX_LOOP_MIN_AUDITS DEX_LOOP_MAX_ITERATIONS \
  DEX_SESSION_ID DEX_WORKFLOW DEX_HEADLESS_RUN DEX_HEADLESS_REQUIRES_PLAN_APPROVAL

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-benchmark-workflow-test.XXXXXX")"
cleanup() {
  chmod -R u+w "$TMP_DIR" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_STATE_DIR="$TMP_DIR/phases"
export DX_RUN_ROOT="$TMP_DIR/runs"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
mkdir -p "$HOME" "$DX_LOOP_DIR" "$DX_STATE_DIR"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"
# shellcheck disable=SC1091
source "$ROOT/tests/review-proof-fixture.sh"

REPO="$TMP_DIR/repo"
git init -q "$REPO"
git -C "$REPO" config user.email dex@example.test
git -C "$REPO" config user.name "Dex Test"
printf '%s\n' "benchmark fixture" > "$REPO/README.md"
git -C "$REPO" add README.md
git -C "$REPO" commit -q -m "test: initialize benchmark fixture"
git -C "$REPO" branch -M main

run_hook() { # <session-id> <phase> <provider-session>
  set +e
  OUT="$(cd "$REPO" && printf '{"session_id":"%s"}' "$3" | env \
    DEX_WORKFLOW=benchmark DEX_SESSION_ID="$1" DEX_LOOP_ACTIVE=1 \
    DEX_LOOP_PHASE="$2" DEX_PHASE_HANDOFF=inline bash "$HOOK" 2>&1)"
  RC=$?
  set -e
}

start_inline_phase() { # <session-id> <phase> <audit-basename>
  local generation
  touch "$DX_LOOP_DIR/$1.active"
  printf '%s\n' "inline" > "$DX_LOOP_DIR/$1.handoff-mode"
  printf '%s\n' "$2" > "$DX_STATE_DIR/$1.phase"
  generation=$(dx_completion_issue "$1" lifecycle phase "$2")
  printf '%s:PHASE_%s_COMPLETE:%s:1:lifecycle:phase:%s\n' \
    "$2" "$2" "$ROOT/prompts/phase-audits/$3.md" "$generation" \
    > "$(dx_loop_config_file "$1")"
}

write_completion() { # <session-id> <phase>
  dx_completion_write_receipt "$1" \
    "$(dx_completion_current_generation "$1" lifecycle phase "$2")"
}

write_approved_criteria() { # <session-id>
  printf '%s\n' '{"version":1,"source":"headless-run-spec","objectives":["Exercise the benchmark lifecycle."],"acceptance_criteria":["Review is the last phase."],"verification_requirements":["Run tests/benchmark-workflow-test.sh."]}' \
    > "$(dx_review_criteria_file "$1")"
  dx_review_approve_criteria "$1" initial \
    "$(dx_review_criteria_hash "$(dx_review_criteria_file "$1")")" >/dev/null
}

# --- the phase table ---
[[ "$(dx_lifecycle_workflow)" == "ticket_to_pr" ]] || assert_at $LINENO
[[ "$(dx_lifecycle_first_phase)" == "0" ]] || assert_at $LINENO
[[ "$(dx_lifecycle_final_phase)" == "6" ]] || assert_at $LINENO
[[ "$(DEX_WORKFLOW=benchmark dx_lifecycle_workflow)" == "benchmark" ]] || assert_at $LINENO
[[ "$(DEX_WORKFLOW=benchmark dx_lifecycle_first_phase)" == "1" ]] || assert_at $LINENO
[[ "$(DEX_WORKFLOW=benchmark dx_lifecycle_final_phase)" == "3" ]] || assert_at $LINENO
# An unknown name is the default lifecycle, not a partial one.
[[ "$(DEX_WORKFLOW=bench dx_lifecycle_final_phase)" == "6" ]] || assert_at $LINENO
# workflow.phases leaves Plan or Review out; an unknown set means all three.
[[ "$(DEX_WORKFLOW=benchmark DEX_BENCHMARK_PHASES=implement,review dx_lifecycle_first_phase)" == "2" ]] \
  || assert_at $LINENO
[[ "$(DEX_WORKFLOW=benchmark DEX_BENCHMARK_PHASES=plan,implement dx_lifecycle_final_phase)" == "2" ]] \
  || assert_at $LINENO
[[ "$(DEX_WORKFLOW=benchmark DEX_BENCHMARK_PHASES=implement dx_lifecycle_first_phase)$(DEX_WORKFLOW=benchmark DEX_BENCHMARK_PHASES=implement dx_lifecycle_final_phase)" == "22" ]] \
  || assert_at $LINENO
[[ "$(DEX_WORKFLOW=benchmark DEX_BENCHMARK_PHASES=review dx_lifecycle_final_phase)" == "3" ]] \
  || assert_at $LINENO

# --- run spec normalization ---
write_spec() { # <path> <workflow-json>
  python3 - "$1" "$REPO" "$2" <<'PY'
import json
import sys
from pathlib import Path

path, repo, workflow = sys.argv[1:4]
spec = {
    "run_id": "run_bench-test",
    "repository": {"working_directory": repo, "default_branch": "main"},
    "source": {"type": "task", "title": "Benchmark task", "body": "Fix the bug."},
    "workflow": json.loads(workflow),
}
Path(path).write_text(json.dumps(spec), encoding="utf-8")
PY
}

write_spec "$TMP_DIR/bench.json" '{"name":"benchmark"}'
dx_run_spec_normalize "$TMP_DIR/bench.json" "$TMP_DIR/bench.normalized.json"
[[ "$(dx_run_spec_field "$TMP_DIR/bench.normalized.json" workflow.requires_plan_approval)" == "false" ]] \
  || assert_at $LINENO
[[ "$(dx_run_spec_field "$TMP_DIR/bench.normalized.json" workflow.requires_ui_evidence)" == "never" ]] \
  || assert_at $LINENO

write_spec "$TMP_DIR/bench-approval.json" '{"name":"benchmark","requires_plan_approval":true}'
if dx_run_spec_normalize "$TMP_DIR/bench-approval.json" "$TMP_DIR/x.json" 2>"$TMP_DIR/err"; then
  assert_at $LINENO
fi
grep -Fq "requires_plan_approval must be false for the benchmark workflow" "$TMP_DIR/err" \
  || assert_at $LINENO

python3 - "$TMP_DIR/bench.json" "$TMP_DIR/bench-codex.json" <<'PY'
import json
import sys
spec = json.load(open(sys.argv[1]))
spec["harness"] = {"name": "codex"}
json.dump(spec, open(sys.argv[2], "w"))
PY
if dx_run_spec_normalize "$TMP_DIR/bench-codex.json" "$TMP_DIR/x.json" 2>"$TMP_DIR/err"; then
  assert_at $LINENO
fi
grep -Fq "supports the claude-code harness only" "$TMP_DIR/err" || assert_at $LINENO

# workflow.phases is canonicalised, must include implement, and is benchmark-only.
write_spec "$TMP_DIR/bench-phases.json" '{"name":"benchmark","phases":["review","implement"]}'
dx_run_spec_normalize "$TMP_DIR/bench-phases.json" "$TMP_DIR/bench-phases.normalized.json"
[[ "$(dx_run_spec_field "$TMP_DIR/bench-phases.normalized.json" workflow.phases)" == '["implement","review"]' ]] \
  || assert_at $LINENO
[[ "$(dx_run_spec_field "$TMP_DIR/bench.normalized.json" workflow.phases)" == '["plan","implement","review"]' ]] \
  || assert_at $LINENO
write_spec "$TMP_DIR/bench-noimpl.json" '{"name":"benchmark","phases":["plan","review"]}'
if dx_run_spec_normalize "$TMP_DIR/bench-noimpl.json" "$TMP_DIR/x.json" 2>"$TMP_DIR/err"; then
  assert_at $LINENO
fi
grep -Fq "workflow.phases must include implement" "$TMP_DIR/err" || assert_at $LINENO
write_spec "$TMP_DIR/ticket-phases.json" '{"name":"ticket_to_pr","phases":["implement"]}'
if dx_run_spec_normalize "$TMP_DIR/ticket-phases.json" "$TMP_DIR/x.json" 2>"$TMP_DIR/err"; then
  assert_at $LINENO
fi
grep -Fq "applies only to the benchmark workflow" "$TMP_DIR/err" || assert_at $LINENO

# The default workflow keeps its defaults.
write_spec "$TMP_DIR/ticket.json" '{"name":"ticket_to_pr"}'
dx_run_spec_normalize "$TMP_DIR/ticket.json" "$TMP_DIR/ticket.normalized.json"
[[ "$(dx_run_spec_field "$TMP_DIR/ticket.normalized.json" workflow.requires_plan_approval)" == "true" ]] \
  || assert_at $LINENO
[[ "$(dx_run_spec_field "$TMP_DIR/ticket.normalized.json" workflow.requires_ui_evidence)" == "auto" ]] \
  || assert_at $LINENO

# --- Stop hook: a benchmark audit marks PR, push and tracker checks N/A ---
SID="bench-audit"
start_inline_phase "$SID" 2 2-implement
run_hook "$SID" 2 claude-bench-audit
[[ "$RC" -eq 2 ]] || assert_at $LINENO
[[ "$OUT" == *"Benchmark Run Overrides"* ]] || assert_at $LINENO
rm -f "$DX_LOOP_DIR/$SID".* "$DX_STATE_DIR/$SID".*

# --- Stop hook: Phase 2 hands off to a benchmark Phase 3 ---
SID="bench-phase-2"
start_inline_phase "$SID" 2 2-implement
touch "$DX_LOOP_DIR/$SID.phase-2.ready"
write_approved_criteria "$SID"
printf '%s\n' "candidate change" >> "$REPO/README.md"
dx_review_write_selection "$SID" normal lifecycle-agent bounded-production-change "$REPO"
write_completion "$SID" 2
run_hook "$SID" 2 claude-bench-phase-2
[[ "$RC" -eq 0 ]] || assert_at $LINENO
[[ "$OUT" == *"Phase Handoff: Phase 2 complete"* ]] || assert_at $LINENO
[[ "$OUT" == *"Review is the last phase of a benchmark run"* ]] || assert_at $LINENO
[[ "$OUT" != *"Commit and push accepted review fixes"* ]] || assert_at $LINENO
[[ "$(cat "$DX_STATE_DIR/$SID.phase")" == "3" ]] || assert_at $LINENO
rm -f "$DX_LOOP_DIR/$SID".* "$DX_STATE_DIR/$SID".*

# --- Stop hook: a valid review receipt ends a benchmark lifecycle ---
SID="bench-phase-3"
start_inline_phase "$SID" 3 3-review-loop
write_approved_criteria "$SID"
dx_review_write_selection "$SID" normal lifecycle-agent bounded-production-change "$REPO"
FINGERPRINT=$(dx_review_scope_fingerprint "$REPO")
CRITERIA_BINDING=$(dx_review_read_criteria_approval "$SID")
POLICY_BINDING=$(dx_review_policy_resolve "$REPO" | cut -f4)
for iteration in 1 2; do
  dx_test_write_clean_review_proof "$SID" "bench-clean-$iteration" standard \
    "$FINGERPRINT" "$CRITERIA_BINDING" "$POLICY_BINDING" \
    "$TMP_DIR/clean-$iteration.evidence.json" "$TMP_DIR/clean-$iteration.context.md"
  dx_review_ledger_append "$SID" "$iteration" "bench-clean-$iteration" standard \
    "$FINGERPRINT" "$CRITERIA_BINDING" "$POLICY_BINDING" \
    "$TMP_DIR/clean-$iteration.evidence.json" "$TMP_DIR/clean-$iteration.context.md"
done
dx_review_write_receipt "$SID" normal 2 2 "$REPO" "$CRITERIA_BINDING" "$POLICY_BINDING"
write_completion "$SID" 3
run_hook "$SID" 3 claude-bench-phase-3
[[ "$RC" -eq 2 ]] || assert_at $LINENO
[[ "$OUT" == *"--- Dex lifecycle complete ---"* ]] || assert_at $LINENO
[[ "$OUT" == *"benchmark lifecycle is complete"* ]] || assert_at $LINENO
[[ "$OUT" != *"Phase Handoff"* ]] || assert_at $LINENO
[[ "$(cat "$DX_STATE_DIR/$SID.phase")" == "7" ]] || assert_at $LINENO
DEX_WORKFLOW=benchmark dx_lifecycle_terminal_commit_valid "$SID" || assert_at $LINENO
[[ ! -e "$(dx_review_receipt_file "$SID")" ]] || assert_at $LINENO

# The summary turn that follows is allowed to end the provider session.
run_hook "$SID" 3 claude-bench-phase-3
[[ "$RC" -eq 0 ]] || assert_at $LINENO
chmod -R u+w "$(dx_review_proof_dir "$SID")" 2>/dev/null || true
rm -rf "$(dx_review_proof_dir "$SID")"
rm -f "$DX_LOOP_DIR/$SID".* "$DX_STATE_DIR/$SID".*

# --- Stop hook: without Review, Implement ends the lifecycle ---
# No sealed criteria and no risk tier: both exist to feed Review.
SID="bench-noreview"
start_inline_phase "$SID" 2 2-implement
touch "$DX_LOOP_DIR/$SID.phase-2.ready"
write_completion "$SID" 2
set +e
OUT="$(cd "$REPO" && printf '{"session_id":"claude-bench-noreview"}' | env \
  DEX_WORKFLOW=benchmark DEX_BENCHMARK_PHASES=plan,implement DEX_SESSION_ID="$SID" \
  DEX_LOOP_ACTIVE=1 DEX_LOOP_PHASE=2 DEX_PHASE_HANDOFF=inline bash "$HOOK" 2>&1)"
RC=$?
set -e
[[ "$RC" -eq 2 ]] || assert_at $LINENO
[[ "$OUT" == *"benchmark lifecycle is complete"* ]] || assert_at $LINENO
[[ "$OUT" != *"review risk selection missing"* ]] || assert_at $LINENO
[[ "$(cat "$DX_STATE_DIR/$SID.phase")" == "7" ]] || assert_at $LINENO
DEX_WORKFLOW=benchmark DEX_BENCHMARK_PHASES=plan,implement dx_lifecycle_terminal_commit_valid "$SID" \
  || assert_at $LINENO
rm -f "$DX_LOOP_DIR/$SID".* "$DX_STATE_DIR/$SID".*

# --- without Plan, the task text becomes sealed acceptance criteria ---
SID="bench-noplan"
dx_benchmark_seed_criteria "$SID" "$TMP_DIR/bench.normalized.json" || assert_at $LINENO
dx_review_criteria_valid "$(dx_review_criteria_file "$SID")" || assert_at $LINENO
grep -Fq "Fix the bug." "$(dx_review_criteria_file "$SID")" || assert_at $LINENO
[[ "$(dx_review_read_criteria_approval "$SID")" =~ ^[a-f0-9]{64}$ ]] || assert_at $LINENO
# A second call leaves the sealed criteria alone.
dx_benchmark_seed_criteria "$SID" "$TMP_DIR/bench.normalized.json" || assert_at $LINENO
rm -f "$DX_LOOP_DIR/$SID".* "$DX_STATE_DIR/$SID".*

# --- dx.sh: launch text and completion ---
if command -v zsh >/dev/null 2>&1; then
  BENCH_MESSAGE=$(DEX_WORKFLOW=benchmark zsh -fc \
    'source "$DEX_DIR/dx.sh" >/dev/null 2>&1; __dx_phase_message 2 "task" in-place "$PWD"')
  [[ "$BENCH_MESSAGE" == *"never push, open a PR, or touch a tracker"* ]] || assert_at $LINENO
  [[ "$BENCH_MESSAGE" != *"prompts/issue-hygiene.md"* ]] || assert_at $LINENO
  NOPLAN_MESSAGE=$(DEX_WORKFLOW=benchmark DEX_BENCHMARK_PHASES=implement,review zsh -fc \
    'source "$DEX_DIR/dx.sh" >/dev/null 2>&1; __dx_phase_message 2 "task" in-place "$PWD"')
  [[ "$NOPLAN_MESSAGE" == *"has no planning phase"* ]] || assert_at $LINENO
  [[ "$NOPLAN_MESSAGE" == *"dx_review_write_selection"* ]] || assert_at $LINENO
  NOREVIEW_MESSAGE=$(DEX_WORKFLOW=benchmark DEX_BENCHMARK_PHASES=plan,implement zsh -fc \
    'source "$DEX_DIR/dx.sh" >/dev/null 2>&1; __dx_phase_message 2 "task" in-place "$PWD"')
  [[ "$NOREVIEW_MESSAGE" == *"no review follows"* ]] || assert_at $LINENO
  [[ "$NOREVIEW_MESSAGE" != *"dx_review_write_selection"* ]] || assert_at $LINENO
  PLAN_MESSAGE=$(DEX_WORKFLOW=benchmark zsh -fc \
    'source "$DEX_DIR/dx.sh" >/dev/null 2>&1; __dx_phase_message 1 "task" in-place "$PWD"')
  # No plan mode to hold the line, so the text has to: planning edits nothing.
  [[ "$PLAN_MESSAGE" == *"Phase 1 is read-only"* ]] || assert_at $LINENO
  TICKET_MESSAGE=$(zsh -fc \
    'source "$DEX_DIR/dx.sh" >/dev/null 2>&1; __dx_phase_message 2 "task" in-place "$PWD"')
  [[ "$TICKET_MESSAGE" == *"prompts/issue-hygiene.md"* ]] || assert_at $LINENO

  # Completion would normally switch back to main and delete the lifecycle
  # branch. A benchmark keeps both: the verifier reads this checkout.
  git -C "$REPO" checkout -q -- README.md
  git -C "$REPO" switch -q -c worktree-headless-run_bench-test
  printf '%s\n' "benchmark change" >> "$REPO/README.md"
  git -C "$REPO" commit -q -am "test: benchmark change"
  (cd "$REPO" && DEX_WORKFLOW=benchmark zsh -fc \
    'source "$DEX_DIR/dx.sh" >/dev/null 2>&1; __dx_cleanup_completed_workspace headless-run_bench-test "$PWD" main in-place ""') \
    >/dev/null
  [[ "$(git -C "$REPO" branch --show-current)" == "worktree-headless-run_bench-test" ]] \
    || assert_at $LINENO
  grep -Fq "benchmark change" "$REPO/README.md" || assert_at $LINENO
fi

# --- init: a benchmark checkout gets the .dex skeleton and nothing else ---
INIT_REPO="$TMP_DIR/init-repo"
git init -q "$INIT_REPO"
git -C "$INIT_REPO" config user.email dex@example.test
git -C "$INIT_REPO" config user.name "Dex Test"
printf '%s\n' "init fixture" > "$INIT_REPO/README.md"
git -C "$INIT_REPO" add README.md
git -C "$INIT_REPO" commit -q -m "test: initialize init fixture"
(cd "$INIT_REPO" && DEX_WORKFLOW=benchmark DEXCODE_SYNC=0 \
  bash "$ROOT/bin/init.sh" --skip-analysis --skip-config) > "$TMP_DIR/init.out" 2>&1
[[ -f "$INIT_REPO/.dex/dex.md" ]] || assert_at $LINENO
[[ ! -e "$INIT_REPO/.github/pull_request_template.md" ]] || assert_at $LINENO
[[ -z "$(git -C "$INIT_REPO" config --get core.hooksPath || true)" ]] || assert_at $LINENO
grep -Fq "Benchmark run: skipping Claude/Codex tooling bootstrap" "$TMP_DIR/init.out" \
  || assert_at $LINENO

printf '%s\n' "benchmark-workflow-test: ok"
