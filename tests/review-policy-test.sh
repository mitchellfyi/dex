#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-review-policy-test.XXXXXX")"

cleanup() {
  rm -rf "$TMP_DIR"
}
trap cleanup EXIT

export HOME="$TMP_DIR/home"
export DEX_DIR="$ROOT"
export DX_STATE_DIR="$TMP_DIR/state"
export DX_LOOP_DIR="$TMP_DIR/loops"
export DX_ARTIFACT_DIR="$TMP_DIR/artifacts"
export DX_TOOL_DIR="$TMP_DIR/tools"
export DX_RUN_ROOT="$TMP_DIR/runs"
mkdir -p "$HOME" "$DX_STATE_DIR" "$DX_LOOP_DIR"

# shellcheck disable=SC1091
source "$ROOT/lib/common.sh"

assert_eq() {
  local expected="$1" actual="$2" label="$3"
  if [[ "$expected" != "$actual" ]]; then
    printf '%s: expected %s, got %s\n' "$label" "$expected" "$actual" >&2
    exit 1
  fi
}

assert_rejected() {
  local label="$1"
  shift
  if "$@"; then
    printf '%s: expected command to fail\n' "$label" >&2
    exit 1
  fi
}

assert_eq "small" "$(dx_review_normalize_tier light)" "light alias"
assert_eq "normal" "$(dx_review_normalize_tier standard)" "standard alias"
assert_eq "complex" "$(dx_review_normalize_tier thorough)" "thorough alias"
assert_eq "complex" "$(dx_review_normalize_tier high-risk)" "high-risk alias"
assert_eq "light" "$(dx_review_tier_profile small)" "small depth"
assert_eq "standard" "$(dx_review_tier_profile normal)" "normal depth"
assert_eq "thorough" "$(dx_review_tier_profile complex)" "complex depth"
assert_eq "3" "$(dx_review_tier_clean_passes small)" "small gate"
assert_eq "6" "$(dx_review_tier_clean_passes normal)" "normal gate"
assert_eq "9" "$(dx_review_tier_clean_passes complex)" "complex gate"
assert_eq "normal" "$(dx_review_higher_tier small normal)" "tier promotion"
assert_eq "complex" "$(dx_review_higher_tier complex normal)" "tier retention"
assert_rejected "unknown tier" dx_review_normalize_tier unknown

dx_review_is_positive_integer 08
dx_review_is_nonnegative_integer 0
assert_rejected "zero clean gate" dx_review_is_positive_integer 0
assert_rejected "negative safety limit" dx_review_is_nonnegative_integer -1
assert_rejected "overflowing integer" dx_review_is_positive_integer 9999999999999999999

dx_review_reason_codes_valid "cross-module,public-contract"
assert_rejected "free-form reason" dx_review_reason_codes_valid "This contains prose"
dx_review_assessment_reason_codes_valid "cross-module,public-contract"
assert_rejected "invented assessment reason" dx_review_assessment_reason_codes_valid "invented-agent-rationale"
dx_review_tier_reason_codes_valid small "localized-change,focused-verification"
dx_review_tier_reason_codes_valid normal "bounded-production-change"
dx_review_tier_reason_codes_valid complex "cross-module,public-contract"
assert_rejected "small tier missing focused verification" dx_review_tier_reason_codes_valid small "localized-change"
assert_rejected "small tier with complex reason" dx_review_tier_reason_codes_valid small "localized-change,focused-verification,public-contract"
assert_rejected "normal tier claiming exact small conditions" dx_review_tier_reason_codes_valid normal "localized-change,focused-verification"
assert_rejected "complex tier without complex reason" dx_review_tier_reason_codes_valid complex "bounded-production-change"

assessment_file="$TMP_DIR/assessment.json"
printf '%s\n' '{"tier":"complex","reason_codes":"cross-module,public-contract"}' > "$assessment_file"
assert_eq $'complex\tcross-module,public-contract' "$(dx_review_parse_assessment_file "$assessment_file")" "assessment result"
printf '%s\n' '{"tier":"complex","reason_codes":"invented-agent-rationale"}' > "$assessment_file"
assert_rejected "assessment result vocabulary" dx_review_parse_assessment_file "$assessment_file"
printf '%s\n' '{"tier":"small","reason_codes":"public-contract"}' > "$assessment_file"
assert_rejected "assessment result tier consistency" dx_review_parse_assessment_file "$assessment_file"
printf '%s\n' '{"tier":"complex","reason_codes":"cross-module","extra":"prose"}' > "$assessment_file"
assert_rejected "assessment result extra field" dx_review_parse_assessment_file "$assessment_file"

criteria_file=$(dx_review_criteria_file criteria-policy)
printf '%s\n' '{"version":1,"source":"approved-plan","objectives":["Preserve the public behavior."],"acceptance_criteria":["The command returns the documented result."],"verification_requirements":["Run tests/review-policy-test.sh."]}' > "$criteria_file"
dx_review_criteria_valid "$criteria_file"
criteria_hash=$(dx_review_criteria_hash "$criteria_file")
[[ "$criteria_hash" =~ ^[a-f0-9]{64}$ ]] || {
  printf 'criteria hash is not a full lowercase SHA-256 digest\n' >&2
  exit 1
}
printf '%s\n' '{"version":1,"source":"approved-plan","objectives":[],"acceptance_criteria":["The command works."],"verification_requirements":["Run the test."]}' > "$criteria_file"
assert_rejected "criteria require an objective" dx_review_criteria_valid "$criteria_file"
printf '%s\n' '{"version":1,"source":"conversation","objectives":["Implement the change."],"acceptance_criteria":["The command works."],"verification_requirements":["Run the test."]}' > "$criteria_file"
assert_rejected "criteria source is bounded" dx_review_criteria_valid "$criteria_file"
printf '%s\n' '{"version":1,"source":"approved-plan","objectives":["Implement the change."],"acceptance_criteria":["The command works.","The command works."],"verification_requirements":["Run the test."]}' > "$criteria_file"
assert_rejected "criteria reject duplicates" dx_review_criteria_valid "$criteria_file"
printf '%s\n' '{"version":1,"source":"approved-plan","objectives":[" Implement the change."],"acceptance_criteria":["The command works."],"verification_requirements":["Run the test."],"extra":true}' > "$criteria_file"
assert_rejected "criteria reject whitespace and extra fields" dx_review_criteria_valid "$criteria_file"
printf '%s\n' '{"version":1,"source":"approved-plan","objectives":["<approved objective>"],"acceptance_criteria":["The command works."],"verification_requirements":["Run the test."]}' > "$criteria_file"
assert_rejected "criteria reject placeholders" dx_review_criteria_valid "$criteria_file"
rm -f "$criteria_file"

for result in \
  CLEAN \
  FINDINGS_FIXED:1 \
  FINDINGS:2 \
  BLOCKED:missing-tool \
  CHURN:repeated-fingerprint \
  ESCALATE:normal:cross-module \
  ESCALATE:complex:security \
  ESCALATE_THOROUGH:legacy; do
  dx_review_result_valid "$result"
done

for result in \
  "" \
  FINDINGS_FIXED:0 \
  FINDINGS:0 \
  BLOCKED: \
  "BLOCKED:free form prose" \
  CHURN: \
  ESCALATE:small:reason \
  $'CLEAN\nBLOCKED:x'; do
  assert_rejected "invalid result '$result'" dx_review_result_valid "$result"
done

assert_eq "clean" "$(dx_review_result_kind CLEAN)" "clean result kind"
assert_eq "findings_fixed" "$(dx_review_result_kind FINDINGS_FIXED:4)" "fixed result kind"
assert_eq "4" "$(dx_review_result_count FINDINGS_FIXED:4)" "fixed result count"
assert_eq "normal" "$(dx_review_escalation_tier ESCALATE:normal:scope)" "normal escalation"
assert_eq "complex" "$(dx_review_escalation_tier ESCALATE_THOROUGH:legacy)" "legacy escalation"

REPO="$TMP_DIR/repo"
git init -q -b main "$REPO"
git -C "$REPO" config user.name "Dex Test"
git -C "$REPO" config user.email "dex-test@example.com"
printf 'base\n' > "$REPO/app.txt"
git -C "$REPO" add app.txt
git -C "$REPO" commit -qm "test: initialize review fixture"

base_fingerprint="$(dx_review_scope_fingerprint "$REPO")"
evidence_file="$TMP_DIR/review-evidence.json"
printf '%s\n' "{\"version\":1,\"scope_fingerprint\":\"${base_fingerprint}\",\"deterministic_checks\":\"pass\",\"coverage\":[\"correctness\",\"security\",\"contracts\",\"tests\",\"architecture\"],\"verifier\":\"pass\",\"verified_findings\":0,\"fixes_applied\":0}" > "$evidence_file"
dx_review_evidence_valid "$evidence_file" CLEAN light "$base_fingerprint"
printf '%s\n' "{\"version\":1,\"scope_fingerprint\":\"${base_fingerprint}\",\"deterministic_checks\":\"partial\",\"coverage\":[\"correctness\",\"security\",\"contracts\",\"tests\",\"architecture\"],\"verifier\":\"pass\",\"verified_findings\":0,\"fixes_applied\":0}" > "$evidence_file"
assert_rejected "clean evidence requires passing checks" dx_review_evidence_valid "$evidence_file" CLEAN light "$base_fingerprint"
printf '%s\n' "{\"version\":1,\"scope_fingerprint\":\"${base_fingerprint}\",\"deterministic_checks\":\"pass\",\"coverage\":[\"correctness\",\"security\",\"contracts\",\"tests\",\"architecture\"],\"verifier\":\"pass\",\"verified_findings\":1,\"fixes_applied\":1}" > "$evidence_file"
dx_review_evidence_valid "$evidence_file" FINDINGS_FIXED:1 light "$base_fingerprint"
assert_rejected "evidence is bound to scope" dx_review_evidence_valid "$evidence_file" FINDINGS_FIXED:1 light "$(printf '0%.0s' {1..64})"

printf 'changed\n' >> "$REPO/app.txt"
changed_fingerprint="$(dx_review_scope_fingerprint "$REPO")"
[[ "$base_fingerprint" != "$changed_fingerprint" ]] || {
  printf 'tracked change did not alter the scope fingerprint\n' >&2
  exit 1
}
git -C "$REPO" restore app.txt

printf 'staged-only\n' > "$REPO/app.txt"
git -C "$REPO" add app.txt
git -C "$REPO" restore --source=HEAD --worktree -- app.txt
git -C "$REPO" diff --cached --quiet -- app.txt && {
  printf 'fingerprint cancellation fixture has no cached diff\n' >&2
  exit 1
}
git -C "$REPO" diff --quiet -- app.txt && {
  printf 'fingerprint cancellation fixture has no worktree diff\n' >&2
  exit 1
}
cancelled_fingerprint="$(dx_review_scope_fingerprint "$REPO")"
[[ "$base_fingerprint" != "$cancelled_fingerprint" ]] || {
  printf 'cached and worktree changes cancelled in the scope fingerprint\n' >&2
  exit 1
}
git -C "$REPO" restore --source=HEAD --staged --worktree -- app.txt

printf 'untracked\n' > "$REPO/new.txt"
untracked_fingerprint="$(dx_review_scope_fingerprint "$REPO")"
[[ "$base_fingerprint" != "$untracked_fingerprint" ]] || {
  printf 'untracked content did not alter the scope fingerprint\n' >&2
  exit 1
}
chmod +x "$REPO/new.txt"
[[ "$untracked_fingerprint" != "$(dx_review_scope_fingerprint "$REPO")" ]] || {
  printf 'untracked executable mode did not alter the scope fingerprint\n' >&2
  exit 1
}
rm "$REPO/new.txt"

mkdir -p "$REPO/subdir"
printf 'root-untracked\n' > "$REPO/root-untracked.txt"
subdir_fingerprint="$(dx_review_scope_fingerprint "$REPO/subdir")"
assert_eq "$(dx_review_scope_fingerprint "$REPO")" "$subdir_fingerprint" "subdirectory scope uses repository root"
printf 'root-untracked-changed\n' > "$REPO/root-untracked.txt"
[[ "$subdir_fingerprint" != "$(dx_review_scope_fingerprint "$REPO/subdir")" ]] || {
  printf 'subdirectory fingerprint missed a root-level untracked change\n' >&2
  exit 1
}
rm "$REPO/root-untracked.txt"

LOCAL_ONLY_REPO="$TMP_DIR/local-only-repo"
git init -q -b main "$LOCAL_ONLY_REPO"
git -C "$LOCAL_ONLY_REPO" config user.name "Dex Test"
git -C "$LOCAL_ONLY_REPO" config user.email "dex-test@example.com"
printf 'base\n' > "$LOCAL_ONLY_REPO/app.txt"
git -C "$LOCAL_ONLY_REPO" add app.txt
git -C "$LOCAL_ONLY_REPO" commit -qm "test: initialize local-only fixture"
local_main_oid=$(git -C "$LOCAL_ONLY_REPO" rev-parse main)
git -C "$LOCAL_ONLY_REPO" switch -qc feature
printf 'feature\n' >> "$LOCAL_ONLY_REPO/app.txt"
git -C "$LOCAL_ONLY_REPO" commit -qam "test: add local feature change"
IFS=$'\t' read -r local_mode local_ref local_comparison_oid local_merge_base < <(dx_review_scope_descriptor "$LOCAL_ONLY_REPO")
assert_eq "changes" "$local_mode" "local-only feature scope mode"
assert_eq "main" "$local_ref" "local-only feature comparison ref"
assert_eq "$local_main_oid" "$local_comparison_oid" "local-only feature comparison oid"
assert_eq "$local_main_oid" "$local_merge_base" "local-only feature merge base"

MOVING_REF_REPO="$TMP_DIR/moving-ref-repo"
git init -q -b main "$MOVING_REF_REPO"
git -C "$MOVING_REF_REPO" config user.name "Dex Test"
git -C "$MOVING_REF_REPO" config user.email "dex-test@example.com"
printf 'base\n' > "$MOVING_REF_REPO/app.txt"
git -C "$MOVING_REF_REPO" add app.txt
git -C "$MOVING_REF_REPO" commit -qm "test: initialize moving-ref fixture"
moving_base_oid=$(git -C "$MOVING_REF_REPO" rev-parse HEAD)
git -C "$MOVING_REF_REPO" switch -qc feature
printf 'feature\n' >> "$MOVING_REF_REPO/app.txt"
git -C "$MOVING_REF_REPO" commit -qam "test: add moving-ref feature"
git -C "$MOVING_REF_REPO" switch -q main
printf 'upstream\n' > "$MOVING_REF_REPO/upstream.txt"
git -C "$MOVING_REF_REPO" add upstream.txt
git -C "$MOVING_REF_REPO" commit -qm "test: advance default branch"
moving_advanced_oid=$(git -C "$MOVING_REF_REPO" rev-parse HEAD)
git -C "$MOVING_REF_REPO" switch -q feature
git -C "$MOVING_REF_REPO" update-ref refs/remotes/origin/main "$moving_base_oid"
moving_before=$(dx_review_scope_fingerprint "$MOVING_REF_REPO")
dx_review_write_selection moving-ref small environment operator-override "$MOVING_REF_REPO"
git -C "$MOVING_REF_REPO" update-ref refs/remotes/origin/main "$moving_advanced_oid"
moving_after=$(dx_review_scope_fingerprint "$MOVING_REF_REPO")
[[ "$moving_before" != "$moving_after" ]] || {
  printf 'comparison ref movement did not alter the scope fingerprint\n' >&2
  exit 1
}
assert_rejected "comparison ref movement invalidates selection" dx_review_selection_valid moving-ref "$MOVING_REF_REPO"

UNBORN_REPO="$TMP_DIR/unborn-repo"
git init -q -b main "$UNBORN_REPO"
printf 'staged\n' > "$UNBORN_REPO/staged.txt"
git -C "$UNBORN_REPO" add staged.txt
printf 'untracked\n' > "$UNBORN_REPO/untracked.txt"
unborn_scope_before=$(dx_review_scope_fingerprint "$UNBORN_REPO")
unborn_working_before=$(dx_review_working_fingerprint "$UNBORN_REPO")
printf 'changed\n' >> "$UNBORN_REPO/staged.txt"
[[ "$unborn_scope_before" != "$(dx_review_scope_fingerprint "$UNBORN_REPO")" ]] || {
  printf 'unborn tracked change did not alter the scope fingerprint\n' >&2
  exit 1
}
[[ "$unborn_working_before" != "$(dx_review_working_fingerprint "$UNBORN_REPO")" ]] || {
  printf 'unborn tracked change did not alter the working fingerprint\n' >&2
  exit 1
}

# Keep the policy fixture in change-set mode so lifecycle-agent selections are
# checked against a localized implementation rather than a whole-codebase floor.
printf 'candidate\n' > "$REPO/candidate.txt"
base_fingerprint="$(dx_review_scope_fingerprint "$REPO")"

session_id="review-policy"
dx_review_write_selection "$session_id" normal lifecycle-agent bounded-production-change "$REPO"
IFS=$'\t' read -r tier source reason selection_required fingerprint < <(dx_review_read_selection "$session_id" "$REPO")
assert_eq "normal" "$tier" "selection tier"
assert_eq "lifecycle-agent" "$source" "selection source"
assert_eq "bounded-production-change" "$reason" "selection reason"
assert_eq "6" "$selection_required" "selection requirement"
assert_eq "$base_fingerprint" "$fingerprint" "selection fingerprint"
assert_rejected "invented selection reason" dx_review_write_selection "$session_id" normal lifecycle-agent invented-agent-rationale "$REPO"
assert_rejected "reserved reason with assessor source" dx_review_write_selection "$session_id" normal lifecycle-agent operator-override "$REPO"
assert_rejected "selection tier contradicts reason" dx_review_write_selection "$session_id" normal lifecycle-agent cross-module "$REPO"

dx_review_write_state "$session_id" normal 6 4 2 "$REPO"
IFS=$'\t' read -r state_tier required iteration clean_count state_fingerprint < <(dx_review_read_state "$session_id" "$REPO")
assert_eq "normal" "$state_tier" "state tier"
assert_eq "6" "$required" "state requirement"
assert_eq "4" "$iteration" "state iteration"
assert_eq "2" "$clean_count" "state clean count"
assert_eq "$base_fingerprint" "$state_fingerprint" "state fingerprint"
assert_rejected "state below tier gate" dx_review_write_state "$session_id" normal 5 1 0 "$REPO"
assert_rejected "state clean exceeds iteration" dx_review_write_state "$session_id" normal 6 1 2 "$REPO"
assert_rejected "completed state is not resumable" dx_review_write_state "$session_id" normal 6 6 6 "$REPO"

assert_rejected "small receipt below canonical gate" dx_review_write_receipt "$session_id" small 2 2 "$REPO"
assert_rejected "normal receipt below canonical gate" dx_review_write_receipt "$session_id" normal 5 5 "$REPO"
assert_rejected "complex receipt below canonical gate" dx_review_write_receipt "$session_id" complex 8 8 "$REPO"
assert_rejected "incomplete receipt" dx_review_write_receipt "$session_id" normal 6 5 "$REPO"
for ledger_iteration in 1 2 3 4 5 6; do
  dx_review_ledger_append "$session_id" "$ledger_iteration" "clean-${ledger_iteration}" "$base_fingerprint" "$(printf '%016x' "$ledger_iteration")"
done
dx_review_write_receipt "$session_id" normal 6 6 "$REPO"
assert_rejected "active state blocks receipt" dx_review_receipt_valid "$session_id" "$REPO"
rm "$(dx_review_state_file "$session_id")"
dx_review_receipt_valid "$session_id" "$REPO"

dx_review_ledger_reset "$session_id"
for ledger_iteration in 1 2 3 4 5 6 7 8; do
  dx_review_ledger_append "$session_id" "$ledger_iteration" "higher-clean-${ledger_iteration}" "$base_fingerprint" "$(printf '%016x' "$ledger_iteration")"
done
dx_review_write_receipt "$session_id" normal 8 8 "$REPO"
IFS=$'\t' read -r receipt_tier receipt_required receipt_clean receipt_fingerprint receipt_ledger_hash < <(dx_review_read_receipt "$session_id" "$REPO")
assert_eq "normal" "$receipt_tier" "higher-gate receipt tier"
assert_eq "8" "$receipt_required" "higher-gate receipt requirement"
assert_eq "8" "$receipt_clean" "higher-gate receipt clean count"
assert_eq "$base_fingerprint" "$receipt_fingerprint" "higher-gate receipt fingerprint"
[[ "$receipt_ledger_hash" =~ ^[a-f0-9]{64}$ ]]
assert_rejected "receipt gate must match selection" dx_review_receipt_valid "$session_id" "$REPO"
dx_review_write_selection "$session_id" normal lifecycle-agent bounded-production-change "$REPO" 8
dx_review_receipt_valid "$session_id" "$REPO"

printf '1\tnormal\t1\t1\t%s\n' "$base_fingerprint" > "$(dx_review_receipt_file "$session_id")"
assert_rejected "receipt reader rejects below canonical gate" dx_review_read_receipt "$session_id" "$REPO"
assert_rejected "receipt validator rejects below canonical gate" dx_review_receipt_valid "$session_id" "$REPO"
dx_review_write_selection "$session_id" normal lifecycle-agent bounded-production-change "$REPO" 6
dx_review_ledger_reset "$session_id"
for ledger_iteration in 1 2 3 4 5 6; do
  dx_review_ledger_append "$session_id" "$ledger_iteration" "final-clean-${ledger_iteration}" "$base_fingerprint" "$(printf '%016x' "$ledger_iteration")"
done
dx_review_write_receipt "$session_id" normal 6 6 "$REPO"

printf 'external change\n' >> "$REPO/app.txt"
assert_rejected "stale selection" dx_review_selection_valid "$session_id" "$REPO"
assert_rejected "stale state" dx_review_read_state "$session_id" "$REPO"
assert_rejected "stale receipt" dx_review_receipt_valid "$session_id" "$REPO"
git -C "$REPO" restore app.txt

findings_file="$DX_LOOP_DIR/findings"
printf '%s\n' aabbccddeeff0011 > "$findings_file"
assert_eq "aabbccddeeff0011" "$(dx_review_read_findings_hash "$findings_file")" "findings hash"
assert_eq "a3395601ed5265fe" "$(dx_review_empty_findings_hash)" "empty findings hash"
printf '%s\n' not-a-hash > "$findings_file"
assert_rejected "malformed findings hash" dx_review_read_findings_hash "$findings_file"
printf '%s\n' a a a > "$findings_file"
assert_eq "repeated_fingerprint" "$(dx_review_findings_churn_kind "$findings_file")" "repeat churn"
printf '%s\n' a b a b > "$findings_file"
assert_eq "alternating_fingerprints" "$(dx_review_findings_churn_kind "$findings_file")" "oscillation churn"
printf '%s\n' a b c > "$findings_file"
assert_rejected "distinct findings" dx_review_findings_churn_kind "$findings_file"

event_json="$(dx_review_event_json tier=normal iteration_int=4 churn_detected_bool=false)"
assert_eq '{"churn_detected":false,"iteration":4,"tier":"normal"}' "$event_json" "typed event JSON"

timeout_watchdog_pid_file="$TMP_DIR/watchdog-sleep.pid"
# shellcheck disable=SC2329  # invoked indirectly by the timeout helper's watchdog subshell
sleep() {
  /bin/sleep "$@" &
  printf '%s\n' "$!" > "$timeout_watchdog_pid_file"
  wait "$!"
}
dx_run_with_timeout 5 bash -c '/bin/sleep 0.2'
watchdog_sleep_pid="$(cat "$timeout_watchdog_pid_file")"
unset -f sleep
for _ in 1 2 3 4 5; do
  kill -0 "$watchdog_sleep_pid" 2>/dev/null || break
  /bin/sleep 0.1
done
if kill -0 "$watchdog_sleep_pid" 2>/dev/null; then
  printf 'timeout watchdog left its sleep child running: %s\n' "$watchdog_sleep_pid" >&2
  kill "$watchdog_sleep_pid" 2>/dev/null || true
  exit 1
fi

dx_cleanup_session "$session_id"
[[ ! -e "$(dx_review_selection_file "$session_id")" ]]
[[ ! -e "$(dx_review_state_file "$session_id")" ]]
[[ ! -e "$(dx_review_receipt_file "$session_id")" ]]

printf 'review-policy-test passed\n'
