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

# dx_review_capacity_limit
# Independent review waves this host admits at once. Derived the way
# dx_host_heavy_limit is — max(1, min(cpus / 4, mem_gb / 8)), clamped to 8 —
# because a wave is a provider session plus its checks and targeted tests,
# about the footprint of one project gate. DEX_REVIEW_MAX_ACTIVE_WAVES (1..8)
# replaces the calculation. Heavy checks keep their separate budget, and scout
# parallelism and test jobs remain bounded per wave.
dx_review_capacity_limit() {
  local configured_limit="${DEX_REVIEW_MAX_ACTIVE_WAVES:-}" cpu_count mem_gb
  local by_cpu by_memory wave_limit
  if [[ -n "$configured_limit" ]]; then
    [[ "$configured_limit" =~ ^[1-8]$ ]] || return 1
    printf '%s\n' "$configured_limit"
    return 0
  fi
  cpu_count=$(dx_host_cpu_count)
  mem_gb=$(dx_host_memory_total_gb 2>/dev/null) \
    || mem_gb="$DX_HOST_FALLBACK_MEM_GB"
  by_cpu=$((cpu_count / 4))
  by_memory=$((mem_gb / 8))
  wave_limit="$by_cpu"
  [[ "$by_memory" -lt "$wave_limit" ]] && wave_limit="$by_memory"
  [[ "$wave_limit" -ge 1 ]] || wave_limit=1
  [[ "$wave_limit" -le 8 ]] || wave_limit=8
  printf '%s\n' "$wave_limit"
}

dx_review_check_capacity_limit() {
  local check_limit="${DEX_REVIEW_MAX_ACTIVE_CHECKS:-1}"
  [[ "$check_limit" =~ ^[1-8]$ ]] || return 1
  printf '%s\n' "$check_limit"
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
# DX_REVIEW_CAPACITY_SUBJECT names what is waiting in the one message this
# prints, so a pool other than `waves` does not report itself as a review wave.
dx_review_capacity_wait() {
  [[ $# -ge 3 && $# -le 4 ]] || return 2
  local session_id="$1" owner_token="$2" limit="$3"
  local subject="${DX_REVIEW_CAPACITY_SUBJECT:-review wave}"
  local cancel_callback="${4:-}" recheck_seconds start_epoch claim_result
  recheck_seconds="${DX_REVIEW_CAPACITY_RECHECK_SECONDS:-1}"
  [[ "$recheck_seconds" =~ ^[1-9][0-9]*$ \
    && "$recheck_seconds" -le 60 ]] || return 2
  if [[ -n "$cancel_callback" ]]; then
    command -v "$cancel_callback" >/dev/null 2>&1 || return 2
  fi
  dx_review_capacity_enqueue "$session_id" "$owner_token" || return 2
  start_epoch=$(date +%s)
  local memory_notice=0 active_now=0
  while :; do
    claim_result=0
    # A wave that would join others already running waits for host memory
    # to recover first. The first wave is always admitted, so a host that
    # cannot report memory, or one that is simply busy, still makes progress.
    active_now=$(dx_review_capacity_active_count 2>/dev/null \
      || printf '%s\n' "0")
    if [[ "$active_now" =~ ^[1-9][0-9]*$ ]] && dx_host_memory_low; then
      if [[ "$memory_notice" -eq 0 ]]; then
        dx_info "Host memory is below ${DEX_MIN_FREE_MEMORY_PERCENT:-10}% free; holding this ${subject} until it recovers"
        memory_notice=1
      fi
      claim_result=1
    else
      dx_review_capacity_try_acquire "$session_id" "$owner_token" "$limit" \
        || claim_result=$?
    fi
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

# ─── Named capacity pools ───────────────────────────────────────────────────
#
# Review waves were the first host-wide admission problem, so the FIFO lease
# above is written in their vocabulary. The mechanics are not review-specific:
# anything that competes for the whole machine wants the same queue, the same
# PID-reuse-safe stale-owner recovery, and the same refusal to over-admit.
#
# Three pools share it. `waves` is the original one and keeps the original
# directory, so every existing caller, every environment override and every
# existing test mean exactly what they meant before. `checks` is the
# deterministic check runner's, scoped the way bin/review-check.sh has scoped
# it since it was added. `heavy` is new: project gates, test suites and builds,
# in any phase, from any skill — the work that actually takes the host down
# when several sessions do it at once. A dev server is not in it: it starts
# directly and is session-owned, because a lease held for a server's whole life
# is a lease never returned.
#
# Each pool is its own directory with its own sequence and its own limit, so a
# queued review wave and a queued test suite never block each other.

# dx_capacity_pool_valid <pool>
dx_capacity_pool_valid() {
  case "${1:-}" in
    waves|checks|heavy) return 0 ;;
    *) return 1 ;;
  esac
}

# dx_capacity_pool_root <pool>
# `waves` is the base root — what DX_REVIEW_CAPACITY_DIR names — and every
# other pool is a directory inside it.
#
# DX_CAPACITY_POOL_BASE is how this stays re-entrant. The wrappers below select
# a pool by shadowing DX_REVIEW_CAPACITY_DIR, which is dynamically scoped, so
# anything they call — a wait loop's heartbeat callback asking where the pool is
# — would otherwise resolve the pool root relative to the pool root and look in
# `heavy/heavy`. Pinning the base once means nesting answers the same as the
# outermost call.
dx_capacity_pool_root() {
  local pool="${1:-}" base="${DX_CAPACITY_POOL_BASE:-}"
  dx_capacity_pool_valid "$pool" || return 2
  [[ -n "$base" ]] || base=$(dx_review_capacity_root) || return 2
  if [[ "$pool" == "waves" ]]; then
    printf '%s\n' "$base"
    return 0
  fi
  printf '%s/%s\n' "$base" "$pool"
}

# dx_capacity_pool_limit <pool>
dx_capacity_pool_limit() {
  case "${1:-}" in
    waves) dx_review_capacity_limit ;;
    checks) dx_review_check_capacity_limit ;;
    heavy) dx_host_heavy_limit ;;
    *) return 2 ;;
  esac
}

# __dx_capacity_pool_record_files <pool-root> <wait|lease>
# `find` rather than a glob: zsh, which sources lib/ through dx.sh, makes an
# unmatched glob an error rather than an empty list, and an empty pool is the
# normal case here.
__dx_capacity_pool_record_files() {
  local pool_root="$1" kind="$2"
  [[ -d "$pool_root" ]] || return 0
  find "$pool_root" -maxdepth 1 -type f -name "${kind}-*" 2>/dev/null \
    | LC_ALL=C sort || true
}

# __dx_capacity_pool_record_field <record-file> <1|2>
# The sequence or the owner PID from a lease/wait record, read by the shell so
# a status read costs no fork. __dx_review_capacity_record remains the
# validating reader that admission decisions use.
__dx_capacity_pool_record_field() {
  local record_file="$1" field="$2" record_line="" record_rest=""
  read -r record_line < "$record_file" 2>/dev/null || return 1
  case "$field" in
    1) printf '%s\n' "${record_line%%$'\t'*}" ;;
    2)
      record_rest="${record_line#*$'\t'}"
      printf '%s\n' "${record_rest%%$'\t'*}"
      ;;
    *) return 2 ;;
  esac
}

# dx_capacity_pool_live_count <pool> [lease|wait]
# Records of one kind whose recorded owner is still running, without taking
# the pool lock: `lease` (the default) is the held side, `wait` the queue.
# Advisory: it is the number a status line, `dx doctor` or a host snapshot
# shows, cheap enough to compute on every phase start.
# dx_capacity_pool_active_count is the locked, pruning count that decides
# admission.
dx_capacity_pool_live_count() {
  local pool="${1:-}" kind="${2:-lease}" pool_root record_file owner_pid
  local live_count=0
  dx_capacity_pool_valid "$pool" || return 2
  case "$kind" in
    lease|wait) ;;
    *) return 2 ;;
  esac
  pool_root=$(dx_capacity_pool_root "$pool") || return 2
  while IFS= read -r record_file; do
    [[ -n "$record_file" ]] || continue
    owner_pid=$(__dx_capacity_pool_record_field "$record_file" 2) || continue
    [[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] || continue
    kill -0 "$owner_pid" 2>/dev/null || continue
    live_count=$((live_count + 1))
  done < <(__dx_capacity_pool_record_files "$pool_root" "$kind")
  printf '%s\n' "$live_count"
}

# dx_capacity_pool_queue_status <pool> <owner-token>
# Two numbers for a caller that has to tell someone why it is waiting:
#
#   <owners ahead of this one> <TAB> <age of the oldest running lease|->
#
# "Ahead" counts every live lease plus every waiter that enqueued earlier, so
# it is the number of owners that must finish or give up first. The age is `-`
# when nothing is running, which is what a caller held back by low memory
# rather than by a full pool sees.
dx_capacity_pool_queue_status() {
  [[ $# -eq 2 ]] || return 2
  local pool="$1" owner_token="$2" pool_root record_file owner_pid
  local own_sequence="" record_sequence ahead=0 oldest_epoch="" record_epoch
  local oldest_age="-" now_epoch
  dx_capacity_pool_valid "$pool" || return 2
  __dx_review_capacity_token_valid "$owner_token" || return 2
  pool_root=$(dx_capacity_pool_root "$pool") || return 2
  for record_file in "$pool_root/wait-$owner_token" \
    "$pool_root/lease-$owner_token"; do
    [[ -f "$record_file" ]] || continue
    own_sequence=$(__dx_capacity_pool_record_field "$record_file" 1) \
      || own_sequence=""
  done
  while IFS= read -r record_file; do
    [[ -n "$record_file" ]] || continue
    owner_pid=$(__dx_capacity_pool_record_field "$record_file" 2) || continue
    [[ "$owner_pid" =~ ^[1-9][0-9]*$ ]] || continue
    kill -0 "$owner_pid" 2>/dev/null || continue
    ahead=$((ahead + 1))
    record_epoch=$(dx_path_mtime "$record_file" 2>/dev/null || true)
    [[ "$record_epoch" =~ ^[0-9]+$ ]] || continue
    if [[ -z "$oldest_epoch" || "$record_epoch" -lt "$oldest_epoch" ]]; then
      oldest_epoch="$record_epoch"
    fi
  done < <(__dx_capacity_pool_record_files "$pool_root" lease)
  if [[ "$own_sequence" =~ ^[1-9][0-9]*$ ]]; then
    while IFS= read -r record_file; do
      [[ -n "$record_file" ]] || continue
      [[ "${record_file##*/}" == "wait-$owner_token" ]] && continue
      record_sequence=$(__dx_capacity_pool_record_field "$record_file" 1) \
        || continue
      [[ "$record_sequence" =~ ^[1-9][0-9]*$ ]] || continue
      [[ "$record_sequence" -lt "$own_sequence" ]] || continue
      ahead=$((ahead + 1))
    done < <(__dx_capacity_pool_record_files "$pool_root" wait)
  fi
  if [[ -n "$oldest_epoch" ]]; then
    now_epoch=$(date +%s)
    oldest_age=$((now_epoch - oldest_epoch))
    [[ "$oldest_age" -ge 0 ]] || oldest_age=0
  fi
  printf '%s\t%s\n' "$ahead" "$oldest_age"
}

# dx_capacity_pool_mark_started <pool> <owner-token>
# Stamp the lease with the moment the work actually began.
#
# A lease file arrives by rename from the waiter record, so until this runs its
# mtime is when the owner joined the queue — and "oldest started 40m ago" about
# a command that spent 38 of those minutes queued is the wrong number to show
# someone deciding whether to wait for it.
dx_capacity_pool_mark_started() {
  [[ $# -eq 2 ]] || return 2
  local pool="$1" owner_token="$2" pool_root lease_file
  dx_capacity_pool_valid "$pool" || return 2
  __dx_review_capacity_token_valid "$owner_token" || return 2
  pool_root=$(dx_capacity_pool_root "$pool") || return 2
  lease_file="$pool_root/lease-$owner_token"
  [[ -f "$lease_file" ]] || return 1
  touch "$lease_file" 2>/dev/null || return 1
}

# The pool-scoped entry points. DX_REVIEW_CAPACITY_DIR is the pool selector the
# lease functions already read, so each wrapper resolves the pool root first and
# then shadows that variable for the call. `local` is dynamically scoped in both
# bash and zsh, so the lease functions see the pool root and the caller's own
# value is untouched once the wrapper returns. Two details matter: resolve
# before shadowing, or a declared-but-empty local hides the caller's
# DX_REVIEW_CAPACITY_DIR from dx_capacity_pool_root itself; and pin
# DX_CAPACITY_POOL_BASE too, so anything called from inside the wrapper still
# resolves the same pool rather than a pool inside it.

# dx_capacity_pool_wait <pool> <session-id> <owner-token> [cancel-callback]
dx_capacity_pool_wait() {
  [[ $# -ge 3 && $# -le 4 ]] || return 2
  local pool="$1" pool_base pool_root pool_limit pool_subject
  shift
  pool_base="${DX_CAPACITY_POOL_BASE:-}"
  [[ -n "$pool_base" ]] || pool_base=$(dx_review_capacity_root) || return 2
  pool_root=$(dx_capacity_pool_root "$pool") || return 2
  pool_limit=$(dx_capacity_pool_limit "$pool") || return 2
  case "$pool" in
    waves) pool_subject="review wave" ;;
    checks) pool_subject="check" ;;
    *) pool_subject="heavy command" ;;
  esac
  local DX_CAPACITY_POOL_BASE="$pool_base"
  local DX_REVIEW_CAPACITY_DIR="$pool_root"
  local DX_REVIEW_CAPACITY_SUBJECT="$pool_subject"
  dx_review_capacity_wait "$1" "$2" "$pool_limit" "${3:-}"
}

# dx_capacity_pool_release <pool> <owner-token>
dx_capacity_pool_release() {
  [[ $# -eq 2 ]] || return 2
  local pool="$1" owner_token="$2" pool_base pool_root
  pool_base="${DX_CAPACITY_POOL_BASE:-}"
  [[ -n "$pool_base" ]] || pool_base=$(dx_review_capacity_root) || return 2
  pool_root=$(dx_capacity_pool_root "$pool") || return 2
  local DX_CAPACITY_POOL_BASE="$pool_base"
  local DX_REVIEW_CAPACITY_DIR="$pool_root"
  dx_review_capacity_release "$owner_token"
}

# dx_capacity_pool_active_count <pool>
dx_capacity_pool_active_count() {
  [[ $# -eq 1 ]] || return 2
  local pool="$1" pool_base pool_root
  pool_base="${DX_CAPACITY_POOL_BASE:-}"
  [[ -n "$pool_base" ]] || pool_base=$(dx_review_capacity_root) || return 2
  pool_root=$(dx_capacity_pool_root "$pool") || return 2
  local DX_CAPACITY_POOL_BASE="$pool_base"
  local DX_REVIEW_CAPACITY_DIR="$pool_root"
  dx_review_capacity_active_count
}
