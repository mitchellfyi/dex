# shellcheck shell=bash
# Doyaken shared library — session ID and state file helpers
#
# Session IDs key all state and loop files. Path-based derivation makes them
# stable across branch renames (the SessionStart hook may rename branches to
# follow project conventions). See: docs/autonomous-mode.md § State Management
#
# Scope: state/loop dirs are global (~/.claude/.doyaken-{phases,loops}/) so
# session IDs must be unique across repos. Worktree-based IDs include the
# worktree name (e.g., "worktree-ticket-999") which is unique per-repo.
# Branch-based IDs (fallback for non-worktree use) could collide if two repos
# share the same branch name — this is acceptable since dkloop cleans state
# after each run, so stale collisions are unlikely.
#
# Concurrency: dk_unique_session_id() appends PID+epoch to avoid collisions
# when multiple dkloop invocations run on the same branch. The unique ID is
# passed to Claude via DOYAKEN_SESSION_ID env var so the stop hook resolves
# to the same unique ID. See: hooks/phase-loop.sh line 29.

# dk_session_id [wt_name]
# Derive a stable session identifier used to key state and loop files.
#
# With argument:  "worktree-<wt_name>" — used by dk.sh which knows the name.
# Without argument: auto-detect from the current git directory:
#   - If inside a doyaken worktree (path contains /.doyaken/worktrees/),
#     derive from the directory name. This is stable even if the branch
#     is renamed by the SessionStart hook.
#   - Otherwise, fall back to the current branch name (slashes → dashes).
# shellcheck disable=SC2120  # Intentionally dual-mode: called with args from dk.sh, without from hooks
dk_session_id() {
  if [[ $# -ge 1 ]]; then
    echo "worktree-${1}"
    return
  fi
  local toplevel
  toplevel=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  if [[ "$toplevel" == *"/.doyaken/worktrees/"* ]]; then
    echo "worktree-$(basename "$toplevel")"
  else
    local branch
    branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "default")
    echo "${branch//\//-}"
  fi
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

# dk_cleanup_session <session_id>
# Remove all loop and phase state files for a session. Safe to call when dirs don't exist.
dk_cleanup_session() {
  local sid="$1"
  [[ -d "$DK_LOOP_DIR" ]]  && rm -f "$(dk_loop_file "$sid")" "$(dk_complete_file "$sid")" "$(dk_active_file "$sid")" "$(dk_prompt_file "$sid")" "$(dk_findings_file "$sid")" "$(dk_debt_file "$sid")" "$(dk_loop_config_file "$sid")" "$(dk_handoff_mode_file "$sid")" "$(dk_paused_file "$sid")" "$(dk_review_state_file "$sid")" "$(dk_review_result_file "$sid")" "$(dk_complete_state_file "$sid")" "$(dk_provider_state_file "$sid")" "${DK_LOOP_DIR}/${sid}".phase-*.started "${DK_LOOP_DIR}/${sid}".phase-*.ready 2>/dev/null
  [[ -d "$DK_STATE_DIR" ]] && rm -f "$(dk_state_file "$sid")" "$(dk_times_file "$sid")" "$(dk_context_file "$sid")" "$(dk_log_file "$sid")" 2>/dev/null
}
