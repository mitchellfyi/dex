#!/usr/bin/env bash
# shellcheck shell=bash
# Session-scoped soft policy overrides shared by hooks and provider CLIs.

dx_override_session_id_valid() {
  local session_id="${1:-}"
  if command -v dx_session_id_valid >/dev/null 2>&1; then
    dx_session_id_valid "$session_id"
    return
  fi
  [[ -n "$session_id" && ${#session_id} -le 180 ]] || return 1
  [[ "$session_id" != "." && "$session_id" != ".." ]] || return 1
  [[ "$session_id" =~ ^[A-Za-z0-9][A-Za-z0-9._-]*$ ]]
}

dx_override_gate_valid() {
  local gate="${1:-}"
  [[ -n "$gate" && ${#gate} -le 120 ]] || return 1
  [[ "$gate" =~ ^[a-z][a-z0-9]*([.][a-z0-9][a-z0-9-]*)*$ ]]
}

dx_override_value_valid() {
  local value="${1:-}"
  [[ -n "$value" && ${#value} -le 180 ]] || return 1
  [[ "$value" != *$'\t'* && "$value" != *$'\n'* \
    && "$value" != *$'\r'* ]]
}

# Keep this registry aligned with the consumers documented in
# docs/autonomous-mode.md. Accepting an unconsumed name would create an audit
# row that looks effective even though no runtime policy changed.
dx_override_gate_supported() {
  [[ $# -eq 1 ]] || return 2
  local gate="$1"
  case "$gate" in
    phase.timeout|phase.min-audits|loop.max-iterations|\
    loop.stall-timeout|loop.stall-escalate|review.clean-passes|\
    review.pass-timeout|review.notice-interval|review.recheck-seconds|\
    watch.pause-ttl|watch.cycle-timeout|watch.command-timeout|\
    complete.max-cycles|complete.wait-minutes|complete.ci-fix-attempts|\
    failure.attempts-per-strategy|failure.max-strategies|\
    maintain.max-prs|sync.budget-minutes|maintain.budget-minutes|\
    maintain.respond-budget-minutes|maintain.command-timeout-seconds|\
    maintain.max-surfaces|control.pause|control.cancel|control.resume|\
    phase.completion|phase.jump|verification.required-gates|guard.*)
      return 0
      ;;
    *) return 1 ;;
  esac
}

# Known gate values are validated at write time so an override cannot leave a
# running hook with a policy it cannot interpret.
dx_override_gate_value_valid() {
  [[ $# -eq 2 ]] || return 2
  local gate="$1" value="$2"
  dx_override_gate_supported "$gate" || return 1
  case "$gate" in
    review.clean-passes)
      [[ "$value" =~ ^[1-9][0-9]*$ && ${#value} -le 2 \
        && $((10#$value)) -le 30 ]]
      ;;
    phase.timeout|phase.min-audits|loop.max-iterations|\
    loop.stall-timeout|loop.stall-escalate|review.pass-timeout|\
    review.notice-interval|review.recheck-seconds|watch.pause-ttl|\
    watch.cycle-timeout|watch.command-timeout|complete.max-cycles|\
    complete.wait-minutes|complete.ci-fix-attempts|\
    failure.attempts-per-strategy|failure.max-strategies|maintain.max-prs|\
    sync.budget-minutes|maintain.budget-minutes|\
    maintain.respond-budget-minutes|maintain.command-timeout-seconds)
      [[ "$value" =~ ^[0-9]+$ && ${#value} -le 15 ]]
      ;;
    maintain.max-surfaces)
      [[ "$value" =~ ^[1-9][0-9]*$ && ${#value} -le 15 ]]
      ;;
    guard.*)
      [[ "$value" == "allow" || "$value" == "enforce" ]]
      ;;
    control.pause|control.cancel|control.resume)
      [[ "$value" == "requested" ]]
      ;;
    phase.completion)
      [[ "$value" == "waived" ]]
      ;;
    verification.required-gates)
      [[ "$value" == "waived" ]]
      ;;
    phase.jump)
      [[ "$value" =~ ^[0-6]$ ]]
      ;;
  esac
}

dx_override_reason_valid() {
  local reason="${1:-}"
  [[ -n "$reason" && ${#reason} -le 500 ]] || return 1
  [[ "$reason" != *$'\t'* && "$reason" != *$'\n'* \
    && "$reason" != *$'\r'* ]]
}

dx_override_phase_valid() {
  [[ "${1:-}" == "-" || "${1:-}" == "prompt-loop" \
    || "${1:-}" =~ ^[0-6]$ ]]
}

dx_override_file() {
  dx_override_session_id_valid "${1:-}" || return 1
  printf '%s/%s.overrides\n' "$DX_STATE_DIR" "$1"
}

dx_override_lock_dir() {
  dx_override_session_id_valid "${1:-}" || return 1
  printf '%s/%s.override-lock\n' "$DX_STATE_DIR" "$1"
}

__dx_override_append_unlocked() {
  local session_id="$1" action="$2" gate="$3" value="$4" scope="$5"
  local phase="$6" override_source="$7" reason="$8" expires_at="$9"
  local override_file prior="" prior_rc=0 tmp_file created_at generation
  override_file=$(dx_override_file "$session_id") || return 1

  if [[ -e "$override_file" || -L "$override_file" ]]; then
    prior=$(dx_session_trusted_file_read "$override_file" 1048576) \
      || prior_rc=$?
    [[ "$prior_rc" -eq 0 ]] || return 1
  fi

  created_at=$(date +%s)
  generation="${created_at}-$$-${RANDOM}"
  mkdir -p "$DX_STATE_DIR" || return 1
  tmp_file=$(mktemp "${override_file}.tmp.XXXXXX") || return 1
  chmod 600 "$tmp_file" 2>/dev/null || true

  if [[ -n "$prior" ]]; then
    if ! printf '%s\n' "$prior" >| "$tmp_file"; then
      command rm -f "$tmp_file" 2>/dev/null || true
      return 1
    fi
  elif ! printf '%s\n' \
    $'created_at\tgeneration\taction\tgate\tvalue\tscope\tphase\tsource\texpires_at\treason' \
    >| "$tmp_file"; then
    command rm -f "$tmp_file" 2>/dev/null || true
    return 1
  fi

  if ! printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$created_at" "$generation" "$action" "$gate" "$value" "$scope" \
    "$phase" "$override_source" "$expires_at" "$reason" >> "$tmp_file" \
    || ! command mv -f "$tmp_file" "$override_file"; then
    command rm -f "$tmp_file" 2>/dev/null || true
    return 1
  fi
}

# dx_override_set <session> <gate> <value> <phase|session> <phase|->
#   <agent|human> <reason> <expires-at-epoch|0>
dx_override_set() {
  [[ $# -eq 8 ]] || return 2
  local session_id="$1" gate="$2" value="$3" scope="$4" phase="$5"
  local override_source="$6" reason="$7" expires_at="$8" lock_token
  dx_override_session_id_valid "$session_id" || return 2
  dx_override_gate_valid "$gate" || return 2
  dx_override_value_valid "$value" || return 2
  dx_override_gate_value_valid "$gate" "$value" || return 2
  [[ "$scope" == "phase" || "$scope" == "session" ]] || return 2
  dx_override_phase_valid "$phase" || return 2
  if [[ "$scope" == "phase" ]]; then
    [[ "$phase" != "-" ]] || return 2
  else
    [[ "$phase" == "-" ]] || return 2
  fi
  [[ "$override_source" == "agent" || "$override_source" == "human" ]] \
    || return 2
  dx_override_reason_valid "$reason" || return 2
  [[ "$expires_at" =~ ^[0-9]+$ && ${#expires_at} -le 15 ]] || return 2

  lock_token="override-$$-${RANDOM}"
  dx_lock_with "$(dx_override_lock_dir "$session_id")" "$lock_token" 5 \
    __dx_override_append_unlocked "$session_id" set "$gate" "$value" \
    "$scope" "$phase" "$override_source" "$reason" "$expires_at"
}

# dx_override_clear <session> <gate> <phase|session> <phase|->
#   <agent|human> <reason>
dx_override_clear() {
  [[ $# -eq 6 ]] || return 2
  local session_id="$1" gate="$2" scope="$3" phase="$4"
  local override_source="$5" reason="$6" lock_token
  dx_override_session_id_valid "$session_id" || return 2
  dx_override_gate_valid "$gate" || return 2
  dx_override_gate_supported "$gate" || return 2
  [[ "$scope" == "phase" || "$scope" == "session" ]] || return 2
  dx_override_phase_valid "$phase" || return 2
  if [[ "$scope" == "phase" ]]; then
    [[ "$phase" != "-" ]] || return 2
  else
    [[ "$phase" == "-" ]] || return 2
  fi
  [[ "$override_source" == "agent" || "$override_source" == "human" ]] \
    || return 2
  dx_override_reason_valid "$reason" || return 2

  lock_token="override-$$-${RANDOM}"
  dx_lock_with "$(dx_override_lock_dir "$session_id")" "$lock_token" 5 \
    __dx_override_append_unlocked "$session_id" clear "$gate" - "$scope" \
    "$phase" "$override_source" "$reason" 0
}

# Record a named phase waiver as an audit decision, not as a live operational
# value. This also clears any older phase-scoped value for the same gate when
# the journal is reduced, so jumping back cannot feed "waived" to a numeric
# consumer or silently revive the earlier override.
# dx_override_waive <session> <gate> <phase> <agent|human> <reason>
dx_override_waive() {
  [[ $# -eq 5 ]] || return 2
  local session_id="$1" gate="$2" phase="$3" override_source="$4"
  local reason="$5" lock_token
  dx_override_session_id_valid "$session_id" || return 2
  dx_override_gate_valid "$gate" || return 2
  dx_override_gate_supported "$gate" || return 2
  dx_override_phase_valid "$phase" || return 2
  [[ "$phase" != "-" ]] || return 2
  [[ "$override_source" == "agent" || "$override_source" == "human" ]] \
    || return 2
  dx_override_reason_valid "$reason" || return 2

  lock_token="override-$$-${RANDOM}"
  dx_lock_with "$(dx_override_lock_dir "$session_id")" "$lock_token" 5 \
    __dx_override_append_unlocked "$session_id" waive "$gate" waived phase \
    "$phase" "$override_source" "$reason" 0
}

# dx_override_list <session> [phase]
# Print active rows as gate, value, scope, phase, source, expiry, reason.
dx_override_list() {
  [[ $# -eq 1 || $# -eq 2 ]] || return 2
  local session_id="$1" current_phase="${2:--}" override_file raw="" read_rc=0
  dx_override_session_id_valid "$session_id" || return 2
  dx_override_phase_valid "$current_phase" || return 2
  override_file=$(dx_override_file "$session_id") || return 2
  [[ -e "$override_file" || -L "$override_file" ]] || return 0
  raw=$(dx_session_trusted_file_read "$override_file" 1048576) || read_rc=$?
  [[ "$read_rc" -eq 0 ]] || return 2

  printf '%s\n' "$raw" | awk -F '\t' -v phase="$current_phase" \
    -v now="$(date +%s)" '
      BEGIN { OFS = "\t"; valid = 1 }
      NR == 1 {
        if ($0 != "created_at\tgeneration\taction\tgate\tvalue\tscope\tphase\tsource\texpires_at\treason") valid = 0
        next
      }
      {
        if (NF != 10 || $1 !~ /^[0-9]+$/ ||
            $2 !~ /^[0-9]+-[0-9]+-[0-9]+$/ ||
            ($3 != "set" && $3 != "clear" && $3 != "waive") ||
            $4 !~ /^[a-z][a-z0-9]*([.][a-z0-9][a-z0-9-]*)*$/ ||
            ($6 != "phase" && $6 != "session") ||
            ($7 != "-" && $7 != "prompt-loop" && $7 !~ /^[0-6]$/) ||
            ($8 != "agent" && $8 != "human") || $9 !~ /^[0-9]+$/ ||
            $10 == "" || ($6 == "phase" && $7 == "-") ||
            ($6 == "session" && $7 != "-")) {
          valid = 0
          next
        }
        if ($6 == "phase" && $7 != phase) next
        key = $4 SUBSEP $6
        if ($3 == "clear" || $3 == "waive") {
          delete candidate[key]
          delete candidate_order[key]
          next
        }
        if ($9 != 0 && $9 <= now) next
        candidate[key] = $0
        candidate_order[key] = NR
      }
      END {
        if (!valid || NR < 2) exit 2
        for (key in candidate) {
          split(candidate[key], fields, "\t")
          gate = fields[4]
          if (!(gate in chosen_order) || candidate_order[key] > chosen_order[gate]) {
            chosen[gate] = candidate[key]
            chosen_order[gate] = candidate_order[key]
          }
        }
        for (gate in chosen) {
          split(chosen[gate], fields, "\t")
          print fields[4], fields[5], fields[6], fields[7], fields[8], fields[9], fields[10]
        }
      }
    ' | LC_ALL=C sort
}

# dx_override_get <session> <gate> [phase]
dx_override_get() {
  [[ $# -eq 2 || $# -eq 3 ]] || return 2
  local session_id="$1" gate="$2" phase="${3:--}" rows="" list_rc=0 value=""
  dx_override_gate_valid "$gate" || return 2
  rows=$(dx_override_list "$session_id" "$phase") || list_rc=$?
  [[ "$list_rc" -eq 0 ]] || return "$list_rc"
  value=$(printf '%s\n' "$rows" | awk -F '\t' -v gate="$gate" \
    '$1 == gate { print $2; found = 1 } END { if (!found) exit 1 }') || return 1
  printf '%s\n' "$value"
}

# Bind an active decision to its value, scope, attribution, expiry, and reason.
# The journal remains the human-readable audit trail; this digest lets a
# downstream receipt prove which active decision it relied on.
dx_override_binding() {
  [[ $# -eq 3 || $# -eq 4 ]] || return 2
  local session_id="$1" gate="$2" expected_value="$3" phase="${4:--}"
  local rows="" list_rc=0 record=""
  dx_override_gate_supported "$gate" || return 2
  rows=$(dx_override_list "$session_id" "$phase") || list_rc=$?
  [[ "$list_rc" -eq 0 ]] || return "$list_rc"
  record=$(printf '%s\n' "$rows" | awk -F '\t' -v gate="$gate" \
    -v value="$expected_value" \
    '$1 == gate && $2 == value { print; found = 1 } END { if (!found) exit 1 }') \
    || return 1
  printf 'dex-override-v1\t%s\n' "$record" | python3 -c \
    'import hashlib, sys; print(hashlib.sha256(sys.stdin.buffer.read()).hexdigest())'
}

# dx_override_effective <session> <gate> <default> [phase]
dx_override_effective() {
  [[ $# -eq 3 || $# -eq 4 ]] || return 2
  local session_id="$1" gate="$2" default_value="$3" phase="${4:--}"
  local value="" get_rc=0
  value=$(dx_override_get "$session_id" "$gate" "$phase") || get_rc=$?
  if [[ "$get_rc" -eq 0 ]]; then
    printf '%s\n' "$value"
    return 0
  fi
  [[ "$get_rc" -eq 1 ]] || return "$get_rc"
  printf '%s\n' "$default_value"
}
