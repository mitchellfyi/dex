#!/usr/bin/env bash
# The bounded research consumer: evaluates what the feedback outbox holds and
# takes every candidate it touches towards a terminal state on evidence.
#
#   consume.sh --max-candidates N --max-minutes M --max-iterations I
#              [--candidate ID] [--evaluator SCRIPT] [--dex-source head|working-tree]
#              [--dex-ref REF] [--out DIR] [--include-research-origin]
#              [--activate low|off] [--max-attempts N] [--reproduce on|off]
#              [--dex-dir-live DIR] [--review on|off]
#
# All three caps are required and positive: there is no unlimited default.
# For each candidate, in order: claim it (one owner at a time); build a pinned,
# read-only baseline runtime of Dex (git archive of --dex-ref, default HEAD,
# through review_eval_prepare_runtime; or the allowlisted paths of the working
# tree, hashed); copy it; apply the candidate's patch to the copy
# all-or-nothing, and only if every path it touches is in the allowlist
# (skills/*/SKILL.md, prompts/**/*.md); run the evaluator against baseline and
# candidate; record everything in the candidate's evaluation.json.
#
# What happens next depends on the decision, and none of it waits for a person:
#   validated     the allowlist is the risk tier, so every validated patch is
#                 `low`. With --activate low (the default, or
#                 DX_RESEARCH_AUTO_ACTIVATE) and --review on (the default, or
#                 DX_RESEARCH_REVIEW) a fresh bounded model session first
#                 reviews the change through research/consume-review.sh, the
#                 only non-deterministic step before a live change. `approve`
#                 applies the patch, unstaged, to the live Dex checkout
#                 (--dex-dir-live, default $DEX_DIR) with the rollback command
#                 recorded: the candidate is `activated`. `reject` retires it
#                 with the reviewer's reason. A review that produces no
#                 decision leaves it `evaluated`, spends an attempt, and the
#                 next run tries again; at --max-attempts it is retired.
#                 --review off activates on validated alone, so the two
#                 policies can be compared. --activate off leaves it
#                 `evaluated` for a person; a later run with activation on
#                 re-evaluates it and picks it up. A patch that no longer
#                 applies to the live checkout spends an attempt each run.
#   rejected      final: the candidate stays `evaluated`.
#   inconclusive  the candidate returns to `eligible` with one attempt spent;
#                 at --max-attempts (default 3) it is `retired` with the reason.
# A `captured` candidate (evidence, but no reproduction and no patch) gets one
# model call per run through research/consume-reproduce.sh while --reproduce
# is on: the model writes a check, the deterministic layer installs it and runs
# it on both runtimes. A check that fails on the baseline is a reproduced bug
# nobody has fixed (inconclusive, one attempt spent); one that passes retires
# the candidate as not reproducible; no usable script spends an attempt. The
# baseline is never modified. A candidate the learner itself raised (origin:
# research) is skipped unless asked for, so a campaign does not feed itself.
# Nothing here touches research/orchestrate.sh, improve.sh or loop.sh.
set -euo pipefail

DEX_DIR="${DEX_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}"
export DEX_DIR
# shellcheck disable=SC1091
source "$DEX_DIR/research/review-loop/lib.sh"
# shellcheck disable=SC1091
source "$DEX_DIR/lib/feedback.sh"

usage() {
  cat >&2 <<'USAGE'
Usage: consume.sh --max-candidates N --max-minutes M --max-iterations I
                  [--candidate ID] [--evaluator SCRIPT] [--dex-source head|working-tree]
                  [--dex-ref REF] [--out DIR] [--include-research-origin]
                  [--activate low|off] [--max-attempts N] [--reproduce on|off]
                  [--dex-dir-live DIR] [--review on|off]
USAGE
  exit 2
}

MAX_CANDIDATES="" MAX_MINUTES="" MAX_ITERATIONS="" ONLY_CANDIDATE="" INCLUDE_RESEARCH=0
EVALUATOR="$DEX_DIR/research/consume-eval.sh" DEX_SOURCE="head" DEX_REF="HEAD" OUT_DIR=""
ACTIVATE="${DX_RESEARCH_AUTO_ACTIVATE:-low}" MAX_ATTEMPTS=3 REPRODUCE="on" LIVE_DEX_DIR=""
REVIEW="${DX_RESEARCH_REVIEW:-on}"
REPRODUCER="$DEX_DIR/research/consume-reproduce.sh"
REVIEWER="$DEX_DIR/research/consume-review.sh"
while [[ $# -gt 0 ]]; do
  case "$1" in
    --max-candidates) MAX_CANDIDATES="${2:-}"; shift 2 ;;
    --max-minutes) MAX_MINUTES="${2:-}"; shift 2 ;;
    --max-iterations) MAX_ITERATIONS="${2:-}"; shift 2 ;;
    --candidate) ONLY_CANDIDATE="${2:-}"; shift 2 ;;
    --evaluator) EVALUATOR="${2:-}"; shift 2 ;;
    --dex-source) DEX_SOURCE="${2:-}"; shift 2 ;;
    --dex-ref) DEX_REF="${2:-}"; shift 2 ;;
    --out) OUT_DIR="${2:-}"; shift 2 ;;
    --include-research-origin) INCLUDE_RESEARCH=1; shift ;;
    --activate) ACTIVATE="${2:-}"; shift 2 ;;
    --max-attempts) MAX_ATTEMPTS="${2:-}"; shift 2 ;;
    --reproduce) REPRODUCE="${2:-}"; shift 2 ;;
    --dex-dir-live) LIVE_DEX_DIR="${2:-}"; shift 2 ;;
    --review) REVIEW="${2:-}"; shift 2 ;;
    -h|--help) usage ;;
    *) usage ;;
  esac
done
for cap in "$MAX_CANDIDATES" "$MAX_MINUTES" "$MAX_ITERATIONS" "$MAX_ATTEMPTS"; do
  [[ "$cap" =~ ^[1-9][0-9]*$ ]] || usage
done
[[ "$DEX_SOURCE" == "head" || "$DEX_SOURCE" == "working-tree" ]] || usage
[[ "$ACTIVATE" == "low" || "$ACTIVATE" == "off" ]] || usage
[[ "$REPRODUCE" == "on" || "$REPRODUCE" == "off" ]] || usage
[[ "$REVIEW" == "on" || "$REVIEW" == "off" ]] || usage
[[ -x "$EVALUATOR" ]] || { echo "consume: evaluator is not executable: $EVALUATOR" >&2; exit 2; }
LIVE_DEX_DIR="${LIVE_DEX_DIR:-$DEX_DIR}"
[[ -d "$LIVE_DEX_DIR" ]] || { echo "consume: --dex-dir-live is not a directory: $LIVE_DEX_DIR" >&2; exit 2; }

export DX_RESEARCH_CONSUMER_ACTIVE=1
OWNER="consume:$$:$(hostname -s 2>/dev/null || printf 'host')"
STARTED_EPOCH=$(date +%s)
DEADLINE_EPOCH=$((STARTED_EPOCH + MAX_MINUTES * 60))
CLAIM_TTL=$((MAX_MINUTES * 60))
RUN_ROOT="${OUT_DIR:-${DX_RESEARCH_ROOT:-$HOME/.dex/research-consume}}/run-$(date -u +%Y%m%dT%H%M%SZ)-$$"
mkdir -p "$RUN_ROOT/candidates"
chmod 700 "$RUN_ROOT"
OUTBOX_DIR="$(dx_feedback_dir)"

# ── the pinned baseline ────────────────────────────────────────────────────
BASELINE_DIR="$RUN_ROOT/baseline"
BASELINE_SOURCE=""
if [[ "$DEX_SOURCE" == "head" ]]; then
  BASELINE_SHA=$(review_eval_prepare_runtime "$DEX_DIR" "$DEX_REF" "$BASELINE_DIR") \
    || { echo "consume: could not build the baseline runtime from $DEX_REF" >&2; exit 1; }
  BASELINE_SOURCE="head@${BASELINE_SHA}"
else
  mkdir -p "$BASELINE_DIR"
  # The same runtime surface review_eval_prepare_runtime archives, taken from
  # the working tree (tracked plus untracked, never ignored files).
  (cd "$DEX_DIR" && git ls-files --cached --others --exclude-standard -z -- \
      dx.sh settings.json bin hooks lib prompts scripts skills \
      research/review-loop/launch.zsh research/review-loop/agent-observer.sh \
    | tar -c --null -T - | tar -x -C "$BASELINE_DIR") \
    || { echo "consume: could not copy the working-tree runtime" >&2; exit 1; }
  BASELINE_SOURCE="working-tree@$(review_eval_runtime_tree_hash "$BASELINE_DIR")"
fi
BASELINE_HASH=$(review_eval_runtime_tree_hash "$BASELINE_DIR")
review_eval_runtime_make_read_only "$BASELINE_DIR" || { echo "consume: could not seal the baseline" >&2; exit 1; }
DEX_VERSION=$(git -C "$DEX_DIR" rev-parse --short HEAD 2>/dev/null || printf 'unknown')

# ── candidates ─────────────────────────────────────────────────────────────
ALLOWLIST_RE='^(skills/[^/]+/SKILL\.md|prompts/.+\.md)$'
PROCESSED=0
DECISIONS="{}"
SKIPPED="[]"
ACTIVATED="[]"
RETIRED="[]"
RETIRED_REASONS="{}"
ACTIVATION_FAILED="{}"
REVIEWS="{}"
REVIEW_UNAVAILABLE="{}"

json_set() {  # json_set <object-json> <key> <value-json>
  python3 -c 'import json, sys; d = json.loads(sys.argv[1]); d[sys.argv[2]] = json.loads(sys.argv[3]); print(json.dumps(d, sort_keys=True))' "$1" "$2" "$3"
}
json_append() {  # json_append <array-json> <value-json>
  python3 -c 'import json, sys; a = json.loads(sys.argv[1]); a.append(json.loads(sys.argv[2])); print(json.dumps(a))' "$1" "$2"
}
json_str() { python3 -c 'import json, sys; print(json.dumps(sys.argv[1]))' "$1"; }
json_get() {  # json_get <json> <dotted.path> ; empty when absent
  python3 -c 'import json, sys
d = json.loads(sys.argv[1])
for key in sys.argv[2].split("."):
    d = d.get(key) if isinstance(d, dict) else None
print("" if d is None else d)' "$1" "$2"
}
skip() { SKIPPED=$(json_append "$SKIPPED" "{\"id\": $(json_str "$1"), \"reason\": $(json_str "$2")}"); }
first_line() { head -c 300 "$1" | tr '\n' ' '; }

# write_mission_brief <id> <package-dir> <attempts>
# A ticket-shaped brief for `dx --workflow`, written into the package and
# named in the retirement reason's evidence. Prose comes from the manifest and
# evidence summary; the reproduction check is the acceptance test.
write_mission_brief() {
  local id="$1" package="$2" attempts="$3" brief="$2/mission-brief.md"
  python3 - "$id" "$package" "$attempts" "$brief" <<'PY_BRIEF' || return 0
import json, os, sys
identity, package, attempts, brief = sys.argv[1:5]
manifest = json.load(open(os.path.join(package, "manifest.json")))
summary = ""
try:
    summary = open(os.path.join(package, "evidence-summary.md"), encoding="utf-8").read().strip()
except OSError:
    pass
check = os.path.join(package, "reproduction", "check.sh")
lines = [
    f"# Fix: {manifest.get('mechanism', identity)}",
    "",
    f"Feedback candidate `{identity}` reproduced {attempts} time(s) and nothing in the research",
    "consumer's allowlist (prompts, skills) can fix it. This brief is the hand-off.",
    "",
    "## Symptom",
    "",
    manifest.get("symptom", "").strip() or "(see evidence)",
    "",
    "## Evidence",
    "",
    summary or manifest.get("evidence_summary", "").strip() or "(none recorded)",
    "",
    "## Acceptance",
    "",
    f"`{check}` exits 0 against the fixed Dex checkout (`DEX_DIR` set) and non-zero against the",
    "current one. Keep the check; add a hermetic test under `tests/` that fails the same way.",
    "",
    "## Run it",
    "",
    "```",
    f"dx --workflow \"$(cat {brief})\"",
    "```",
    "",
]
with open(brief, "w", encoding="utf-8") as handle:
    handle.write("\n".join(lines))
os.chmod(brief, 0o600)
PY_BRIEF
}

retire_candidate() {  # retire_candidate <id> <reason> [evaluation-file] ; the claim must be held
  local id="$1" reason="$2" evaluation="${3:-}"
  if [[ -n "$evaluation" ]]; then
    dx_feedback_outbox retire "$id" --owner "$OWNER" --reason "$reason" --evaluation "$evaluation" >/dev/null
  else
    dx_feedback_outbox retire "$id" --owner "$OWNER" --reason "$reason" >/dev/null
  fi
  RETIRED=$(json_append "$RETIRED" "$(json_str "$id")")
  RETIRED_REASONS=$(json_set "$RETIRED_REASONS" "$id" "$(json_str "$reason")")
}

evaluate_candidate() {  # evaluate_candidate <id> <repro-source> <model-calls> <model-seconds>
  # Prints "<decision> <reason>" and writes $RUN_ROOT/candidates/<id>.evaluation.json.
  # The outbox transition is the caller's: decide, retire or activate.
  local id="$1" repro_source="$2" model_calls="$3" model_seconds="$4"
  local package="$OUTBOX_DIR/$1" cand_dir="$RUN_ROOT/candidates/$1"
  local started finished changed_file changed_paths strip="" reason="" decision="" eval_json="{}" risk_tier="none"
  started=$(date +%s)
  cp -R "$BASELINE_DIR" "$cand_dir"
  chmod -R u+w "$cand_dir"
  changed_file="$cand_dir.changed"
  : > "$changed_file"
  if [[ -f "$package/proposed-change.patch" ]]; then
    # The paths a patch touches are judged from the patch itself, before any
    # file is looked up: a patch aimed outside the allowlist is rejected for
    # that reason even when its target is not in the runtime at all. Prefix
    # depth follows the headers (`+++ b/…` is -p1, else -p0).
    if grep -q '^+++ b/' "$package/proposed-change.patch"; then strip=1; else strip=0; fi
    (cd "$cand_dir" && git apply --numstat "-p$strip" "$package/proposed-change.patch" 2>/dev/null \
      | awk -F'\t' '{print $3}') > "$changed_file" || true
    # The allowlist is the risk tier: every path inside it is low, anything
    # else is high and is rejected below for that reason.
    risk_tier="low"
    if [[ ! -s "$changed_file" ]]; then
      reason="patch names no files (not a unified diff git apply can read)"
      decision="rejected"
      risk_tier="high"
    fi
    if [[ -z "$decision" ]]; then
      while IFS= read -r rel; do
        [[ -n "$rel" ]] || continue
        if ! [[ "$rel" =~ $ALLOWLIST_RE ]]; then
          reason="patch touches ${rel}, outside the allowlist (skills/*/SKILL.md, prompts/**/*.md)"
          decision="rejected"
          risk_tier="high"
          break
        fi
      done < "$changed_file"
    fi
    if [[ -z "$decision" ]]; then
      if ! (cd "$cand_dir" && git apply --check "-p$strip" "$package/proposed-change.patch" >/dev/null 2>&1); then
        reason="patch does not apply to the baseline runtime"
        decision="rejected"
      elif ! (cd "$cand_dir" && git apply "-p$strip" "$package/proposed-change.patch" >/dev/null 2>&1); then
        reason="patch failed to apply after a clean check"
        decision="rejected"
      fi
    fi
  fi
  if [[ -z "$decision" ]]; then
    if ! eval_json=$("$EVALUATOR" "$BASELINE_DIR" "$cand_dir" "$package" "$changed_file" 2>"$cand_dir.eval.err"); then
      reason="evaluator failed: $(first_line "$cand_dir.eval.err")"
      decision="inconclusive"
      eval_json="{}"
    else
      read -r decision reason < <(printf '%s' "$eval_json" | HAS_PATCH="$([[ -f "$package/proposed-change.patch" ]] && printf 1 || printf 0)" python3 -c '
import json, os, sys
d = json.load(sys.stdin)
b, c = d.get("baseline", {}), d.get("candidate", {})
if os.environ.get("HAS_PATCH") != "1":
    # No change to judge: the reproduction alone says whether the bug is real.
    if b.get("reproduction") == "fail":
        print("inconclusive reproduced, no change proposed"); sys.exit()
    if b.get("reproduction") == "pass":
        print("rejected could not reproduce: the check already passes on the baseline"); sys.exit()
    print("inconclusive no reproduction and no change to evaluate"); sys.exit()
if c.get("static") == "fail":
    print("rejected static check failed on the candidate"); sys.exit()
if c.get("reproduction") == "none":
    print("inconclusive no reproduction to run; only a static check was possible"); sys.exit()
if c.get("reproduction") == "fail":
    print("rejected reproduction still fails on the candidate"); sys.exit()
if b.get("reproduction") == "pass":
    print("inconclusive reproduction already passes on the baseline; the change fixes nothing it measures"); sys.exit()
print("validated reproduction fails on the baseline and passes on the candidate")')
    fi
  fi
  finished=$(date +%s)
  changed_paths=$(python3 -c 'import json, sys; print(json.dumps([l.strip() for l in open(sys.argv[1]) if l.strip()]))' "$changed_file")
  python3 - "$cand_dir.evaluation.json" <<PY
import json
record = {
  "schema_version": 1,
  "candidate_id": "$id",
  "decision": "$decision",
  "reason": $(json_str "$reason"),
  "risk_tier": "$risk_tier",
  "reproduction_source": "$repro_source",
  "baseline_runtime": {"source": "$BASELINE_SOURCE", "tree_hash": "$BASELINE_HASH", "dir": "$BASELINE_DIR"},
  "candidate_runtime": {"dir": "$cand_dir", "tree_hash": "$(review_eval_runtime_tree_hash "$cand_dir" 2>/dev/null || printf unknown)"},
  "changed_paths": $changed_paths,
  "patch_strip": "$strip",
  "baseline": $(printf '%s' "$eval_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get("baseline", {})))'),
  "candidate": $(printf '%s' "$eval_json" | python3 -c 'import json,sys; d=json.load(sys.stdin); print(json.dumps(d.get("candidate", {})))'),
  "evaluator": "$EVALUATOR",
  "cost": {"seconds": $((finished - started)), "iterations": $MAX_ITERATIONS, "model_calls": $model_calls, "model_seconds": $model_seconds},
  "activation": None,
  "consumer_owner": "$OWNER",
  "dex_version": "$DEX_VERSION",
  "started_at": "$(date -u -r "$started" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)",
  "finished_at": "$(date -u -r "$finished" +%Y-%m-%dT%H:%M:%SZ 2>/dev/null || date -u +%Y-%m-%dT%H:%M:%SZ)",
}
json.dump(record, open("$cand_dir.evaluation.json", "w"), indent=1, sort_keys=True)
PY
  printf '%s %s\n' "$decision" "$reason"
}

try_activate() {  # try_activate <id> : claim, apply into the live checkout, or spend an attempt
  local id="$1" err="$RUN_ROOT/candidates/$1.activate.err" reason attempts
  if ! dx_feedback_outbox claim "$id" --owner "$OWNER" --ttl-seconds "$CLAIM_TTL" >/dev/null 2>"$err"; then
    ACTIVATION_FAILED=$(json_set "$ACTIVATION_FAILED" "$id" "$(json_str "claim refused: $(first_line "$err")")")
    return 0
  fi
  if dx_feedback_outbox activate "$id" --owner "$OWNER" --dex-dir "$LIVE_DEX_DIR" >/dev/null 2>"$err"; then
    ACTIVATED=$(json_append "$ACTIVATED" "$(json_str "$id")")
    return 0
  fi
  reason=$(first_line "$err")
  attempts=$(json_get "$(dx_feedback_outbox attempt "$id" --owner "$OWNER")" attempts)
  if [[ "$attempts" -ge "$MAX_ATTEMPTS" ]]; then
    retire_candidate "$id" "activation failed $attempts times: $reason"
  else
    dx_feedback_outbox release "$id" --owner "$OWNER" >/dev/null
  fi
  ACTIVATION_FAILED=$(json_set "$ACTIVATION_FAILED" "$id" "$(json_str "$reason (attempt $attempts of $MAX_ATTEMPTS)")")
}

review_candidate() {  # review_candidate <id> : prints approve|reject|unavailable; records `review` in the evaluation
  local id="$1" package="$OUTBOX_DIR/$1" cand_dir="$RUN_ROOT/candidates/$1"
  local out="$RUN_ROOT/candidates/$1.review.json" started finished verdict reason
  started=$(date +%s)
  if bash "$REVIEWER" "$package" "$BASELINE_DIR" "$cand_dir" "$out" >"$cand_dir.review.out" 2>"$cand_dir.review.err"; then
    verdict=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1]))["decision"])' "$out")
  else
    verdict="unavailable"
    reason="review produced no decision: $(first_line "$cand_dir.review.err")"
    printf '{"decision": "unavailable", "reason": %s, "risks": [], "generality": "unknown"}\n' "$(json_str "$reason")" > "$out"
  fi
  finished=$(date +%s)
  python3 - "$cand_dir.evaluation.json" "$out" "$((finished - started))" <<'PY'
import json
import sys

evaluation_path, review_path, seconds = sys.argv[1:4]
with open(evaluation_path, encoding="utf-8") as handle:
    evaluation = json.load(handle)
with open(review_path, encoding="utf-8") as handle:
    review = json.load(handle)
review["model_calls"] = 1
review["seconds"] = int(seconds)
evaluation["review"] = review
cost = evaluation.setdefault("cost", {})
cost["model_calls"] = int(cost.get("model_calls", 0)) + 1
cost["model_seconds"] = int(cost.get("model_seconds", 0)) + int(seconds)
with open(evaluation_path, "w", encoding="utf-8") as handle:
    json.dump(evaluation, handle, indent=1, sort_keys=True)
PY
  printf '%s\n' "$verdict"
}
review_field() {  # review_field <id> <key> : one field of the recorded review
  python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("review", {}).get(sys.argv[2], ""))' \
    "$RUN_ROOT/candidates/$1.evaluation.json" "$2"
}

process_candidate() {  # process_candidate <id> ; the claim is already held
  local id="$1" package="$OUTBOX_DIR/$1" cand_dir="$RUN_ROOT/candidates/$1"
  local repro_source="none" model_calls=0 model_seconds=0 decision reason attempts out risk_tier check started verdict
  # A candidate validated earlier and left `evaluated` (activation was off, or
  # its review produced no decision) comes back through the same evaluation:
  # the reviewer needs the candidate runtime, and the baseline may have moved.
  [[ -f "$package/reproduction/check.sh" ]] && repro_source="submitted"
  if [[ ! -f "$package/reproduction/check.sh" && ! -f "$package/proposed-change.patch" ]]; then
    check="$cand_dir.check.sh"
    started=$(date +%s)
    model_calls=1
    if bash "$REPRODUCER" "$package" "$BASELINE_DIR" "$check" >"$cand_dir.reproduce.out" 2>"$cand_dir.reproduce.err"; then
      model_seconds=$(( $(date +%s) - started ))
      dx_feedback_outbox attach "$id" --owner "$OWNER" --reproduction "$check" --source model >/dev/null
      repro_source="model"
    else
      model_seconds=$(( $(date +%s) - started ))
      reason="no usable reproduction from the model: $(first_line "$cand_dir.reproduce.err")"
      attempts=$(json_get "$(dx_feedback_outbox attempt "$id" --owner "$OWNER")" attempts)
      if [[ "$attempts" -ge "$MAX_ATTEMPTS" ]]; then
        retire_candidate "$id" "could not produce a reproduction after $attempts attempts: $reason"
      else
        dx_feedback_outbox release "$id" --owner "$OWNER" >/dev/null
        skip "$id" "$reason (attempt $attempts of $MAX_ATTEMPTS)"
      fi
      return 0
    fi
  fi
  read -r decision reason < <(evaluate_candidate "$id" "$repro_source" "$model_calls" "$model_seconds")
  risk_tier=$(python3 -c 'import json, sys; print(json.load(open(sys.argv[1])).get("risk_tier", ""))' "$cand_dir.evaluation.json")
  DECISIONS=$(json_set "$DECISIONS" "$id" "$(json_str "$decision")")
  case "$decision" in
    validated)
      verdict=""
      if [[ "$ACTIVATE" == "low" && "$risk_tier" == "low" && "$REVIEW" == "on" ]]; then
        verdict=$(review_candidate "$id")
        REVIEWS=$(json_set "$REVIEWS" "$id" "$(json_str "$verdict")")
      fi
      case "$verdict" in
        reject)
          # The reviewer's reason is the retirement's; the evaluator's decision stays validated.
          retire_candidate "$id" "review: $(review_field "$id" reason)" "$cand_dir.evaluation.json"
          ;;
        unavailable)
          dx_feedback_outbox decide "$id" --owner "$OWNER" --decision validated --evaluation "$cand_dir.evaluation.json" >/dev/null
          dx_feedback_outbox claim "$id" --owner "$OWNER" --ttl-seconds "$CLAIM_TTL" >/dev/null
          attempts=$(json_get "$(dx_feedback_outbox attempt "$id" --owner "$OWNER")" attempts)
          reason=$(review_field "$id" reason)
          if [[ "$attempts" -ge "$MAX_ATTEMPTS" ]]; then
            retire_candidate "$id" "review unavailable after $attempts attempts: $reason"
          else
            dx_feedback_outbox release "$id" --owner "$OWNER" >/dev/null
          fi
          REVIEW_UNAVAILABLE=$(json_set "$REVIEW_UNAVAILABLE" "$id" "$(json_str "$reason (attempt $attempts of $MAX_ATTEMPTS)")")
          ;;
        *)
          dx_feedback_outbox decide "$id" --owner "$OWNER" --decision validated --evaluation "$cand_dir.evaluation.json" >/dev/null
          if [[ "$ACTIVATE" == "low" && "$risk_tier" == "low" ]]; then try_activate "$id"; fi
          ;;
      esac
      ;;
    rejected)
      if [[ "$repro_source" == "model" && "$reason" == "could not reproduce"* ]]; then
        # The model's own check says the problem is not there: nothing left to look for.
        retire_candidate "$id" "could not reproduce (model-written check passes on the baseline)" "$cand_dir.evaluation.json"
      else
        dx_feedback_outbox decide "$id" --owner "$OWNER" --decision rejected --evaluation "$cand_dir.evaluation.json" >/dev/null
      fi
      ;;
    inconclusive)
      out=$(dx_feedback_outbox decide "$id" --owner "$OWNER" --decision inconclusive --evaluation "$cand_dir.evaluation.json")
      attempts=$(json_get "$out" attempts)
      if [[ "$attempts" -ge "$MAX_ATTEMPTS" ]]; then
        if [[ ! -f "$package/proposed-change.patch" && "$reason" == "reproduced"* ]]; then
          reason="reproduced $attempts times, nothing fixed it"
          # A reproducible defect the consumer may not fix (its allowlist is
          # prompts and skills) is handed to a lifecycle as a ready brief, so
          # the retirement ends in work, not in a note.
          write_mission_brief "$id" "$package" "$attempts"
        else
          reason="inconclusive after $attempts evaluations"
        fi
        dx_feedback_outbox claim "$id" --owner "$OWNER" --ttl-seconds "$CLAIM_TTL" >/dev/null
        retire_candidate "$id" "$reason"
      fi
      ;;
  esac
}

while IFS=$'\t' read -r id origin state; do
  [[ -n "$id" ]] || continue
  [[ -z "$ONLY_CANDIDATE" || "$id" == "$ONLY_CANDIDATE" ]] || continue
  if [[ "$PROCESSED" -ge "$MAX_CANDIDATES" ]]; then skip "$id" "max-candidates reached"; continue; fi
  if [[ "$(date +%s)" -ge "$DEADLINE_EPOCH" ]]; then skip "$id" "max-minutes reached"; continue; fi
  if [[ "$origin" == "research" && "$INCLUDE_RESEARCH" -ne 1 ]]; then skip "$id" "origin research: deferred to a later campaign"; continue; fi
  if [[ "$state" == "captured" && "$REPRODUCE" != "on" ]]; then skip "$id" "captured: no reproduction or patch, and --reproduce is off"; continue; fi
  if ! dx_feedback_outbox claim "$id" --owner "$OWNER" --ttl-seconds "$CLAIM_TTL" >/dev/null 2>"$RUN_ROOT/candidates/$id.claim.err"; then
    skip "$id" "claim refused: $(first_line "$RUN_ROOT/candidates/$id.claim.err")"; continue
  fi
  process_candidate "$id"
  PROCESSED=$((PROCESSED + 1))
done < <(dx_feedback_outbox list | ACTIVATE="$ACTIVATE" python3 -c 'import json, os, sys
for row in json.load(sys.stdin):
    state = row.get("state")
    wanted = state in ("eligible", "captured") or (
        state == "evaluated" and row.get("decision") == "validated" and os.environ["ACTIVATE"] == "low")
    if wanted:
        print(row["id"] + "\t" + str(row.get("origin", "project")) + "\t" + state)')

python3 - "$PROCESSED" "$DECISIONS" "$SKIPPED" "$RUN_ROOT" "$BASELINE_SOURCE" "$BASELINE_HASH" "$OWNER" \
  "$ACTIVATED" "$RETIRED" "$RETIRED_REASONS" "$ACTIVATION_FAILED" "$ACTIVATE" "$REPRODUCE" "$MAX_ATTEMPTS" "$LIVE_DEX_DIR" \
  "$REVIEW" "$REVIEWS" "$REVIEW_UNAVAILABLE" <<'PY'
import json
import sys

a = sys.argv[1:]
print(json.dumps({
    "processed": int(a[0]), "decisions": json.loads(a[1]), "skipped": json.loads(a[2]), "run_dir": a[3],
    "baseline": {"source": a[4], "tree_hash": a[5]}, "owner": a[6],
    "activated": json.loads(a[7]), "retired": json.loads(a[8]), "retired_reasons": json.loads(a[9]),
    "activation_failed": json.loads(a[10]), "activate": a[11], "reproduce": a[12],
    "max_attempts": int(a[13]), "dex_dir_live": a[14],
    "review": a[15], "reviews": json.loads(a[16]), "review_unavailable": json.loads(a[17]),
}, sort_keys=True))
PY
