#!/usr/bin/env bash
set -euo pipefail
umask 077
ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
source "$ROOT/tests/helpers.sh"
TMP_DIR=$(mktemp -d "${TMPDIR:-/tmp}/dex-review-report.XXXXXX")
trap 'rm -rf "$TMP_DIR"' EXIT
export DEX_DIR="$ROOT" DX_LOOP_DIR="$TMP_DIR/loops" DX_STATE_DIR="$TMP_DIR/state"
source "$ROOT/lib/common.sh"
mkdir -p "$DX_LOOP_DIR" "$DX_STATE_DIR"
export DEX_SESSION_ID=report-test DEX_REVIEW_CRITERIA_BINDING=standalone
export DEX_REVIEW_PROFILE=standard DEX_REVIEW_PASS_ID=report-pass-one
export DEX_REVIEW_SCOPE_FINGERPRINT DEX_REVIEW_POLICY_BINDING DEX_REVIEW_PASS_BINDING
DEX_REVIEW_SCOPE_FINGERPRINT=$(printf fixture | dx_review_sha256_stdin)
DEX_REVIEW_POLICY_BINDING=$(dx_review_policy_binding 1 2 3)
bind_pass() {
  DEX_REVIEW_PASS_BINDING=$(dx_review_pass_binding "$DEX_REVIEW_PASS_ID" "$DEX_REVIEW_SCOPE_FINGERPRINT" \
    "$DEX_REVIEW_CRITERIA_BINDING" "$DEX_REVIEW_POLICY_BINDING")
}
bind_pass
generation=$(dx_completion_loop_activate "$DEX_SESSION_ID" child review-pass 3)
write_report() {
  python3 - "$TMP_DIR/report.json" "$1" <<'PY'
import json
import sys
mode = sys.argv[2]
criteria = {section: [] for section in ('objectives', 'acceptance_criteria', 'verification_requirements')}
if mode.startswith('criteria'):
    for section in criteria:
        criteria[section] = [{'outcome': 'met', 'evidence': [
            {'kind': 'test', 'detail': 'The focused fixture exercised the supplied criterion.'}]}]
if mode == 'criteria-missing':
    criteria['objectives'] = []
if mode == 'criteria-placeholder':
    criteria['objectives'][0]['evidence'][0]['detail'] = 'TODO'
if mode == 'criteria-not-met':
    criteria['objectives'][0]['outcome'] = 'not_met'
report = {
    'version': 1, 'result': 'CLEAN',
    'context': {'scope': 'Reviewed the entire current fixture change and its consumers.',
                'checks': 'The fixture command completed successfully before review.',
                'coverage': 'Inspected all five required domains and their relevant surfaces.',
                'verification': 'Rechecked the current source and confirmed no verified findings.'},
    'criteria': criteria, 'deterministic_checks': 'pass',
    'coverage': ['correctness', 'security', 'contracts', 'tests', 'architecture'],
    'verifier': 'pass', 'findings': [], 'fixes_applied': 0,
}
if mode == 'false-clean':
    report['findings'] = ['The fixture has a verified defect in its input handling.']
    report['fixes_applied'] = 1
if mode == 'missing-coverage':
    report['coverage'].remove('security')
if mode == 'failed-checks':
    report['deterministic_checks'] = 'fail'
if mode == 'unverified':
    report['verifier'] = 'not-run'
with open(sys.argv[1], 'w', encoding='utf-8') as stream:
    json.dump(report, stream)
PY
}
publish() { bash "$ROOT/bin/review-result.sh" "$TMP_DIR/report.json" "$generation"; }
for invalid in false-clean missing-coverage failed-checks unverified; do
  write_report "$invalid"
  assert_rejected "$invalid rejected" publish
  [[ ! -e "$DX_LOOP_DIR/$DEX_SESSION_ID.review-publish-lock" ]] || assert_at $LINENO
  assert_rejected 'no premature receipt' dx_completion_receipt_present "$DEX_SESSION_ID"
  [[ ! -e "$(dx_review_result_file "$DEX_SESSION_ID")" ]] || assert_at $LINENO
done
write_report valid
assert_rejected 'stale generation' bash "$ROOT/bin/review-result.sh" "$TMP_DIR/report.json" 00000000000000000000000000000000
publish
dx_completion_receipt_valid "$DEX_SESSION_ID" child review-pass 3 "$generation" || assert_at $LINENO
assert_eq CLEAN "$(cat "$(dx_review_result_file "$DEX_SESSION_ID")")" 'published result'
assert_eq "$(dx_review_empty_findings_hash)" "$(cat "$(dx_findings_file "$DEX_SESSION_ID")")" 'empty findings hash'
dx_review_evidence_valid "$(dx_review_evidence_file "$DEX_SESSION_ID")" CLEAN standard \
  "$DEX_REVIEW_SCOPE_FINGERPRINT" standalone '' "$DEX_REVIEW_PASS_ID" \
  "$DEX_REVIEW_POLICY_BINDING" "$(dx_review_context_file "$DEX_SESSION_ID")" || assert_at $LINENO
assert_rejected 'already completed generation' publish
dx_cleanup_session "$DEX_SESSION_ID"

export DEX_REVIEW_CRITERIA_FILE="$TMP_DIR/criteria.json"
printf '%s\n' '{"version":1,"source":"approved-plan","objectives":["Retain independent review."],"acceptance_criteria":["Require complete evidence."],"verification_requirements":["Run focused fixture checks."]}' > "$DEX_REVIEW_CRITERIA_FILE"
DEX_REVIEW_CRITERIA_BINDING=$(dx_review_criteria_hash "$DEX_REVIEW_CRITERIA_FILE")
bind_pass
generation=$(dx_completion_loop_activate "$DEX_SESSION_ID" child review-pass 3)
for invalid in criteria-missing criteria-placeholder criteria-not-met; do
  write_report "$invalid"
  assert_rejected "$invalid rejected" publish
  assert_rejected 'no criterion bypass receipt' dx_completion_receipt_present "$DEX_SESSION_ID"
done
write_report criteria-valid
publish
dx_review_evidence_valid "$(dx_review_evidence_file "$DEX_SESSION_ID")" CLEAN standard \
  "$DEX_REVIEW_SCOPE_FINGERPRINT" "$DEX_REVIEW_CRITERIA_BINDING" "$DEX_REVIEW_CRITERIA_FILE" \
  "$DEX_REVIEW_PASS_ID" "$DEX_REVIEW_POLICY_BINDING" "$(dx_review_context_file "$DEX_SESSION_ID")" || assert_at $LINENO
dx_cleanup_session "$DEX_SESSION_ID"

git init -q -b main "$TMP_DIR/repo"
git -C "$TMP_DIR/repo" config user.name 'Dex Test'
git -C "$TMP_DIR/repo" config user.email dex-test@example.com
printf '%s\n' original > "$TMP_DIR/repo/app.txt"
git -C "$TMP_DIR/repo" add app.txt
git -C "$TMP_DIR/repo" commit -qm 'test: initialize input fixture'
dx_review_input_write "$DEX_SESSION_ID" "$TMP_DIR/repo" \
  "$(dx_review_scope_fingerprint "$TMP_DIR/repo")" "$(dx_review_working_fingerprint "$TMP_DIR/repo")"
input_file=$(dx_review_input_file "$DEX_SESSION_ID")
assert_contains 'entire tracked codebase' "$input_file"
assert_contains 'app.txt' "$input_file"
assert_rejected 'factual inventory cannot pass as reviewed context' dx_review_context_valid "$input_file" standalone
printf '%s\n' new > "$TMP_DIR/repo/new.txt"
dx_review_input_write "$DEX_SESSION_ID" "$TMP_DIR/repo" \
  "$(dx_review_scope_fingerprint "$TMP_DIR/repo")" "$(dx_review_working_fingerprint "$TMP_DIR/repo")"
assert_contains 'full current change set' "$input_file"
assert_contains 'new.txt' "$input_file"
dx_cleanup_session "$DEX_SESSION_ID"
[[ ! -e "$input_file" ]] || assert_at $LINENO
printf '%s\n' 'review report and input tests passed'
