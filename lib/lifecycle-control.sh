#!/usr/bin/env bash
# shellcheck shell=bash
# Direct-human lifecycle intervention state shared by hooks and CLI sessions.

dx_lifecycle_session_id_valid() {
  local session_id="${1:-}"
  if command -v dx_session_id_valid >/dev/null 2>&1; then
    dx_session_id_valid "$session_id"
    return
  fi
  [[ -n "$session_id" && ${#session_id} -le 180 ]] || return 1
  [[ "$session_id" != "." && "$session_id" != ".." ]] || return 1
  [[ "$session_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

# One phase table for every consumer. The Stop hook, the UserPromptSubmit
# hook, dx control, and dx.sh each carried a private copy that had already
# drifted (some knew about phase 7, some did not).

# dx_lifecycle_phase_label <phase>
dx_lifecycle_phase_label() {
  case "${1:-}" in
    0) printf '%s\n' "Setup" ;;
    1) printf '%s\n' "Plan" ;;
    2) printf '%s\n' "Implement" ;;
    3) printf '%s\n' "Review" ;;
    4) printf '%s\n' "Verify & Commit" ;;
    5) printf '%s\n' "PR" ;;
    6) printf '%s\n' "Complete" ;;
    7) printf '%s\n' "Lifecycle complete" ;;
    *) printf '%s\n' "Unknown" ;;
  esac
}

# dx_lifecycle_phase_promise <phase>
dx_lifecycle_phase_promise() {
  case "${1:-}" in
    0) printf '%s\n' "PHASE_0_COMPLETE" ;;
    1) printf '%s\n' "PHASE_1_COMPLETE" ;;
    2) printf '%s\n' "PHASE_2_COMPLETE" ;;
    3) printf '%s\n' "PHASE_3_COMPLETE" ;;
    4) printf '%s\n' "PHASE_4_COMPLETE" ;;
    5) printf '%s\n' "PHASE_5_COMPLETE" ;;
    *) printf '%s\n' "DEX_TICKET_COMPLETE" ;;
  esac
}

# dx_lifecycle_phase_audit_basename <phase> — prompts/phase-audits/<name>.md
dx_lifecycle_phase_audit_basename() {
  case "${1:-}" in
    0) printf '%s\n' "0-setup" ;;
    1) printf '%s\n' "1-plan" ;;
    2) printf '%s\n' "2-implement" ;;
    3) printf '%s\n' "3-review-loop" ;;
    4) printf '%s\n' "4-verify" ;;
    5) printf '%s\n' "5-pr" ;;
    6) printf '%s\n' "6-complete" ;;
    *) printf '%s\n' "" ;;
  esac
}

# dx_lifecycle_phase_min_audits <phase>
# Honors the DEX_PHASE_<n>_MIN_AUDITS override; defaults to one audit pass.
dx_lifecycle_phase_min_audits() {
  local phase="${1:-}" env_name value
  [[ "$phase" =~ ^[0-9]+$ ]] || phase=""
  env_name="DEX_PHASE_${phase}_MIN_AUDITS"
  value="$(printenv "$env_name" 2>/dev/null || true)"
  if [[ -z "$value" && -n "$phase" ]]; then
    # An unexported override set in the caller's interactive shell (a plain
    # DEX_PHASE_2_MIN_AUDITS=5 in .zshrc) is invisible to printenv; read it
    # indirectly. env_name is validated digits-only above, so the eval cannot
    # expand anything user-controlled.
    eval "value=\${${env_name}:-}"
  fi
  if [[ "$value" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$value"
  else
    printf '%s\n' "1"
  fi
}

# dx_lifecycle_detach <session_id> <reason> <source>
# The shared detach sequence: record why, ask a running Phase 3 review child
# to stop, mark the pause, and drop the activation/completion/iteration
# markers so the loop cannot re-enter. The child-cancel request applies to
# every detach deliberately — a detaching session must not leave an orphan
# review wave editing files — including the one historical site that skipped
# it.
dx_lifecycle_detach() {
  local session_id="$1" reason="$2" detach_source="$3"
  dx_write_pause_state "$session_id" "$reason" "$detach_source" 2>/dev/null || true
  if [[ -f "$(dx_phase_busy_file "$session_id" 3)" ]]; then
    dx_phase_busy_request_cancel "$session_id" 3 2>/dev/null || true
  fi
  touch "$(dx_paused_file "$session_id")"
  rm -f "$(dx_active_file "$session_id")" \
    "$(dx_complete_file "$session_id")" "$(dx_loop_file "$session_id")" 2>/dev/null || true
}

dx_lifecycle_control_file() {
  dx_lifecycle_session_id_valid "$1" || return 1
  printf '%s/%s.control\n' "$DX_LOOP_DIR" "$1"
}

dx_lifecycle_control_history_file() {
  dx_lifecycle_session_id_valid "$1" || return 1
  printf '%s/%s.interventions\n' "$DX_STATE_DIR" "$1"
}

dx_lifecycle_control_lock_dir() {
  dx_lifecycle_session_id_valid "$1" || return 1
  printf '%s/%s.control-lock\n' "$DX_LOOP_DIR" "$1"
}

dx_lifecycle_human_complete_file() {
  dx_lifecycle_session_id_valid "$1" || return 1
  printf '%s/%s.human-complete\n' "$DX_STATE_DIR" "$1"
}

dx_lifecycle_atomic_write() {
  local target="$1" content="$2" target_dir tmp_file
  target_dir=$(dirname "$target")
  mkdir -p "$target_dir" || return 1
  if [[ ( -e "$target" || -L "$target" ) && ( ! -f "$target" || -L "$target" ) ]]; then
    return 1
  fi
  tmp_file=$(mktemp "${target}.tmp.XXXXXX") || return 1
  chmod 600 "$tmp_file" 2>/dev/null || true
  # >| because mktemp already created the file; a plain > is refused when the
  # caller's interactive zsh sets noclobber (lib/ runs inside that shell).
  if ! printf '%s\n' "$content" >| "$tmp_file" || ! command mv -f "$tmp_file" "$target"; then
    command rm -f "$tmp_file" 2>/dev/null || true
    return 1
  fi
}

dx_lifecycle_control_snapshot_unlocked() {
  local session_id="$1" control_file size
  dx_lifecycle_session_id_valid "$session_id" || return 0
  control_file=$(dx_lifecycle_control_file "$session_id")
  [[ -f "$control_file" && ! -L "$control_file" ]] || return 0
  # tr always succeeds, so the fallback has to come from the read itself:
  # an unreadable control file must look oversized, not empty.
  size=$(wc -c < "$control_file" 2>/dev/null || printf '4097')
  size=$(printf '%s' "$size" | tr -d '[:space:]')
  [[ "$size" =~ ^[0-9]+$ && "$size" -le 4096 ]] || return 0
  cat "$control_file" 2>/dev/null || true
}

dx_lifecycle_control_snapshot() {
  local session_id="$1" snapshot=""
  dx_lifecycle_session_id_valid "$session_id" || return 0
  dx_lifecycle_control_lock_acquire "$session_id" || return 0
  snapshot=$(dx_lifecycle_control_snapshot_unlocked "$session_id")
  dx_lifecycle_control_lock_release "$session_id" || true
  printf '%s\n' "$snapshot"
}

dx_lifecycle_control_value() {
  local snapshot="$1" key="$2"
  [[ -n "$key" ]] || return 0
  printf '%s\n' "$snapshot" | awk -F= -v key="$key" '$1 == key { sub(/^[^=]*=/, ""); print; exit }'
}

dx_lifecycle_control_read() {
  local session_id="$1" key="$2" snapshot
  dx_lifecycle_session_id_valid "$session_id" || return 0
  snapshot=$(dx_lifecycle_control_snapshot "$session_id")
  dx_lifecycle_control_value "$snapshot" "$key"
}

dx_lifecycle_current_phase() {
  local session_id="$1" phase="" config_file
  dx_lifecycle_session_id_valid "$session_id" || return 0

  phase=$(cat "$(dx_state_file "$session_id")" 2>/dev/null || true)
  if [[ "$phase" =~ ^[0-7]$ ]]; then
    printf '%s\n' "$phase"
    return 0
  fi

  config_file=$(dx_loop_config_file "$session_id")
  if [[ -f "$config_file" && ! -L "$config_file" ]]; then
    phase=$(cut -d: -f1 "$config_file" 2>/dev/null || true)
    if [[ "$phase" =~ ^[0-7]$ ]]; then
      printf '%s\n' "$phase"
      return 0
    fi
  fi

  phase="${DEX_LOOP_PHASE:-}"
  [[ "$phase" =~ ^[0-7]$ ]] && printf '%s\n' "$phase"
}

dx_lifecycle_session_active() {
  local session_id="$1" phase
  dx_lifecycle_session_id_valid "$session_id" || return 1
  phase=$(dx_lifecycle_current_phase "$session_id")
  [[ "$phase" == "7" ]] && return 1
  [[ "${DEX_LOOP_ACTIVE:-}" == "1" || "${DEX_REVIEW_PASS_ACTIVE:-}" == "1" ]] && return 0
  [[ -f "$(dx_active_file "$session_id")" || -f "$(dx_handoff_mode_file "$session_id")" ]] && return 0
  [[ "$phase" =~ ^[0-6]$ && -f "$(dx_paused_file "$session_id")" \
    && ! -L "$(dx_paused_file "$session_id")" ]] && return 0
  [[ -f "$(dx_loop_config_file "$session_id")" ]] || return 1
  [[ "$phase" =~ ^[0-6]$ ]]
}

dx_write_lifecycle_control() {
  local session_id="$1" action="$2" target_phase="${3:-}" source="${4:-user-prompt}"
  local prompt_sha256="${5:-}" expected_phase="${6:-}" owner_session="${7:-}"
  local control_file history_file tmp_file history_tmp_file issued_at generation owner_file
  local published=0 write_status=0
  dx_lifecycle_session_id_valid "$session_id" || return 1
  case "$action" in
    pause|cancel|resume) [[ -z "$target_phase" ]] || return 1 ;;
    complete|jump) [[ "$target_phase" =~ ^[0-7]$ ]] || return 1 ;;
    *) return 1 ;;
  esac
  case "$source" in
    user-prompt|terminal) ;;
    *) return 1 ;;
  esac
  [[ -z "$prompt_sha256" || "$prompt_sha256" =~ ^[0-9a-f]{64}$ ]] || return 1
  control_file=$(dx_lifecycle_control_file "$session_id")
  history_file=$(dx_lifecycle_control_history_file "$session_id")
  mkdir -p "$DX_LOOP_DIR" "$DX_STATE_DIR"
  dx_lifecycle_control_lock_acquire "$session_id" || return 1

  if [[ -z "$expected_phase" ]]; then
    expected_phase=$(dx_lifecycle_current_phase "$session_id")
  fi
  if [[ -n "$expected_phase" && "$expected_phase" != "prompt-loop" && ! "$expected_phase" =~ ^[0-7]$ ]]; then
    write_status=1
  fi
  owner_file=$(dx_owner_file "$session_id")
  if [[ -z "$owner_session" && -f "$owner_file" && ! -L "$owner_file" ]]; then
    owner_session=$(cat "$owner_file" 2>/dev/null || true)
  fi
  if [[ -n "$owner_session" ]] && ! dx_lifecycle_session_id_valid "$owner_session"; then
    write_status=1
  fi

  if [[ ( -e "$control_file" || -L "$control_file" ) && ( ! -f "$control_file" || -L "$control_file" ) ]]; then
    write_status=1
  fi
  if [[ ( -e "$history_file" || -L "$history_file" ) && ( ! -f "$history_file" || -L "$history_file" ) ]]; then
    write_status=1
  fi
  issued_at=$(date +%s)
  generation="${issued_at}-$$-${RANDOM}"

  tmp_file=""
  history_tmp_file=""
  if [[ "$write_status" -eq 0 ]]; then
    tmp_file=$(mktemp "${control_file}.tmp.XXXXXX") || write_status=1
  fi
  if [[ "$write_status" -eq 0 ]] && ! {
    printf 'version=1\n'
    printf 'action=%s\n' "$action"
    printf 'target_phase=%s\n' "$target_phase"
    printf 'expected_phase=%s\n' "$expected_phase"
    printf 'issued_at=%s\n' "$issued_at"
    printf 'generation=%s\n' "$generation"
    printf 'source=%s\n' "$source"
    printf 'owner_session=%s\n' "$owner_session"
    printf 'prompt_sha256=%s\n' "$prompt_sha256"
  } >| "$tmp_file"; then
    write_status=1
  fi

  if [[ "$write_status" -eq 0 ]]; then
    history_tmp_file=$(mktemp "${history_file}.tmp.XXXXXX") || write_status=1
  fi
  if [[ "$write_status" -eq 0 && -f "$history_file" ]]; then
    if ! cat "$history_file" >| "$history_tmp_file"; then
      write_status=1
    fi
  elif [[ "$write_status" -eq 0 ]] && ! printf 'issued_at\tgeneration\taction\ttarget_phase\texpected_phase\tsource\towner_session\tprompt_sha256\n' >| "$history_tmp_file"; then
    write_status=1
  fi
  if [[ "$write_status" -eq 0 ]] && ! printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$issued_at" "$generation" "$action" "$target_phase" "$expected_phase" \
    "$source" "$owner_session" "$prompt_sha256" >> "$history_tmp_file"; then
    write_status=1
  fi

  # History is the durable audit record. Publish it before the live receipt so
  # callers never receive a failure after a new control action became visible.
  if [[ "$write_status" -eq 0 ]] && ! command mv -f "$history_tmp_file" "$history_file"; then
    write_status=1
  fi
  if [[ "$write_status" -eq 0 ]]; then
    history_tmp_file=""
    if command mv -f "$tmp_file" "$control_file"; then
      tmp_file=""
      published=1
    else
      write_status=1
    fi
  fi

  [[ -n "$tmp_file" ]] && command rm -f "$tmp_file" 2>/dev/null || true
  [[ -n "$history_tmp_file" ]] && command rm -f "$history_tmp_file" 2>/dev/null || true
  dx_lifecycle_control_lock_release "$session_id" || true
  [[ "$published" -eq 1 && "$write_status" -eq 0 ]]
}

__dx_lifecycle_path_mtime() {
  stat -f '%m' "$1" 2>/dev/null || stat -c '%Y' "$1" 2>/dev/null
}

__dx_lifecycle_control_lock_try() {
  local session_id="$1" lock_dir owner_file owner_raw owner_pid owner_epoch owner_token
  local now_epoch lock_epoch stale_after token current_raw tmp_owner doomed_dir
  dx_lifecycle_session_id_valid "$session_id" || return 1
  lock_dir=$(dx_lifecycle_control_lock_dir "$session_id")
  owner_file="$lock_dir/owner"
  mkdir -p "$DX_LOOP_DIR"
  if mkdir "$lock_dir" 2>/dev/null; then
    chmod 700 "$lock_dir" 2>/dev/null || true
    now_epoch=$(date +%s)
    token="${now_epoch}-$$-${RANDOM}"
    tmp_owner="$lock_dir/.owner-${token}"
    if ! ( umask 077; printf '%s\t%s\t%s\n' "$$" "$now_epoch" "$token" > "$tmp_owner" ) \
      || ! command mv -f "$tmp_owner" "$owner_file"; then
      command rm -f "$tmp_owner" 2>/dev/null || true
      rmdir "$lock_dir" 2>/dev/null || true
      return 1
    fi
    DX_LIFECYCLE_CONTROL_LOCK_SESSION="$session_id"
    DX_LIFECYCLE_CONTROL_LOCK_TOKEN="$token"
    return 0
  fi
  [[ -d "$lock_dir" && ! -L "$lock_dir" ]] || return 1
  stale_after="${DEX_LIFECYCLE_CONTROL_LOCK_STALE_SECONDS:-2}"
  [[ "$stale_after" =~ ^[0-9]+$ ]] || stale_after=2

  if [[ ! -e "$owner_file" && ! -L "$owner_file" ]]; then
    sleep 0.05
    [[ ! -e "$owner_file" && ! -L "$owner_file" ]] || return 1
    lock_epoch=$(__dx_lifecycle_path_mtime "$lock_dir" 2>/dev/null || printf '0')
    now_epoch=$(date +%s)
    [[ "$lock_epoch" =~ ^[0-9]+$ ]] || return 1
    [[ $((now_epoch - lock_epoch)) -ge "$stale_after" ]] || return 1
    # Same rename-to-claim rule as below: an abandoned lock whose owner file
    # never appeared must be removed by exactly one cleaner.
    doomed_dir="${lock_dir}.doomed.$$"
    if command mv "$lock_dir" "$doomed_dir" 2>/dev/null; then
      command rm -rf "$doomed_dir" 2>/dev/null || true
    fi
    return 1
  fi
  [[ -f "$owner_file" && ! -L "$owner_file" ]] || return 1
  owner_raw=$(cat "$owner_file" 2>/dev/null || true)
  owner_pid="${owner_raw%%$'\t'*}"
  owner_raw="${owner_raw#*$'\t'}"
  owner_epoch="${owner_raw%%$'\t'*}"
  owner_token="${owner_raw#*$'\t'}"
  if [[ ! "$owner_pid" =~ ^[0-9]+$ || ! "$owner_epoch" =~ ^[0-9]+$ \
    || ! "$owner_token" =~ ^[0-9]+-[0-9]+-[0-9]+$ ]] \
    || ! kill -0 "$owner_pid" 2>/dev/null; then
    current_raw=$(cat "$owner_file" 2>/dev/null || true)
    [[ "$current_raw" == "${owner_pid}"$'\t'"${owner_epoch}"$'\t'"${owner_token}" ]] || return 1
    # Claim the removal by renaming: whoever wins the rename owns the cleanup.
    # Deleting the owner file and directory in place leaves a window in which
    # another cleaner can remove the lock and a new holder can recreate it,
    # after which this process would delete a lock it no longer owns.
    doomed_dir="${lock_dir}.doomed.$$"
    if command mv "$lock_dir" "$doomed_dir" 2>/dev/null; then
      command rm -rf "$doomed_dir" 2>/dev/null || true
    fi
  fi
  return 1
}

dx_lifecycle_control_lock_acquire() {
  local session_id="$1" attempts_raw="${2:-${DEX_LIFECYCLE_CONTROL_LOCK_ATTEMPTS:-40}}" attempt=0
  dx_lifecycle_session_id_valid "$session_id" || return 1
  [[ "$attempts_raw" =~ ^[0-9]+$ && "$attempts_raw" -ge 1 && "$attempts_raw" -le 400 ]] || attempts_raw=40
  while [[ "$attempt" -lt "$attempts_raw" ]]; do
    if __dx_lifecycle_control_lock_try "$session_id"; then
      return 0
    fi
    attempt=$((attempt + 1))
    [[ "$attempt" -lt "$attempts_raw" ]] && sleep 0.05
  done
  return 1
}

dx_lifecycle_control_lock_release() {
  local session_id="$1" lock_dir owner_file owner_raw owner_pid owner_token
  dx_lifecycle_session_id_valid "$session_id" || return 1
  lock_dir=$(dx_lifecycle_control_lock_dir "$session_id")
  owner_file="$lock_dir/owner"
  [[ "${DX_LIFECYCLE_CONTROL_LOCK_SESSION:-}" == "$session_id" ]] || return 1
  [[ -n "${DX_LIFECYCLE_CONTROL_LOCK_TOKEN:-}" ]] || return 1
  [[ -f "$owner_file" && ! -L "$owner_file" ]] || return 1
  owner_raw=$(cat "$owner_file" 2>/dev/null || true)
  owner_pid="${owner_raw%%$'\t'*}"
  owner_token="${owner_raw##*$'\t'}"
  [[ "$owner_pid" == "$$" && "$owner_token" == "$DX_LIFECYCLE_CONTROL_LOCK_TOKEN" ]] || return 1
  rm -f "$owner_file" 2>/dev/null || return 1
  rmdir "$lock_dir" 2>/dev/null || return 1
  DX_LIFECYCLE_CONTROL_LOCK_SESSION=""
  DX_LIFECYCLE_CONTROL_LOCK_TOKEN=""
}

dx_clear_lifecycle_control_unlocked() {
  local session_id="$1"
  dx_lifecycle_session_id_valid "$session_id" || return 0
  rm -f "$(dx_lifecycle_control_file "$session_id")" 2>/dev/null || true
}

dx_clear_lifecycle_control() {
  local session_id="$1"
  dx_lifecycle_session_id_valid "$session_id" || return 0
  dx_lifecycle_control_lock_acquire "$session_id" || return 1
  dx_clear_lifecycle_control_unlocked "$session_id"
  dx_lifecycle_control_lock_release "$session_id" || true
}

dx_write_pause_state() {
  local session_id="$1" reason="$2" source="$3" pause_file
  dx_lifecycle_session_id_valid "$session_id" || return 1
  [[ "$reason" =~ ^[A-Za-z0-9._-]+$ && "$source" =~ ^[A-Za-z0-9._-]+$ ]] || return 1
  pause_file=$(dx_pause_state_file "$session_id")
  dx_lifecycle_atomic_write "$pause_file" "reason=${reason}"$'\n'"source=${source}"
}

dx_pause_state_read() {
  local session_id="$1" key="$2" pause_file snapshot
  dx_lifecycle_session_id_valid "$session_id" || return 0
  pause_file=$(dx_pause_state_file "$session_id")
  [[ -f "$pause_file" && ! -L "$pause_file" ]] || return 0
  snapshot=$(cat "$pause_file" 2>/dev/null || true)
  dx_lifecycle_control_value "$snapshot" "$key"
}

# Remove a generic phase completion signal before publishing a new phase. A
# consumed signal can be safely recreated after a failed publish; carrying it
# across a phase boundary could falsely complete the next phase.
dx_consume_completion_receipt() {
  local session_id="$1" complete_file
  dx_lifecycle_session_id_valid "$session_id" || return 1
  complete_file=$(dx_complete_file "$session_id")
  command rm -f "$complete_file" 2>/dev/null || return 1
  [[ ! -e "$complete_file" && ! -L "$complete_file" ]]
}

# dx_record_human_phase_outcomes <session_id> <current> <target> <action> <generation> <source> [recovery]
# Record the phases a direct human transition crosses. Callers hold the
# lifecycle lock and clear the live control receipt only after this succeeds.
dx_record_human_phase_outcomes() {
  local session_id="$1" current="$2" target="$3" action="$4"
  local generation="$5" source="$6" recovery="${7:-0}"
  local outcome reason event_type phase record_status data_json
  dx_lifecycle_session_id_valid "$session_id" || return 1
  [[ "$current" =~ ^[0-7]$ && "$target" =~ ^[0-7]$ ]] || return 1
  [[ "$generation" =~ ^[0-9]+-[0-9]+-[0-9]+$ ]] || return 1
  case "$source" in
    user-prompt|terminal) ;;
    *) return 1 ;;
  esac
  [[ "$recovery" == "0" || "$recovery" == "1" ]] || return 1
  [[ "$target" -gt "$current" ]] || return 0

  case "$action" in
    complete)
      [[ "$target" -eq $((current + 1)) ]] || return 1
      outcome="waived"
      reason="human-complete"
      event_type="phase.waived"
      ;;
    jump)
      outcome="skipped"
      reason="human-jump"
      event_type="phase.skipped"
      ;;
    *) return 1 ;;
  esac

  phase="$current"
  while [[ "$phase" -lt "$target" && "$phase" -le 6 ]]; do
    record_status=0
    dx_phase_outcome_record "$session_id" "$phase" "$outcome" "$source" \
      "$generation" "$reason" || record_status=$?
    if [[ "$record_status" -eq 3 ]]; then
      phase=$((phase + 1))
      continue
    fi
    [[ "$record_status" -eq 0 ]] || return 1

    data_json=$(printf \
      '{"outcome":"%s","reason":"%s","source":"%s","generation":"%s","target_phase":%s}' \
      "$outcome" "$reason" "$source" "$generation" "$target")
    dx_event_emit_for_session "$session_id" "$event_type" "warn" \
      "Phase ${phase} ${outcome} by direct human instruction" "$phase" "$data_json"
    dx_run_log_append_for_session "$session_id" "warn" "lifecycle-control" \
      "Phase ${phase} ${outcome} by direct human instruction; target_phase=${target}; generation=${generation}; source=${source}"
    phase=$((phase + 1))
  done
}

dx_phase_busy_token() {
  local session_id="$1" phase="$2" busy_file raw token
  dx_lifecycle_session_id_valid "$session_id" || return 0
  [[ "$phase" =~ ^[0-6]$ ]] || return 0
  busy_file=$(dx_phase_busy_file "$session_id" "$phase")
  [[ -f "$busy_file" && ! -L "$busy_file" ]] || return 0
  raw=$(cat "$busy_file" 2>/dev/null || true)
  raw="${raw#*$'\t'}"
  token="${raw%%$'\t'*}"
  [[ "$token" =~ ^[0-9]+-[0-9]+-[0-9]+$ ]] && printf '%s\n' "$token"
}

dx_phase_busy_begin() {
  local session_id="$1" phase="$2" label="${3:-busy}" epoch token busy_file
  dx_lifecycle_session_id_valid "$session_id" || return 1
  [[ "$phase" =~ ^[0-6]$ ]] || return 1
  [[ "$label" != *$'\n'* && "$label" != *$'\r'* && ${#label} -le 500 ]] || return 1
  epoch=$(date +%s)
  token="${epoch}-$$-${RANDOM}"
  busy_file=$(dx_phase_busy_file "$session_id" "$phase")
  rm -f "$(dx_phase_busy_cancel_file "$session_id" "$phase")" \
    "$(dx_phase_busy_quiesced_file "$session_id" "$phase")" 2>/dev/null || true
  dx_lifecycle_atomic_write "$busy_file" "${epoch}"$'\t'"${token}"$'\t'"$$"$'\t'"${label}" || return 1
  printf '%s\n' "$token"
}

dx_phase_busy_request_cancel() {
  local session_id="$1" phase="$2" token cancel_file
  token=$(dx_phase_busy_token "$session_id" "$phase")
  [[ -n "$token" ]] || return 1
  cancel_file=$(dx_phase_busy_cancel_file "$session_id" "$phase")
  dx_lifecycle_atomic_write "$cancel_file" "$token"
}

dx_phase_busy_cancel_requested() {
  local session_id="$1" phase="$2" token requested
  token=$(dx_phase_busy_token "$session_id" "$phase")
  [[ -n "$token" ]] || return 1
  requested=$(cat "$(dx_phase_busy_cancel_file "$session_id" "$phase")" 2>/dev/null || true)
  [[ "$requested" == "$token" ]]
}

dx_phase_busy_acknowledge() {
  local session_id="$1" phase="$2" token="$3" current ack_file
  current=$(dx_phase_busy_token "$session_id" "$phase")
  [[ -n "$token" && "$current" == "$token" ]] || return 1
  ack_file=$(dx_phase_busy_quiesced_file "$session_id" "$phase")
  dx_lifecycle_atomic_write "$ack_file" "$token"
}

dx_phase_busy_quiesced() {
  local session_id="$1" phase="$2" token acknowledged ack_file
  token=$(dx_phase_busy_token "$session_id" "$phase")
  [[ -n "$token" ]] || return 1
  ack_file=$(dx_phase_busy_quiesced_file "$session_id" "$phase")
  [[ -f "$ack_file" && ! -L "$ack_file" ]] || return 1
  acknowledged=$(cat "$ack_file" 2>/dev/null || true)
  [[ "$acknowledged" == "$token" ]]
}

dx_phase_busy_finish() {
  local session_id="$1" phase="$2" token="$3" current
  current=$(dx_phase_busy_token "$session_id" "$phase")
  [[ -n "$token" && "$current" == "$token" ]] || return 1
  dx_phase_busy_quiesced "$session_id" "$phase" || return 1
  rm -f "$(dx_phase_busy_file "$session_id" "$phase")" \
    "$(dx_phase_busy_notice_file "$session_id" "$phase")" \
    "$(dx_phase_busy_cancel_file "$session_id" "$phase")" \
    "$(dx_phase_busy_quiesced_file "$session_id" "$phase")" 2>/dev/null || true
}

dx_phase_transition_crosses() {
  local current="$1" target="$2" boundary="$3"
  [[ "$current" =~ ^[0-7]$ && "$target" =~ ^[0-7]$ && "$boundary" =~ ^[0-7]$ ]] || return 1
  [[ "$current" != "$target" ]] || return 1
  if [[ "$current" -le "$target" ]]; then
    [[ "$current" -le "$boundary" && "$target" -ge "$boundary" ]]
  else
    [[ "$target" -le "$boundary" && "$current" -ge "$boundary" ]]
  fi
}

dx_phase_busy_transition_blocked() {
  local session_id="$1" phase="$2" current="$3" target="$4" busy_file
  busy_file=$(dx_phase_busy_file "$session_id" "$phase")
  [[ -f "$busy_file" && ! -L "$busy_file" ]] || return 1
  dx_phase_transition_crosses "$current" "$target" "$phase" || return 1
  dx_phase_busy_quiesced "$session_id" "$phase" && return 1
  return 0
}
