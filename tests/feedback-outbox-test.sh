#!/usr/bin/env bash
set -euo pipefail

# The feedback outbox is where a project leaves a bounded, sanitised candidate
# for the Dex research consumer: one directory per mechanism with a versioned
# manifest. Repeats of the same mechanism add support to the existing candidate.
# A claim is a lease one owner holds at a time; a decision needs the claim and
# ends it. Feedback raised while the research consumer itself is running is
# tagged so it is not consumed in the same campaign.

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-feedback-outbox-test.XXXXXX")"
# macOS sets TMPDIR with a trailing slash; the outbox records normalised
# absolute paths, so the paths asserted against have to be normalised too.
TMP_DIR="$(cd "$TMP_DIR" && pwd)"
cleanup() { chmod -R u+w "$TMP_DIR" 2>/dev/null || true; rm -rf "$TMP_DIR"; }
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_RUN_ROOT="$TMP_DIR/runs"
export DX_FEEDBACK_DIR="$TMP_DIR/feedback"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR" "$DX_RUN_ROOT"
OUTBOX="$ROOT/scripts/feedback_outbox.py"

jget() { python3 -c 'import json,sys; d=json.load(open(sys.argv[1])); print(eval(sys.argv[2]))' "$1" "$2"; }
jline() { python3 -c 'import json,sys; d=json.loads(sys.argv[1]); print(eval(sys.argv[2]))' "$1" "$2"; }

printf '#!/usr/bin/env bash\nexit 0\n' > "$TMP_DIR/check.sh"
printf 'diff --git a/prompts/x.md b/prompts/x.md\n' > "$TMP_DIR/change.patch"

# ── submit: a complete candidate is eligible; the same mechanism adds support ─
OUT="$(python3 "$OUTBOX" "$DX_FEEDBACK_DIR" submit --patch "$TMP_DIR/change.patch" --reproduction "$TMP_DIR/check.sh" --json '{
  "mechanism": "post-commit guard fires on commands whose heredoc text mentions git commit",
  "symptom": "PostToolUse commit-format warning on a command that made no commit",
  "evidence_summary": "Observed twice on 2026-10-01; HEAD unchanged across the call.",
  "impact": "noise; a false blocking message per affected tool call",
  "suspected_cause": "hooks/git-commit-target.py reads commit tokens inside heredoc payloads",
  "candidate_mechanism": "treat heredoc bodies as data in the commit-target parser",
  "applicability": "any repository with the post-commit guard installed",
  "exclusions": "commands that really commit inside a heredoc-driven script",
  "metrics": {"occurrences": 2, "units": "tool calls"},
  "dex_version": "33fc68c-dirty"
}')"
ID="$(jline "$OUT" 'd["id"]')"
[[ "$ID" == fb-* ]] || assert_at $LINENO
[[ "$(jline "$OUT" 'd["deduplicated"]')" == "False" ]] || assert_at $LINENO
MANIFEST="$DX_FEEDBACK_DIR/$ID/manifest.json"
[[ -f "$MANIFEST" ]] || assert_at $LINENO
[[ "$(jget "$MANIFEST" 'd["schema_version"]')" == "1" ]] || assert_at $LINENO
[[ "$(jget "$MANIFEST" 'd["state"]')" == "eligible" ]] || assert_at $LINENO
[[ "$(jget "$MANIFEST" 'd["origin"]')" == "project" ]] || assert_at $LINENO
[[ "$(jget "$MANIFEST" 'd["export_class"]')" == "local" ]] || assert_at $LINENO
[[ "$(jget "$MANIFEST" 'd["support"]')" == "1" ]] || assert_at $LINENO
[[ -f "$DX_FEEDBACK_DIR/$ID/evidence-summary.md" ]] || assert_at $LINENO
[[ -f "$DX_FEEDBACK_DIR/$ID/metrics.json" ]] || assert_at $LINENO
[[ -f "$DX_FEEDBACK_DIR/$ID/proposed-change.patch" ]] || assert_at $LINENO
[[ -f "$DX_FEEDBACK_DIR/$ID/reproduction/check.sh" ]] || assert_at $LINENO
[[ "$(jget "$MANIFEST" 'd["decision"]')" == "None" ]] || assert_at $LINENO

OUT2="$(python3 "$OUTBOX" "$DX_FEEDBACK_DIR" submit --json '{"mechanism": "Post-commit guard fires on commands whose heredoc text mentions git commit", "symptom": "same warning again", "evidence_summary": "third time", "metrics": {"occurrences": 1}}')"
[[ "$(jline "$OUT2" 'd["id"]')" == "$ID" ]] || assert_at $LINENO
[[ "$(jline "$OUT2" 'd["deduplicated"]')" == "True" ]] || assert_at $LINENO
[[ "$(jget "$MANIFEST" 'd["support"]')" == "2" ]] || assert_at $LINENO
[[ "$(jget "$MANIFEST" 'd["state"]')" == "eligible" ]] || assert_at $LINENO

# A candidate with nothing to reproduce or apply stays captured and says what is missing.
OUT3="$(python3 "$OUTBOX" "$DX_FEEDBACK_DIR" submit --json '{"mechanism": "something vague", "symptom": "slow", "evidence_summary": "felt slow"}')"
ID3="$(jline "$OUT3" 'd["id"]')"
[[ "$(jget "$DX_FEEDBACK_DIR/$ID3/manifest.json" 'd["state"]')" == "captured" ]] || assert_at $LINENO
[[ "$(jget "$DX_FEEDBACK_DIR/$ID3/manifest.json" '"reproduction" in d["missing"]')" == "True" ]] || assert_at $LINENO

# Missing required fields are refused, not stored.
set +e
python3 "$OUTBOX" "$DX_FEEDBACK_DIR" submit --json '{"symptom": "no mechanism"}' > /dev/null 2>&1
RC=$?
set -e
[[ "$RC" == "2" ]] || assert_at $LINENO
[[ "$(python3 "$OUTBOX" "$DX_FEEDBACK_DIR" list | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" == "2" ]] || assert_at $LINENO
[[ "$(python3 "$OUTBOX" "$DX_FEEDBACK_DIR" list --state eligible | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))')" == "1" ]] || assert_at $LINENO

# ── claim: one owner at a time; a decision needs the claim and releases it ──
python3 "$OUTBOX" "$DX_FEEDBACK_DIR" claim "$ID" --owner consumer-a > /dev/null
[[ "$(jget "$MANIFEST" 'd["state"]')" == "claimed" ]] || assert_at $LINENO
[[ "$(jget "$MANIFEST" 'd["claim"]["owner"]')" == "consumer-a" ]] || assert_at $LINENO
set +e
python3 "$OUTBOX" "$DX_FEEDBACK_DIR" claim "$ID" --owner consumer-b > /dev/null 2>&1
RC=$?
set -e
[[ "$RC" == "3" ]] || assert_at $LINENO
set +e
printf '{"decision":"validated"}' > "$TMP_DIR/eval.json"
python3 "$OUTBOX" "$DX_FEEDBACK_DIR" decide "$ID" --owner consumer-b --decision validated --evaluation "$TMP_DIR/eval.json" > /dev/null 2>&1
RC=$?
set -e
[[ "$RC" == "3" ]] || assert_at $LINENO
python3 "$OUTBOX" "$DX_FEEDBACK_DIR" decide "$ID" --owner consumer-a --decision rejected --evaluation "$TMP_DIR/eval.json" > /dev/null
[[ "$(jget "$MANIFEST" 'd["state"]')" == "evaluated" ]] || assert_at $LINENO
[[ "$(jget "$MANIFEST" 'd["decision"]')" == "rejected" ]] || assert_at $LINENO
[[ "$(jget "$MANIFEST" 'd["claim"]')" == "None" ]] || assert_at $LINENO
[[ -f "$DX_FEEDBACK_DIR/$ID/evaluation.json" ]] || assert_at $LINENO
# An evaluated candidate is not claimable again.
set +e
python3 "$OUTBOX" "$DX_FEEDBACK_DIR" claim "$ID" --owner consumer-c > /dev/null 2>&1
RC=$?
set -e
[[ "$RC" == "3" ]] || assert_at $LINENO

# An expired claim can be taken over, with a new generation.
OUT4="$(python3 "$OUTBOX" "$DX_FEEDBACK_DIR" submit --reproduction "$TMP_DIR/check.sh" --json '{"mechanism": "another mechanism", "symptom": "s", "evidence_summary": "e"}')"
ID4="$(jline "$OUT4" 'd["id"]')"
python3 "$OUTBOX" "$DX_FEEDBACK_DIR" claim "$ID4" --owner consumer-a --ttl-seconds 1 > /dev/null
sleep 2
# Once the lease has lapsed the candidate reads as eligible again, so a consumer
# that only lists eligible work finds what a crashed consumer left behind.
[[ "$(python3 "$OUTBOX" "$DX_FEEDBACK_DIR" list --state eligible | python3 -c 'import json,sys; print(any(r["id"] == sys.argv[1] for r in json.load(sys.stdin)))' "$ID4")" == "True" ]] || assert_at $LINENO
python3 "$OUTBOX" "$DX_FEEDBACK_DIR" claim "$ID4" --owner consumer-b > /dev/null
[[ "$(jget "$DX_FEEDBACK_DIR/$ID4/manifest.json" 'd["claim"]["owner"]')" == "consumer-b" ]] || assert_at $LINENO
[[ "$(jget "$DX_FEEDBACK_DIR/$ID4/manifest.json" 'd["claim"]["generation"]')" == "2" ]] || assert_at $LINENO

# ── research-origin feedback is tagged for a later campaign ────────────────
OUT5="$(DX_RESEARCH_CONSUMER_ACTIVE=1 python3 "$OUTBOX" "$DX_FEEDBACK_DIR" submit --reproduction "$TMP_DIR/check.sh" --json '{"mechanism": "learner found a learner bug", "symptom": "s", "evidence_summary": "e"}')"
ID5="$(jline "$OUT5" 'd["id"]')"
[[ "$(jget "$DX_FEEDBACK_DIR/$ID5/manifest.json" 'd["origin"]')" == "research" ]] || assert_at $LINENO

# ── the lead submits through the mission CLI: outbox entry plus ledger ref ──
# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"
SID="feedback-outbox-session"
printf 'Build.\n' > "$TMP_DIR/brief.md"
bash "$ROOT/bin/mission.sh" "$SID" init --mission-id m-fb --brief-file "$TMP_DIR/brief.md" \
  --workspace "$TMP_DIR" --branch main --base-revision abc > /dev/null
bash "$ROOT/bin/mission.sh" "$SID" feedback --reproduction "$TMP_DIR/check.sh" \
  --json '{"mechanism": "from the lead", "symptom": "s", "evidence_summary": "e"}' > "$TMP_DIR/fb.out"
[[ "$(jget "$DX_STATE_DIR/$SID.mission/current.json" 'd["counts"]["feedback-ref"]')" == "1" ]] || assert_at $LINENO
[[ "$(python3 "$OUTBOX" "$DX_FEEDBACK_DIR" list | python3 -c 'import json,sys; print(sum(1 for c in json.load(sys.stdin) if c["mechanism"]=="from the lead"))')" == "1" ]] || assert_at $LINENO

# ── retire: needs the claim, is terminal, and a resubmit does not reopen it ─
OUT6="$(python3 "$OUTBOX" "$DX_FEEDBACK_DIR" submit --reproduction "$TMP_DIR/check.sh" --json '{"mechanism": "retire me after enough evidence", "symptom": "s", "evidence_summary": "e"}')"
ID6="$(jline "$OUT6" 'd["id"]')"
M6="$DX_FEEDBACK_DIR/$ID6/manifest.json"
[[ "$(jget "$M6" 'd["attempts"]')" == "0" ]] || assert_at $LINENO
set +e
python3 "$OUTBOX" "$DX_FEEDBACK_DIR" retire "$ID6" --owner consumer-a --reason "no claim held" > /dev/null 2>&1
RC=$?
set -e
[[ "$RC" == "3" ]] || assert_at $LINENO
[[ "$(jget "$M6" 'd["state"]')" == "eligible" ]] || assert_at $LINENO
python3 "$OUTBOX" "$DX_FEEDBACK_DIR" claim "$ID6" --owner consumer-a > /dev/null
# attempt counts under the claim.
python3 "$OUTBOX" "$DX_FEEDBACK_DIR" attempt "$ID6" --owner consumer-a > /dev/null
[[ "$(jget "$M6" 'd["attempts"]')" == "1" ]] || assert_at $LINENO
# An inconclusive decision counts as an attempt and hands the candidate back
# as eligible, so a later run can look again instead of parking it.
printf '{"note":"first look"}' > "$TMP_DIR/eval-inc.json"
OUT_INC="$(python3 "$OUTBOX" "$DX_FEEDBACK_DIR" decide "$ID6" --owner consumer-a --decision inconclusive --evaluation "$TMP_DIR/eval-inc.json")"
[[ "$(jline "$OUT_INC" 'd["attempts"]')" == "2" ]] || assert_at $LINENO
[[ "$(jget "$M6" 'd["attempts"]')" == "2" ]] || assert_at $LINENO
[[ "$(jget "$M6" 'd["state"]')" == "eligible" ]] || assert_at $LINENO
[[ "$(jget "$M6" 'd["decision"]')" == "inconclusive" ]] || assert_at $LINENO
[[ "$(jget "$M6" 'd["claim"]')" == "None" ]] || assert_at $LINENO
python3 "$OUTBOX" "$DX_FEEDBACK_DIR" claim "$ID6" --owner consumer-a > /dev/null
python3 "$OUTBOX" "$DX_FEEDBACK_DIR" retire "$ID6" --owner consumer-a --reason "inconclusive after 2 evaluations" > /dev/null
[[ "$(jget "$M6" 'd["state"]')" == "retired" ]] || assert_at $LINENO
[[ "$(jget "$M6" 'd["retired_reason"]')" == "inconclusive after 2 evaluations" ]] || assert_at $LINENO
[[ "$(jget "$M6" 'd["claim"]')" == "None" ]] || assert_at $LINENO
set +e
python3 "$OUTBOX" "$DX_FEEDBACK_DIR" claim "$ID6" --owner consumer-b > /dev/null 2>&1
RC=$?
set -e
[[ "$RC" == "3" ]] || assert_at $LINENO
[[ "$(python3 "$OUTBOX" "$DX_FEEDBACK_DIR" list --state retired | python3 -c 'import json,sys; print([r["id"] for r in json.load(sys.stdin)])')" == "['$ID6']" ]] || assert_at $LINENO
# The same mechanism reported again adds support and stays retired.
OUT7="$(python3 "$OUTBOX" "$DX_FEEDBACK_DIR" submit --json '{"mechanism": "retire me after enough evidence", "symptom": "again", "evidence_summary": "e2"}')"
[[ "$(jline "$OUT7" 'd["deduplicated"]')" == "True" ]] || assert_at $LINENO
[[ "$(jline "$OUT7" 'd["state"]')" == "retired" ]] || assert_at $LINENO
[[ "$(jget "$M6" 'd["support"]')" == "2" ]] || assert_at $LINENO
[[ "$(jget "$M6" 'd["state"]')" == "retired" ]] || assert_at $LINENO
# --reopen with a reason brings it back with a fresh attempt budget; the
# reason and the retirement it undoes are both kept.
OUT8="$(python3 "$OUTBOX" "$DX_FEEDBACK_DIR" submit --reopen "new evidence: fails on a second host" --json '{"mechanism": "retire me after enough evidence", "symptom": "again", "evidence_summary": "e3"}')"
[[ "$(jline "$OUT8" 'd["state"]')" == "eligible" ]] || assert_at $LINENO
[[ "$(jline "$OUT8" 'd["reopened"]')" == "True" ]] || assert_at $LINENO
[[ "$(jget "$M6" 'd["attempts"]')" == "0" ]] || assert_at $LINENO
[[ "$(jget "$M6" 'd["retired_reason"]')" == "None" ]] || assert_at $LINENO
[[ "$(jget "$M6" 'd["reopened"][0]["reason"]')" == "new evidence: fails on a second host" ]] || assert_at $LINENO
[[ "$(jget "$M6" 'd["reopened"][0]["previous_retired_reason"]')" == "inconclusive after 2 evaluations" ]] || assert_at $LINENO
[[ "$(jget "$M6" 'd["support"]')" == "3" ]] || assert_at $LINENO
python3 "$OUTBOX" "$DX_FEEDBACK_DIR" claim "$ID6" --owner consumer-c > /dev/null
[[ "$(jget "$M6" 'd["state"]')" == "claimed" ]] || assert_at $LINENO

# ── activate: the validated patch lands in a live checkout, unstaged, with a rollback ─
LIVE="$TMP_DIR/live"
mkdir -p "$LIVE"
git -C "$ROOT" archive HEAD prompts/guardrails.md | tar -xf - -C "$LIVE"
git init -q -b main "$LIVE"
git -C "$LIVE" config user.email "dex@example.com"
git -C "$LIVE" config user.name "Dex Test"
git -C "$LIVE" add .
git -C "$LIVE" -c commit.gpgsign=false commit -q -m "live baseline"
LIVE_HEAD="$(git -C "$LIVE" rev-parse HEAD)"
cp "$LIVE/prompts/guardrails.md" "$TMP_DIR/guardrails.orig"
printf '\nTreat heredoc bodies as data when deciding whether a command committed.\n' >> "$LIVE/prompts/guardrails.md"
git -C "$LIVE" diff -- prompts/guardrails.md > "$TMP_DIR/live.patch"
cp "$TMP_DIR/guardrails.orig" "$LIVE/prompts/guardrails.md"
[[ -s "$TMP_DIR/live.patch" && -z "$(git -C "$LIVE" status --porcelain)" ]] || assert_at $LINENO

OUT9="$(python3 "$OUTBOX" "$DX_FEEDBACK_DIR" submit --patch "$TMP_DIR/live.patch" --reproduction "$TMP_DIR/check.sh" --json '{"mechanism": "activate a validated prompt change", "symptom": "s", "evidence_summary": "e"}')"
ID9="$(jline "$OUT9" 'd["id"]')"
M9="$DX_FEEDBACK_DIR/$ID9/manifest.json"
python3 "$OUTBOX" "$DX_FEEDBACK_DIR" claim "$ID9" --owner consumer-a > /dev/null
# No decision yet: activation is refused and the checkout is untouched.
set +e
python3 "$OUTBOX" "$DX_FEEDBACK_DIR" activate "$ID9" --owner consumer-a --dex-dir "$LIVE" > /dev/null 2>&1
RC=$?
set -e
[[ "$RC" == "3" ]] || assert_at $LINENO
[[ -z "$(git -C "$LIVE" status --porcelain)" ]] || assert_at $LINENO
printf '{"reason":"reproduction fails on the baseline and passes on the candidate"}' > "$TMP_DIR/eval-ok.json"
python3 "$OUTBOX" "$DX_FEEDBACK_DIR" decide "$ID9" --owner consumer-a --decision validated --evaluation "$TMP_DIR/eval-ok.json" > /dev/null
[[ "$(jget "$M9" 'd["state"]')" == "evaluated" ]] || assert_at $LINENO
# A validated candidate can be claimed again, for activation.
python3 "$OUTBOX" "$DX_FEEDBACK_DIR" claim "$ID9" --owner consumer-a > /dev/null
set +e
python3 "$OUTBOX" "$DX_FEEDBACK_DIR" activate "$ID9" --owner consumer-b --dex-dir "$LIVE" > /dev/null 2>&1
RC=$?
set -e
[[ "$RC" == "3" ]] || assert_at $LINENO
python3 "$OUTBOX" "$DX_FEEDBACK_DIR" activate "$ID9" --owner consumer-a --dex-dir "$LIVE" > "$TMP_DIR/activate.out"
[[ "$(jget "$M9" 'd["state"]')" == "activated" ]] || assert_at $LINENO
[[ "$(jget "$M9" 'd["claim"]')" == "None" ]] || assert_at $LINENO
[[ "$(jget "$M9" 'd["activation"]["head"]')" == "$LIVE_HEAD" ]] || assert_at $LINENO
[[ "$(jget "$M9" 'd["activation"]["dex_dir"]')" == "$LIVE" ]] || assert_at $LINENO
[[ "$(jget "$M9" 'd["activation"]["changed_paths"]')" == "['prompts/guardrails.md']" ]] || assert_at $LINENO
[[ "$(jget "$M9" 'd["activation"]["rollback"]')" == "git -C $LIVE apply -R $DX_FEEDBACK_DIR/$ID9/proposed-change.patch" ]] || assert_at $LINENO
[[ "$(jget "$M9" 'len(d["activation"]["patch_sha256"]) == 64')" == "True" ]] || assert_at $LINENO
assert_contains "Treat heredoc bodies as data" "$LIVE/prompts/guardrails.md"
# Applied to the working tree only: modified, unstaged, no new commit.
[[ "$(git -C "$LIVE" status --porcelain -- prompts/guardrails.md)" == " M prompts/guardrails.md" ]] || assert_at $LINENO
[[ "$(git -C "$LIVE" rev-parse HEAD)" == "$LIVE_HEAD" ]] || assert_at $LINENO
# The evaluation record carries the same activation.
[[ "$(jget "$DX_FEEDBACK_DIR/$ID9/evaluation.json" 'd["activation"]["head"]')" == "$LIVE_HEAD" ]] || assert_at $LINENO
# Terminal: not claimable, listed under its state.
set +e
python3 "$OUTBOX" "$DX_FEEDBACK_DIR" claim "$ID9" --owner consumer-c > /dev/null 2>&1
RC=$?
set -e
[[ "$RC" == "3" ]] || assert_at $LINENO
[[ "$(python3 "$OUTBOX" "$DX_FEEDBACK_DIR" list --state activated | python3 -c 'import json,sys; print([r["id"] for r in json.load(sys.stdin)])')" == "['$ID9']" ]] || assert_at $LINENO

# ── revert: the recorded patch comes back out and the file is as it was ────
python3 "$OUTBOX" "$DX_FEEDBACK_DIR" revert "$ID9" --owner operator --reason "regressed the plan phase" > /dev/null
[[ "$(jget "$M9" 'd["state"]')" == "reverted" ]] || assert_at $LINENO
[[ "$(jget "$M9" 'd["revert"]["reason"]')" == "regressed the plan phase" ]] || assert_at $LINENO
assert_not_contains "Treat heredoc bodies as data" "$LIVE/prompts/guardrails.md"
[[ -z "$(git -C "$LIVE" status --porcelain)" ]] || assert_at $LINENO
cmp -s "$TMP_DIR/guardrails.orig" "$LIVE/prompts/guardrails.md" || assert_at $LINENO
set +e
python3 "$OUTBOX" "$DX_FEEDBACK_DIR" revert "$ID9" --owner operator --reason "twice" > /dev/null 2>&1
RC=$?
set -e
[[ "$RC" == "3" ]] || assert_at $LINENO
[[ "$(python3 "$OUTBOX" "$DX_FEEDBACK_DIR" list --state reverted | python3 -c 'import json,sys; print([r["id"] for r in json.load(sys.stdin)])')" == "['$ID9']" ]] || assert_at $LINENO

# ── activate refuses a patch that does not apply, and changes nothing ──────
cat > "$TMP_DIR/stale.patch" <<'P'
--- prompts/guardrails.md
+++ prompts/guardrails.md
@@ -1,3 +1,4 @@
 this line does not exist in guardrails
+added
 nor this one
 nor this
P
OUT10="$(python3 "$OUTBOX" "$DX_FEEDBACK_DIR" submit --patch "$TMP_DIR/stale.patch" --reproduction "$TMP_DIR/check.sh" --json '{"mechanism": "stale patch cannot activate", "symptom": "s", "evidence_summary": "e"}')"
ID10="$(jline "$OUT10" 'd["id"]')"
M10="$DX_FEEDBACK_DIR/$ID10/manifest.json"
python3 "$OUTBOX" "$DX_FEEDBACK_DIR" claim "$ID10" --owner consumer-a > /dev/null
python3 "$OUTBOX" "$DX_FEEDBACK_DIR" decide "$ID10" --owner consumer-a --decision validated --evaluation "$TMP_DIR/eval-ok.json" > /dev/null
python3 "$OUTBOX" "$DX_FEEDBACK_DIR" claim "$ID10" --owner consumer-a > /dev/null
set +e
python3 "$OUTBOX" "$DX_FEEDBACK_DIR" activate "$ID10" --owner consumer-a --dex-dir "$LIVE" > /dev/null 2> "$TMP_DIR/activate.err"
RC=$?
set -e
[[ "$RC" == "3" ]] || assert_at $LINENO
assert_contains "does not apply" "$TMP_DIR/activate.err"
[[ "$(jget "$M10" 'd["state"]')" == "claimed" ]] || assert_at $LINENO
[[ "$(jget "$M10" 'd["activation"]')" == "None" ]] || assert_at $LINENO
[[ -z "$(git -C "$LIVE" status --porcelain)" ]] || assert_at $LINENO
python3 "$OUTBOX" "$DX_FEEDBACK_DIR" release "$ID10" --owner consumer-a > /dev/null
[[ "$(jget "$M10" 'd["state"]')" == "evaluated" ]] || assert_at $LINENO

# A manifest that is not private is not trusted.
chmod 644 "$MANIFEST"
set +e
python3 "$OUTBOX" "$DX_FEEDBACK_DIR" show "$ID" > /dev/null 2>&1
RC=$?
set -e
[[ "$RC" == "2" ]] || assert_at $LINENO

# ── maintenance closes the loop: the consumer runs only when there is something to decide ─
# shellcheck disable=SC1091
source "$ROOT/lib/feedback.sh"
CONSUMER_LOG="$TMP_DIR/consumer-calls.log"
cat > "$TMP_DIR/consumer-stub.sh" <<SH
#!/usr/bin/env bash
printf '%s\n' "\$*" >> "$CONSUMER_LOG"
printf '{"processed": 1, "retired": []}\n'
SH
chmod 700 "$TMP_DIR/consumer-stub.sh"
EMPTY_OUTBOX="$TMP_DIR/empty-outbox"
mkdir -p "$EMPTY_OUTBOX"
DX_FEEDBACK_DIR="$EMPTY_OUTBOX" DX_FEEDBACK_CONSUMER="$TMP_DIR/consumer-stub.sh" dx_feedback_consume_due > "$TMP_DIR/consume-empty.out" 2>&1 || assert_at $LINENO
assert_contains "nothing to decide" "$TMP_DIR/consume-empty.out"
[[ ! -e "$CONSUMER_LOG" ]] || assert_at $LINENO
# The real outbox of this test holds captured and eligible candidates.
REPORT="$TMP_DIR/maintain-report.md"
: > "$REPORT"
DX_FEEDBACK_CONSUMER="$TMP_DIR/consumer-stub.sh" dx_feedback_consume_due "$REPORT" > "$TMP_DIR/consume-run.out" 2>&1 || assert_at $LINENO
assert_contains "running the research consumer" "$TMP_DIR/consume-run.out"
assert_contains "--max-candidates 5 --max-minutes 20 --max-iterations 3" "$CONSUMER_LOG"
assert_contains "## Feedback consumer" "$REPORT"
assert_contains '"processed": 1' "$REPORT"
rm -f "$CONSUMER_LOG"
DEX_MAINTAIN_CONSUME=0 DX_FEEDBACK_CONSUMER="$TMP_DIR/consumer-stub.sh" dx_feedback_consume_due > "$TMP_DIR/consume-off.out" 2>&1 || assert_at $LINENO
[[ ! -e "$CONSUMER_LOG" ]] || assert_at $LINENO

echo "feedback-outbox-test: ok"
