#!/usr/bin/env bash
# Collect one arm's metrics from what the run left behind, with provenance.
#
#   collect.sh <arm-dir>   (the directory launch-arm.sh prepared)
#
# Acceptance comes from the scenario's own rubric through the research
# harness's score_scenario (LLM judge skipped, so it is deterministic and
# makes no model call). Time comes from the launcher's run-meta. Tokens come
# from the provider transcripts the run produced, read by
# scripts/usage_collect.py (one count per requestId, per agent). Counts of
# gates, reviews, phases and mission records come from the run journal and
# the ledger. Anything that cannot be read is reported as unavailable, not as
# zero.
set -euo pipefail

ARM_DIR="${1:-}"
[[ -d "$ARM_DIR" && -f "$ARM_DIR/plan.json" ]] || { echo "collect: need an arm directory with plan.json" >&2; exit 2; }
HERE="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
ROOT="$(cd "$HERE/../.." && pwd)"
ARM=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["arm"])' "$ARM_DIR/plan.json")
TASK=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["task"])' "$ARM_DIR/plan.json")
REPO=$(python3 -c 'import json,sys; print(json.load(open(sys.argv[1]))["repo"])' "$ARM_DIR/plan.json")

META="$ARM_DIR/logs/run-meta.txt"
if [[ ! -f "$META" ]]; then
  python3 -c 'import json,sys; print(json.dumps({"schema_version": 1, "arm": sys.argv[1], "task": sys.argv[2], "status": "not-run", "time": {"available": False}, "tokens": {"available": False}, "acceptance": {"available": False}, "events": {"available": False}, "provenance": {"reason": "no run-meta.txt; the arm was prepared but not launched"}}, sort_keys=True))' "$ARM" "$TASK"
  exit 0
fi
meta() { sed -n "s/^$1=//p" "$META" | tail -1; }
START_EPOCH=$(meta start_epoch); END_EPOCH=$(meta end_epoch); WALL=$(meta wall_seconds); RUN_EXIT=$(meta run_exit); TIMED_OUT=$(meta timed_out)
STATUS="finished"; [[ -n "$END_EPOCH" ]] || STATUS="running"

# ── acceptance: the scenario rubric through the harness scorer, no LLM ─────
ACCEPT_JSON='{"available": false, "reason": "rubric did not run"}'
# The result is the lifecycle branch, not whatever the fixture has checked out
# when the run ends (an in-place lifecycle switches back to main and may drop
# its local branch). Prefer the local branch, else the pushed copy in the
# fixture's bare origin; archive it to a scratch tree the rubric can build in.
RESULT_REF="" RESULT_SOURCE=""
if [[ -d "$REPO/.git" ]]; then
  RESULT_REF=$(git -C "$REPO" branch --list 'worktree-task-*' 2>/dev/null | tr -d ' *' | head -1 || true)
  [[ -n "$RESULT_REF" ]] && RESULT_SOURCE="$REPO"
fi
if [[ -z "$RESULT_REF" && -d "$ARM_DIR/origin.git" ]]; then
  RESULT_REF=$(git -C "$ARM_DIR/origin.git" branch --list 'worktree-task-*' 2>/dev/null | tr -d ' *' | head -1 || true)
  [[ -n "$RESULT_REF" ]] && RESULT_SOURCE="$ARM_DIR/origin.git"
fi
RESULT_TREE=""
if [[ -n "$RESULT_REF" ]]; then
  RESULT_TREE=$(mktemp -d "${TMPDIR:-/tmp}/dex-ab-result.XXXXXX")
  git -C "$RESULT_SOURCE" archive "$RESULT_REF" | tar -xf - -C "$RESULT_TREE" || RESULT_TREE=""
fi
RESULT_COMMITS=""
[[ -n "$RESULT_REF" ]] && RESULT_COMMITS=$(git -C "$RESULT_SOURCE" rev-list --count "$RESULT_REF" 2>/dev/null || true)
if [[ -n "$RESULT_TREE" ]]; then
  RESULT_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dex-ab-score.XXXXXX")
  SCORE_OUT=$( (
    # The harness's scorer expects research/config.sh (weights) and does not
    # run under set -u; give it the environment it was written for.
    set +u
    export RESEARCH_DIR="$ROOT/research"
    # shellcheck disable=SC1091
    source "$ROOT/research/config.sh" 2>/dev/null
    # shellcheck disable=SC1091
    source "$ROOT/research/lib/common.sh" 2>/dev/null
    # shellcheck disable=SC1091
    source "$ROOT/research/lib/score.sh" 2>/dev/null
    scenario_dir() { printf '%s/research/scenarios/%s\n' "$ROOT" "$1"; }
    workspace_dir() { printf '%s\n' "$RESULT_TREE"; }
    json_write() { printf '%s\n' "$2" > "$1"; }
    score_scenario "$TASK" "$RESULT_DIR" --skip-llm-judge > /dev/null 2>&1 || true
    [[ -f "$RESULT_DIR/rubric-results.json" ]] && cat "$RESULT_DIR/rubric-results.json"
  ) 2>/dev/null || true)
  if [[ -n "$SCORE_OUT" ]] && python3 -c 'import json,sys; json.loads(sys.argv[1])' "$SCORE_OUT" 2>/dev/null; then
    ACCEPT_JSON=$(python3 -c 'import json,sys; d=json.loads(sys.argv[1]); d["available"]=True; d["evaluator"]="research/scenarios/'"$TASK"'/rubric.sh via score_scenario --skip-llm-judge (code_quality is the neutral 50 default)"; d["scored_ref"]=sys.argv[2]; d["scored_from"]=sys.argv[3]; print(json.dumps(d))' "$SCORE_OUT" "$RESULT_REF" "$RESULT_SOURCE")
  fi
  rm -rf "$RESULT_DIR" "$RESULT_TREE"
else
  ACCEPT_JSON='{"available": false, "reason": "no lifecycle branch (worktree-task-*) in the fixture or its origin to score"}'
fi

# ── tokens: transcripts for this repository written during the run ─────────
# Claude Code names a project directory after the cwd with both "/" and "." replaced by "-".
ENCODED=$(printf '%s' "$REPO" | sed 's#[/.]#-#g')
PROJECT_DIR="$HOME/.claude/projects/$ENCODED"
TOKENS_JSON='{"available": false, "reason": "no transcripts found for the run"}'
if [[ -d "$PROJECT_DIR" && -n "$START_EPOCH" ]]; then
  TOKENS_JSON=$(python3 - "$PROJECT_DIR" "$START_EPOCH" "${END_EPOCH:-0}" "$ROOT/scripts/usage_collect.py" <<'PY'
import glob, json, os, subprocess, sys
project, start, end, collector = sys.argv[1], int(sys.argv[2]), int(sys.argv[3]), sys.argv[4]
totals = {}
agents = {}
sessions = []
for transcript in sorted(glob.glob(os.path.join(project, "*.jsonl"))):
    mtime = os.path.getmtime(transcript)
    if mtime < start - 5:
        continue
    sid = os.path.basename(transcript)[:-6]
    sub = os.path.join(project, sid, "subagents")
    args = [sys.executable, collector, transcript] + (["--subagents", sub] if os.path.isdir(sub) else [])
    out = subprocess.run(args, capture_output=True, text=True)
    if out.returncode != 0:
        continue
    record = json.loads(out.stdout)
    sessions.append({"session": sid, "requests": record["requests"], "complete": record["complete"], "agents": len(record["by_agent"])})
    for key, value in record["totals"].items():
        totals[key] = totals.get(key, 0) + value
    for agent, t in record["by_agent"].items():
        name = agent if agent == "main" else f"{sid[:8]}/{agent}"
        agents[name] = {k: t.get(k) for k in ("agent_type", "requests", "prompt_tokens_total", "cache_read_input_tokens", "cache_creation_input_tokens", "input_tokens", "output_tokens")}
print(json.dumps({"available": bool(sessions), "sessions": sessions, "totals": totals, "by_agent": agents,
                  "provenance": "transcript JSONL under ~/.claude/projects, files modified after the run started, first line per requestId; the tail of a live transcript may be missing"}, sort_keys=True))
PY
)
fi

# ── events, receipts, review, phases ───────────────────────────────────────
EVENTS_JSON=$(python3 - "$ARM_DIR/runs" <<'PY'
import glob, json, os, sys
root = sys.argv[1]
counts = {}
phases = {}
files = sorted(glob.glob(os.path.join(root, "*", "events.jsonl")))
for path in files:
    for line in open(path):
        try:
            e = json.loads(line)
        except ValueError:
            continue
        t = e.get("type", "?")
        counts[t] = counts.get(t, 0) + 1
        if t in ("phase.started", "phase.completed", "phase.skipped", "phase.waived"):
            phases.setdefault(str(e.get("phase")), []).append({"type": t, "at": e.get("created_at")})
print(json.dumps({"available": bool(files), "journals": len(files), "counts": counts, "phases": phases}, sort_keys=True))
PY
)
RECEIPTS=$(find "$ARM_DIR/loops" -path '*.gate-receipts/*.json' 2>/dev/null | wc -l | tr -d ' ' || echo 0)
UNGATED=$( { cat "$ARM_DIR"/loops/*.gate-receipts/ungated.jsonl 2>/dev/null || true; } | wc -l | tr -d ' ')
# The phase file is removed when a lifecycle completes; the journal keeps the
# highest phase that started or completed.
HIGHEST_PHASE=$(printf '%s' "$EVENTS_JSON" | python3 -c 'import json,sys
d = json.load(sys.stdin)
phases = [int(k) for k in (d.get("phases") or {}) if str(k).isdigit()]
print(max(phases) if phases else "")')

# ── fragmentation and (B0) coordination ────────────────────────────────────
WORKTREES=$( { git -C "$REPO" worktree list 2>/dev/null || true; } | wc -l | tr -d ' ')
BRANCHES=$( { git -C "$REPO" branch --list 2>/dev/null; git -C "$ARM_DIR/origin.git" branch --list 2>/dev/null; } | tr -d ' *' | sort -u | wc -l | tr -d ' ')
COMMITS="${RESULT_COMMITS:-}"
LEDGER_JSON='{"available": false}'
for ledger in "$ARM_DIR"/state/*.mission/current.json; do
  [[ -f "$ledger" ]] || continue
  VIOL=$( { cat "$(dirname "$ledger")/violations.jsonl" 2>/dev/null || true; } | wc -l | tr -d ' ')
  OBS=$( { cat "$(dirname "$ledger")/observations.jsonl" 2>/dev/null || true; } | wc -l | tr -d ' ')
  LEDGER_JSON=$(python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(json.dumps({"available": True, "generation": d.get("generation"), "assignments": len(d.get("assignments") or {}), "assignment_statuses": sorted(set(a.get("status","?") for a in (d.get("assignments") or {}).values())), "lease_generations": d.get("lease_generations"), "decisions": len(d.get("decisions") or []), "selfchecks": len(d.get("selfchecks") or []), "violations": int(sys.argv[2]), "helper_observations": int(sys.argv[3])}))' "$ledger" "$VIOL" "$OBS")
  break
done
WATCHER=$( { cat "$ARM_DIR/logs/watcher.log" 2>/dev/null || true; } | head -3 | tr '\n' ' ')

python3 - "$ARM" "$TASK" "$STATUS" "${WALL:-}" "${RUN_EXIT:-}" "${TIMED_OUT:-}" "$ACCEPT_JSON" "$TOKENS_JSON" "$EVENTS_JSON" "$RECEIPTS" "$UNGATED" "${HIGHEST_PHASE:-}" "$WORKTREES" "$BRANCHES" "${COMMITS:-}" "$LEDGER_JSON" "$WATCHER" <<'PY'
import json, sys
a = sys.argv
print(json.dumps({
  "schema_version": 1,
  "arm": a[1], "task": a[2], "status": a[3],
  "time": {"available": a[4] != "", "wall_seconds": int(a[4]) if a[4] else None, "run_exit": int(a[5]) if a[5] else None, "timed_out": a[6] == "1"},
  "acceptance": json.loads(a[7]),
  "tokens": json.loads(a[8]),
  "events": json.loads(a[9]),
  "receipts": {"gate_receipts": int(a[10]), "ungated_heavy_commands": int(a[11])},
  "phase_reached": int(a[12]) if a[12] else None,
  "fragmentation": {"worktrees": int(a[13]), "branches_including_origin": int(a[14]), "lifecycle_branch_commits": int(a[15]) if a[15] else None},
  "coordination": json.loads(a[16]),
  "endpoint_watcher": a[17] or None,
  "provenance": {"time": "launcher run-meta.txt (date +%s)", "acceptance": "scenario rubric via research/lib/score.sh, LLM judge skipped", "tokens": "transcripts, see tokens.provenance", "events": "run journals under the arm's DX_RUN_ROOT", "unknown_policy": "fields the run did not produce are null or available:false, never zero"},
}, sort_keys=True))
PY
