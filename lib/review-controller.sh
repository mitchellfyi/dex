# shellcheck shell=bash
# Pure review-loop transitions and controller-local state helpers.
# Source this file after lib/lock.sh and lib/review.sh.

# dx_review_transition <current-tier> <current-required> <current-clean>
#   <event-kind> <event-count> <event-reason> <scope-changed> <working-changed>
#   <candidate-tier> <candidate-required> <candidate-source>
#   <candidate-reason-codes> <churn-kind> <invalidate-authorization>
# Print one versioned TSV transition record without changing filesystem state.
# Fields after the version are action, next tier/requirement/clean count,
# terminal reason/detail, then ledger, findings, selection, state, and receipt operations.
dx_review_transition() {
  [[ $# -eq 14 ]] || return 1

  local current_tier="$1" current_required="$2" current_clean="$3"
  local event_kind="$4" event_count="$5" event_reason="$6"
  local scope_changed="$7" working_changed="$8" candidate_tier="$9"
  local candidate_required="${10}" candidate_source="${11}"
  local candidate_reasons="${12}" churn_kind="${13}"
  local invalidate_authorization="${14}"
  local current_rank candidate_rank=0 candidate_present=0
  local next_clean next_required selection_op state_op

  current_tier=$(dx_review_normalize_tier "$current_tier") || return 1
  dx_review_is_positive_integer "$current_required" || return 1
  dx_review_is_nonnegative_integer "$current_clean" || return 1
  dx_review_is_nonnegative_integer "$event_count" || return 1
  current_required=$((10#$current_required))
  current_clean=$((10#$current_clean))
  event_count=$((10#$event_count))
  [[ $current_clean -lt $current_required ]] || return 1

  case "$scope_changed:$working_changed:$invalidate_authorization" in
    true:true:true|true:true:false|true:false:true|true:false:false|false:true:true|false:true:false|false:false:true|false:false:false) ;;
    *) return 1 ;;
  esac
  case "$churn_kind" in
    none|repeated_fingerprint|alternating_fingerprints) ;;
    *) return 1 ;;
  esac

  if [[ "$candidate_tier" == "-" ]]; then
    [[ "$candidate_required" == "0" && "$candidate_source" == "-" && "$candidate_reasons" == "-" ]] || return 1
  else
    candidate_tier=$(dx_review_normalize_tier "$candidate_tier") || return 1
    dx_review_is_positive_integer "$candidate_required" || return 1
    candidate_required=$((10#$candidate_required))
    case "$candidate_source" in
      deterministic-floor|wave-escalation) ;;
      *) return 1 ;;
    esac
    dx_review_selection_reason_codes_valid \
      "$candidate_tier" "$candidate_source" "$candidate_reasons" || return 1
    candidate_present=1
    candidate_rank=$(dx_review_tier_rank "$candidate_tier") || return 1
  fi
  current_rank=$(dx_review_tier_rank "$current_tier") || return 1

  case "$event_kind" in
    clean)
      [[ $event_count -eq 0 && "$event_reason" == "none" && "$churn_kind" == "none" ]] || return 1
      [[ $candidate_present -eq 0 && "$invalidate_authorization" == "false" ]] || return 1
      if [[ "$scope_changed" == "true" ]]; then
        printf '1\tpause\t%s\t%s\t0\tclean_mutated_scope\t-\treset\tkeep\tinvalidate\tinvalidate\tinvalidate\n' \
          "$current_tier" "$current_required"
        return 0
      fi
      next_clean=$((current_clean + 1))
      if [[ $next_clean -eq $current_required ]]; then
        printf '1\tcomplete\t%s\t%s\t%s\tnone\t-\tappend\tkeep\tkeep\tinvalidate\tfinalize\n' \
          "$current_tier" "$current_required" "$next_clean"
      else
        printf '1\tcount\t%s\t%s\t%s\tnone\t-\tappend\tkeep\tkeep\twrite\tkeep\n' \
          "$current_tier" "$current_required" "$next_clean"
      fi
      ;;
    findings_fixed)
      [[ $event_count -gt 0 && "$event_reason" == "none" && "$invalidate_authorization" == "false" ]] || return 1
      if [[ $candidate_present -eq 1 && "$candidate_source" != "deterministic-floor" ]]; then
        return 1
      fi
      if [[ "$scope_changed" != "true" && "$working_changed" != "true" ]]; then
        selection_op="keep"
        state_op="write"
        if [[ "$scope_changed" == "true" ]]; then
          selection_op="invalidate"
          state_op="invalidate"
        fi
        printf '1\tpause\t%s\t%s\t0\tclaimed_fix_without_change\t-\treset\tkeep\t%s\t%s\tinvalidate\n' \
          "$current_tier" "$current_required" "$selection_op" "$state_op"
        return 0
      fi
      if [[ "$churn_kind" != "none" ]]; then
        printf '1\tpause\t%s\t%s\t0\t%s\t-\treset\tappend\tinvalidate\tinvalidate\tinvalidate\n' \
          "$current_tier" "$current_required" "$churn_kind"
        return 0
      fi
      if [[ $candidate_present -eq 1 && $candidate_rank -gt $current_rank ]]; then
        next_required="$current_required"
        [[ $candidate_required -gt $next_required ]] && next_required="$candidate_required"
        printf '1\tescalate_continue\t%s\t%s\t0\tnone\t-\treset\tappend\trefresh\twrite\tinvalidate\n' \
          "$candidate_tier" "$next_required"
      else
        printf '1\treset_continue\t%s\t%s\t0\tnone\t-\treset\tappend\trefresh\twrite\tinvalidate\n' \
          "$current_tier" "$current_required"
      fi
      ;;
    findings)
      [[ $event_count -gt 0 && "$event_reason" == "none" && "$churn_kind" == "none" ]] || return 1
      [[ $candidate_present -eq 0 && "$invalidate_authorization" == "false" ]] || return 1
      selection_op="keep"
      state_op="write"
      if [[ "$scope_changed" == "true" ]]; then
        selection_op="invalidate"
        state_op="invalidate"
      fi
      printf '1\tpause\t%s\t%s\t0\tunresolved_findings\t%s\treset\tkeep\t%s\t%s\tinvalidate\n' \
        "$current_tier" "$current_required" "$event_count" "$selection_op" "$state_op"
      ;;
    blocked|churn)
      [[ $event_count -eq 0 && "$event_reason" != "none" && "$churn_kind" == "none" ]] || return 1
      [[ $candidate_present -eq 0 && "$invalidate_authorization" == "false" ]] || return 1
      dx_review_reason_codes_valid "$event_reason" || return 1
      selection_op="keep"
      state_op="write"
      if [[ "$scope_changed" == "true" ]]; then
        selection_op="invalidate"
        state_op="invalidate"
      fi
      if [[ "$event_kind" == "blocked" ]]; then
        printf '1\tpause\t%s\t%s\t0\tblocked\t%s\treset\tkeep\t%s\t%s\tinvalidate\n' \
          "$current_tier" "$current_required" "$event_reason" "$selection_op" "$state_op"
      else
        printf '1\tpause\t%s\t%s\t0\twave_reported_churn\t%s\treset\tkeep\t%s\t%s\tinvalidate\n' \
          "$current_tier" "$current_required" "$event_reason" "$selection_op" "$state_op"
      fi
      ;;
    escalate)
      [[ $event_count -eq 0 && "$event_reason" != "none" && "$churn_kind" == "none" ]] || return 1
      [[ $candidate_present -eq 1 && "$candidate_source" == "wave-escalation" && "$invalidate_authorization" == "false" ]] || return 1
      dx_review_reason_codes_valid "$event_reason" || return 1
      if [[ "$scope_changed" == "true" ]]; then
        printf '1\tpause\t%s\t%s\t0\tescalation_mutated_scope\t%s\treset\tkeep\tinvalidate\tinvalidate\tinvalidate\n' \
          "$current_tier" "$current_required" "$candidate_tier"
      elif [[ $candidate_rank -le $current_rank ]]; then
        printf '1\tpause\t%s\t%s\t0\tinvalid_escalation\t%s\treset\tkeep\tkeep\twrite\tinvalidate\n' \
          "$current_tier" "$current_required" "$candidate_tier"
      else
        next_required="$current_required"
        [[ $candidate_required -gt $next_required ]] && next_required="$candidate_required"
        printf '1\tescalate_continue\t%s\t%s\t0\tnone\t-\treset\tkeep\trefresh\twrite\tinvalidate\n' \
          "$candidate_tier" "$next_required"
      fi
      ;;
    failure)
      [[ $event_count -eq 0 && "$event_reason" != "none" && "$churn_kind" == "none" ]] || return 1
      [[ $candidate_present -eq 0 ]] || return 1
      dx_review_reason_codes_valid "$event_reason" || return 1
      if [[ "$invalidate_authorization" == "true" || "$scope_changed" == "true" ]]; then
        selection_op="invalidate"
        state_op="invalidate"
      else
        selection_op="keep"
        state_op="write"
      fi
      printf '1\tpause\t%s\t%s\t0\t%s\t-\treset\tkeep\t%s\t%s\tinvalidate\n' \
        "$current_tier" "$current_required" "$event_reason" "$selection_op" "$state_op"
      ;;
    *)
      return 1
      ;;
  esac
}

# dx_review_findings_history_append <history-file> <findings-hash>
# Append a validated hash atomically and retain only the four newest entries.
dx_review_findings_history_append() {
  [[ $# -eq 2 ]] || return 1
  local history_file="$1" findings_hash="$2" tmp_file="" lock_dir owner="" append_status=1
  [[ -n "$history_file" && ${#findings_hash} -eq 16 && "$findings_hash" != *[!0-9a-f]* ]] || return 1
  [[ ! -e "$history_file" || -f "$history_file" ]] || return 1

  mkdir -p "$(dirname "$history_file")" || return 1
  lock_dir="${history_file}.lock"
  # Stale-lock takeover used to be an unserialized rm-then-recreate: two
  # waiters could both see a dead owner, and the second would remove the
  # first's fresh lock, letting both append and then reporting a successful
  # append as a failure. dx_lock_acquire serializes reclamation.
  owner="review-history-$$"
  dx_lock_acquire "$lock_dir" "$owner" || return 1

  if [[ ! -e "$history_file" || -f "$history_file" ]] && \
     { [[ ! -f "$history_file" ]] || LC_ALL=C awk '
         length($0) != 16 || $0 ~ /[^0-9a-f]/ { invalid = 1 }
         END { exit invalid }
       ' "$history_file"; }; then
    tmp_file=$(mktemp "${history_file}.tmp.XXXXXX" 2>/dev/null || true)
  fi
  if [[ -n "$tmp_file" && -f "$history_file" ]]; then
    if ! LC_ALL=C awk '
      { entries[NR % 3] = $0 }
      END {
        start = NR > 3 ? NR - 2 : 1
        for (i = start; i <= NR; i++) {
          print entries[i % 3]
        }
      }
    ' "$history_file" >| "$tmp_file"; then
      command rm -f "$tmp_file" 2>/dev/null || true
      tmp_file=""
    fi
  fi
  if [[ -n "$tmp_file" && ! -f "$history_file" ]] && ! : >| "$tmp_file"; then
    command rm -f "$tmp_file" 2>/dev/null || true
    tmp_file=""
  fi
  if [[ -n "$tmp_file" ]] && \
     printf '%s\n' "$findings_hash" >> "$tmp_file" && \
     command mv -f "$tmp_file" "$history_file"; then
    tmp_file=""
    append_status=0
  fi
  [[ -z "$tmp_file" ]] || command rm -f "$tmp_file" 2>/dev/null || true
  dx_lock_release "$lock_dir" "$owner" || append_status=1
  return "$append_status"
}
