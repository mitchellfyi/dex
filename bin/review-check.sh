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
# Three separate budgets, because they answer different questions. The
# execution budget is a reporting line: a command that finishes late is still
# the answer, and killing it at the budget is what taught agents to run the
# gate themselves instead. The hard ceiling is the only deadline that stops a
# command. Queue time is not the command's fault at all, so it has no deadline
# unless someone sets one.
check_timeout="${DEX_REVIEW_CHECK_TIMEOUT:-900}"
[[ "$check_timeout" =~ ^[1-9][0-9]*$ && ${#check_timeout} -le 6 ]] || exit 2
check_hard_timeout="${DEX_REVIEW_CHECK_HARD_TIMEOUT:-$((check_timeout * 4))}"
[[ "$check_hard_timeout" =~ ^[1-9][0-9]*$ && ${#check_hard_timeout} -le 7 ]] || exit 2
check_queue_timeout="${DEX_REVIEW_CHECK_QUEUE_TIMEOUT:-0}"
[[ "$check_queue_timeout" =~ ^[0-9]+$ && ${#check_queue_timeout} -le 6 ]] || exit 2
check_recheck_seconds="${DEX_REVIEW_CAPACITY_RECHECK_SECONDS:-1}"
[[ "$check_recheck_seconds" =~ ^[1-9][0-9]*$ && "$check_recheck_seconds" -le 60 ]] \
  || check_recheck_seconds=1
check_heartbeat_seconds="${DEX_REVIEW_CHECK_HEARTBEAT_SECONDS:-$((check_recheck_seconds * 30))}"
[[ "$check_heartbeat_seconds" =~ ^[1-9][0-9]{0,3}$ ]] \
  || check_heartbeat_seconds=$((check_recheck_seconds * 30))
check_spec=$(mktemp "$check_cache/spec.XXXXXX")
# The shell owns this lease; the timeout supervisor owns the command tree.
check_capacity_root=$(dx_review_capacity_root)
# Pin the pool base before shadowing the capacity directory: the pool helpers
# resolve `checks` under the base, so without this they would look for the
# checks pool inside the checks pool. Deliberately not exported — the command's
# environment is part of its reuse key.
# shellcheck disable=SC2034  # read by the pool helpers through dynamic scope
DX_CAPACITY_POOL_BASE="$check_capacity_root"
export DX_REVIEW_CAPACITY_DIR="$check_capacity_root/checks"
check_notice_pid=""
check_notice_stop() {
  [[ -n "$check_notice_pid" ]] || return 0
  kill "$check_notice_pid" 2>/dev/null || true
  wait "$check_notice_pid" 2>/dev/null || true
  check_notice_pid=""
}
check_cleanup() {
  check_notice_stop
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
check_queue_capped=0
check_heartbeat_last=0
# Passed where dx_review_capacity_wait takes a cancel callback. It says where
# the queue stands on the way past, so waiting is legible to whoever is reading
# the transcript, and it returns 1 — keep waiting — unless a queue cap is set
# and spent.
check_queue_tick() {
  local queue_now queue_ahead queue_oldest
  queue_now=$(date +%s)
  if [[ $((queue_now - check_heartbeat_last)) -ge "$check_heartbeat_seconds" ]]; then
    check_heartbeat_last="$queue_now"
    IFS=$'\t' read -r queue_ahead queue_oldest <<EOF
$(dx_capacity_pool_queue_status checks "$check_token" 2>/dev/null || printf '?\t-\n')
EOF
    if [[ "$queue_oldest" == "-" ]]; then
      dx_info "$check_name: queued behind $queue_ahead, nothing running yet"
    else
      dx_info "$check_name: queued behind $queue_ahead, oldest started $(dx_format_duration "$queue_oldest") ago"
    fi
  fi
  [[ "$check_queue_timeout" -gt 0 ]] || return 1
  [[ $((queue_now - check_queue_started)) -ge "$check_queue_timeout" ]] || return 1
  check_queue_capped=1
}
dx_info "$check_name: waiting for check capacity"
check_exit=0
dx_review_capacity_wait "$check_session" "$check_token" "$check_limit" check_queue_tick || check_exit=$?
if [[ "$check_exit" -ne 0 ]]; then
  if [[ "$check_queue_capped" -eq 1 ]]; then
    # Not 124: nothing ran, so this is not a verdict on the command. The caller
    # can do lighter work and ask again, and the answer is still unknown.
    dx_warn "$check_name: queued — the check pool did not admit it within ${check_queue_timeout}s (DEX_REVIEW_CHECK_QUEUE_TIMEOUT); nothing ran"
    exit 75
  fi
  dx_error "$check_name: check queue did not admit the command"
  exit "$check_exit"
fi
# Another wave may have completed this check while we were queued.
check_before=$(check_key) || check_before=never
if [[ "$check_before" != never ]] && check_saved=$(python3 "$check_helper" cached "$check_receipt" "$check_before"); then
  dx_ok "$check_name: reused passing check ($check_saved seconds saved)"
  exit 0
fi
dx_info "$check_name: running (queue $DX_REVIEW_CAPACITY_WAIT_SECONDS seconds, execution budget $check_timeout seconds)"
# Stamp the lease so the age another waiter reads is how long this command has
# been running, not how long its owner has been in the pool.
dx_capacity_pool_mark_started checks "$check_token" 2>/dev/null || true
check_started=$(date +%s)
# One line at the moment the command outlives its budget, so a long wait is
# visible while it happens rather than only in the result. Short sleeps: this
# is stopped as soon as the command returns, and a chunk is the longest it can
# outlive it by.
check_budget_notice() {
  local notice_start="$SECONDS" notice_left
  while :; do
    notice_left=$(( check_timeout - (SECONDS - notice_start) ))
    [[ "$notice_left" -gt 0 ]] || break
    [[ "$notice_left" -le 5 ]] || notice_left=5
    dx_pause "$notice_left"
  done
  dx_warn "$check_name: over-budget — past its ${check_timeout} second execution budget and still running; the real result will be recorded (hard ceiling ${check_hard_timeout} seconds)"
}
check_budget_notice &
check_notice_pid=$!
dx_run_with_timeout "$check_hard_timeout" python3 "$check_helper" execute "$check_spec" || check_exit=$?
check_duration=$(( $(date +%s) - check_started ))
check_notice_stop
check_over_budget=""
[[ "$check_duration" -le "$check_timeout" ]] || check_over_budget=", over-budget"
if [[ "$check_exit" -ne 0 ]]; then
  if [[ "$check_exit" -eq 124 ]]; then
    dx_error "$check_name: stopped at the ${check_hard_timeout} second hard ceiling after $check_duration seconds; no reusable result"
  else
    dx_error "$check_name: failed ($check_exit) after $check_duration seconds$check_over_budget; no reusable result"
  fi
  exit "$check_exit"
fi
check_after=$(check_key) || check_after=never
if [[ "$check_before" != never && "$check_before" == "$check_after" ]]; then
  python3 "$check_helper" record "$check_receipt" "$check_before" "$check_duration"
  dx_ok "$check_name: passed ($check_duration seconds$check_over_budget; reusable for these inputs)"
else
  dx_ok "$check_name: passed ($check_duration seconds$check_over_budget; not cached)"
fi
