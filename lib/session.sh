# shellcheck shell=bash
# Doyaken shared library — session ID and state file helpers
#
# Session IDs key all state and loop files. Path-based derivation makes them
# stable across branch renames (the SessionStart hook may rename branches to
# follow project conventions). See: docs/autonomous-mode.md § State Management
#
# Scope: state/loop dirs are global (~/.claude/.doyaken-{phases,loops}/), so
# session IDs include a repo-stable key plus the worktree/branch identifier.
# This prevents two repos using the same ticket, task, or branch name from
# sharing phase, provider, watcher, or loop state.
#
# Concurrency: dk_unique_session_id() appends PID+epoch to avoid collisions
# when multiple dkloop invocations run on the same branch. The unique ID is
# passed to Claude via DOYAKEN_SESSION_ID env var so the stop hook resolves
# to the same unique ID. See: hooks/phase-loop.sh line 29.

# dk_session_repo_key
# Derive a filesystem-safe repo key from the main repo root. The basename keeps
# state files readable; the cksum component makes same-named repos distinct.
dk_session_repo_key() {
  local root name slug hash
  root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  if [[ "$root" == *"/.doyaken/worktrees/"* ]]; then
    root="${root%%/.doyaken/worktrees/*}"
  fi
  [[ -n "$root" ]] || root="${PWD:-unknown}"

  name=$(basename "$root")
  slug=$(printf '%s' "$name" | tr '[:upper:]' '[:lower:]' | sed -E 's/[^a-z0-9._-]+/-/g; s/^-+//; s/-+$//')
  [[ -n "$slug" ]] || slug="repo"

  hash=""
  if command -v cksum >/dev/null 2>&1; then
    hash=$(printf '%s' "$root" | cksum 2>/dev/null | awk '{print $1}') || hash=""
  fi
  [[ -n "$hash" ]] || hash="nohash"

  printf 'repo-%s-%s\n' "$slug" "$hash"
}

# dk_scoped_session_id <raw_id>
# Add the current repo namespace to a raw worktree/branch/session identifier.
dk_scoped_session_id() {
  local raw_id="$1"
  printf '%s-%s\n' "$(dk_session_repo_key)" "$raw_id"
}

# __dk_migrate_legacy_session_file <old_path> <new_path> <new_session_id>
# Move one pre-scoped session file into the current repo scope without
# overwriting newer scoped state.
__dk_migrate_legacy_session_file() {
  local old_path="$1" new_path="$2" new_session_id="$3" tmp_file
  [[ -f "$old_path" && ! -e "$new_path" ]] || return 0

  if [[ "$old_path" == *.provider ]]; then
    tmp_file="${new_path}.tmp.$$"
    if awk -v sid="$new_session_id" '
      BEGIN { saw_session = 0 }
      /^session=/ { print "session=" sid; saw_session = 1; next }
      { print }
      END { if (!saw_session) print "session=" sid }
    ' "$old_path" > "$tmp_file" && command mv -f "$tmp_file" "$new_path"; then
      command rm -f "$old_path" 2>/dev/null || true
      return 0
    fi
    command rm -f "$tmp_file" 2>/dev/null || true
    return 0
  fi

  command mv "$old_path" "$new_path" 2>/dev/null || true
}

# dk_migrate_legacy_session_state <legacy_id> <scoped_id>
# Upgrade state created before repo-scoped session IDs existed. The legacy files
# were global, so migrate only when the scoped target does not already exist.
dk_migrate_legacy_session_state() {
  local legacy_id="$1" scoped_id="$2" suffix old_file new_file base
  [[ -n "$legacy_id" && -n "$scoped_id" && "$legacy_id" != "$scoped_id" ]] || return 0

  if [[ -d "$DK_STATE_DIR" ]]; then
    for suffix in phase times system-context log branch; do
      old_file="${DK_STATE_DIR}/${legacy_id}.${suffix}"
      new_file="${DK_STATE_DIR}/${scoped_id}.${suffix}"
      __dk_migrate_legacy_session_file "$old_file" "$new_file" "$scoped_id"
    done
  fi

  if [[ -d "$DK_LOOP_DIR" ]]; then
    for suffix in state complete active prompt findings debt config handoff-mode paused watch-pause ci.watch-lock pr.watch-lock review-state review-result complete-state provider; do
      old_file="${DK_LOOP_DIR}/${legacy_id}.${suffix}"
      new_file="${DK_LOOP_DIR}/${scoped_id}.${suffix}"
      __dk_migrate_legacy_session_file "$old_file" "$new_file" "$scoped_id"
    done

    while IFS= read -r old_file; do
      [[ -n "$old_file" && -f "$old_file" ]] || continue
      base=$(basename "$old_file")
      new_file="${DK_LOOP_DIR}/${scoped_id}${base#"$legacy_id"}"
      __dk_migrate_legacy_session_file "$old_file" "$new_file" "$scoped_id"
    done < <(find "$DK_LOOP_DIR" -maxdepth 1 -type f \( -name "${legacy_id}.phase-*.started" -o -name "${legacy_id}.phase-*.ready" -o -name "${legacy_id}.phase-*.busy" -o -name "${legacy_id}.phase-*.busy-notice" \) -print 2>/dev/null)
  fi
}

# dk_session_id [wt_name]
# Derive a stable session identifier used to key state and loop files.
#
# With argument:  "repo-<name>-<hash>-worktree-<wt_name>" — used by dk.sh
# which knows the name.
# Without argument: auto-detect from the current git directory:
#   - If inside a doyaken worktree (path contains /.doyaken/worktrees/),
#     derive from the directory name. This is stable even if the branch
#     is renamed by the SessionStart hook.
#   - Otherwise, fall back to the current branch name (slashes → dashes).
# shellcheck disable=SC2120  # Intentionally dual-mode: called with args from dk.sh, without from hooks
dk_session_id() {
  local raw_id scoped_id
  if [[ $# -ge 1 ]]; then
    raw_id="worktree-${1}"
    scoped_id=$(dk_scoped_session_id "$raw_id")
    dk_migrate_legacy_session_state "$raw_id" "$scoped_id" 2>/dev/null || true
    printf '%s\n' "$scoped_id"
    return
  fi
  local toplevel
  toplevel=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  if [[ "$toplevel" == *"/.doyaken/worktrees/"* ]]; then
    raw_id="worktree-$(basename "$toplevel")"
  else
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "default")
    raw_id="${branch//\//-}"
  fi
  scoped_id=$(dk_scoped_session_id "$raw_id")
  dk_migrate_legacy_session_state "$raw_id" "$scoped_id" 2>/dev/null || true
  printf '%s\n' "$scoped_id"
}

# dk_unique_session_id
# Generate a session ID unique to this shell invocation, for concurrent dkloop isolation.
# Appends PID, epoch seconds, and $RANDOM to the branch-based ID so multiple dkloop
# calls on the same branch get distinct state/prompt files — even if started in the
# same second ($RANDOM provides 0-32767 range, available in both bash and zsh).
dk_unique_session_id() {
  echo "$(dk_session_id)-$$-$(date +%s)-${RANDOM}"
}

# dk_state_file <session_id>  — phase state file path
dk_state_file() { echo "${DK_STATE_DIR}/${1}.phase"; }

# dk_times_file <session_id>  — phase timing file path
dk_times_file() { echo "${DK_STATE_DIR}/${1}.times"; }

# dk_loop_file <session_id>   — loop iteration state file path
dk_loop_file() { echo "${DK_LOOP_DIR}/${1}.state"; }

# dk_complete_file <session_id> — loop completion signal file path
dk_complete_file() { echo "${DK_LOOP_DIR}/${1}.complete"; }

# dk_active_file <session_id>  — loop activation signal file path (for in-session /dkloop)
dk_active_file() { echo "${DK_LOOP_DIR}/${1}.active"; }

# dk_prompt_file <session_id>  — original prompt file path (for dkloop prompt persistence)
dk_prompt_file() { echo "${DK_LOOP_DIR}/${1}.prompt"; }

# dk_context_file <session_id> — system prompt context file (survives compaction via --append-system-prompt-file)
dk_context_file() { echo "${DK_STATE_DIR}/${1}.system-context"; }

# dk_log_file <session_id> — structured phase execution log (TSV)
dk_log_file() { echo "${DK_STATE_DIR}/${1}.log"; }

# dk_branch_file <session_id> — branch last used by this lifecycle session
dk_branch_file() { echo "${DK_STATE_DIR}/${1}.branch"; }

# dk_findings_file <session_id> — findings hash history for stuck loop detection
dk_findings_file() { echo "${DK_LOOP_DIR}/${1}.findings"; }

# dk_debt_file <session_id> — technical debt ledger (append-only markdown)
dk_debt_file() { echo "${DK_LOOP_DIR}/${1}.debt"; }

# dk_loop_config_file <session_id> — loop configuration (phase:promise:audit_file_path)
dk_loop_config_file() { echo "${DK_LOOP_DIR}/${1}.config"; }

# dk_handoff_mode_file <session_id> — marker for same-session phase handoff
dk_handoff_mode_file() { echo "${DK_LOOP_DIR}/${1}.handoff-mode"; }

# dk_paused_file <session_id> — one-shot marker allowing an inline paused session to exit
dk_paused_file() { echo "${DK_LOOP_DIR}/${1}.paused"; }

# dk_watch_pause_file <session_id> — marker that scheduled CI/PR watchers should no-op
dk_watch_pause_file() { echo "${DK_LOOP_DIR}/${1}.watch-pause"; }

# dk_watch_pause_ttl_seconds — watch-pause lifetime; 0 means no automatic expiry
dk_watch_pause_ttl_seconds() {
  local ttl="${DOYAKEN_WATCH_PAUSE_TTL_SECONDS:-3600}"
  if [[ "$ttl" =~ ^[0-9]+$ ]]; then
    echo "$ttl"
  else
    echo "3600"
  fi
}

# dk_watch_pause_active <session_id> — true when scheduled watchers should skip work
dk_watch_pause_active() {
  local session_id="$1" pause_file raw epoch now ttl age
  [[ "${DOYAKEN_WATCH_IGNORE_PAUSE:-0}" == "1" ]] && return 1

  pause_file=$(dk_watch_pause_file "$session_id")
  [[ -f "$pause_file" ]] || return 1

  raw=$(cat "$pause_file" 2>/dev/null || echo "")
  epoch="${raw%%$'\t'*}"
  if [[ ! "$epoch" =~ ^[0-9]+$ ]]; then
    rm -f "$pause_file" 2>/dev/null || true
    return 1
  fi

  ttl=$(dk_watch_pause_ttl_seconds)
  [[ "$ttl" -gt 0 ]] || return 0

  now=$(date +%s)
  age=$((now - epoch))
  if [[ "$age" -lt "$ttl" ]]; then
    return 0
  fi

  rm -f "$pause_file" 2>/dev/null || true
  return 1
}

# dk_write_watch_pause <session_id> [reason] — atomically write a watcher pause marker
dk_write_watch_pause() {
  local session_id="$1" reason="${2:-user-prompt}" pause_file tmp_file
  [[ -n "$session_id" ]] || return 0
  pause_file=$(dk_watch_pause_file "$session_id")
  mkdir -p "$(dirname "$pause_file")"
  tmp_file="${pause_file}.tmp.$$"
  if ! printf '%s\t%s\n' "$(date +%s)" "$reason" > "$tmp_file" || ! command mv -f "$tmp_file" "$pause_file"; then
    command rm -f "$tmp_file" 2>/dev/null
    return 1
  fi
}

# dk_clear_watch_pause <session_id> — remove any watcher pause marker for the session
dk_clear_watch_pause() {
  local session_id="$1"
  [[ -n "$session_id" ]] || return 0
  rm -f "$(dk_watch_pause_file "$session_id")" 2>/dev/null || true
}

# dk_watch_cycle_timeout_seconds — max runtime for one scheduled watcher cycle
dk_watch_cycle_timeout_seconds() {
  local timeout="${DOYAKEN_WATCH_CYCLE_TIMEOUT_SECONDS:-120}"
  if [[ "$timeout" =~ ^[0-9]+$ ]]; then
    echo "$timeout"
  else
    echo "120"
  fi
}

# dk_watch_command_timeout_seconds — max runtime for a single watcher shell command
dk_watch_command_timeout_seconds() {
  local timeout="${DOYAKEN_WATCH_COMMAND_TIMEOUT_SECONDS:-30}"
  if [[ "$timeout" =~ ^[0-9]+$ ]]; then
    echo "$timeout"
  else
    echo "30"
  fi
}

# dk_watch_lock_file <session_id> <watch_name> — per-watcher overlap guard
dk_watch_lock_file() { echo "${DK_LOOP_DIR}/${1}.${2}.watch-lock"; }

# dk_watch_lock_acquire <session_id> <watch_name> — acquire or reject active watcher lock
dk_watch_lock_acquire() {
  local session_id="$1" watch_name="$2" lock_file raw epoch now age timeout
  [[ -n "$session_id" && -n "$watch_name" ]] || return 1

  lock_file=$(dk_watch_lock_file "$session_id" "$watch_name")
  mkdir -p "$(dirname "$lock_file")"

  if ( set -C; printf '%s\t%s\n' "$(date +%s)" "$$" > "$lock_file" ) 2>/dev/null; then
    return 0
  fi

  raw=$(cat "$lock_file" 2>/dev/null || echo "")
  epoch="${raw%%$'\t'*}"
  timeout=$(dk_watch_cycle_timeout_seconds)
  now=$(date +%s)

  if [[ ! "$epoch" =~ ^[0-9]+$ ]]; then
    rm -f "$lock_file" 2>/dev/null || true
  else
    age=$((now - epoch))
    [[ "$timeout" -gt 0 && "$age" -lt "$timeout" ]] && return 1
    rm -f "$lock_file" 2>/dev/null || true
  fi

  ( set -C; printf '%s\t%s\n' "$(date +%s)" "$$" > "$lock_file" ) 2>/dev/null
}

# dk_watch_lock_release <session_id> <watch_name> — release a watcher overlap lock
dk_watch_lock_release() {
  local session_id="$1" watch_name="$2"
  [[ -n "$session_id" && -n "$watch_name" ]] || return 0
  rm -f "$(dk_watch_lock_file "$session_id" "$watch_name")" 2>/dev/null || true
}

# dk_run_with_timeout <seconds> <command> [args...] — portable timeout wrapper
dk_run_with_timeout() {
  local timeout="$1" marker cmd_pid watchdog_pid cmd_status
  shift
  [[ $# -gt 0 ]] || return 2

  if [[ ! "$timeout" =~ ^[0-9]+$ || "$timeout" -eq 0 ]]; then
    "$@"
    return $?
  fi

  marker="${TMPDIR:-/tmp}/doyaken-timeout-${$}-${RANDOM}"
  "$@" &
  cmd_pid=$!

  (
    sleep "$timeout" 2>/dev/null
    if kill -0 "$cmd_pid" 2>/dev/null; then
      : > "$marker"
      kill "$cmd_pid" 2>/dev/null || true
      sleep 2 2>/dev/null
      kill -KILL "$cmd_pid" 2>/dev/null || true
    fi
  ) &
  watchdog_pid=$!

  cmd_status=0
  wait "$cmd_pid" || cmd_status=$?
  kill "$watchdog_pid" 2>/dev/null || true
  wait "$watchdog_pid" 2>/dev/null || true

  if [[ -f "$marker" ]]; then
    rm -f "$marker" 2>/dev/null || true
    return 124
  fi

  rm -f "$marker" 2>/dev/null || true
  return "$cmd_status"
}

# dk_review_state_file <session_id> — review sub-loop clean pass counter (survives interrupts)
dk_review_state_file() { echo "${DK_LOOP_DIR}/${1}.review-state"; }

# dk_review_result_file <session_id> — per-iteration review result ("CLEAN" or "FINDINGS:N")
dk_review_result_file() { echo "${DK_LOOP_DIR}/${1}.review-result"; }

# dk_complete_state_file <session_id> — Phase 6 cycle bookkeeping ("cycle_count:last_check_epoch")
# Survives interrupts so resuming Phase 6 picks up the same cycle counter.
dk_complete_state_file() { echo "${DK_LOOP_DIR}/${1}.complete-state"; }

# dk_provider_state_file <session_id> — resolved provider engine for hook fallback
dk_provider_state_file() { echo "${DK_LOOP_DIR}/${1}.provider"; }

# dk_phase_started_file <session_id> <phase> — marker that the phase skill/workflow started
dk_phase_started_file() { echo "${DK_LOOP_DIR}/${1}.phase-${2}.started"; }

# dk_phase_ready_file <session_id> <phase> — marker that a pre-audit phase gate is satisfied
dk_phase_ready_file() { echo "${DK_LOOP_DIR}/${1}.phase-${2}.ready"; }

# dk_phase_busy_file <session_id> <phase> — marker that async phase work is still running
dk_phase_busy_file() { echo "${DK_LOOP_DIR}/${1}.phase-${2}.busy"; }

# dk_phase_busy_notice_file <session_id> <phase> — last busy-gate notice timestamp
dk_phase_busy_notice_file() { echo "${DK_LOOP_DIR}/${1}.phase-${2}.busy-notice"; }

# dk_log_phase <session_id> <step> <phase_name> <start_epoch> <end_epoch> <duration_s> <iterations> <status> <exit_code>
# Append a TSV row to the structured phase log. Creates the header on first write.
dk_log_phase() {
  local session_id="$1" step="$2" phase_name="$3"
  local start_epoch="$4" end_epoch="$5" duration_s="$6"
  local iterations="$7" phase_status="$8" exit_code="$9"
  local log_file
  log_file=$(dk_log_file "$session_id")

  mkdir -p "$(dirname "$log_file")"
  if [[ ! -f "$log_file" ]]; then
    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "session_id" "phase" "phase_name" "start_epoch" "end_epoch" \
      "duration_s" "iterations" "status" "exit_code" > "$log_file"
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$session_id" "$step" "$phase_name" "$start_epoch" "$end_epoch" \
    "$duration_s" "$iterations" "$phase_status" "$exit_code" >> "$log_file"
}

# dk_record_session_branch <session_id> [repo_dir]
# Persist the branch used by this lifecycle. In-place sessions need this to
# resume safely because the checkout can be moved to a different branch between
# runs. Worktree sessions record it too for diagnostics.
dk_record_session_branch() {
  local session_id="$1" repo_dir="${2:-.}" branch branch_file tmp_file
  [[ -n "$session_id" ]] || return 0
  branch=$(git -C "$repo_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  [[ -n "$branch" && "$branch" != "HEAD" ]] || return 0

  branch_file=$(dk_branch_file "$session_id")
  mkdir -p "$(dirname "$branch_file")"
  tmp_file="${branch_file}.tmp.$$"
  if ! printf '%s\n' "$branch" > "$tmp_file" || ! command mv -f "$tmp_file" "$branch_file"; then
    command rm -f "$tmp_file" 2>/dev/null
    return 1
  fi
}

# dk_cleanup_session <session_id>
# Remove all loop and phase state files for a session. Safe to call when dirs don't exist.
dk_cleanup_session() {
  local sid="$1"
  if [[ -d "$DK_LOOP_DIR" ]]; then
    rm -f "$(dk_loop_file "$sid")" "$(dk_complete_file "$sid")" "$(dk_active_file "$sid")" "$(dk_prompt_file "$sid")" "$(dk_findings_file "$sid")" "$(dk_debt_file "$sid")" "$(dk_loop_config_file "$sid")" "$(dk_handoff_mode_file "$sid")" "$(dk_paused_file "$sid")" "$(dk_watch_pause_file "$sid")" "$(dk_watch_lock_file "$sid" ci)" "$(dk_watch_lock_file "$sid" pr)" "$(dk_review_state_file "$sid")" "$(dk_review_result_file "$sid")" "$(dk_complete_state_file "$sid")" "$(dk_provider_state_file "$sid")" 2>/dev/null
    find "$DK_LOOP_DIR" -maxdepth 1 -type f \( -name "${sid}.phase-*.started" -o -name "${sid}.phase-*.ready" -o -name "${sid}.phase-*.busy" -o -name "${sid}.phase-*.busy-notice" \) -exec rm -f {} + 2>/dev/null || true
  fi
  [[ -d "$DK_STATE_DIR" ]] && rm -f "$(dk_state_file "$sid")" "$(dk_times_file "$sid")" "$(dk_context_file "$sid")" "$(dk_log_file "$sid")" "$(dk_branch_file "$sid")" 2>/dev/null
}
