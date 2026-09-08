#!/usr/bin/env bash
set -euo pipefail
umask 077
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"
if [[ $# -ne 2 ]]; then
  dx_error "Usage: review-result.sh <report.json> <authorized-generation>"
  exit 2
fi
report_session="${DEX_SESSION_ID:-}"
dx_session_id_valid "$report_session" || exit 2
report_generation="$2"
[[ "$report_generation" =~ ^[a-f0-9]{32}$ ]] || exit 2
report_scratch="$DX_LOOP_DIR/$report_session.review-report"
mkdir "$report_scratch"
report_cleanup() {
  command rm -f "$report_scratch/context" "$report_scratch/evidence" \
    "$report_scratch/findings" "$report_scratch/result"
  rmdir "$report_scratch"
}
trap report_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
report_publish() {
  local hashes pass_binding result target source_name
  [[ "$(dx_completion_current_generation "$report_session" child review-pass 3)" == "$report_generation" ]] || return 1
  # Never replace artifacts underneath a live completion receipt.
  if dx_completion_receipt_present "$report_session"; then
    dx_error "This review generation already has a completion receipt"
    return 1
  fi
  hashes=$(dx_review_criteria_coverage_json "${DEX_REVIEW_CRITERIA_BINDING:-}" "${DEX_REVIEW_CRITERIA_FILE:-}") || return 1
  pass_binding=$(dx_review_pass_binding "${DEX_REVIEW_PASS_ID:-}" "${DEX_REVIEW_SCOPE_FINGERPRINT:-}" \
    "${DEX_REVIEW_CRITERIA_BINDING:-}" "${DEX_REVIEW_POLICY_BINDING:-}") || return 1
  [[ "$pass_binding" == "${DEX_REVIEW_PASS_BINDING:-}" ]] || return 1
  python3 "$DEX_DIR/scripts/review_report.py" "$1" "$report_scratch" "$hashes" \
    "$DEX_REVIEW_SCOPE_FINGERPRINT" "$DEX_REVIEW_CRITERIA_BINDING" \
    "$DEX_REVIEW_POLICY_BINDING" "$pass_binding" || return 1
  result=$(cat "$report_scratch/result") || return 1
  dx_review_result_valid "$result" || return 1
  dx_review_evidence_valid "$report_scratch/evidence" "$result" "${DEX_REVIEW_PROFILE:-}" \
    "$DEX_REVIEW_SCOPE_FINGERPRINT" "$DEX_REVIEW_CRITERIA_BINDING" "${DEX_REVIEW_CRITERIA_FILE:-}" \
    "$DEX_REVIEW_PASS_ID" "$DEX_REVIEW_POLICY_BINDING" "$report_scratch/context" || {
      dx_error "Review report failed the existing evidence gate; no artifacts published"
      return 1
    }
  dx_review_findings_hash_valid "$report_scratch/findings" || return 1
  for source_name in context evidence findings result; do
    case "$source_name" in
      context) target=$(dx_review_context_file "$report_session") ;;
      evidence) target=$(dx_review_evidence_file "$report_session") ;;
      findings) target=$(dx_findings_file "$report_session") ;;
      result) target=$(dx_review_result_file "$report_session") ;;
    esac
    [[ ! -L "$target" && (! -e "$target" || -f "$target") ]] || return 1
    command mv -f "$report_scratch/$source_name" "$target" || return 1
  done
  dx_completion_write_receipt "$report_session" "$report_generation" || return 1
  dx_ok "Review report validated and published: $result"
}
dx_lock_with "$DX_LOOP_DIR/$report_session.review-publish-lock" "publish-$$-$RANDOM" 30 report_publish "$1"
