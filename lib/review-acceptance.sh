# shellcheck shell=bash
# A wave remains recoverable until its parent checkpoint and receipt retirement finish.

dx_review_acceptance_dir() {
  dx_session_id_valid "${1:-}" || return 1
  printf '%s/%s.review-acceptance\n' "$DX_LOOP_DIR" "$1"
}

dx_review_acceptance_pending() {
  local acceptance_dir
  acceptance_dir=$(dx_review_acceptance_dir "$1") || return 1
  [[ -e "$acceptance_dir" || -L "$acceptance_dir" ]]
}

__dx_review_acceptance_store() {
  local operation="$1" session_id="$2"
  shift 2
  python3 "$DEX_DIR/scripts/review_acceptance.py" "$operation" "$DX_LOOP_DIR" "$session_id" "$@"
}

dx_review_acceptance_begin() {
  local session_id="$1"
  shift
  __dx_lifecycle_control_lock_owned "$session_id" || return 1
  __dx_review_acceptance_store begin "$session_id" "$@"
}

__dx_review_acceptance_retire_child() (
  # The subshell keeps the child's lock token separate from the parent's.
  local child="$1" generation="$2" expectation retire_rc=0
  dx_lifecycle_control_lock_acquire "$child" || return 1
  expectation=$(dx_completion_expectation_file "$child") || retire_rc=1
  if [[ "$retire_rc" -eq 0 ]]; then
    if [[ -e "$expectation" || -L "$expectation" ]]; then
      dx_completion_receipt_valid "$child" child review-pass 3 "$generation" || retire_rc=1
    fi
    if [[ "$retire_rc" -eq 0 ]]; then
      rm -f "$(dx_active_file "$child")" || retire_rc=1
      if [[ "$retire_rc" -eq 0 && -e "$expectation" ]]; then
        dx_completion_consume "$child" child review-pass 3 "$generation" || retire_rc=1
      fi
    fi
  fi
  dx_lifecycle_control_lock_release "$child" || retire_rc=1
  return "$retire_rc"
)

# Caller holds the parent control lock. The same function handles first
# acceptance and recovery; installing the sealed checkpoint never adds credit.
dx_review_acceptance_finish() {
  local session_id="$1" repo_dir="$2" expected_criteria="$3" expected_policy="$4"
  local acceptance_dir record descriptor recorded_repo committed_rc=0
  local accept_child accept_pass accept_generation accept_result accept_findings accept_profile
  local accept_tier accept_required accept_iteration accept_clean accept_total accept_scope
  local accept_working accept_criteria accept_policy accept_source accept_reasons
  local accept_ledger_op accept_findings_op accept_scope_before accept_branch accept_head
  local accept_pass_binding criteria_file="" stage_dir current_descriptor
  __dx_lifecycle_control_lock_owned "$session_id" || return 1
  acceptance_dir=$(dx_review_acceptance_dir "$session_id") || return 1
  record=$(__dx_review_acceptance_store read "$session_id" \
    child pass_id generation result findings profile tier required iteration clean total \
    scope working criteria policy source reasons ledger_op findings_op scope_before branch head) || return 1
  IFS=$'\t' read -r accept_child accept_pass accept_generation accept_result accept_findings accept_profile \
    accept_tier accept_required accept_iteration accept_clean accept_total accept_scope accept_working \
    accept_criteria accept_policy accept_source accept_reasons accept_ledger_op accept_findings_op \
    accept_scope_before accept_branch accept_head <<< "$record"
  descriptor=$(__dx_review_acceptance_store read "$session_id" descriptor) || return 1
  recorded_repo=$(__dx_review_acceptance_store read "$session_id" repo) || return 1
  [[ "$(cd "$repo_dir" && pwd -P)" == "$recorded_repo" \
    && "$expected_criteria" == "$accept_criteria" && "$expected_policy" == "$accept_policy" ]] || return 1
  [[ "$(dx_review_resolve_criteria_binding "$session_id" "$expected_criteria")" == "$accept_criteria" ]] || return 1
  current_descriptor=$(dx_review_scope_descriptor "$repo_dir") || return 1
  [[ "$(dx_review_scope_boundary "$current_descriptor")" == "$(dx_review_scope_boundary "$descriptor")" \
    && "$(dx_review_scope_fingerprint "$repo_dir" "$current_descriptor")" == "$accept_scope" \
    && "$(dx_review_working_fingerprint "$repo_dir")" == "$accept_working" \
    && "$(git -C "$repo_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || printf '%s\n' DETACHED)" == "$accept_branch" \
    && "$(git -C "$repo_dir" rev-parse --verify HEAD 2>/dev/null || printf '%s\n' UNBORN)" == "$accept_head" ]] || return 1
  [[ "$accept_criteria" == standalone ]] || criteria_file="$acceptance_dir/before/${session_id}.review-criteria.json"
  accept_pass_binding=$(dx_review_pass_binding "$accept_pass" "$accept_scope_before" "$accept_criteria" "$accept_policy") || return 1
  dx_review_evidence_valid "$acceptance_dir/evidence.json" "$accept_result" "$accept_profile" \
    "$accept_scope_before" "$accept_criteria" "$criteria_file" "$accept_pass" "$accept_policy" \
    "$acceptance_dir/context.md" || return 1
  dx_review_pass_attestation "$acceptance_dir/evidence.json" "$acceptance_dir/context.md" \
    "$accept_result" "$accept_profile" "$accept_findings" "$accept_pass_binding" >/dev/null || return 1
  (DX_LOOP_DIR="$acceptance_dir/authorization"
    dx_completion_receipt_valid "$accept_child" child review-pass 3 "$accept_generation"
  ) || return 1
  __dx_review_acceptance_store committed "$session_id" || committed_rc=$?
  [[ "$committed_rc" -eq 0 || "$committed_rc" -eq 3 ]] || return 1
  if [[ "$committed_rc" -eq 3 ]]; then
    dx_completion_receipt_valid "$accept_child" child review-pass 3 "$accept_generation" || return 1
    __dx_review_acceptance_store stage "$session_id" || return 1
    stage_dir="$acceptance_dir/stage"
    (
      DX_LOOP_DIR="$stage_dir"
      case "$accept_ledger_op" in
        reset) dx_review_ledger_reset "$session_id" || exit 1 ;;
        append)
          dx_review_ledger_append "$session_id" "$accept_iteration" "$accept_pass" "$accept_profile" \
            "$accept_scope" "$accept_criteria" "$accept_policy" \
            "$acceptance_dir/evidence.json" "$acceptance_dir/context.md" || exit 1 ;;
        *) exit 1 ;;
      esac
      case "$accept_findings_op" in
        append) dx_review_findings_history_append "$(dx_findings_file "$session_id")" "$accept_findings" || exit 1 ;;
        keep) ;;
        *) exit 1 ;;
      esac
      dx_review_write_selection "$session_id" "$accept_tier" "$accept_source" "$accept_reasons" \
        "$repo_dir" "$accept_required" "$accept_criteria" "$accept_policy" || exit 1
      dx_review_write_state "$session_id" "$accept_tier" "$accept_required" "$accept_iteration" \
        "$accept_clean" "$repo_dir" "$accept_criteria" "$accept_policy" "$accept_total" || exit 1
    ) || return 1
    __dx_review_acceptance_store seal "$session_id" || return 1
  fi
  __dx_review_acceptance_store validate "$session_id" || return 1
  (
    DX_LOOP_DIR="$acceptance_dir/stage"
    dx_review_read_state "$session_id" "$repo_dir" "$accept_criteria" "$accept_policy" >/dev/null || exit 1
    dx_review_selection_valid "$session_id" "$repo_dir" "$accept_criteria" "$accept_policy" || exit 1
    dx_review_ledger_valid "$session_id" "$accept_clean" "$accept_scope" "$accept_criteria" \
      "$accept_policy" "$(dx_review_tier_profile "$accept_tier")" || exit 1
  ) || return 1
  [[ -z "${review_interrupt_reason:-}" ]] || return 1
  current_descriptor=$(dx_review_scope_descriptor "$repo_dir") || return 1
  [[ "$(dx_review_scope_boundary "$current_descriptor")" == "$(dx_review_scope_boundary "$descriptor")" \
    && "$(dx_review_scope_fingerprint "$repo_dir" "$current_descriptor")" == "$accept_scope" \
    && "$(dx_review_working_fingerprint "$repo_dir")" == "$accept_working" \
    && "$(git -C "$repo_dir" symbolic-ref --quiet --short HEAD 2>/dev/null || printf '%s\n' DETACHED)" == "$accept_branch" \
    && "$(git -C "$repo_dir" rev-parse --verify HEAD 2>/dev/null || printf '%s\n' UNBORN)" == "$accept_head" ]] || return 1
  __dx_review_acceptance_store commit "$session_id" || return 1
  __dx_review_acceptance_store install "$session_id" || return 1
  __dx_review_acceptance_retire_child "$accept_child" "$accept_generation" || return 1
  dx_cleanup_session "$accept_child"
}
