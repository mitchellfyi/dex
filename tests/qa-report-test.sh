#!/usr/bin/env bash
# The manual QA report: one evidenced row per approved criterion, a status the
# tool derives rather than the agent declares, staleness against the tree, and
# the same retention as UI proof.
set -euo pipefail
umask 077

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-qa-report-test.XXXXXX")"
export HOME="$TMP_DIR/home"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_RUN_ROOT="$TMP_DIR/runs"
export DEXCODE_SYNC=0
export DEX_DIR="$ROOT"

cleanup() {
  chmod -R u+w "$TMP_DIR" 2>/dev/null || true
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

# shellcheck source=lib/common.sh
source "$ROOT/lib/common.sh"

SID="qa-report-contract"
QA_DIR="$(dx_qa_session_dir "$SID")"
assert_eq "$DX_ARTIFACT_DIR/qa/$SID" "$QA_DIR" "qa session dir"
assert_eq "$QA_DIR/qa-report.json" "$(dx_qa_report_file "$SID")" "report path"
assert_eq "$QA_DIR/qa-report.md" "$(dx_qa_markdown_file "$SID")" "markdown path"
assert_eq "$QA_DIR/evidence" "$(dx_qa_evidence_dir "$SID")" "evidence dir"
assert_eq "MISSING" "$(dx_qa_status "$SID")" "missing status"
dx_qa_summary "$SID" > "$TMP_DIR/summary-missing.out"
assert_contains 'QA: MISSING' "$TMP_DIR/summary-missing.out"

# A repository to fingerprint the report against.
REPO="$TMP_DIR/repo"
mkdir -p "$REPO"
git -C "$REPO" init -q
git -C "$REPO" config user.email qa@example.test
git -C "$REPO" config user.name "QA Test"
printf 'one\n' > "$REPO/app.txt"
git -C "$REPO" add app.txt
git -C "$REPO" commit -q -m init

# The approved criteria and their seal, as Phase 1 leaves them.
CRITERIA="$(dx_review_criteria_file "$SID")"
mkdir -p "$(dirname "$CRITERIA")"
printf '%s\n' '{"version":1,"source":"approved-plan","objectives":["Confirm saves"],"acceptance_criteria":["Saving confirms the change","Email toggles persist"],"verification_requirements":["The settings tests pass"]}' > "$CRITERIA"
dx_review_criteria_valid "$CRITERIA" || assert_at $LINENO
CRITERIA_HASH="$(dx_review_criteria_hash "$CRITERIA")"
printf '1\t1\t%s\n' "$CRITERIA_HASH" > "$(dx_review_criteria_approval_file "$SID")"
assert_eq "$CRITERIA_HASH" "$(dx_review_read_criteria_approval "$SID")" "approval seal"

mkdir -p "$QA_DIR/evidence"
printf 'screenshot\n' > "$QA_DIR/evidence/save.png"
printf 'toggle\n' > "$QA_DIR/evidence/toggle.png"
printf 'tests\n' > "$QA_DIR/evidence/tests.log"
printf 'outside\n' > "$TMP_DIR/outside.png"
ln -s "$QA_DIR/evidence/save.png" "$QA_DIR/evidence/linked.png"

python3 - "$TMP_DIR/draft.json" "$QA_DIR/evidence" <<'PY'
import json
import sys

draft, evidence = sys.argv[1:]
value = {
    "version": 1,
    "status": "PASSED",
    "ui_surface": "web",
    "hands": ["playwright-mcp", "curl"],
    "criteria": [
        {"kind": "acceptance", "index": 1, "text": "Saving confirms the change", "outcome": "MET",
         "evidence": [f"{evidence}/save.png"], "notes": "The saved banner appears after Save."},
        {"kind": "acceptance", "index": 2, "text": "Email toggles persist", "outcome": "MET",
         "evidence": [f"{evidence}/toggle.png"], "notes": "A reload keeps the toggle on."},
        {"kind": "verification", "index": 1, "text": "The settings tests pass", "outcome": "MET",
         "evidence": [f"{evidence}/tests.log"], "notes": "12 examples, 0 failures."},
    ],
    "exploratory": [
        {"id": "qa-1", "severity": "low", "title": "Focus ring is faint", "repro": "1. Tab to Save.",
         "expected": "A visible focus ring.", "actual": "A faint ring.", "evidence": [],
         "disposition": "note", "reference": ""},
    ],
}
json.dump(value, open(draft, "w", encoding="utf-8"), indent=2)
PY

(cd "$REPO" && bash "$ROOT/bin/qa.sh" report --input "$TMP_DIR/draft.json" --session "$SID") > "$TMP_DIR/report.out"
assert_eq "PASSED" "$(dx_qa_status "$SID")" "passed status"
assert_contains 'QA: PASSED' "$TMP_DIR/report.out"
REPORT="$(dx_qa_report_file "$SID")"
assert_file "$REPORT"
assert_contains '"status": "PASSED"' "$REPORT"
assert_contains "\"approval_hash\": \"$CRITERIA_HASH\"" "$REPORT"
assert_contains '"working_fingerprint"' "$REPORT"
assert_contains '"checkout_fingerprint"' "$REPORT"
assert_contains '3/3 criteria MET' "$REPORT"
MARKDOWN="$(dx_qa_markdown_file "$SID")"
assert_file "$MARKDOWN"
assert_contains '# Manual QA' "$MARKDOWN"
assert_contains '| # | Kind | Criterion | Outcome | Evidence | Notes |' "$MARKDOWN"
assert_contains 'Saving confirms the change' "$MARKDOWN"
assert_contains 'Focus ring is faint' "$MARKDOWN"
assert_contains 'Do not commit' "$MARKDOWN"
assert_file "$(dx_qa_draft_file "$SID")"
(cd "$REPO" && bash "$ROOT/bin/qa.sh" status --session "$SID") > "$TMP_DIR/status-fresh.out" || assert_at $LINENO
assert_contains 'PASSED' "$TMP_DIR/status-fresh.out"
(cd "$REPO" && bash "$ROOT/bin/qa.sh" show --session "$SID" --json) > "$TMP_DIR/show.json"
assert_contains '"status": "PASSED"' "$TMP_DIR/show.json"
(cd "$REPO" && bash "$ROOT/bin/qa.sh" show --session "$SID") > "$TMP_DIR/show.out"
assert_contains 'QA: PASSED' "$TMP_DIR/show.out"

# The tool derives the status; a drafted PASSED with a NOT_MET row is FINDINGS.
variant() {
  python3 - "$TMP_DIR/draft.json" "$1" "$2" <<'PY'
import json
import sys

source, target, mutation = sys.argv[1:]
value = json.load(open(source, encoding="utf-8"))
exec(mutation)
json.dump(value, open(target, "w", encoding="utf-8"))
PY
}
variant "$TMP_DIR/not-met.json" 'value["criteria"][1]["outcome"] = "NOT_MET"'
(cd "$REPO" && bash "$ROOT/bin/qa.sh" report --input "$TMP_DIR/not-met.json" --session "$SID") > "$TMP_DIR/not-met.out"
assert_eq "FINDINGS" "$(dx_qa_status "$SID")" "a NOT_MET row overrides the drafted status"
assert_contains 'NOT_MET' "$TMP_DIR/not-met.out"
variant "$TMP_DIR/open-finding.json" 'value["exploratory"][0]["severity"] = "high"'
(cd "$REPO" && bash "$ROOT/bin/qa.sh" report --input "$TMP_DIR/open-finding.json" --session "$SID") > /dev/null
assert_eq "FINDINGS" "$(dx_qa_status "$SID")" "a high finding left as a note is FINDINGS"
variant "$TMP_DIR/filed-finding.json" 'value["exploratory"][0]["severity"] = "medium"; value["exploratory"][0]["disposition"] = "follow-up"; value["exploratory"][0]["reference"] = "DEX-123"'
(cd "$REPO" && bash "$ROOT/bin/qa.sh" report --input "$TMP_DIR/filed-finding.json" --session "$SID") > /dev/null
assert_eq "PASSED" "$(dx_qa_status "$SID")" "a medium finding filed as a follow-up is handled"
variant "$TMP_DIR/fixed-finding.json" 'value["exploratory"][0]["severity"] = "high"; value["exploratory"][0]["disposition"] = "fixed"'
(cd "$REPO" && bash "$ROOT/bin/qa.sh" report --input "$TMP_DIR/fixed-finding.json" --session "$SID") > /dev/null
assert_eq "PASSED" "$(dx_qa_status "$SID")" "a fixed high finding passes"
variant "$TMP_DIR/blocked-row.json" 'value["criteria"][2]["outcome"] = "BLOCKED"; value["criteria"][2]["evidence"] = []'
(cd "$REPO" && bash "$ROOT/bin/qa.sh" report --input "$TMP_DIR/blocked-row.json" --session "$SID") > /dev/null
assert_eq "BLOCKED" "$(dx_qa_status "$SID")" "a blocked row without findings is BLOCKED"

# Drafts the validator refuses. Each must leave the previous report in place.
reject() {
  local label="$1" mutation="$2"
  variant "$TMP_DIR/rejected.json" "$mutation"
  assert_rejected "$label" bash -c 'cd "$1" && bash "$2/bin/qa.sh" report --input "$3" --session "$4" >/dev/null 2>&1' _ "$REPO" "$ROOT" "$TMP_DIR/rejected.json" "$SID"
  assert_eq "BLOCKED" "$(dx_qa_status "$SID")" "$label kept the previous report"
}
reject "missing criterion row" 'value["criteria"].pop()'
reject "wrong index" 'value["criteria"][1]["index"] = 3'
reject "text mismatch" 'value["criteria"][0]["text"] = "Saving shows a toast"'
reject "evidence outside the session dir" 'value["criteria"][0]["evidence"] = ["'"$TMP_DIR"'/outside.png"]'
reject "the report cited as its own evidence" 'value["criteria"][0]["evidence"] = ["'"$QA_DIR"'/qa-report.md"]'
reject "symlinked evidence" 'value["criteria"][0]["evidence"] = ["'"$QA_DIR"'/evidence/linked.png"]'
reject "MET without evidence" 'value["criteria"][0]["evidence"] = []'
reject "unknown outcome" 'value["criteria"][0]["outcome"] = "PASS"'
reject "follow-up without a reference" 'value["exploratory"][0]["disposition"] = "follow-up"'
reject "BLOCKED without notes" 'value["criteria"][0]["outcome"] = "BLOCKED"; value["criteria"][0]["notes"] = ""'
reject "unknown kind" 'value["criteria"][0]["kind"] = "objective"'

# Whole-pass terminal states carry a reason and need no draft.
BLOCKED_SID="qa-report-blocked"
(cd "$REPO" && bash "$ROOT/bin/qa.sh" blocked --session "$BLOCKED_SID" --reason "The app needs a licensed upstream service that is unavailable locally.") > "$TMP_DIR/blocked.out"
assert_eq "BLOCKED" "$(dx_qa_status "$BLOCKED_SID")" "blocked status"
assert_contains 'QA: BLOCKED' "$TMP_DIR/blocked.out"
assert_contains 'licensed upstream service' "$(dx_qa_report_file "$BLOCKED_SID")"
assert_rejected "blocked without reason" bash "$ROOT/bin/qa.sh" blocked --session "qa-no-reason"
NA_SID="qa-report-na"
(cd "$REPO" && bash "$ROOT/bin/qa.sh" not-applicable --session "$NA_SID" --reason "Documentation only; nothing runs.") > "$TMP_DIR/na.out"
assert_eq "N_A" "$(dx_qa_status "$NA_SID")" "not-applicable status"
assert_contains 'QA: N_A' "$TMP_DIR/na.out"
assert_rejected "not-applicable without reason" bash "$ROOT/bin/qa.sh" not-applicable --session "qa-no-reason"

# The escape hatch the workflow relies on: a criteria file that exists but no
# longer validates must not stop the agent from recording a blocked pass.
INVALID_SID="qa-report-invalid-criteria"
INVALID_CRITERIA="$(dx_review_criteria_file "$INVALID_SID")"
printf '%s\n' '{"version":1,"source":"approved-plan","objectives":["x"],"acceptance_criteria":["Only half an artifact"]}' > "$INVALID_CRITERIA"
(cd "$REPO" && bash "$ROOT/bin/qa.sh" blocked --session "$INVALID_SID" --reason "Phase 1 left an invalid criteria file; repair it first.") > "$TMP_DIR/invalid-blocked.out"
assert_eq "BLOCKED" "$(dx_qa_status "$INVALID_SID")" "blocked despite an invalid criteria file"

# Staleness: the report binds to the tree it was written against.
(cd "$REPO" && bash "$ROOT/bin/qa.sh" report --input "$TMP_DIR/draft.json" --session "$SID") > /dev/null
(cd "$REPO" && bash "$ROOT/bin/qa.sh" status --session "$SID") > /dev/null || assert_at $LINENO
printf 'two\n' >> "$REPO/app.txt"
set +e
(cd "$REPO" && bash "$ROOT/bin/qa.sh" status --session "$SID") > "$TMP_DIR/status-stale.out"
stale_exit=$?
set -e
assert_eq "3" "$stale_exit" "stale status exit"
assert_contains 'stale' "$TMP_DIR/status-stale.out"
(cd "$REPO" && dx_qa_summary "$SID") > "$TMP_DIR/summary-stale.out"
assert_contains 'QA: PASSED' "$TMP_DIR/summary-stale.out"
assert_contains 'Stale: yes' "$TMP_DIR/summary-stale.out"
set +e
bash "$ROOT/bin/qa.sh" status --session "qa-report-nothing"
missing_exit=$?
set -e
assert_eq "1" "$missing_exit" "missing status exit"
# A present report whose fingerprint cannot be checked is unverifiable, not missing.
mkdir -p "$TMP_DIR/nogit"
set +e
(cd "$TMP_DIR/nogit" && bash "$ROOT/bin/qa.sh" status --session "$SID") > "$TMP_DIR/status-nogit.out"
nogit_exit=$?
set -e
assert_eq "3" "$nogit_exit" "unverifiable status exit"
assert_contains 'fingerprint unavailable' "$TMP_DIR/status-nogit.out"

# The report joins the run journal like the UI proof bundle.
RUN_ID=$(dx_run_prepare "$SID" "$ROOT" "worktree" "qa-report-contract" "QA report test" "test")
dx_qa_register_report "$SID"
assert_file "$(dx_run_artifact_file "$RUN_ID" "qa/qa-report.json")"
assert_file "$(dx_run_artifact_file "$RUN_ID" "qa/qa-report.md")"
assert_contains '"type": "qa_report"' "$(dx_run_artifact_manifest_file "$RUN_ID")"

# Retention mirrors UI proof: completed reports expire, active ones stay.
OLD_SID="qa-report-old"
(cd "$REPO" && bash "$ROOT/bin/qa.sh" not-applicable --session "$OLD_SID" --reason "An old pass.") > /dev/null
dx_qa_mark_completed "$OLD_SID"
assert_contains '"phase_state": "completed"' "$(dx_qa_report_file "$OLD_SID")"
python3 - "$(dx_qa_report_file "$OLD_SID")" <<'PY'
import json
import sys

path = sys.argv[1]
value = json.load(open(path, encoding="utf-8"))
value["completed_epoch"] = 1
json.dump(value, open(path, "w", encoding="utf-8"), indent=2)
PY
dx_qa_cleanup 30 > "$TMP_DIR/cleanup.out"
assert_no_file "$(dx_qa_session_dir "$OLD_SID")"
[[ -d "$QA_DIR" ]] || assert_at $LINENO
assert_contains 'Removed 1 expired QA report' "$TMP_DIR/cleanup.out"

bash "$ROOT/bin/qa.sh" --help > "$TMP_DIR/help.out"
assert_contains 'Usage: dx qa' "$TMP_DIR/help.out"

printf 'qa report tests passed\n'
