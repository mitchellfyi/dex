# shellcheck shell=bash
# Host-wide review admission. Review waves share CPU, memory, provider quotas,
# and test-runner capacity even when their checkouts are isolated worktrees.

dx_review_capacity_root() {
  printf '%s\n' "${DX_REVIEW_CAPACITY_DIR:-$DX_LOOP_DIR/review-capacity}"
}

__dx_review_capacity_token_valid() {
  local owner_token="${1:-}"
  [[ -n "$owner_token" && ${#owner_token} -le 96 \
    && "$owner_token" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

__dx_review_capacity_prepare_root() {
  local capacity_root="$1" format_file
  [[ -n "$capacity_root" && ! -L "$capacity_root" ]] || return 1
  if [[ -e "$capacity_root" && ! -d "$capacity_root" ]]; then
    return 1
  fi
  mkdir -p "$capacity_root" || return 1
  chmod 700 "$capacity_root" || return 1
  [[ "$(dx_path_mode "$capacity_root" 2>/dev/null || true)" == "700" ]] \
    || return 1
  format_file="$capacity_root/format"
  if [[ ! -e "$format_file" && ! -L "$format_file" ]]; then
    dx_review_write_atomic "$format_file" "1" || return 1
  fi
  [[ -f "$format_file" && ! -L "$format_file" \
    && "$(__dx_review_read_private_record "$format_file" 16 \
      2>/dev/null || true)" == "1" ]]
}

__dx_review_host_cpu_count() {
  local cpu_count=""
  cpu_count=$(getconf _NPROCESSORS_ONLN 2>/dev/null \
    || sysctl -n hw.ncpu 2>/dev/null || true)
  [[ "$cpu_count" =~ ^[1-9][0-9]*$ ]] || cpu_count=1
  printf '%s\n' "$cpu_count"
}

__dx_review_host_memory_mebibytes() {
  local memory_bytes="" memory_mebibytes=""
  memory_bytes=$(sysctl -n hw.memsize 2>/dev/null || true)
  if [[ "$memory_bytes" =~ ^[1-9][0-9]*$ ]]; then
    printf '%s\n' "$((memory_bytes / 1024 / 1024))"
    return 0
  fi
  if [[ -r /proc/meminfo ]]; then
    memory_mebibytes=$(awk '/^MemTotal:/ { print int($2 / 1024); exit }' \
      /proc/meminfo 2>/dev/null || true)
  fi
  [[ "$memory_mebibytes" =~ ^[1-9][0-9]*$ ]] || return 1
  printf '%s\n' "$memory_mebibytes"
}

# dx_review_capacity_limit
# One wave is conservative enough for common 8-core/32-GiB developer hosts.
# Larger workers may run two; operators can set an explicit limit from 1 to 8.
dx_review_capacity_limit() {
  local configured_limit="${DEX_REVIEW_MAX_ACTIVE_WAVES:-}"
  local cpu_count memory_mebibytes=""
  if [[ -n "$configured_limit" ]]; then
    [[ "$configured_limit" =~ ^[1-8]$ ]] || return 1
    printf '%s\n' "$configured_limit"
    return 0
  fi
  cpu_count=$(__dx_review_host_cpu_count) || return 1
  memory_mebibytes=$(__dx_review_host_memory_mebibytes 2>/dev/null || true)
  if [[ "$cpu_count" -ge 16 && "$memory_mebibytes" =~ ^[0-9]+$ \
    && "$memory_mebibytes" -ge 49152 ]]; then
    printf '%s\n' "2"
  else
    printf '%s\n' "1"
  fi
}

__dx_review_capacity_record() {
  local record_file="$1" raw sequence owner_pid process_identity session_id
  local recorded_token extra
  [[ -f "$record_file" && ! -L "$record_file" ]] || return 2
  raw=$(__dx_review_read_private_record "$record_file" 1024 2>/dev/null) || return 2
  [[ "$raw" != *$'\n'* && "$raw" != *$'\r'* ]] || return 2
  IFS=$'\t' read -r sequence owner_pid process_identity session_id \
    recorded_token extra <<EOF
$raw
EOF
  [[ -z "$extra" && "$sequence" =~ ^[1-9][0-9]*$ \
    && "$owner_pid" =~ ^[1-9][0-9]*$ ]] || return 2
  dx_session_id_valid "$session_id" || return 2
  __dx_review_capacity_token_valid "$recorded_token" || return 2
  case "$process_identity" in
    linux:*|darwin:*) ;;
    *) return 2 ;;
  esac
  printf '%s\t%s\t%s\t%s\t%s\n' \
    "$sequence" "$owner_pid" "$process_identity" "$session_id" \
    "$recorded_token"
}

__dx_review_capacity_prune_locked() {
  local capacity_root="$1" record_file record record_state records=""
  local sequence owner_pid process_identity session_id recorded_token
  local probed_states="" combined_records=""
  local probe_arguments=()
  for record_file in "$capacity_root"/*; do
    case "${record_file##*/}" in
      wait-*|lease-*) ;;
      *) continue ;;
    esac
    record=$(__dx_review_capacity_record "$record_file") || return 2
    IFS=$'\t' read -r sequence owner_pid process_identity session_id \
      recorded_token <<EOF
$record
EOF
    records="${records}${record_file}"$'\t'"${record}"$'\n'
    probe_arguments+=("$owner_pid" "$process_identity")
  done
  [[ ${#probe_arguments[@]} -gt 0 ]] || return 0
  probed_states=$(dx_session_runtime_process_states \
    "${probe_arguments[@]}" 2>/dev/null) || return 2
  combined_records=$(paste -d $'\t' \
    <(printf '%s' "$records") <(printf '%s\n' "$probed_states")) \
    || return 2
  while IFS=$'\t' read -r record_file sequence owner_pid process_identity \
      session_id recorded_token record_state; do
    [[ -n "$record_file" && -n "$record_state" ]] || return 2
    case "$record_state" in
      live|unverifiable) ;;
      dead|replaced) command rm -f "$record_file" || return 2 ;;
      *) return 2 ;;
    esac
  done <<EOF
$combined_records
EOF
}

__dx_review_capacity_sequence_locked() {
  local capacity_root="$1" sequence_file="$1/sequence" sequence=0
  if [[ -e "$sequence_file" || -L "$sequence_file" ]]; then
    sequence=$(__dx_review_read_private_record "$sequence_file" 64 \
      2>/dev/null) || return 1
    [[ "$sequence" != *$'\n'* && "$sequence" != *$'\r'* \
      && "$sequence" =~ ^[0-9]+$ && ${#sequence} -le 18 ]] || return 1
  fi
  sequence=$((10#$sequence + 1))
  dx_review_write_atomic "$sequence_file" "$sequence" || return 1
  printf '%s\n' "$sequence"
}

__dx_review_capacity_enqueue_locked() {
  local capacity_root="$1" session_id="$2" owner_token="$3"
  local owner_pid="$4" process_identity="$5" wait_file lease_file record
  local sequence recorded_pid recorded_identity recorded_session recorded_token
  local record_content
  __dx_review_capacity_prune_locked "$capacity_root" || return 2
  wait_file="$capacity_root/wait-$owner_token"
  lease_file="$capacity_root/lease-$owner_token"
  for record in "$wait_file" "$lease_file"; do
    [[ -e "$record" || -L "$record" ]] || continue
    record=$(__dx_review_capacity_record "$record") || return 2
    IFS=$'\t' read -r sequence recorded_pid recorded_identity recorded_session \
      recorded_token <<EOF
$record
EOF
    [[ "$recorded_pid" == "$owner_pid" \
      && "$recorded_identity" == "$process_identity" \
      && "$recorded_session" == "$session_id" \
      && "$recorded_token" == "$owner_token" ]] || return 2
    return 0
  done
  sequence=$(__dx_review_capacity_sequence_locked "$capacity_root") || return 2
  record_content="${sequence}"$'\t'"${owner_pid}"$'\t'"${process_identity}"$'\t'"${session_id}"$'\t'"${owner_token}"
  dx_review_write_atomic "$wait_file" "$record_content"
}

# dx_review_capacity_enqueue <session-id> <owner-token>
dx_review_capacity_enqueue() {
  [[ $# -eq 2 ]] || return 2
  local session_id="$1" owner_token="$2" capacity_root mutation_token
  local owner_pid process_identity
  dx_session_id_valid "$session_id" || return 2
  __dx_review_capacity_token_valid "$owner_token" || return 2
  capacity_root=$(dx_review_capacity_root) || return 2
  __dx_review_capacity_prepare_root "$capacity_root" || return 2
  dx_lock_self_pid_var
  owner_pid="$DX_LOCK_SELF_PID"
  process_identity=$(dx_session_runtime_process_identity "$owner_pid" \
    2>/dev/null) || return 2
  mutation_token="enqueue-${owner_token}"
  dx_lock_with "${capacity_root}.mutation" "$mutation_token" 30 \
    __dx_review_capacity_enqueue_locked "$capacity_root" "$session_id" \
    "$owner_token" "$owner_pid" "$process_identity"
}

__dx_review_capacity_try_acquire_locked() {
  local capacity_root="$1" session_id="$2" owner_token="$3" limit="$4"
  local wait_file="$1/wait-$3" lease_file="$1/lease-$3"
  local record_file record sequence owner_pid process_identity recorded_session
  local recorded_token active_count=0 oldest_sequence=""
  __dx_review_capacity_prune_locked "$capacity_root" || return 2
  if [[ -e "$lease_file" || -L "$lease_file" ]]; then
    record=$(__dx_review_capacity_record "$lease_file") || return 2
    IFS=$'\t' read -r sequence owner_pid process_identity recorded_session \
      recorded_token <<EOF
$record
EOF
    [[ "$recorded_session" == "$session_id" \
      && "$recorded_token" == "$owner_token" ]] || return 2
    return 0
  fi
  [[ -f "$wait_file" && ! -L "$wait_file" ]] || return 2
  record=$(__dx_review_capacity_record "$wait_file") || return 2
  IFS=$'\t' read -r sequence owner_pid process_identity recorded_session \
    recorded_token <<EOF
$record
EOF
  [[ "$recorded_session" == "$session_id" \
    && "$recorded_token" == "$owner_token" ]] || return 2

  for record_file in "$capacity_root"/*; do
    [[ "${record_file##*/}" == lease-* ]] || continue
    active_count=$((active_count + 1))
  done
  [[ "$active_count" -lt "$limit" ]] || return 1
  for record_file in "$capacity_root"/*; do
    [[ "${record_file##*/}" == wait-* ]] || continue
    record=$(__dx_review_capacity_record "$record_file") || return 2
    record="${record%%$'\t'*}"
    if [[ -z "$oldest_sequence" || "$record" -lt "$oldest_sequence" ]]; then
      oldest_sequence="$record"
    fi
  done
  [[ "$sequence" == "$oldest_sequence" ]] || return 1
  command mv "$wait_file" "$lease_file" || return 2
}

# dx_review_capacity_try_acquire <session-id> <owner-token> <limit>
# Returns 0 when leased, 1 while queued behind another owner, and 2 for unsafe
# or malformed capacity state.
dx_review_capacity_try_acquire() {
  [[ $# -eq 3 ]] || return 2
  local session_id="$1" owner_token="$2" limit="$3" capacity_root
  local mutation_token
  dx_session_id_valid "$session_id" || return 2
  __dx_review_capacity_token_valid "$owner_token" || return 2
  [[ "$limit" =~ ^[1-8]$ ]] || return 2
  capacity_root=$(dx_review_capacity_root) || return 2
  __dx_review_capacity_prepare_root "$capacity_root" || return 2
  mutation_token="claim-${owner_token}"
  dx_lock_with "${capacity_root}.mutation" "$mutation_token" 30 \
    __dx_review_capacity_try_acquire_locked "$capacity_root" "$session_id" \
    "$owner_token" "$limit"
}

__dx_review_capacity_remove_locked() {
  local capacity_root="$1" owner_token="$2" record_file record sequence
  local owner_pid process_identity session_id recorded_token
  local caller_pid caller_identity
  dx_lock_self_pid_var
  caller_pid="$DX_LOCK_SELF_PID"
  caller_identity=$(dx_session_runtime_process_identity "$caller_pid" \
    2>/dev/null) || return 2
  for record_file in "$capacity_root/wait-$owner_token" \
    "$capacity_root/lease-$owner_token"; do
    [[ -e "$record_file" || -L "$record_file" ]] || continue
    record=$(__dx_review_capacity_record "$record_file") || return 2
    IFS=$'\t' read -r sequence owner_pid process_identity session_id \
      recorded_token <<EOF
$record
EOF
    [[ "$owner_pid" == "$caller_pid" \
      && "$process_identity" == "$caller_identity" \
      && "$recorded_token" == "$owner_token" ]] || return 2
    command rm -f "$record_file" || return 2
  done
}

dx_review_capacity_cancel() {
  [[ $# -eq 1 ]] || return 2
  local owner_token="$1" capacity_root mutation_token
  __dx_review_capacity_token_valid "$owner_token" || return 2
  capacity_root=$(dx_review_capacity_root) || return 2
  __dx_review_capacity_prepare_root "$capacity_root" || return 2
  mutation_token="cancel-${owner_token}"
  dx_lock_with "${capacity_root}.mutation" "$mutation_token" 30 \
    __dx_review_capacity_remove_locked "$capacity_root" "$owner_token"
}

dx_review_capacity_release() {
  dx_review_capacity_cancel "$@"
}

__dx_review_capacity_active_count_locked() {
  local capacity_root="$1" record_file active_count=0
  __dx_review_capacity_prune_locked "$capacity_root" || return 2
  for record_file in "$capacity_root"/*; do
    [[ "${record_file##*/}" == lease-* ]] || continue
    active_count=$((active_count + 1))
  done
  printf '%s\n' "$active_count"
}

dx_review_capacity_active_count() {
  local capacity_root mutation_token
  capacity_root=$(dx_review_capacity_root) || return 2
  __dx_review_capacity_prepare_root "$capacity_root" || return 2
  mutation_token="count-$(date +%s)-${RANDOM}"
  dx_lock_with "${capacity_root}.mutation" "$mutation_token" 30 \
    __dx_review_capacity_active_count_locked "$capacity_root"
}

# dx_review_capacity_wait <session-id> <owner-token> <limit> [cancel-callback]
# The callback returns success when the caller should leave the queue.
dx_review_capacity_wait() {
  [[ $# -ge 3 && $# -le 4 ]] || return 2
  local session_id="$1" owner_token="$2" limit="$3"
  local cancel_callback="${4:-}" recheck_seconds start_epoch claim_result
  recheck_seconds="${DX_REVIEW_CAPACITY_RECHECK_SECONDS:-1}"
  [[ "$recheck_seconds" =~ ^[1-9][0-9]*$ \
    && "$recheck_seconds" -le 60 ]] || return 2
  if [[ -n "$cancel_callback" ]]; then
    command -v "$cancel_callback" >/dev/null 2>&1 || return 2
  fi
  dx_review_capacity_enqueue "$session_id" "$owner_token" || return 2
  start_epoch=$(date +%s)
  while :; do
    claim_result=0
    dx_review_capacity_try_acquire "$session_id" "$owner_token" "$limit" \
      || claim_result=$?
    case "$claim_result" in
      0)
        # shellcheck disable=SC2034  # caller reads these dynamic-scope outputs
        DX_REVIEW_CAPACITY_WAIT_SECONDS=$(( $(date +%s) - start_epoch ))
        # shellcheck disable=SC2034  # caller reads these dynamic-scope outputs
        DX_REVIEW_CAPACITY_ACTIVE=$(dx_review_capacity_active_count \
          2>/dev/null || printf '%s\n' "1")
        return 0
        ;;
      1) ;;
      *)
        dx_review_capacity_cancel "$owner_token" 2>/dev/null || true
        return 2
        ;;
    esac
    if [[ -n "$cancel_callback" ]] && "$cancel_callback"; then
      dx_review_capacity_cancel "$owner_token" 2>/dev/null || true
      return 125
    fi
    sleep "$recheck_seconds"
  done
}
