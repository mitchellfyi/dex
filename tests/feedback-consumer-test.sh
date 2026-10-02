#!/usr/bin/env bash
set -euo pipefail

# research/consume.sh is the separate, bounded workflow that evaluates what
# the outbox holds. It refuses to run without finite caps, claims one
# candidate at a time, builds a pinned read-only baseline runtime, applies the
# candidate's patch to a copy all-or-nothing and only within the allowlist,
# runs the evaluator against both, and records an honest decision. The
# baseline is never changed; a bad patch is rejected with the reason; feedback
# the learner raised about itself waits for a later campaign.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-feedback-consumer-test.XXXXXX")"
# macOS sets TMPDIR with a trailing slash; the outbox records normalised
# absolute paths, so the paths asserted against have to be normalised too.
TMP_DIR="$(cd "$TMP_DIR" && pwd)"
cleanup() { chmod -R u+w "$TMP_DIR" 2>/dev/null || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_FEEDBACK_DIR="$TMP_DIR/feedback"
export DX_RESEARCH_ROOT="$TMP_DIR/research-root"
mkdir -p "$HOME"
OUTBOX="$ROOT/scripts/feedback_outbox.py"
CONSUME="$ROOT/research/consume.sh"
jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }

# A reproduction that fails on the baseline and passes once the candidate's
# prompt change is present: it looks for a sentence the patch adds.
cat > "$TMP_DIR/check.sh" <<'CHECK'
#!/usr/bin/env bash
grep -q "Treat heredoc bodies as data" "$DEX_DIR/prompts/guardrails.md"
CHECK
# Patches come from a throwaway git repo holding the two files as they are in
# HEAD, so their headers are consistent and `git apply -p1` reads them.
WORK="$TMP_DIR/work"
mkdir -p "$WORK"
PROMPT_FILES="prompts/guardrails.md prompts/review.md prompts/commit-format.md prompts/pr-description.md prompts/review-wave.md"
# shellcheck disable=SC2086  # a word list on purpose
git -C "$ROOT" archive HEAD $PROMPT_FILES research/config.sh | tar -xf - -C "$WORK"
git init -q -b main "$WORK"
git -C "$WORK" config user.email "dex@example.com"
git -C "$WORK" config user.name "Dex Test"
git -C "$WORK" add .
git -C "$WORK" -c commit.gpgsign=false commit -q -m "baseline files"
# Good candidate: a one-line addition to an allowlisted prompt.
GOOD_PATCH="$TMP_DIR/good.patch"
printf '\nTreat heredoc bodies as data when deciding whether a command committed.\n' >> "$WORK/prompts/guardrails.md"
git -C "$WORK" diff -- prompts/guardrails.md > "$GOOD_PATCH"
git -C "$WORK" checkout -q -- prompts/guardrails.md
# Bad candidate: edits the research configuration, outside the allowlist.
BAD_PATCH="$TMP_DIR/bad.patch"
printf '\nMAX_IMPROVE_ITERATIONS=0\n' >> "$WORK/research/config.sh"
git -C "$WORK" diff -- research/config.sh > "$BAD_PATCH"
git -C "$WORK" checkout -q -- research/config.sh
[[ -s "$GOOD_PATCH" && -s "$BAD_PATCH" ]] || assert_at $LINENO
# The "live" Dex checkout a validated low-risk change is activated into. Every
# run below names it, so nothing in this test can write to the real checkout.
LIVE="$TMP_DIR/live"
mkdir -p "$LIVE"
# shellcheck disable=SC2086  # a word list on purpose
git -C "$ROOT" archive HEAD $PROMPT_FILES | tar -xf - -C "$LIVE"
git init -q -b main "$LIVE"
git -C "$LIVE" config user.email "dex@example.com"
git -C "$LIVE" config user.name "Dex Test"
git -C "$LIVE" add .
git -C "$LIVE" -c commit.gpgsign=false commit -q -m "live baseline"
LIVE_HEAD="$(git -C "$LIVE" rev-parse HEAD)"

# Every run goes through this stub, never the real `claude`: both the
# reproduction and the review reach `claude -p`, and a test must not spend a
# model call or depend on one. The call's shape picks the answer.
STUB_DIR="$TMP_DIR/stub"
mkdir -p "$STUB_DIR"
cat > "$STUB_DIR/claude" <<'STUB'
#!/usr/bin/env bash
# Appends its arguments to the call log, keeps what arrived on stdin, and
# answers from the file the call's shape selects: a review call sends its
# prompt on stdin, so its last argument is a flag, and gets
# DX_STUB_REVIEW_ANSWER (or fails with DX_STUB_REVIEW_EXIT); a reproduction
# call passes the prompt as its last argument and gets DX_STUB_ANSWER.
printf '%s\n' "$*" >> "${DX_STUB_CALL_LOG:?}"
cat > "${DX_STUB_CALL_LOG}.stdin"
last="${!#}"
case "$last" in
  --*)
    [[ "${DX_STUB_REVIEW_EXIT:-0}" == "0" ]] || exit "$DX_STUB_REVIEW_EXIT"
    cat "${DX_STUB_REVIEW_ANSWER:?}" ;;
  *) cat "${DX_STUB_ANSWER:?}" ;;
esac
STUB
chmod +x "$STUB_DIR/claude"
export DX_CONSUME_CLAUDE_BIN="$STUB_DIR/claude"
cat > "$TMP_DIR/review-approve.md" <<'ANSWER'
The file has no rule about heredoc bodies, and the sentence states one that
every repository with the guard can follow.

```json
{"decision": "approve", "reason": "states a rule the file lacks and applies to every repository with the post-commit guard", "risks": ["none observed"], "generality": "dex-wide"}
```
ANSWER
cat > "$TMP_DIR/review-reject.md" <<'ANSWER'
```json
{"decision": "reject", "reason": "restates the existing heredoc guidance and is specific to one repository", "risks": ["context cost for every session"], "generality": "repo"}
```
ANSWER
cat > "$TMP_DIR/answer-fails.md" <<'ANSWER'
The guardrails never say how to treat heredoc bodies, so the check looks for
the sentence a fix would add.

```bash
#!/usr/bin/env bash
set -euo pipefail
grep -q "Treat heredoc bodies as data" "$DEX_DIR/prompts/guardrails.md"
```
ANSWER
printf 'I cannot tell from the evidence given.\n' > "$TMP_DIR/answer-none.md"
consume() {
  DX_STUB_CALL_LOG="${DX_STUB_CALL_LOG:-$TMP_DIR/stub-default.log}" \
  DX_STUB_ANSWER="${DX_STUB_ANSWER:-$TMP_DIR/answer-none.md}" \
  DX_STUB_REVIEW_ANSWER="${DX_STUB_REVIEW_ANSWER:-$TMP_DIR/review-approve.md}" \
    bash "$CONSUME" --max-minutes 10 --max-iterations 1 --dex-source head --dex-dir-live "$LIVE" "$@"
}
# Broken candidate: a patch whose context does not exist.
BROKEN_PATCH="$TMP_DIR/broken.patch"
cat > "$BROKEN_PATCH" <<'P'
--- prompts/guardrails.md
+++ prompts/guardrails.md
@@ -1,3 +1,4 @@
 this line does not exist in guardrails
+added
 nor this one
 nor this
P

submit() { python3 "$OUTBOX" "$DX_FEEDBACK_DIR" submit "$@" | python3 -c 'import json,sys; print(json.load(sys.stdin)["id"])'; }
GOOD_ID="$(submit --patch "$GOOD_PATCH" --reproduction "$TMP_DIR/check.sh" --json '{"mechanism": "commit-target parser reads heredoc bodies", "symptom": "false commit warning", "evidence_summary": "seen twice", "candidate_mechanism": "say so in the guardrails"}')"
BAD_ID="$(submit --patch "$BAD_PATCH" --reproduction "$TMP_DIR/check.sh" --json '{"mechanism": "unlimited research iterations", "symptom": "loop", "evidence_summary": "e"}')"
BROKEN_ID="$(submit --patch "$BROKEN_PATCH" --reproduction "$TMP_DIR/check.sh" --json '{"mechanism": "stale patch", "symptom": "s", "evidence_summary": "e"}')"
RESEARCH_ID="$(DX_RESEARCH_CONSUMER_ACTIVE=1 submit --patch "$GOOD_PATCH" --reproduction "$TMP_DIR/check.sh" --json '{"mechanism": "learner about learner", "symptom": "s", "evidence_summary": "e"}')"

# ── caps are required ──────────────────────────────────────────────────────
set +e
bash "$CONSUME" --max-candidates 3 --max-minutes 5 > /dev/null 2>&1
RC=$?
set -e
[[ "$RC" == "2" ]] || assert_at $LINENO

# ── one bounded run: good validated and activated, bad and broken rejected, research skipped ─
consume --max-candidates 3 > "$TMP_DIR/run.json" 2> "$TMP_DIR/run.err" || { cat "$TMP_DIR/run.err" >&2; assert_at $LINENO; }
[[ "$(jget "$TMP_DIR/run.json" 'd["processed"]')" == "3" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run.json" "d['decisions']['$GOOD_ID']")" == "validated" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run.json" "d['decisions']['$BAD_ID']")" == "rejected" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run.json" "d['decisions']['$BROKEN_ID']")" == "rejected" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run.json" "any(s['id'] == '$RESEARCH_ID' for s in d['skipped'])")" == "True" ]] || assert_at $LINENO
# The summary names what reached a terminal state this run.
[[ "$(jget "$TMP_DIR/run.json" 'd["activated"]')" == "['$GOOD_ID']" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run.json" 'd["retired"]')" == "[]" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run.json" 'd["activate"]')" == "low" ]] || assert_at $LINENO

GOOD_EVAL="$DX_FEEDBACK_DIR/$GOOD_ID/evaluation.json"
[[ "$(jget "$GOOD_EVAL" 'd["decision"]')" == "validated" ]] || assert_at $LINENO
[[ "$(jget "$GOOD_EVAL" 'd["baseline"]["reproduction"]')" == "fail" ]] || assert_at $LINENO
[[ "$(jget "$GOOD_EVAL" 'd["candidate"]["reproduction"]')" == "pass" ]] || assert_at $LINENO
[[ "$(jget "$GOOD_EVAL" 'd["baseline"]["static"]')" == "pass" ]] || assert_at $LINENO
[[ "$(jget "$GOOD_EVAL" 'len(d["baseline_runtime"]["tree_hash"]) == 64')" == "True" ]] || assert_at $LINENO
[[ "$(jget "$GOOD_EVAL" 'd["baseline_runtime"]["source"]')" == head* ]] || assert_at $LINENO
[[ "$(jget "$GOOD_EVAL" 'd["changed_paths"]')" == "['prompts/guardrails.md']" ]] || assert_at $LINENO
[[ "$(jget "$GOOD_EVAL" 'd["cost"]["seconds"] >= 0')" == "True" ]] || assert_at $LINENO
[[ "$(jget "$GOOD_EVAL" 'd["cost"]["model_calls"]')" == "1" ]] || assert_at $LINENO
[[ "$(jget "$GOOD_EVAL" 'd["risk_tier"]')" == "low" ]] || assert_at $LINENO
[[ "$(jget "$GOOD_EVAL" 'd["reproduction_source"]')" == "submitted" ]] || assert_at $LINENO
# Validated and low-risk: activated into the live checkout, unstaged, with the
# rollback recorded in both the manifest and the evaluation.
GOOD_MANIFEST="$DX_FEEDBACK_DIR/$GOOD_ID/manifest.json"
[[ "$(jget "$GOOD_MANIFEST" 'd["state"]')" == "activated" ]] || assert_at $LINENO
[[ "$(jget "$GOOD_MANIFEST" 'd["activation"]["head"]')" == "$LIVE_HEAD" ]] || assert_at $LINENO
[[ "$(jget "$GOOD_MANIFEST" 'd["activation"]["dex_dir"]')" == "$LIVE" ]] || assert_at $LINENO
[[ "$(jget "$GOOD_EVAL" 'd["activation"]["rollback"]')" == "git -C $LIVE apply -R $DX_FEEDBACK_DIR/$GOOD_ID/proposed-change.patch" ]] || assert_at $LINENO
assert_contains "Treat heredoc bodies as data" "$LIVE/prompts/guardrails.md"
[[ "$(git -C "$LIVE" status --porcelain -- prompts/guardrails.md)" == " M prompts/guardrails.md" ]] || assert_at $LINENO
[[ "$(git -C "$LIVE" rev-parse HEAD)" == "$LIVE_HEAD" ]] || assert_at $LINENO
# Between validated and activate a fresh bounded model session reviewed the
# change and approved it; the record says so and what it cost.
[[ "$(jget "$GOOD_EVAL" 'd["review"]["decision"]')" == "approve" ]] || assert_at $LINENO
[[ "$(jget "$GOOD_EVAL" 'd["review"]["generality"]')" == "dex-wide" ]] || assert_at $LINENO
[[ "$(jget "$GOOD_EVAL" 'd["review"]["risks"]')" == "['none observed']" ]] || assert_at $LINENO
[[ "$(jget "$GOOD_EVAL" 'd["review"]["model_calls"]')" == "1" ]] || assert_at $LINENO
[[ "$(jget "$GOOD_EVAL" 'd["review"]["seconds"] >= 0')" == "True" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run.json" "d['reviews']['$GOOD_ID']")" == "approve" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run.json" 'd["review"]')" == "on" ]] || assert_at $LINENO
# Called as the contract says: print mode, bounded turns, read-only tools,
# isolated settings, and the prompt on stdin with the bar, the diff and the mechanism.
[[ "$(grep -m1 -- '--allowedTools' "$TMP_DIR/stub-default.log")" == "-p --output-format text --max-turns 4 --allowedTools Read,Grep,Glob --disallowedTools Edit,Write,NotebookEdit,Bash,Agent --setting-sources project,local --strict-mcp-config" ]] || assert_at $LINENO
assert_contains "more than the one incident" "$TMP_DIR/stub-default.log.stdin"
assert_contains "+Treat heredoc bodies as data" "$TMP_DIR/stub-default.log.stdin"
assert_contains "commit-target parser reads heredoc bodies" "$TMP_DIR/stub-default.log.stdin"

BAD_EVAL="$DX_FEEDBACK_DIR/$BAD_ID/evaluation.json"
[[ "$(jget "$BAD_EVAL" 'd["decision"]')" == "rejected" ]] || assert_at $LINENO
assert_contains "allowlist" "$BAD_EVAL"
assert_contains "research/config.sh" "$BAD_EVAL"
[[ "$(jget "$BAD_EVAL" 'd["risk_tier"]')" == "high" ]] || assert_at $LINENO
[[ "$(jget "$DX_FEEDBACK_DIR/$BAD_ID/manifest.json" 'd["state"]')" == "evaluated" ]] || assert_at $LINENO
BROKEN_EVAL="$DX_FEEDBACK_DIR/$BROKEN_ID/evaluation.json"
[[ "$(jget "$BROKEN_EVAL" 'd["decision"]')" == "rejected" ]] || assert_at $LINENO
assert_contains "does not apply" "$BROKEN_EVAL"

# The baseline runtime was never changed: its recorded hash matches a fresh one.
BASE_DIR="$(jget "$GOOD_EVAL" 'd["baseline_runtime"]["dir"]')"
[[ -d "$BASE_DIR" ]] || assert_at $LINENO
# shellcheck disable=SC1091
source "$ROOT/research/review-loop/lib.sh"
[[ "$(review_eval_runtime_tree_hash "$BASE_DIR")" == "$(jget "$GOOD_EVAL" 'd["baseline_runtime"]["tree_hash"]')" ]] || assert_at $LINENO
[[ ! -w "$BASE_DIR/prompts/guardrails.md" ]] || assert_at $LINENO
assert_not_contains "Treat heredoc bodies as data" "$BASE_DIR/prompts/guardrails.md"

# ── a second run finds nothing eligible and says so without a model call ───
consume --max-candidates 3 > "$TMP_DIR/run2.json"
[[ "$(jget "$TMP_DIR/run2.json" 'd["processed"]')" == "0" ]] || assert_at $LINENO

# ── reproduction only: a confirmed bug with no change yet is inconclusive ──
# The reproduction fails on the baseline (the bug is real) and there is no
# patch; the honest decision is "reproduced, nothing to evaluate", not a pass
# and not a rejection of a fix nobody proposed.
REPRO_ID="$(submit --reproduction "$TMP_DIR/check.sh" --json '{"mechanism": "reproduced but unfixed", "symptom": "s", "evidence_summary": "e"}')"
printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_DIR/passes.sh"
NOREPRO_ID="$(submit --reproduction "$TMP_DIR/passes.sh" --json '{"mechanism": "claimed bug that does not reproduce", "symptom": "s", "evidence_summary": "e"}')"
consume --max-candidates 2 > "$TMP_DIR/run-repro.json"
[[ "$(jget "$TMP_DIR/run-repro.json" "d['decisions']['$REPRO_ID']")" == "inconclusive" ]] || assert_at $LINENO
assert_contains "reproduced" "$DX_FEEDBACK_DIR/$REPRO_ID/evaluation.json"
[[ "$(jget "$TMP_DIR/run-repro.json" "d['decisions']['$NOREPRO_ID']")" == "rejected" ]] || assert_at $LINENO
assert_contains "could not reproduce" "$DX_FEEDBACK_DIR/$NOREPRO_ID/evaluation.json"
# Inconclusive is not a parking state: the candidate is eligible again with one attempt spent.
REPRO_MANIFEST="$DX_FEEDBACK_DIR/$REPRO_ID/manifest.json"
[[ "$(jget "$REPRO_MANIFEST" 'd["state"]')" == "eligible" ]] || assert_at $LINENO
[[ "$(jget "$REPRO_MANIFEST" 'd["attempts"]')" == "1" ]] || assert_at $LINENO
[[ "$(jget "$DX_FEEDBACK_DIR/$REPRO_ID/evaluation.json" 'd["risk_tier"]')" == "none" ]] || assert_at $LINENO

# ── working-tree source, activation off: validated but left for a human ────
WT_ID="$(submit --patch "$GOOD_PATCH" --reproduction "$TMP_DIR/check.sh" --json '{"mechanism": "commit-target parser reads heredoc bodies (working tree)", "symptom": "s", "evidence_summary": "e"}')"
bash "$CONSUME" --max-candidates 1 --max-minutes 10 --max-iterations 1 --dex-source working-tree --candidate "$WT_ID" --activate off --dex-dir-live "$LIVE" > "$TMP_DIR/run3.json"
[[ "$(jget "$TMP_DIR/run3.json" "d['decisions']['$WT_ID']")" == "validated" ]] || assert_at $LINENO
[[ "$(jget "$DX_FEEDBACK_DIR/$WT_ID/evaluation.json" 'd["baseline_runtime"]["source"]')" == working-tree* ]] || assert_at $LINENO
[[ "$(jget "$DX_FEEDBACK_DIR/$WT_ID/manifest.json" 'd["state"]')" == "evaluated" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run3.json" 'd["activated"]')" == "[]" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run3.json" 'd["activate"]')" == "off" ]] || assert_at $LINENO
# DX_RESEARCH_AUTO_ACTIVATE is the default the flag overrides.
DX_RESEARCH_AUTO_ACTIVATE=off consume --max-candidates 1 --candidate "$NOREPRO_ID" > "$TMP_DIR/run3b.json"
[[ "$(jget "$TMP_DIR/run3b.json" 'd["activate"]')" == "off" ]] || assert_at $LINENO

# ── inconclusive three times: retired with the reason, and never listed again ─
consume --max-candidates 1 --candidate "$REPRO_ID" > "$TMP_DIR/run4.json"
[[ "$(jget "$REPRO_MANIFEST" 'd["attempts"]')" == "2" ]] || assert_at $LINENO
[[ "$(jget "$REPRO_MANIFEST" 'd["state"]')" == "eligible" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run4.json" 'd["retired"]')" == "[]" ]] || assert_at $LINENO
consume --max-candidates 1 --candidate "$REPRO_ID" > "$TMP_DIR/run5.json"
[[ "$(jget "$TMP_DIR/run5.json" "d['decisions']['$REPRO_ID']")" == "inconclusive" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run5.json" 'd["retired"]')" == "['$REPRO_ID']" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run5.json" "d['retired_reasons']['$REPRO_ID']")" == "reproduced 3 times, nothing fixed it" ]] || assert_at $LINENO
[[ "$(jget "$REPRO_MANIFEST" 'd["state"]')" == "retired" ]] || assert_at $LINENO
[[ "$(jget "$REPRO_MANIFEST" 'd["attempts"]')" == "3" ]] || assert_at $LINENO
[[ "$(jget "$REPRO_MANIFEST" 'd["retired_reason"]')" == "reproduced 3 times, nothing fixed it" ]] || assert_at $LINENO
# A reproducible defect outside the allowlist leaves as a lifecycle brief, not a note.
[[ -f "$DX_FEEDBACK_DIR/$REPRO_ID/mission-brief.md" ]] || assert_at $LINENO
assert_contains "reproduction/check.sh" "$DX_FEEDBACK_DIR/$REPRO_ID/mission-brief.md"
assert_contains "dx --workflow" "$DX_FEEDBACK_DIR/$REPRO_ID/mission-brief.md"
consume --max-candidates 1 --candidate "$REPRO_ID" > "$TMP_DIR/run6.json"
[[ "$(jget "$TMP_DIR/run6.json" 'd["processed"]')" == "0" ]] || assert_at $LINENO
# A lower --max-attempts retires sooner: a fresh inconclusive candidate goes after one look.
ONESHOT_ID="$(submit --reproduction "$TMP_DIR/check.sh" --json '{"mechanism": "reproduced once and retired", "symptom": "s", "evidence_summary": "e"}')"
consume --max-candidates 1 --candidate "$ONESHOT_ID" --max-attempts 1 > "$TMP_DIR/run7.json"
[[ "$(jget "$DX_FEEDBACK_DIR/$ONESHOT_ID/manifest.json" 'd["state"]')" == "retired" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run7.json" "d['retired_reasons']['$ONESHOT_ID']")" == "reproduced 1 times, nothing fixed it" ]] || assert_at $LINENO

# ── captured: the model writes the missing reproduction ────────────────────
# The stub answers a reproduction call with one fenced bash block, the way the
# prompt asks the model to.
CAPTURED_ID="$(submit --json '{"mechanism": "guardrails never mention heredoc bodies", "symptom": "false commit warning", "evidence_summary": "seen in two missions", "reproduction_gap": "no check written yet"}')"
CAPTURED_MANIFEST="$DX_FEEDBACK_DIR/$CAPTURED_ID/manifest.json"
[[ "$(jget "$CAPTURED_MANIFEST" 'd["state"]')" == "captured" ]] || assert_at $LINENO
# --reproduce off leaves a captured candidate alone and calls no model.
DX_STUB_CALL_LOG="$TMP_DIR/stub-call.log" consume --max-candidates 1 --candidate "$CAPTURED_ID" --reproduce off > "$TMP_DIR/run-off.json"
[[ "$(jget "$TMP_DIR/run-off.json" 'd["processed"]')" == "0" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run-off.json" "any(s['id'] == '$CAPTURED_ID' and 'reproduce' in s['reason'] for s in d['skipped'])")" == "True" ]] || assert_at $LINENO
[[ "$(jget "$CAPTURED_MANIFEST" 'd["state"]')" == "captured" ]] || assert_at $LINENO
[[ ! -e "$TMP_DIR/stub-call.log" ]] || assert_at $LINENO
# With reproduction on, the model's check is installed, the candidate becomes
# eligible and is evaluated in the same run: the check fails on the baseline,
# so the bug is real but nothing fixes it yet.
DX_STUB_CALL_LOG="$TMP_DIR/stub-call.log" DX_STUB_ANSWER="$TMP_DIR/answer-fails.md" \
  consume --max-candidates 1 --candidate "$CAPTURED_ID" > "$TMP_DIR/run-cap.json" 2> "$TMP_DIR/run-cap.err" || { cat "$TMP_DIR/run-cap.err" >&2; assert_at $LINENO; }
[[ "$(jget "$TMP_DIR/run-cap.json" "d['decisions']['$CAPTURED_ID']")" == "inconclusive" ]] || assert_at $LINENO
[[ "$(jget "$CAPTURED_MANIFEST" 'd["state"]')" == "eligible" ]] || assert_at $LINENO
[[ "$(jget "$CAPTURED_MANIFEST" 'd["attempts"]')" == "1" ]] || assert_at $LINENO
[[ "$(jget "$CAPTURED_MANIFEST" 'd["has_reproduction"]')" == "True" ]] || assert_at $LINENO
[[ "$(jget "$CAPTURED_MANIFEST" 'd["reproduction_source"]["kind"]')" == "model" ]] || assert_at $LINENO
[[ -x "$DX_FEEDBACK_DIR/$CAPTURED_ID/reproduction/check.sh" ]] || assert_at $LINENO
[[ "$(stat -c '%a' "$DX_FEEDBACK_DIR/$CAPTURED_ID/reproduction/check.sh" 2>/dev/null || stat -f '%Lp' "$DX_FEEDBACK_DIR/$CAPTURED_ID/reproduction/check.sh")" == "700" ]] || assert_at $LINENO
assert_contains "Treat heredoc bodies as data" "$DX_FEEDBACK_DIR/$CAPTURED_ID/reproduction/check.sh"
CAPTURED_EVAL="$DX_FEEDBACK_DIR/$CAPTURED_ID/evaluation.json"
assert_contains "reproduced, no change proposed" "$CAPTURED_EVAL"
[[ "$(jget "$CAPTURED_EVAL" 'd["cost"]["model_calls"]')" == "1" ]] || assert_at $LINENO
[[ "$(jget "$CAPTURED_EVAL" 'd["cost"]["model_seconds"] >= 0')" == "True" ]] || assert_at $LINENO
[[ "$(jget "$CAPTURED_EVAL" 'd["reproduction_source"]')" == "model" ]] || assert_at $LINENO
[[ "$(jget "$CAPTURED_EVAL" 'd["baseline"]["reproduction"]')" == "fail" ]] || assert_at $LINENO
# The model was called the way the contract says: print mode, bounded turns,
# read-only tools, isolated settings, text output, then the prompt naming the mechanism.
[[ "$(head -1 "$TMP_DIR/stub-call.log")" == "-p --max-turns 12 --allowedTools Read,Grep,Glob --disallowedTools Edit,Write,NotebookEdit,Bash,Agent --setting-sources project,local --strict-mcp-config --output-format text "* ]] || assert_at $LINENO
assert_contains "guardrails never mention heredoc bodies" "$TMP_DIR/stub-call.log"
# Two more looks spend the budget. No new model call: the check is already in the package.
rm -f "$TMP_DIR/stub-call.log"
DX_STUB_CALL_LOG="$TMP_DIR/stub-call.log" consume --max-candidates 1 --candidate "$CAPTURED_ID" > "$TMP_DIR/run-cap2.json"
[[ ! -e "$TMP_DIR/stub-call.log" ]] || assert_at $LINENO
[[ "$(jget "$CAPTURED_MANIFEST" 'd["attempts"]')" == "2" ]] || assert_at $LINENO
[[ "$(jget "$CAPTURED_EVAL" 'd["cost"]["model_calls"]')" == "0" ]] || assert_at $LINENO
DX_STUB_CALL_LOG="$TMP_DIR/stub-call.log" consume --max-candidates 1 --candidate "$CAPTURED_ID" > "$TMP_DIR/run-cap3.json"
[[ "$(jget "$CAPTURED_MANIFEST" 'd["state"]')" == "retired" ]] || assert_at $LINENO
[[ "$(jget "$CAPTURED_MANIFEST" 'd["retired_reason"]')" == "reproduced 3 times, nothing fixed it" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run-cap3.json" 'd["retired"]')" == "['$CAPTURED_ID']" ]] || assert_at $LINENO

# A model-written check that passes on the baseline retires the candidate at once.
cat > "$TMP_DIR/answer-passes.md" <<'ANSWER'
```bash
#!/usr/bin/env bash
set -euo pipefail
test -f "$DEX_DIR/dx.sh"
```
ANSWER
PHANTOM_ID="$(submit --json '{"mechanism": "a problem that is not there", "symptom": "s", "evidence_summary": "e"}')"
DX_STUB_CALL_LOG="$TMP_DIR/stub-call-2.log" DX_STUB_ANSWER="$TMP_DIR/answer-passes.md" \
  consume --max-candidates 1 --candidate "$PHANTOM_ID" > "$TMP_DIR/run-phantom.json"
PHANTOM_MANIFEST="$DX_FEEDBACK_DIR/$PHANTOM_ID/manifest.json"
[[ "$(jget "$PHANTOM_MANIFEST" 'd["state"]')" == "retired" ]] || assert_at $LINENO
[[ "$(jget "$PHANTOM_MANIFEST" 'd["retired_reason"]')" == "could not reproduce (model-written check passes on the baseline)" ]] || assert_at $LINENO
[[ "$(jget "$PHANTOM_MANIFEST" 'd["decision"]')" == "rejected" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run-phantom.json" 'd["retired"]')" == "['$PHANTOM_ID']" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run-phantom.json" "d['decisions']['$PHANTOM_ID']")" == "rejected" ]] || assert_at $LINENO
[[ "$(jget "$DX_FEEDBACK_DIR/$PHANTOM_ID/evaluation.json" 'd["retired_reason"]')" == "could not reproduce (model-written check passes on the baseline)" ]] || assert_at $LINENO
[[ "$(jget "$DX_FEEDBACK_DIR/$PHANTOM_ID/evaluation.json" 'd["cost"]["model_calls"]')" == "1" ]] || assert_at $LINENO

# An answer with no fenced bash block produces nothing: the attempt is counted
# and the candidate stays captured for a later run.
MUTE_ID="$(submit --json '{"mechanism": "evidence too thin to check", "symptom": "s", "evidence_summary": "e"}')"
DX_STUB_CALL_LOG="$TMP_DIR/stub-call-3.log" DX_STUB_ANSWER="$TMP_DIR/answer-none.md" \
  consume --max-candidates 1 --candidate "$MUTE_ID" > "$TMP_DIR/run-mute.json"
MUTE_MANIFEST="$DX_FEEDBACK_DIR/$MUTE_ID/manifest.json"
[[ "$(jget "$MUTE_MANIFEST" 'd["state"]')" == "captured" ]] || assert_at $LINENO
[[ "$(jget "$MUTE_MANIFEST" 'd["attempts"]')" == "1" ]] || assert_at $LINENO
[[ "$(jget "$MUTE_MANIFEST" 'd["claim"]')" == "None" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run-mute.json" "any(s['id'] == '$MUTE_ID' and 'bash block' in s['reason'] for s in d['skipped'])")" == "True" ]] || assert_at $LINENO
# The reproduction budget is the attempt budget: a third empty answer retires it.
for _ in 1 2; do
  DX_STUB_CALL_LOG="$TMP_DIR/stub-call-3.log" DX_STUB_ANSWER="$TMP_DIR/answer-none.md" \
    consume --max-candidates 1 --candidate "$MUTE_ID" > "$TMP_DIR/run-mute.json"
done
[[ "$(jget "$MUTE_MANIFEST" 'd["state"]')" == "retired" ]] || assert_at $LINENO
[[ "$(jget "$MUTE_MANIFEST" 'd["retired_reason"]')" == could\ not\ produce\ a\ reproduction* ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run-mute.json" 'd["retired"]')" == "['$MUTE_ID']" ]] || assert_at $LINENO

# ── the denylist reads commands, not text ──────────────────────────────────
# A reproduction of a parser bug carries `git commit` as heredoc data, and a
# sandboxed init needs a stub file named curl; neither runs the denied thing.
cat > "$TMP_DIR/answer-data.md" <<'ANSWER'
```bash
#!/usr/bin/env bash
set -euo pipefail
T=$(mktemp -d)
trap 'rm -rf "$T"' EXIT
cat > "$T/probe.txt" <<'OUTER'
python3 - <<'PY'
print("git commit -m 'Merge branch main'")
PY
OUTER
# curl is stubbed so nothing reaches the network
printf '#!/usr/bin/env bash\nexit 0\n' > "$T/curl"
chmod 700 "$T/curl"
grep -q "Merge branch" "$T/probe.txt" || exit 0
exit 1
```
ANSWER
DATA_ID="$(submit --json '{"mechanism": "parser reads heredoc data as a command", "symptom": "s", "evidence_summary": "e"}')"
DX_STUB_CALL_LOG="$TMP_DIR/stub-call-4.log" DX_STUB_ANSWER="$TMP_DIR/answer-data.md" \
  consume --max-candidates 1 --candidate "$DATA_ID" > "$TMP_DIR/run-data.json" 2> "$TMP_DIR/run-data.err" || { cat "$TMP_DIR/run-data.err" >&2; assert_at $LINENO; }
DATA_MANIFEST="$DX_FEEDBACK_DIR/$DATA_ID/manifest.json"
[[ "$(jget "$DATA_MANIFEST" 'd["has_reproduction"]')" == "True" ]] || { cat "$TMP_DIR/run-data.json" >&2; assert_at $LINENO; }
[[ "$(jget "$TMP_DIR/run-data.json" "d['decisions']['$DATA_ID']")" == "inconclusive" ]] || assert_at $LINENO
assert_contains "Merge branch main" "$DX_FEEDBACK_DIR/$DATA_ID/reproduction/check.sh"
# The same words in command position are still refused.
cat > "$TMP_DIR/answer-mutates.md" <<'ANSWER'
```bash
#!/usr/bin/env bash
set -euo pipefail
cd "$DEX_DIR" && git commit -q --allow-empty -m "probe"
exit 1
```
ANSWER
MUTATE_ID="$(submit --json '{"mechanism": "a check that would commit", "symptom": "s", "evidence_summary": "e"}')"
DX_STUB_CALL_LOG="$TMP_DIR/stub-call-5.log" DX_STUB_ANSWER="$TMP_DIR/answer-mutates.md" \
  consume --max-candidates 1 --candidate "$MUTATE_ID" > "$TMP_DIR/run-mutate.json"
[[ "$(jget "$DX_FEEDBACK_DIR/$MUTATE_ID/manifest.json" 'd["has_reproduction"]')" == "False" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run-mutate.json" "any(s['id'] == '$MUTATE_ID' and 'git mutation' in s['reason'] for s in d['skipped'])")" == "True" ]] || { cat "$TMP_DIR/run-mutate.json" >&2; assert_at $LINENO; }
cat > "$TMP_DIR/answer-network.md" <<'ANSWER'
```bash
#!/usr/bin/env bash
set -euo pipefail
curl -fsS https://example.test/ > /dev/null || exit 1
```
ANSWER
NET_ID="$(submit --json '{"mechanism": "a check that would reach the network", "symptom": "s", "evidence_summary": "e"}')"
DX_STUB_CALL_LOG="$TMP_DIR/stub-call-6.log" DX_STUB_ANSWER="$TMP_DIR/answer-network.md" \
  consume --max-candidates 1 --candidate "$NET_ID" > "$TMP_DIR/run-net.json"
[[ "$(jget "$TMP_DIR/run-net.json" "any(s['id'] == '$NET_ID' and 'network access' in s['reason'] for s in d['skipped'])")" == "True" ]] || { cat "$TMP_DIR/run-net.json" >&2; assert_at $LINENO; }

# ── the review gate: a fresh model session judges a validated change before it goes live ─
# A hunk with no trailing context must match at the end of the file, so each
# candidate here appends to a different allowlisted prompt file.
make_patch() {  # make_patch <out.patch> <prompts-file> <sentence> : one appended line, as a git diff
  cp "$WORK/prompts/$2" "$TMP_DIR/prompt.orig"
  printf '\n%s\n' "$3" >> "$WORK/prompts/$2"
  git -C "$WORK" diff -- "prompts/$2" > "$1"
  cp "$TMP_DIR/prompt.orig" "$WORK/prompts/$2"
}
make_check() {  # make_check <out.sh> <prompts-file> <sentence> : fails until the sentence is in that file
  printf '#!/usr/bin/env bash\ngrep -qF -- %q "$DEX_DIR/prompts/%s"\n' "$3" "$2" > "$1"
}
review_candidate() {  # review_candidate <stem> <prompts-file> <sentence> : a candidate that will validate; prints its id
  make_patch "$TMP_DIR/$1.patch" "$2" "$3"
  make_check "$TMP_DIR/$1.sh" "$2" "$3"
  submit --patch "$TMP_DIR/$1.patch" --reproduction "$TMP_DIR/$1.sh" --json "{\"mechanism\": \"review gate: $1\", \"symptom\": \"s\", \"evidence_summary\": \"e\"}"
}

# reject: retired with the reviewer's reason; the live checkout never sees the patch.
REJECT_ID="$(review_candidate reject review.md "Never run the test suite twice in one gate.")"
DX_STUB_CALL_LOG="$TMP_DIR/stub-reject.log" DX_STUB_REVIEW_ANSWER="$TMP_DIR/review-reject.md" \
  consume --max-candidates 1 --candidate "$REJECT_ID" > "$TMP_DIR/run-reject.json"
REJECT_MANIFEST="$DX_FEEDBACK_DIR/$REJECT_ID/manifest.json"
[[ "$(jget "$TMP_DIR/run-reject.json" "d['decisions']['$REJECT_ID']")" == "validated" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run-reject.json" "d['reviews']['$REJECT_ID']")" == "reject" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run-reject.json" 'd["retired"]')" == "['$REJECT_ID']" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run-reject.json" "d['retired_reasons']['$REJECT_ID']")" == "review: restates the existing heredoc guidance and is specific to one repository" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run-reject.json" 'd["activated"]')" == "[]" ]] || assert_at $LINENO
[[ "$(jget "$REJECT_MANIFEST" 'd["state"]')" == "retired" ]] || assert_at $LINENO
[[ "$(jget "$REJECT_MANIFEST" 'd["decision"]')" == "validated" ]] || assert_at $LINENO
[[ "$(jget "$REJECT_MANIFEST" 'd["retired_reason"]')" == review:* ]] || assert_at $LINENO
[[ "$(jget "$REJECT_MANIFEST" 'd["activation"]')" == "None" ]] || assert_at $LINENO
REJECT_EVAL="$DX_FEEDBACK_DIR/$REJECT_ID/evaluation.json"
[[ "$(jget "$REJECT_EVAL" 'd["review"]["decision"]')" == "reject" ]] || assert_at $LINENO
[[ "$(jget "$REJECT_EVAL" 'd["review"]["generality"]')" == "repo" ]] || assert_at $LINENO
[[ "$(jget "$REJECT_EVAL" 'd["retired_reason"]')" == review:* ]] || assert_at $LINENO
assert_not_contains "Never run the test suite twice in one gate." "$LIVE/prompts/review.md"
[[ "$(grep -c -- '--allowedTools' "$TMP_DIR/stub-reject.log")" == "1" ]] || assert_at $LINENO
assert_contains "+Never run the test suite twice in one gate." "$TMP_DIR/stub-reject.log.stdin"

# unavailable: the reviewer fails, so nothing goes live; the candidate waits
# with one attempt spent, and the summary says why.
UNAVAIL_ID="$(review_candidate unavailable commit-format.md "State the gate command before running it.")"
DX_STUB_CALL_LOG="$TMP_DIR/stub-unavail.log" DX_STUB_REVIEW_EXIT=7 \
  consume --max-candidates 1 --candidate "$UNAVAIL_ID" > "$TMP_DIR/run-unavail.json"
UNAVAIL_MANIFEST="$DX_FEEDBACK_DIR/$UNAVAIL_ID/manifest.json"
[[ "$(jget "$UNAVAIL_MANIFEST" 'd["state"]')" == "evaluated" ]] || assert_at $LINENO
[[ "$(jget "$UNAVAIL_MANIFEST" 'd["decision"]')" == "validated" ]] || assert_at $LINENO
[[ "$(jget "$UNAVAIL_MANIFEST" 'd["attempts"]')" == "1" ]] || assert_at $LINENO
[[ "$(jget "$UNAVAIL_MANIFEST" 'd["activation"]')" == "None" ]] || assert_at $LINENO
[[ "$(jget "$UNAVAIL_MANIFEST" 'd["claim"]')" == "None" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run-unavail.json" "d['reviews']['$UNAVAIL_ID']")" == "unavailable" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run-unavail.json" "'$UNAVAIL_ID' in d['review_unavailable']")" == "True" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run-unavail.json" 'd["activated"]')" == "[]" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run-unavail.json" 'd["retired"]')" == "[]" ]] || assert_at $LINENO
[[ "$(jget "$DX_FEEDBACK_DIR/$UNAVAIL_ID/evaluation.json" 'd["review"]["decision"]')" == "unavailable" ]] || assert_at $LINENO
assert_not_contains "State the gate command before running it." "$LIVE/prompts/commit-format.md"
# The next run re-evaluates it against the baseline, reviews again, and activates on approval.
DX_STUB_CALL_LOG="$TMP_DIR/stub-unavail-2.log" \
  consume --max-candidates 1 --candidate "$UNAVAIL_ID" > "$TMP_DIR/run-unavail-2.json"
[[ "$(jget "$TMP_DIR/run-unavail-2.json" 'd["activated"]')" == "['$UNAVAIL_ID']" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run-unavail-2.json" "d['reviews']['$UNAVAIL_ID']")" == "approve" ]] || assert_at $LINENO
[[ "$(jget "$UNAVAIL_MANIFEST" 'd["state"]')" == "activated" ]] || assert_at $LINENO
assert_contains "State the gate command before running it." "$LIVE/prompts/commit-format.md"
# At the attempt limit an unavailable review retires the candidate rather than parking it.
UNAVAIL2_ID="$(review_candidate unavailable-twice pr-description.md "Name the file a rule lives in when citing it.")"
DX_STUB_CALL_LOG="$TMP_DIR/stub-unavail-3.log" DX_STUB_REVIEW_EXIT=7 \
  consume --max-candidates 1 --candidate "$UNAVAIL2_ID" --max-attempts 1 > "$TMP_DIR/run-unavail-3.json"
[[ "$(jget "$DX_FEEDBACK_DIR/$UNAVAIL2_ID/manifest.json" 'd["state"]')" == "retired" ]] || assert_at $LINENO
[[ "$(jget "$DX_FEEDBACK_DIR/$UNAVAIL2_ID/manifest.json" 'd["retired_reason"]')" == review\ unavailable\ after\ 1\ attempts* ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run-unavail-3.json" 'd["retired"]')" == "['$UNAVAIL2_ID']" ]] || assert_at $LINENO
assert_not_contains "Name the file a rule lives in when citing it." "$LIVE/prompts/pr-description.md"

# --review off: the earlier policy, activation on validated alone, with no model call.
OFF_ID="$(review_candidate review-off review-wave.md "Prefer the project runner over a global one.")"
DX_STUB_CALL_LOG="$TMP_DIR/stub-off.log" \
  consume --max-candidates 1 --candidate "$OFF_ID" --review off > "$TMP_DIR/run-off2.json"
[[ "$(jget "$TMP_DIR/run-off2.json" 'd["activated"]')" == "['$OFF_ID']" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run-off2.json" 'd["review"]')" == "off" ]] || assert_at $LINENO
[[ "$(jget "$TMP_DIR/run-off2.json" 'd["reviews"]')" == "{}" ]] || assert_at $LINENO
[[ ! -e "$TMP_DIR/stub-off.log" ]] || assert_at $LINENO
[[ "$(jget "$DX_FEEDBACK_DIR/$OFF_ID/evaluation.json" 'd.get("review")')" == "None" ]] || assert_at $LINENO
[[ "$(jget "$DX_FEEDBACK_DIR/$OFF_ID/evaluation.json" 'd["cost"]["model_calls"]')" == "0" ]] || assert_at $LINENO
assert_contains "Prefer the project runner over a global one." "$LIVE/prompts/review-wave.md"
# DX_RESEARCH_REVIEW is the default the flag overrides.
DX_RESEARCH_REVIEW=off consume --max-candidates 1 --candidate "$NOREPRO_ID" > "$TMP_DIR/run-off3.json"
[[ "$(jget "$TMP_DIR/run-off3.json" 'd["review"]')" == "off" ]] || assert_at $LINENO

# The live checkout holds exactly the three activations (good, unavailable then
# approved, review off), each unstaged, on the same HEAD; nothing the review
# rejected or could not judge.
[[ "$(git -C "$LIVE" status --porcelain | sort | tr '\n' ' ')" == " M prompts/commit-format.md  M prompts/guardrails.md  M prompts/review-wave.md " ]] || assert_at $LINENO
[[ "$(git -C "$LIVE" rev-parse HEAD)" == "$LIVE_HEAD" ]] || assert_at $LINENO

echo "feedback-consumer-test: ok"
