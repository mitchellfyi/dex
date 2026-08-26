#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
# shellcheck source=tests/helpers.sh
source "$ROOT/tests/helpers.sh"
TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/dex-review-policy-test.XXXXXX")"

cleanup() {
  chmod -R u+w "$TMP_DIR" 2>/dev/null || true
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
# shellcheck disable=SC1091
source "$ROOT/tests/review-proof-fixture.sh"


append_clean_ledger() {
  local session_id="$1" count="$2" fingerprint="$3" criteria_binding="$4"
  local policy_binding="$5" pass_prefix="$6" profile="$7" iteration pass_id
  local evidence_file context_file
  for ((iteration = 1; iteration <= count; iteration++)); do
    pass_id="${pass_prefix}-${iteration}"
    evidence_file="$TMP_DIR/${session_id}-${iteration}.evidence.json"
    context_file="$TMP_DIR/${session_id}-${iteration}.context.md"
    dx_test_write_clean_review_proof "$session_id" "$pass_id" "$profile" \
      "$fingerprint" "$criteria_binding" "$policy_binding" "$evidence_file" "$context_file"
    dx_review_ledger_append "$session_id" "$iteration" "$pass_id" "$profile" \
      "$fingerprint" "$criteria_binding" "$policy_binding" "$evidence_file" "$context_file"
    rm -f "$evidence_file" "$context_file"
  done
}

assert_eq "small" "$(dx_review_normalize_tier light)" "light alias"
assert_eq "normal" "$(dx_review_normalize_tier standard)" "standard alias"
assert_eq "complex" "$(dx_review_normalize_tier thorough)" "thorough alias"
assert_eq "complex" "$(dx_review_normalize_tier high-risk)" "high-risk alias"
assert_eq "light" "$(dx_review_tier_profile small)" "small depth"
assert_eq "standard" "$(dx_review_tier_profile normal)" "normal depth"
assert_eq "thorough" "$(dx_review_tier_profile complex)" "complex depth"
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
printf '%s' '{ "verification_requirements" : [ "Run tests/review-policy-test.sh." ], "acceptance_criteria" : [ "The command returns the documented result." ], "objectives" : [ "Preserve the public behavior." ], "source" : "approved-plan", "version" : 1 }' > "$criteria_file"
assert_eq "$criteria_hash" "$(dx_review_criteria_hash "$criteria_file")" "criteria hash uses canonical JSON"
printf '%s\n' '{"version":1,"source":"approved-plan","objectives":["Preserve both public behaviors."],"acceptance_criteria":["The command returns the documented result."],"verification_requirements":["Run tests/review-policy-test.sh."]}' > "$criteria_file"
[[ "$criteria_hash" != "$(dx_review_criteria_hash "$criteria_file")" ]] || {
  printf 'criteria hash did not change with approved requirements\n' >&2
  exit 1
}
printf '%s\n' '{"version":true,"source":"approved-plan","objectives":["Implement the change."],"acceptance_criteria":["The command works."],"verification_requirements":["Run the test."]}' > "$criteria_file"
assert_rejected "criteria reject boolean versions" dx_review_criteria_valid "$criteria_file"
printf '%s\n' '{"version":1,"source":"approved-plan","objectives":[{"text":"Implement the change."}],"acceptance_criteria":["The command works."],"verification_requirements":["Run the test."]}' > "$criteria_file"
assert_rejected "criteria reject non-string entries" dx_review_criteria_valid "$criteria_file"
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

approval_session="criteria-approval-policy"
approval_criteria_file=$(dx_review_criteria_file "$approval_session")
printf '%s\n' '{"version":1,"source":"approved-plan","objectives":["Seal the approved requirements."],"acceptance_criteria":["Later changes require explicit reapproval."],"verification_requirements":["Run tests/review-policy-test.sh."]}' > "$approval_criteria_file"
approval_hash_a=$(dx_review_criteria_hash "$approval_criteria_file")
dx_review_approve_criteria "$approval_session" initial "$approval_hash_a" >/dev/null
assert_eq "$approval_hash_a" "$(dx_review_read_criteria_approval "$approval_session")" "initial criteria approval"
assert_eq "1" "$(cut -f2 "$(dx_review_criteria_approval_file "$approval_session")")" "initial approval revision"
dx_review_approve_criteria "$approval_session" initial "$approval_hash_a" >/dev/null
printf '%s\n' '{"version":1,"source":"approved-plan","objectives":["Seal the reapproved requirements."],"acceptance_criteria":["Rotation invalidates earlier authorization."],"verification_requirements":["Run tests/review-policy-test.sh."]}' > "$approval_criteria_file"
approval_hash_b=$(dx_review_criteria_hash "$approval_criteria_file")
assert_rejected "initial approval cannot rotate criteria" dx_review_approve_criteria "$approval_session" initial "$approval_hash_b"
assert_rejected "reapproval rejects the wrong previous hash" dx_review_approve_criteria "$approval_session" reapproved "$(printf '0%.0s' {1..64})" "$approval_hash_b"
touch "$(dx_review_state_file "$approval_session")" "$(dx_review_ledger_file "$approval_session")" "$(dx_review_receipt_file "$approval_session")"
dx_review_approve_criteria "$approval_session" reapproved "$approval_hash_a" "$approval_hash_b" >/dev/null
assert_eq "$approval_hash_b" "$(dx_review_read_criteria_approval "$approval_session")" "rotated criteria approval"
assert_eq "2" "$(cut -f2 "$(dx_review_criteria_approval_file "$approval_session")")" "rotated approval revision"
[[ ! -e "$(dx_review_state_file "$approval_session")" && ! -e "$(dx_review_ledger_file "$approval_session")" && ! -e "$(dx_review_receipt_file "$approval_session")" ]] || {
  printf 'criteria reapproval retained derived authorization\n' >&2
  exit 1
}
touch "$(dx_review_state_file "$approval_session")"
dx_review_approve_criteria "$approval_session" reapproved "$approval_hash_b" "$approval_hash_b" >/dev/null
[[ ! -e "$(dx_review_state_file "$approval_session")" ]] || {
  printf 'idempotent criteria reapproval retained derived authorization\n' >&2
  exit 1
}
dx_cleanup_session "$approval_session"
[[ ! -e "$(dx_review_criteria_approval_file "$approval_session")" ]] || assert_at $LINENO

copy_source=$(dx_review_criteria_file criteria-copy-source)
copy_target=$(dx_review_criteria_file criteria-copy-target)
printf '%s\n' '{"version":1,"source":"approved-plan","objectives":["Copy approved requirements safely."],"acceptance_criteria":["The copied artifact has the same canonical content."],"verification_requirements":["Run tests/review-policy-test.sh."]}' > "$copy_source"
copy_hash=$(dx_review_criteria_hash "$copy_source")
dx_review_copy_criteria "$copy_source" "$copy_target" "$copy_hash"
assert_eq "$copy_hash" "$(dx_review_criteria_hash "$copy_target")" "criteria copy binding"
assert_rejected "criteria copy rejects the wrong binding" dx_review_copy_criteria "$copy_source" "$copy_target" "$(printf '0%.0s' {1..64})"
rm -f "$copy_source" "$copy_target"

context_file="$TMP_DIR/review-context"
{
  printf '%s\n\n' '## Scope' 'Policy fixture scope.'
  printf '%s\n\n' '## Acceptance Criteria' 'Criteria binding: standalone'
  printf '%s\n\n' '## Deterministic Checks' 'The policy test passed.'
  printf '%s\n\n' '## Review Coverage' 'Core domains covered.'
  printf '%s\n' '## Verification' 'Verifier passed.'
} > "$context_file"
dx_review_context_valid "$context_file" standalone
assert_rejected "context rejects the wrong criteria binding" dx_review_context_valid "$context_file" "$copy_hash"

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
IFS=$'\t' read -r policy_small policy_normal policy_complex policy_binding \
  policy_ref policy_oid < <(dx_review_policy_resolve "$REPO")
assert_eq "1" "$policy_small" "trusted small policy"
assert_eq "3" "$policy_normal" "trusted normal policy"
assert_eq "6" "$policy_complex" "trusted complex policy"
[[ "$policy_binding" =~ ^[a-f0-9]{64}$ ]] || {
  printf 'trusted policy binding is not a full lowercase SHA-256 digest\n' >&2
  exit 1
}
[[ -n "$policy_ref" && "$policy_oid" =~ ^[a-f0-9]{40,64}$ ]] || {
  printf 'trusted policy provenance is incomplete\n' >&2
  exit 1
}
evidence_file="$TMP_DIR/review-evidence.json"
printf '%s\n' "{\"version\":1,\"scope_fingerprint\":\"${base_fingerprint}\",\"deterministic_checks\":\"pass\",\"coverage\":[\"correctness\",\"security\",\"contracts\",\"tests\",\"architecture\"],\"verifier\":\"pass\",\"verified_findings\":0,\"fixes_applied\":0}" > "$evidence_file"
printf '%s\n' "{\"version\":1,\"scope_fingerprint\":\"${base_fingerprint}\",\"deterministic_checks\":\"partial\",\"coverage\":[\"correctness\",\"security\",\"contracts\",\"tests\",\"architecture\"],\"verifier\":\"pass\",\"verified_findings\":0,\"fixes_applied\":0}" > "$evidence_file"
printf '%s\n' "{\"version\":1,\"scope_fingerprint\":\"${base_fingerprint}\",\"deterministic_checks\":\"pass\",\"coverage\":[\"correctness\",\"security\",\"contracts\",\"tests\",\"architecture\"],\"verifier\":\"pass\",\"verified_findings\":1,\"fixes_applied\":1}" > "$evidence_file"

evidence_criteria_file="$TMP_DIR/evidence-criteria.json"
printf '%s\n' '{"version":1,"source":"approved-plan","objectives":["Review every approved requirement."],"acceptance_criteria":["Evidence accounts for each criteria item."],"verification_requirements":["Run the focused policy test."]}' > "$evidence_criteria_file"
evidence_criteria_hash=$(dx_review_criteria_hash "$evidence_criteria_file")
evidence_criteria_coverage=$(dx_review_criteria_coverage_json "$evidence_criteria_hash" "$evidence_criteria_file")
printf '%s\n' "{\"version\":2,\"scope_fingerprint\":\"${base_fingerprint}\",\"criteria_binding\":\"${evidence_criteria_hash}\",\"criteria_coverage\":${evidence_criteria_coverage},\"deterministic_checks\":\"pass\",\"coverage\":[\"correctness\",\"security\",\"contracts\",\"tests\",\"architecture\"],\"verifier\":\"pass\",\"verified_findings\":0,\"fixes_applied\":0}" > "$evidence_file"
printf '%s\n' "{\"version\":2,\"scope_fingerprint\":\"${base_fingerprint}\",\"criteria_binding\":\"${evidence_criteria_hash}\",\"criteria_coverage\":{\"acceptance_criteria\":[],\"objectives\":[],\"verification_requirements\":[]},\"deterministic_checks\":\"pass\",\"coverage\":[\"correctness\",\"security\",\"contracts\",\"tests\",\"architecture\"],\"verifier\":\"pass\",\"verified_findings\":0,\"fixes_applied\":0}" > "$evidence_file"
printf '%s\n' "{\"version\":2,\"scope_fingerprint\":\"${base_fingerprint}\",\"criteria_binding\":\"standalone\",\"criteria_coverage\":{\"acceptance_criteria\":[],\"objectives\":[],\"verification_requirements\":[]},\"deterministic_checks\":\"pass\",\"coverage\":[\"correctness\",\"security\",\"contracts\",\"tests\",\"architecture\"],\"verifier\":\"pass\",\"verified_findings\":0,\"fixes_applied\":0}" > "$evidence_file"

evidence_pass_id="review-policy-evidence-1"
evidence_pass_binding=$(dx_review_pass_binding \
  "$evidence_pass_id" "$base_fingerprint" "$evidence_criteria_hash" "$policy_binding")
evidence_context_file="$TMP_DIR/evidence-context"
{
  printf '%s\n\n' '## Scope' 'Review the complete policy fixture scope.'
  printf '%s\n\n' '## Acceptance Criteria' "Criteria binding: ${evidence_criteria_hash}"
  printf '%s\n\n' '## Deterministic Checks' 'The focused review policy test passed.'
  printf '%s\n' 'Evidence-Ref: criteria:objectives:1:policy-scope | analysis | The current policy behavior was checked against the approved objective.'
  printf '%s\n' 'Evidence-Ref: criteria:acceptance_criteria:1:evidence-contract | file | The evidence manifest contains one bound record for the acceptance criterion.'
  printf '%s\n' 'Evidence-Ref: criteria:verification_requirements:1:focused-test | test | tests/review-policy-test.sh completed successfully.'
  printf '\n%s\n\n' '## Review Coverage' 'Correctness, contracts, tests, security, and architecture were inspected.'
  printf '%s\n' '## Verification' 'The verifier checked the evidence against the current pass inputs.'
} > "$evidence_context_file"
EVIDENCE_COVERAGE="$evidence_criteria_coverage" \
EVIDENCE_FILE="$evidence_file" \
SCOPE_FINGERPRINT="$base_fingerprint" \
CRITERIA_BINDING="$evidence_criteria_hash" \
POLICY_BINDING="$policy_binding" \
PASS_BINDING="$evidence_pass_binding" \
python3 - <<'PY'
import json
import os

coverage = json.loads(os.environ["EVIDENCE_COVERAGE"])
markers = {
    "objectives": "criteria:objectives:1:policy-scope",
    "acceptance_criteria": "criteria:acceptance_criteria:1:evidence-contract",
    "verification_requirements": "criteria:verification_requirements:1:focused-test",
}
criteria_evidence = {
    section: [
        {"item_hash": item_hash, "outcome": "met", "evidence_refs": [markers[section]]}
        for item_hash in item_hashes
    ]
    for section, item_hashes in coverage.items()
}
payload = {
    "version": 3,
    "scope_fingerprint": os.environ["SCOPE_FINGERPRINT"],
    "criteria_binding": os.environ["CRITERIA_BINDING"],
    "policy_binding": os.environ["POLICY_BINDING"],
    "pass_binding": os.environ["PASS_BINDING"],
    "criteria_evidence": criteria_evidence,
    "deterministic_checks": "pass",
    "coverage": ["correctness", "security", "contracts", "tests", "architecture"],
    "verifier": "pass",
    "verified_findings": 0,
    "fixes_applied": 0,
}
with open(os.environ["EVIDENCE_FILE"], "w", encoding="utf-8") as handle:
    json.dump(payload, handle, sort_keys=True, separators=(",", ":"))
    handle.write("\n")
PY
dx_review_evidence_valid "$evidence_file" CLEAN light "$base_fingerprint" \
  "$evidence_criteria_hash" "$evidence_criteria_file" "$evidence_pass_id" \
  "$policy_binding" "$evidence_context_file"
legacy_v2_file="$TMP_DIR/review-evidence-v2.json"
printf '%s\n' "{\"version\":2,\"scope_fingerprint\":\"${base_fingerprint}\",\"criteria_binding\":\"${evidence_criteria_hash}\",\"criteria_coverage\":${evidence_criteria_coverage},\"deterministic_checks\":\"pass\",\"coverage\":[\"correctness\",\"security\",\"contracts\",\"tests\",\"architecture\"],\"verifier\":\"pass\",\"verified_findings\":0,\"fixes_applied\":0}" > "$legacy_v2_file"
assert_rejected "legacy evidence cannot grant current clean credit" \
  dx_review_evidence_valid "$legacy_v2_file" CLEAN light "$base_fingerprint" \
  "$evidence_criteria_hash" "$evidence_criteria_file" "$evidence_pass_id" \
  "$policy_binding" "$evidence_context_file"

printf 'changed\n' >> "$REPO/app.txt"
changed_fingerprint="$(dx_review_scope_fingerprint "$REPO")"
[[ "$base_fingerprint" != "$changed_fingerprint" ]] || {
  printf 'tracked change did not alter the scope fingerprint\n' >&2
  exit 1
}
git -C "$REPO" restore app.txt

git -C "$REPO" switch -qc fingerprint-feature
printf 'publishable\n' >> "$REPO/app.txt"
unstaged_fingerprint="$(dx_review_scope_fingerprint "$REPO")"
publish_receipt_session="publish-receipt-stability"
dx_review_write_selection "$publish_receipt_session" small environment operator-override \
  "$REPO" "$policy_small" standalone "$policy_binding"
append_clean_ledger "$publish_receipt_session" "$policy_small" "$unstaged_fingerprint" \
  standalone "$policy_binding" publish-clean light
dx_review_write_receipt "$publish_receipt_session" small "$policy_small" \
  "$policy_small" "$REPO" standalone "$policy_binding"
dx_review_receipt_valid "$publish_receipt_session" "$REPO" standalone "$policy_binding"
git -C "$REPO" add app.txt
assert_eq "$unstaged_fingerprint" "$(dx_review_scope_fingerprint "$REPO")" \
  "staging identical content preserves scope fingerprint"
dx_review_receipt_valid "$publish_receipt_session" "$REPO" standalone "$policy_binding"
publish_state_session="publish-state-stability"
dx_review_write_selection "$publish_state_session" normal environment operator-override \
  "$REPO" "$policy_normal" standalone "$policy_binding"
dx_review_write_state "$publish_state_session" normal "$policy_normal" 2 1 \
  "$REPO" standalone "$policy_binding"
git -C "$REPO" commit -qm "test: publish identical review content"
assert_eq "$unstaged_fingerprint" "$(dx_review_scope_fingerprint "$REPO")" \
  "committing identical content preserves scope fingerprint"
dx_review_receipt_valid "$publish_receipt_session" "$REPO" standalone "$policy_binding"
IFS=$'\t' read -r publish_state_tier publish_state_required publish_state_iteration \
  publish_state_clean _ _ publish_state_policy < <(dx_review_read_state \
    "$publish_state_session" "$REPO" standalone "$policy_binding")
assert_eq "normal" "$publish_state_tier" "commit preserves review state tier"
assert_eq "$policy_normal" "$publish_state_required" "commit preserves review state gate"
assert_eq "2" "$publish_state_iteration" "commit preserves review state iteration"
assert_eq "1" "$publish_state_clean" "commit preserves review clean credit"
assert_eq "$policy_binding" "$publish_state_policy" "commit preserves review policy binding"
publish_proof_dir=$(dx_review_proof_dir "$publish_receipt_session")
[[ -d "$publish_proof_dir" ]] || assert_at $LINENO
dx_cleanup_session "$publish_receipt_session"
[[ ! -e "$publish_proof_dir" && ! -L "$publish_proof_dir" ]] || assert_at $LINENO
dx_cleanup_session "$publish_state_session"

published_fingerprint="$(dx_review_scope_fingerprint "$REPO")"
chmod +x "$REPO/app.txt"
[[ "$published_fingerprint" != "$(dx_review_scope_fingerprint "$REPO")" ]] || {
  printf 'tracked executable mode did not alter the scope fingerprint\n' >&2
  exit 1
}
chmod -x "$REPO/app.txt"

printf 'target-one\n' > "$REPO/link-target-one"
printf 'target-two\n' > "$REPO/link-target-two"
ln -s link-target-one "$REPO/current-link"
symlink_fingerprint="$(dx_review_scope_fingerprint "$REPO")"
ln -sfn link-target-two "$REPO/current-link"
[[ "$symlink_fingerprint" != "$(dx_review_scope_fingerprint "$REPO")" ]] || {
  printf 'symlink target change did not alter the scope fingerprint\n' >&2
  exit 1
}
rm "$REPO/current-link" "$REPO/link-target-one" "$REPO/link-target-two"

printf 'rename-me\n' > "$REPO/old-name.txt"
rename_source_fingerprint="$(dx_review_scope_fingerprint "$REPO")"
mv "$REPO/old-name.txt" "$REPO/new-name.txt"
[[ "$rename_source_fingerprint" != "$(dx_review_scope_fingerprint "$REPO")" ]] || {
  printf 'file rename did not alter the scope fingerprint\n' >&2
  exit 1
}
rm "$REPO/new-name.txt"

printf 'delete-me\n' > "$REPO/delete-me.txt"
git -C "$REPO" add delete-me.txt
git -C "$REPO" commit -qm "test: add deletion fixture"
delete_source_fingerprint="$(dx_review_scope_fingerprint "$REPO")"
rm "$REPO/delete-me.txt"
[[ "$delete_source_fingerprint" != "$(dx_review_scope_fingerprint "$REPO")" ]] || {
  printf 'tracked deletion did not alter the scope fingerprint\n' >&2
  exit 1
}
git -C "$REPO" restore delete-me.txt
git -C "$REPO" switch -q main

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
dx_review_write_selection moving-ref small environment operator-override \
  "$MOVING_REF_REPO" "$policy_small" standalone "$policy_binding"
git -C "$MOVING_REF_REPO" update-ref refs/remotes/origin/main "$moving_advanced_oid"
moving_after=$(dx_review_scope_fingerprint "$MOVING_REF_REPO")
assert_eq "$moving_before" "$moving_after" \
  "comparison movement with unchanged merge base preserves scope fingerprint"
dx_review_selection_valid moving-ref "$MOVING_REF_REPO" standalone "$policy_binding"
moving_feature_oid=$(git -C "$MOVING_REF_REPO" rev-parse HEAD)
git -C "$MOVING_REF_REPO" update-ref refs/remotes/origin/main "$moving_feature_oid"
moving_material_after=$(dx_review_scope_fingerprint "$MOVING_REF_REPO")
[[ "$moving_before" != "$moving_material_after" ]] || {
  printf 'material comparison-base change did not alter the scope fingerprint\n' >&2
  exit 1
}
assert_rejected "material comparison-base change invalidates selection" \
  dx_review_selection_valid moving-ref "$MOVING_REF_REPO" standalone "$policy_binding"

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
session_criteria_file=$(dx_review_criteria_file "$session_id")
session_criteria_json='{"version":1,"source":"approved-plan","objectives":["Keep review state bound to approved requirements."],"acceptance_criteria":["Changed criteria invalidate review authorization."],"verification_requirements":["Run tests/review-policy-test.sh."]}'
printf '%s\n' "$session_criteria_json" > "$session_criteria_file"
session_criteria_hash=$(dx_review_criteria_hash "$session_criteria_file")
dx_review_approve_criteria "$session_id" initial "$session_criteria_hash" >/dev/null
dx_review_write_selection "$session_id" normal lifecycle-agent bounded-production-change \
  "$REPO" "$policy_normal" "$session_criteria_hash" "$policy_binding"
[[ "$(cut -f1 "$(dx_review_selection_file "$session_id")")" == "5" ]] || {
  printf 'selection was not written with the criteria-bound schema\n' >&2
  exit 1
}
IFS=$'\t' read -r tier source reason selection_required fingerprint selection_binding \
  selection_policy < <(dx_review_read_selection "$session_id" "$REPO" \
    "$session_criteria_hash" "$policy_binding")
assert_eq "normal" "$tier" "selection tier"
assert_eq "lifecycle-agent" "$source" "selection source"
assert_eq "bounded-production-change" "$reason" "selection reason"
assert_eq "$policy_normal" "$selection_required" "selection requirement"
assert_eq "$base_fingerprint" "$fingerprint" "selection fingerprint"
assert_eq "$session_criteria_hash" "$selection_binding" "selection criteria binding"
assert_eq "$policy_binding" "$selection_policy" "selection policy binding"
assert_rejected "invented selection reason" dx_review_write_selection \
  "$session_id" normal lifecycle-agent invented-agent-rationale "$REPO" \
  "$policy_normal" "$session_criteria_hash" "$policy_binding"
assert_rejected "reserved reason with assessor source" dx_review_write_selection \
  "$session_id" normal lifecycle-agent operator-override "$REPO" \
  "$policy_normal" "$session_criteria_hash" "$policy_binding"
assert_rejected "selection tier contradicts reason" dx_review_write_selection \
  "$session_id" normal lifecycle-agent cross-module "$REPO" \
  "$policy_normal" "$session_criteria_hash" "$policy_binding"

standalone_session_id="review-policy-standalone"
dx_review_write_selection "$standalone_session_id" normal environment operator-override \
  "$REPO" "$policy_normal" standalone "$policy_binding"
IFS=$'\t' read -r _ _ _ _ _ standalone_binding standalone_policy < <(dx_review_read_selection \
  "$standalone_session_id" "$REPO" standalone "$policy_binding")
assert_eq "standalone" "$standalone_binding" "standalone selection binding"
assert_eq "$policy_binding" "$standalone_policy" "standalone selection policy"
printf '2\tnormal\tenvironment\toperator-override\t6\t%s\n' "$base_fingerprint" > "$(dx_review_selection_file "$standalone_session_id")"
assert_rejected "legacy unbound selection cannot grant current review credit" \
  dx_review_selection_valid "$standalone_session_id" "$REPO" standalone "$policy_binding"
printf '3\tnormal\tenvironment\toperator-override\t6\t%s\tstandalone\n' \
  "$base_fingerprint" > "$(dx_review_selection_file "$standalone_session_id")"
assert_rejected "legacy criteria-bound selection cannot grant current review credit" \
  dx_review_selection_valid "$standalone_session_id" "$REPO" standalone "$policy_binding"
dx_review_write_selection "$standalone_session_id" normal environment operator-override \
  "$REPO" "$policy_normal" standalone "$policy_binding"
printf '%s\n' "$session_criteria_json" > "$(dx_review_criteria_file "$standalone_session_id")"
assert_rejected "standalone selection rejects criteria state" \
  dx_review_selection_valid "$standalone_session_id" "$REPO" standalone "$policy_binding"
rm -f "$(dx_review_criteria_file "$standalone_session_id")"
printf '4\tnormal\tenvironment\toperator-override\t6\t%s\tstandalone\tSHORT\n' \
  "$base_fingerprint" > "$(dx_review_selection_file "$standalone_session_id")"
assert_rejected "selection rejects malformed policy binding" \
  dx_review_selection_valid "$standalone_session_id" "$REPO" standalone "$policy_binding"
dx_cleanup_session "$standalone_session_id"

dx_review_write_state "$session_id" normal "$policy_normal" 4 2 "$REPO" \
  "$session_criteria_hash" "$policy_binding"
[[ "$(cut -f1 "$(dx_review_state_file "$session_id")")" == "4" ]] || {
  printf 'state was not written with the current policy-bound schema\n' >&2
  exit 1
}
IFS=$'\t' read -r state_tier required iteration clean_count state_fingerprint state_binding \
  state_policy < <(dx_review_read_state "$session_id" "$REPO" \
    "$session_criteria_hash" "$policy_binding")
assert_eq "normal" "$state_tier" "state tier"
assert_eq "$policy_normal" "$required" "state requirement"
assert_eq "4" "$iteration" "state iteration"
assert_eq "2" "$clean_count" "state clean count"
assert_eq "$base_fingerprint" "$state_fingerprint" "state fingerprint"
assert_eq "$session_criteria_hash" "$state_binding" "state criteria binding"
assert_eq "$policy_binding" "$state_policy" "state policy binding"
printf '2\tnormal\t6\t4\t2\t%s\t%s\n' \
  "$base_fingerprint" "$session_criteria_hash" > "$(dx_review_state_file "$session_id")"
assert_rejected "legacy state cannot retain clean review credit" \
  dx_review_read_state "$session_id" "$REPO" "$session_criteria_hash" "$policy_binding"
dx_review_write_state "$session_id" normal "$policy_normal" 4 2 "$REPO" \
  "$session_criteria_hash" "$policy_binding"
assert_rejected "state below tier gate" dx_review_write_state \
  "$session_id" normal "$((policy_normal - 1))" 1 0 "$REPO" \
  "$session_criteria_hash" "$policy_binding"
assert_rejected "state clean exceeds iteration" dx_review_write_state \
  "$session_id" normal "$policy_normal" 1 2 "$REPO" \
  "$session_criteria_hash" "$policy_binding"
assert_rejected "completed state is not resumable" dx_review_write_state \
  "$session_id" normal "$policy_normal" "$policy_normal" "$policy_normal" "$REPO" \
  "$session_criteria_hash" "$policy_binding"

assert_rejected "small receipt below trusted policy gate" dx_review_write_receipt \
  "$session_id" small "$((policy_small - 1))" "$((policy_small - 1))" \
  "$REPO" "$session_criteria_hash" "$policy_binding"
assert_rejected "normal receipt below trusted policy gate" dx_review_write_receipt \
  "$session_id" normal "$((policy_normal - 1))" "$((policy_normal - 1))" \
  "$REPO" "$session_criteria_hash" "$policy_binding"
assert_rejected "complex receipt below trusted policy gate" dx_review_write_receipt \
  "$session_id" complex "$((policy_complex - 1))" "$((policy_complex - 1))" \
  "$REPO" "$session_criteria_hash" "$policy_binding"
assert_rejected "incomplete receipt" dx_review_write_receipt \
  "$session_id" normal "$policy_normal" "$((policy_normal - 1))" \
  "$REPO" "$session_criteria_hash" "$policy_binding"
append_clean_ledger "$session_id" "$policy_normal" "$base_fingerprint" \
  "$session_criteria_hash" "$policy_binding" clean standard
dx_review_ledger_valid "$session_id" "$policy_normal" "$base_fingerprint" \
  "$session_criteria_hash" "$policy_binding" standard
cp "$(dx_review_ledger_file "$session_id")" "$TMP_DIR/current-ledger"
printf '2\t1\tlegacy-clean\t%s\t0123456789abcdef\t%s\n' \
  "$base_fingerprint" "$session_criteria_hash" > "$(dx_review_ledger_file "$session_id")"
assert_rejected "legacy ledger cannot retain clean review credit" \
  dx_review_ledger_valid "$session_id" 1 "$base_fingerprint" \
  "$session_criteria_hash" "$policy_binding" standard
mv "$TMP_DIR/current-ledger" "$(dx_review_ledger_file "$session_id")"
dx_review_write_receipt "$session_id" normal "$policy_normal" "$policy_normal" \
  "$REPO" "$session_criteria_hash" "$policy_binding"
assert_rejected "active state blocks receipt" dx_review_receipt_valid \
  "$session_id" "$REPO" "$session_criteria_hash" "$policy_binding"
rm "$(dx_review_state_file "$session_id")"
dx_review_receipt_valid "$session_id" "$REPO" "$session_criteria_hash" "$policy_binding"

dx_review_ledger_reset "$session_id"
higher_gate=$((policy_normal + 2))
append_clean_ledger "$session_id" "$higher_gate" "$base_fingerprint" \
  "$session_criteria_hash" "$policy_binding" higher-clean standard
dx_review_write_receipt "$session_id" normal "$higher_gate" "$higher_gate" \
  "$REPO" "$session_criteria_hash" "$policy_binding"
IFS=$'\t' read -r receipt_tier receipt_required receipt_clean receipt_fingerprint \
  receipt_ledger_hash receipt_binding receipt_policy < <(dx_review_read_receipt \
    "$session_id" "$REPO" "$session_criteria_hash" "$policy_binding")
assert_eq "normal" "$receipt_tier" "higher-gate receipt tier"
assert_eq "$higher_gate" "$receipt_required" "higher-gate receipt requirement"
assert_eq "$higher_gate" "$receipt_clean" "higher-gate receipt clean count"
assert_eq "$base_fingerprint" "$receipt_fingerprint" "higher-gate receipt fingerprint"
[[ "$receipt_ledger_hash" =~ ^[a-f0-9]{64}$ ]] || assert_at $LINENO
assert_eq "$session_criteria_hash" "$receipt_binding" "receipt criteria binding"
assert_eq "$policy_binding" "$receipt_policy" "receipt policy binding"
assert_rejected "receipt gate must match selection" dx_review_receipt_valid \
  "$session_id" "$REPO" "$session_criteria_hash" "$policy_binding"
dx_review_write_selection "$session_id" normal lifecycle-agent bounded-production-change \
  "$REPO" "$higher_gate" "$session_criteria_hash" "$policy_binding"
dx_review_receipt_valid "$session_id" "$REPO" "$session_criteria_hash" "$policy_binding"
assert_eq "completed" "$(dx_review_receipt_outcome "$session_id" "$REPO" \
  "$session_criteria_hash" "$policy_binding")" "trusted review outcome"

# A lower target is valid only while its exact attributed override remains
# active. It authorizes fewer real CLEAN waves, but its lifecycle outcome is a
# waiver rather than a claim that the trusted tier policy passed.
dx_review_ledger_reset "$session_id"
dx_override_set "$session_id" review.clean-passes 2 phase 3 human \
  "The remaining provider capacity is limited; accept two clean waves" 0
dx_review_write_selection "$session_id" normal lifecycle-agent \
  bounded-production-change "$REPO" 2 "$session_criteria_hash" "$policy_binding"
dx_review_write_state "$session_id" normal 2 1 1 "$REPO" \
  "$session_criteria_hash" "$policy_binding"
dx_review_read_state "$session_id" "$REPO" "$session_criteria_hash" \
  "$policy_binding" >/dev/null
rm "$(dx_review_state_file "$session_id")"
append_clean_ledger "$session_id" 2 "$base_fingerprint" \
  "$session_criteria_hash" "$policy_binding" waived-clean standard
dx_review_write_receipt "$session_id" normal 2 2 "$REPO" \
  "$session_criteria_hash" "$policy_binding"
dx_review_receipt_valid "$session_id" "$REPO" "$session_criteria_hash" \
  "$policy_binding"
assert_eq "waived" "$(dx_review_receipt_outcome "$session_id" "$REPO" \
  "$session_criteria_hash" "$policy_binding")" "reduced review outcome"
dx_override_clear "$session_id" review.clean-passes phase 3 human \
  "Return to the trusted review policy"
assert_rejected "clearing reduced target invalidates selection" \
  dx_review_selection_valid "$session_id" "$REPO" "$session_criteria_hash" \
  "$policy_binding"
assert_rejected "clearing reduced target invalidates receipt" \
  dx_review_receipt_valid "$session_id" "$REPO" "$session_criteria_hash" \
  "$policy_binding"

printf '3\tnormal\t%s\t%s\t%s\t%s\t%s\n' \
  "$higher_gate" "$higher_gate" "$base_fingerprint" "$receipt_ledger_hash" \
  "$session_criteria_hash" > "$(dx_review_receipt_file "$session_id")"
assert_rejected "legacy receipt cannot retain clean review credit" dx_review_read_receipt \
  "$session_id" "$REPO" "$session_criteria_hash" "$policy_binding"
assert_rejected "legacy receipt cannot satisfy the clean-pass gate" dx_review_receipt_valid \
  "$session_id" "$REPO" "$session_criteria_hash" "$policy_binding"
printf '1\tnormal\t1\t1\t%s\n' "$base_fingerprint" > "$(dx_review_receipt_file "$session_id")"
assert_rejected "receipt reader rejects below trusted policy gate" dx_review_read_receipt \
  "$session_id" "$REPO" "$session_criteria_hash" "$policy_binding"
assert_rejected "receipt validator rejects below trusted policy gate" dx_review_receipt_valid \
  "$session_id" "$REPO" "$session_criteria_hash" "$policy_binding"
dx_review_write_selection "$session_id" normal lifecycle-agent bounded-production-change \
  "$REPO" "$policy_normal" "$session_criteria_hash" "$policy_binding"
dx_review_ledger_reset "$session_id"
append_clean_ledger "$session_id" "$policy_normal" "$base_fingerprint" \
  "$session_criteria_hash" "$policy_binding" final-clean standard
dx_review_write_receipt "$session_id" normal "$policy_normal" "$policy_normal" \
  "$REPO" "$session_criteria_hash" "$policy_binding"

printf '%s\n' '{"version":1,"source":"approved-plan","objectives":["Keep review state bound to changed requirements."],"acceptance_criteria":["Changed criteria invalidate review authorization."],"verification_requirements":["Run tests/review-policy-test.sh."]}' > "$session_criteria_file"
assert_rejected "criteria changes invalidate selection" dx_review_selection_valid \
  "$session_id" "$REPO" "$session_criteria_hash" "$policy_binding"
assert_rejected "criteria changes invalidate receipt" dx_review_receipt_valid \
  "$session_id" "$REPO" "$session_criteria_hash" "$policy_binding"
printf '%s\n' "$session_criteria_json" > "$session_criteria_file"
dx_review_selection_valid "$session_id" "$REPO" "$session_criteria_hash" "$policy_binding"
dx_review_receipt_valid "$session_id" "$REPO" "$session_criteria_hash" "$policy_binding"

printf 'external change\n' >> "$REPO/app.txt"
assert_rejected "stale selection" dx_review_selection_valid \
  "$session_id" "$REPO" "$session_criteria_hash" "$policy_binding"
assert_rejected "stale state" dx_review_read_state \
  "$session_id" "$REPO" "$session_criteria_hash" "$policy_binding"
assert_rejected "stale receipt" dx_review_receipt_valid \
  "$session_id" "$REPO" "$session_criteria_hash" "$policy_binding"
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

stale_credit_session="stale-review-credit"
stale_ledger=$(dx_review_ledger_file "$stale_credit_session")
stale_proof_dir=$(dx_review_proof_dir "$stale_credit_session")
mkdir -p "$stale_proof_dir/1"
printf '%s\n' "stale ledger fixture" > "$stale_ledger"
printf '%s\n' "stale proof fixture" > "$stale_proof_dir/1/evidence.json"
touch -t 202001010000 "$stale_ledger" "$stale_proof_dir"
assert_eq "1" "$(dx_cleanup_stale_review_credit 7)" "stale review credit cleanup count"
[[ ! -e "$stale_ledger" && ! -L "$stale_ledger" ]] || assert_at $LINENO
[[ ! -e "$stale_proof_dir" && ! -L "$stale_proof_dir" ]] || assert_at $LINENO

dx_cleanup_session "$session_id"
[[ ! -e "$(dx_review_selection_file "$session_id")" ]] || assert_at $LINENO
[[ ! -e "$(dx_review_state_file "$session_id")" ]] || assert_at $LINENO
[[ ! -e "$(dx_review_receipt_file "$session_id")" ]] || assert_at $LINENO
[[ ! -e "$(dx_review_criteria_file "$session_id")" ]] || assert_at $LINENO
[[ ! -e "$(dx_review_criteria_approval_file "$session_id")" ]] || assert_at $LINENO

printf 'review-policy-test passed\n'
