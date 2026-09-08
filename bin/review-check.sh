#!/usr/bin/env bash
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

if [[ $# -ne 1 ]]; then
  dx_error "Usage: review-check.sh <check-spec.json>"
  exit 2
fi

check_session="${DEX_REVIEW_CHECK_CACHE_SESSION:-${DEX_SESSION_ID:-}}"
dx_session_id_valid "$check_session" || { dx_error "Review check needs a session ID"; exit 2; }
check_repo=$(git rev-parse --show-toplevel)
check_cache=$(dx_review_check_cache_dir "$check_session")
[[ ! -L "$check_cache" && (! -e "$check_cache" || -d "$check_cache") ]] || exit 2
mkdir -p "$check_cache"
chmod 700 "$check_cache"
check_token="check-$$-${RANDOM}"
check_helper="$DEX_DIR/scripts/review_checks.py"
check_limit=$(dx_review_check_capacity_limit) || {
  dx_error "Invalid check capacity; use DEX_REVIEW_MAX_ACTIVE_CHECKS=1..8"
  exit 2
}
check_timeout="${DEX_REVIEW_CHECK_TIMEOUT:-900}"
[[ "$check_timeout" =~ ^[1-9][0-9]*$ && ${#check_timeout} -le 6 ]] || exit 2
check_spec=$(mktemp "$check_cache/spec.XXXXXX")
# The shell owns this lease; the timeout supervisor owns the command tree.
check_capacity_root=$(dx_review_capacity_root)
export DX_REVIEW_CAPACITY_DIR="$check_capacity_root/checks"
check_cleanup() {
  dx_review_capacity_release "$check_token" 2>/dev/null || true
  command rm -f "$check_spec"
}
trap check_cleanup EXIT
trap 'exit 130' INT
trap 'exit 143' TERM
trap 'exit 129' HUP
# Snapshot the spec once so a changed file cannot switch the executed command.
__dx_review_regular_files_bounded 262144 "$1" || exit 2
cp "$1" "$check_spec"
check_description=$(python3 "$check_helper" describe "$check_spec")
IFS=$'\t' read -r check_name check_mode check_slot <<EOF
$check_description
EOF
check_receipt="$check_cache/$check_slot.json"
check_key() {
  local check_scope check_working
  if [[ "$check_mode" == never ]]; then
    printf '%s\n' never
    return 0
  fi
  check_scope=$(dx_review_scope_fingerprint "$check_repo") || return 1
  check_working=$(dx_review_working_fingerprint "$check_repo") || return 1
  python3 "$check_helper" key "$check_spec" "$check_scope" "$check_working" \
    "${DEX_REVIEW_CRITERIA_BINDING:-standalone}" "${DEX_REVIEW_POLICY_BINDING:-}"
}
check_before=$(check_key) || { dx_warn "Cannot establish reusable inputs; running $check_name without reuse"; check_before=never; }
if [[ "$check_before" != never ]] && check_saved=$(python3 "$check_helper" cached "$check_receipt" "$check_before"); then
  dx_ok "$check_name: reused passing check ($check_saved seconds saved)"
  exit 0
fi
check_queue_started=$(date +%s)
check_queue_expired() { [[ $(( $(date +%s) - check_queue_started )) -ge "$check_timeout" ]]; }
dx_info "$check_name: waiting for check capacity"
check_exit=0
dx_review_capacity_wait "$check_session" "$check_token" "$check_limit" check_queue_expired || check_exit=$?
if [[ "$check_exit" -ne 0 ]]; then
  dx_error "$check_name: check queue did not admit the command"
  [[ "$check_exit" -eq 125 ]] && exit 124
  exit "$check_exit"
fi
# Another wave may have completed this check while we were queued.
check_before=$(check_key) || check_before=never
if [[ "$check_before" != never ]] && check_saved=$(python3 "$check_helper" cached "$check_receipt" "$check_before"); then
  dx_ok "$check_name: reused passing check ($check_saved seconds saved)"
  exit 0
fi
dx_info "$check_name: running (queue $DX_REVIEW_CAPACITY_WAIT_SECONDS seconds)"
check_started=$(date +%s)
dx_run_with_timeout "$check_timeout" python3 "$check_helper" execute "$check_spec" || check_exit=$?
[[ "$check_exit" -eq 0 ]] || { dx_error "$check_name: failed ($check_exit); no reusable result"; exit "$check_exit"; }
check_duration=$(( $(date +%s) - check_started ))
check_after=$(check_key) || check_after=never
if [[ "$check_before" != never && "$check_before" == "$check_after" ]]; then
  python3 "$check_helper" record "$check_receipt" "$check_before" "$check_duration"
  dx_ok "$check_name: passed ($check_duration seconds; reusable for these inputs)"
else
  dx_ok "$check_name: passed ($check_duration seconds; not cached)"
fi
