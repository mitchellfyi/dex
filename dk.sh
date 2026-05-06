# shellcheck shell=bash disable=SC2296
# ^ dk.sh is zsh-only; SC2296 suppresses zsh parameter expansion syntax warnings.
# Doyaken — Shell functions (zsh only)
#
# Source this in ~/.zshrc:
#   source $DOYAKEN_DIR/dk.sh
#
# Requires zsh — uses zsh-specific syntax (e.g., ${(j: :)@} for array joining).
# Hook scripts (hooks/*.sh) use #!/usr/bin/env bash. Library files (lib/*.sh)
# use bash/zsh-compatible syntax and are sourced by both dk.sh and hook scripts.
#
# Provides:
#   doyaken <command>       Manage Doyaken installation
#   dk <number>             Start/resume the full autonomous lifecycle (Plan → Complete) for a ticket
#   dk "description"        Same, for a task without a ticket
#   dk --resume             Resume the most recent session
#   dk --from-pr <N>        Resume session linked to a PR
#   dkcomplete              Standalone completion workflow (recovery / non-dk PRs)
#   dkreviewloop            Standalone 3-clean-passes review of staged/unstaged/unpushed/PR diff
#   dkrm <number|name|--all>  Remove a worktree
#   dkls                   List worktrees
#   dkclean                Clean stale worktrees + gone branches
#   dkloop <prompt>         Run a prompt until fully implemented

if [[ -z "${DOYAKEN_DIR:-}" ]]; then
  echo "ERROR: DOYAKEN_DIR not set. Run 'dk install' first." >&2
  return 1
fi
source "$DOYAKEN_DIR/lib/common.sh"

# ─── doyaken CLI ─────────────────────────────────────────────────────────
# unalias/unfunction before each function definition so this file can be
# re-sourced (e.g. via `doyaken reload`) without "already defined" errors.

unalias doyaken 2>/dev/null; unfunction doyaken 2>/dev/null
doyaken() {
  local cmd="${1:-help}"
  shift 2>/dev/null || true

  case "$cmd" in
    install)   bash "$DOYAKEN_DIR/bin/install.sh" "$@" ;;
    uninstall) bash "$DOYAKEN_DIR/bin/uninstall.sh" "$@" ;;
    init)      bash "$DOYAKEN_DIR/bin/init.sh" "$@" ;;
    config)    bash "$DOYAKEN_DIR/bin/config.sh" "$@" ;;
    provider)  dk_provider_command "$@" ;;
    uninit)    bash "$DOYAKEN_DIR/bin/uninit.sh" "$@" ;;
    reload)
      source "$DOYAKEN_DIR/dk.sh"
      echo "Reloaded Doyaken shell functions."
      ;;
    status)    bash "$DOYAKEN_DIR/bin/status.sh" "$@" ;;
    help|--help|-h)
      echo "Doyaken — workflow automation for Claude Code"
      echo ""
      echo "Commands:"
      echo "  dk install          Global install (skills, agents, hooks, zshrc)"
      echo "  dk uninstall        Global uninstall"
      echo "  dk init             Bootstrap current repo for Doyaken"
      echo "  dk config           Configure integrations (ticket tracker, Figma, etc.)"
      echo "  dk provider         Configure provider/model execution profiles"
      echo "  dk uninit           Remove Doyaken from current repo"
      echo "  dk reload           Reload shell functions after editing dk.sh"
      echo "  dk status           Show installation status"
      echo ""
      echo "Worktree commands:"
      echo "  dk <number>            Run autonomous lifecycle (Plan → Complete) for a ticket"
      echo "  dk \"<description>\"     Same, for a task without a ticket"
      echo "  dk --no-worktree <task> Run lifecycle in the current checkout instead"
      echo "  dk --resume            Resume the most recent session"
      echo "  dk --from-pr <N>      Resume session linked to a PR"
      echo "  dk revert <N> [phase] Revert worktree to a phase checkpoint"
      echo "  dk log [session_id]   Show structured phase execution log"
      echo "  dkrm <number|name>    Remove a worktree"
      echo "  dkrm --all            Remove all worktrees"
      echo "  dkls                  List worktrees"
      echo "  dkclean               Clean stale worktrees + gone branches"
      echo ""
      echo "Standalone completion (recovery / non-dk PRs):"
      echo "  dkcomplete             Monitor CI/reviews, address comments, close ticket"
      echo ""
      echo "Standalone review (3-clean-passes loop, no full lifecycle needed):"
      echo "  dkreviewloop           Auto-detect scope (staged → unstaged → unpushed → PR diff) and review"
      echo ""
      echo "Prompt loop:"
      echo "  dkloop <prompt>          Run a prompt until fully implemented"
      echo ""
      echo "Autonomous lifecycle phases (run automatically by dk):"
      echo "  1. Plan            Gather context, draft plan, get approval"
      echo "  2. Implement       Work through tasks with TDD"
      echo "  3. Review          Adversarial code review (3 clean passes required)"
      echo "  4. Verify & Commit Format, lint, typecheck, test, then commit + push"
      echo "  5. PR              Generate PR description, create draft PR + attach reviewers"
      echo "  6. Complete        Mark ready, request reviewers, monitor CI/reviews, close ticket"
      ;;
    revert)
      # dk revert <ticket> [phase] — revert worktree to a phase checkpoint
      local raw="${1:-}"
      if [[ -z "$raw" ]]; then
        echo "Usage: dk revert <ticket|name> [phase]"
        return 1
      fi
      local rev_phase="${2:-}"
      local rev_name
      if __dk_is_ticket "$raw"; then
        rev_name="ticket-${raw//[^0-9]/}"
      else
        rev_name="task-$(dk_slugify "$raw")"
      fi
      local rev_root
      rev_root=$(dk_repo_root) || return 1
      local rev_dir="${rev_root}/.doyaken/worktrees/${rev_name}"
      if [[ ! -d "$rev_dir" ]]; then
        dk_error "Worktree ${rev_name} not found."
        return 1
      fi
      if [[ -z "$rev_phase" ]]; then
        # Find the most recent checkpoint
        local latest_tag
        latest_tag=$(git -C "$rev_dir" tag -l 'dk-checkpoint/phase-*' --sort=-version:refname 2>/dev/null | head -1)
        if [[ -z "$latest_tag" ]]; then
          dk_info "No checkpoints found for ${rev_name}."
          return 1
        fi
        rev_phase="${latest_tag##*-}"
      fi
      echo "Reverting ${rev_name} to checkpoint for phase ${rev_phase}..."
      dk_revert_to_checkpoint "$rev_phase" "$rev_dir"
      ;;
    log)
      bash "$DOYAKEN_DIR/bin/log.sh" "$@"
      ;;
    *)
      dk_error "Unknown command: $cmd"
      dk_info "Run 'dk help' for usage."
      return 1
      ;;
  esac
}

# ─── Phase configuration ────────────────────────────────────────────────────

# Capture explicit user overrides before provider profiles fill defaults.
# shellcheck disable=SC2034
DK_USER_CLAUDE_MODEL="${DK_CLAUDE_MODEL:-}"
if [[ -n "${DK_PROVIDER_LAST_CLAUDE_MODEL:-}" && "$DK_USER_CLAUDE_MODEL" == "$DK_PROVIDER_LAST_CLAUDE_MODEL" ]] || [[ -n "${DK_PROVIDER_LAST_PROVIDER_MODEL:-}" && "$DK_USER_CLAUDE_MODEL" == "$DK_PROVIDER_LAST_PROVIDER_MODEL" ]]; then
  DK_USER_CLAUDE_MODEL=""
fi
# shellcheck disable=SC2034
DK_USER_PLAN_MODEL="${DK_PLAN_MODEL:-}"
if [[ -n "${DK_PROVIDER_LAST_PLAN_MODEL:-}" && "$DK_USER_PLAN_MODEL" == "$DK_PROVIDER_LAST_PLAN_MODEL" ]] || [[ -n "${DK_PROVIDER_LAST_PROVIDER_PLAN_MODEL:-}" && "$DK_USER_PLAN_MODEL" == "$DK_PROVIDER_LAST_PROVIDER_PLAN_MODEL" ]]; then
  DK_USER_PLAN_MODEL=""
fi
# shellcheck disable=SC2034
DK_USER_CLAUDE_EFFORT="${DK_CLAUDE_EFFORT:-}"
if [[ -n "${DK_PROVIDER_LAST_CLAUDE_EFFORT:-}" && "$DK_USER_CLAUDE_EFFORT" == "$DK_PROVIDER_LAST_CLAUDE_EFFORT" ]] || [[ -n "${DK_PROVIDER_LAST_PROVIDER_EFFORT:-}" && "$DK_USER_CLAUDE_EFFORT" == "$DK_PROVIDER_LAST_PROVIDER_EFFORT" ]]; then
  DK_USER_CLAUDE_EFFORT=""
fi
# shellcheck disable=SC2034
DK_USER_PLAN_EFFORT="${DK_PLAN_EFFORT:-}"
if [[ -n "${DK_PROVIDER_LAST_PLAN_EFFORT:-}" && "$DK_USER_PLAN_EFFORT" == "$DK_PROVIDER_LAST_PLAN_EFFORT" ]] || [[ -n "${DK_PROVIDER_LAST_PROVIDER_PLAN_EFFORT:-}" && "$DK_USER_PLAN_EFFORT" == "$DK_PROVIDER_LAST_PROVIDER_PLAN_EFFORT" ]]; then
  DK_USER_PLAN_EFFORT=""
fi

# Default Claude flags for all dk-launched sessions:
#   --chrome           Enable browser automation tools (MCP)
#   --model            Use Opus for autonomous multi-phase work by default.
#                      Override with DK_CLAUDE_MODEL for gateways/custom models.
#   --permission-mode bypassPermissions  No interactive prompts (autonomous)
#   --effort           Maximum reasoning effort for complex tasks by default.
#                      Override with DK_CLAUDE_EFFORT if the provider differs.
unalias __dk_refresh_provider 2>/dev/null; unfunction __dk_refresh_provider 2>/dev/null
__dk_refresh_provider() {
  dk_provider_apply || return 1
  DK_CLAUDE_FLAGS=(--chrome --model "$DK_CLAUDE_MODEL" --permission-mode bypassPermissions --effort "$DK_CLAUDE_EFFORT")
  DK_PLAN_FLAGS=(--chrome --model "$DK_PLAN_MODEL" --permission-mode bypassPermissions --effort "$DK_PLAN_EFFORT")
}

DK_CLAUDE_FLAGS=(--chrome --model "${DK_CLAUDE_MODEL:-opus}" --permission-mode bypassPermissions --effort "${DK_CLAUDE_EFFORT:-max}")
DK_PLAN_FLAGS=(--chrome --model "${DK_PLAN_MODEL:-${DK_CLAUDE_MODEL:-opus}}" --permission-mode bypassPermissions --effort "${DK_PLAN_EFFORT:-${DK_CLAUDE_EFFORT:-max}}")

# Phase 1 uses bypassPermissions to avoid interactive prompts. Claude calls
# EnterPlanMode as its first action to enforce read-only until user approves
# via ExitPlanMode.

unalias __dk_claude 2>/dev/null; unfunction __dk_claude 2>/dev/null
__dk_claude() {
  dk_provider_claude "$@"
}

unalias __dk_provider_prompt 2>/dev/null; unfunction __dk_provider_prompt 2>/dev/null
__dk_provider_prompt() {
  dk_provider_prompt
}

unalias __dk_phase_message 2>/dev/null; unfunction __dk_phase_message 2>/dev/null
__dk_phase_message() {
  local step="$1"
  local raw_input="${2:-}"
  local workspace_mode="${3:-worktree}"
  local wt_dir="${4:-}"
  printf '%s\n' "${DK_PHASE_MESSAGES[$step]}"
  __dk_provider_prompt
  if [[ -n "$raw_input" ]] || [[ "$workspace_mode" == "in-place" ]]; then
    printf '%s\n' ""
    printf '%s\n' "## Doyaken Request Context"
    [[ -n "$raw_input" ]] && printf 'Original request: %s\n' "$raw_input"
    if [[ "$workspace_mode" == "in-place" ]]; then
      printf '%s\n' "Workspace mode: in-place. No Doyaken worktree was created."
      [[ -n "$wt_dir" ]] && printf 'Current checkout: %s\n' "$wt_dir"
      printf '%s\n' "Use the current checkout and Doyaken-managed branch; do not create or switch branches unless ticket setup instructions explicitly require a branch rename."
    fi
  fi
}

# Phase definitions (zsh arrays are 1-indexed, so index 1 = Phase 1)
# Phases 1-6 all run autonomously via `dk`. Phase 6 marks the PR ready, requests
# the configured reviewers, monitors CI/reviews, and closes the ticket.
DK_PHASE_NAMES=("Plan" "Implement" "Review" "Verify & Commit" "PR" "Complete")

DK_PHASE_PROMISES=(\
  "PHASE_1_COMPLETE" \
  "PHASE_2_COMPLETE" \
  "PHASE_3_COMPLETE" \
  "PHASE_4_COMPLETE" \
  "PHASE_5_COMPLETE" \
  "DOYAKEN_TICKET_COMPLETE" \
)

DK_PHASE_MESSAGES=(\
  "Call EnterPlanMode now, then run /dkplan — gather context, explore the codebase, and create your implementation plan. When the plan is ready, use ExitPlanMode to present it for approval. After the user approves the plan, immediately stop this Phase 1 session so the dk wrapper can launch Phase 2 automatically. Do NOT tell the user to run /dkimplement and do NOT wait for another prompt." \
  "The plan is approved. You MUST invoke the Skill tool with skill: \"dkimplement\" to begin implementation. Do NOT implement ad-hoc — the skill enforces TDD and quality gates. SCOPE BOUNDARIES: implementation and testing ONLY. Do NOT commit, push, create branches, or create PRs during this phase — those are handled by later phases. When done, stop — the audit loop will verify your work." \
  "Run an adversarial code review of the implementation. Follow the review audit prompt exactly: run /dkreview --single-pass, perform the 4-pass manual review (Logic, Structure, Security, Holistic), spawn the self-reviewer agent, build the merged findings inventory, and fix all issues. Write the review result signal file after building the inventory. SCOPE BOUNDARIES: review and fix ONLY. Do NOT commit, push, or create PRs. When review is clean, stop — the audit loop will verify." \
  "Invoke the Skill tool with skill: \"dkverify\" to run the quality pipeline (format, lint, typecheck, test). Fix any failures and re-run until all green. Then invoke skill: \"dkcommit\" to commit and push. SCOPE BOUNDARIES: verify and commit ONLY. Do NOT create PRs or modify implementation beyond fixing verify failures. When pushed, stop — the audit loop will verify." \
  "Invoke the Skill tool with skill: \"dkpr\" to generate the PR description, create the draft PR, and attach the configured 'request' reviewers from doyaken.md § Reviewers. SCOPE BOUNDARIES: PR creation and description ONLY. Do NOT mark the PR ready for review (Phase 6 owns that), do NOT post @mention comments, do NOT modify implementation code. When done, stop — the audit loop will verify." \
  "Invoke the Skill tool with skill: \"dkcomplete\". Phase 6 follows the cycle-loop audit prompt: mark the PR ready, request reviewers from doyaken.md § Reviewers, post @mention comments for mention-type reviewers, launch /loop 2m /dkwatchci and /loop 5m /dkwatchpr, wait DOYAKEN_COMPLETE_WAIT_MINUTES per cycle, address comments via /dkprreview, re-request reviewers after each push, and close the ticket when CI is green and all reviewers have approved. Stop — the audit loop will verify." \
)

# Audit prompt file basenames (must match prompts/phase-audits/ filenames)
DK_PHASE_AUDIT_FILES=("1-plan" "2-implement" "3-review" "4-verify" "5-pr" "6-complete")

# Session timeout in seconds — single budget for the entire dk run (all phases).
# Default: 86400 (24 hours). Set to 0 to disable.
# Override: DOYAKEN_SESSION_TIMEOUT=14400 (4h)
DK_SESSION_TIMEOUT=86400

# Minimum audit iterations per phase before the Stop hook authorizes completion.
# Phase 2 (Implement) requires 1 pass (completeness check; deep review is Phase 3).
# Phase 3 (Review) uses a shell-managed sub-loop with DK_REVIEW_CLEAN_PASSES instead.
# Phase 6 (Complete) wait windows are enforced inside the audit prompt; min 1 here.
# Other phases require 1 pass (the audit prompt must be followed at least once).
# Override: DOYAKEN_PHASE_2_MIN_AUDITS=5
# zsh 1-indexed: [1]=Plan, [2]=Implement, [3]=Review, [4]=Verify, [5]=PR, [6]=Complete
DK_PHASE_MIN_AUDITS=("1" "1" "1" "1" "1" "1")

# Review sub-loop configuration (Phase 3 only).
# The shell manages the outer loop — each iteration is a fresh Claude session.
# The Stop hook enforces one audit pass per iteration (MIN_AUDITS=1).
# DK_REVIEW_CLEAN_PASSES: consecutive clean iterations required to advance.
# DK_REVIEW_MAX_ITERATIONS: safety net — stop after this many iterations regardless.
# Override: DOYAKEN_REVIEW_CLEAN_PASSES=5, DOYAKEN_REVIEW_MAX_ITERATIONS=15
DK_REVIEW_CLEAN_PASSES=3
DK_REVIEW_MAX_ITERATIONS=10

# Phase 6 (Complete) cycle configuration.
# DK_COMPLETE_MAX_CYCLES: max review cycles before escalating to user (default 3).
# DK_COMPLETE_WAIT_MINUTES: minimum wait window per cycle in minutes (default 30).
# Override: DOYAKEN_COMPLETE_MAX_CYCLES=5, DOYAKEN_COMPLETE_WAIT_MINUTES=15
DK_COMPLETE_MAX_CYCLES=3
DK_COMPLETE_WAIT_MINUTES=30

# Per-phase timeouts are disabled by default (session timeout covers them).
# Set per-phase: DOYAKEN_PHASE_2_TIMEOUT=3600
# Set all phases: DOYAKEN_PHASE_TIMEOUT=7200
# zsh 1-indexed: [1]=Plan, [2]=Implement, [3]=Review, [4]=Verify, [5]=PR, [6]=Complete
DK_PHASE_TIMEOUTS=("0" "0" "0" "0" "0" "0")

# ─── Internal helpers ───────────────────────────────────────────────────────

# __dk_write_state <file> <content>
# Atomic file write via temp+mv — crash-safe (same pattern as phase-loop.sh).
# On crash mid-write, the temp file is lost and the original is untouched.
__dk_write_state() {
  local file="$1" content="$2"
  mkdir -p "$(dirname "$file")"
  local tmp="${file}.tmp.$$"
  if ! echo "$content" > "$tmp" || ! mv "$tmp" "$file"; then
    rm -f "$tmp"
    return 1
  fi
}

# __dk_phase_timeout <step>
# Resolve the effective timeout for a phase (seconds). Returns 0 to disable.
# Priority: DOYAKEN_PHASE_N_TIMEOUT > DOYAKEN_PHASE_TIMEOUT > DK_PHASE_TIMEOUTS[step]
__dk_phase_timeout() {
  local step="$1"
  # shellcheck disable=SC2034  # used via zsh ${(P)env_var} indirect expansion below
  local env_var="DOYAKEN_PHASE_${step}_TIMEOUT"
  if [[ -n "${(P)env_var:-}" ]]; then
    echo "${(P)env_var}"
  elif [[ -n "${DOYAKEN_PHASE_TIMEOUT:-}" ]]; then
    echo "$DOYAKEN_PHASE_TIMEOUT"
  else
    echo "${DK_PHASE_TIMEOUTS[$step]:-0}"
  fi
}

# __dk_classify_exit <exit_code> <step> <session_id>
# Classify a phase's exit into a status marker (inspired by autoresearch's
# keep/discard/crash statuses). Returns one of:
#   advance  — phase completed successfully (.complete file was written)
#   timeout  — killed by wall-clock watchdog
#   interrupt — user sent Ctrl+C (SIGINT)
#   max-iter — audit/review loop exhausted without completion
#   crash    — unexpected non-zero exit
__dk_classify_exit() {
  local exit_code="$1" step="$2" session_id="$3"
  if [[ $exit_code -eq 0 ]]; then
    # phase-loop.sh cleans up .complete on success but leaves
    # no .complete on max-iterations (also exit 0). Check the loop state file:
    # if it still exists, phase-loop.sh didn't clean it up via the .complete
    # path, meaning max-iterations was hit.
    local loop_file
    loop_file=$(dk_loop_file "$session_id")
    if [[ -f "$loop_file" ]]; then
      echo "max-iter"
      return
    fi
    echo "advance"
  elif [[ $exit_code -eq 88 ]]; then
    echo "max-iter"
  elif [[ $exit_code -eq 143 ]] || [[ $exit_code -eq 137 ]]; then
    echo "timeout"
  elif [[ $exit_code -eq 130 ]]; then
    echo "interrupt"
  else
    echo "crash"
  fi
}

# __dk_log_phase <session_id> <step> <phase_name> <start_epoch> <end_epoch> <duration_s> <iterations> <status> <exit_code>
# Append a TSV row to the structured phase log. Creates the header on first write.
# Inspired by autoresearch's TSV experiment results logging.
__dk_log_phase() {
  local session_id="$1" step="$2" phase_name="$3"
  local start_epoch="$4" end_epoch="$5" duration_s="$6"
  local iterations="$7" phase_status="$8" exit_code="$9"
  local log_file
  log_file=$(dk_log_file "$session_id")

  # Write header if this is a new log file
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

# dk_default_branch is provided by lib/git.sh (sourced via lib/common.sh)

# __dk_is_ticket <string>
# Returns 0 if the string looks like a ticket reference (bare number, prefixed
# like ENG-999, ticket-999). Returns 1 otherwise (freeform task description).
# Used by __dk_setup_worktree and dkrm to consistently classify user input.
__dk_is_ticket() {
  [[ "$1" =~ ^[[:space:]]*[a-zA-Z]*-?[0-9]+[[:space:]]*$ ]]
}

# __dk_resolve_workspace_name <raw_input>
# Sets: _dk_wt_name, _dk_is_task.
__dk_resolve_workspace_name() {
  local raw_input="$1"

  _dk_is_task=0
  if __dk_is_ticket "$raw_input"; then
    local num="${raw_input//[^0-9]/}"  # strip everything except digits
    _dk_wt_name="ticket-${num}"
  else
    local slug
    slug=$(dk_slugify "$raw_input")
    if [[ -z "$slug" ]]; then
      dk_error "Could not create a valid name from '$raw_input'"
      return 1
    fi
    _dk_wt_name="task-${slug}"
    _dk_is_task=1
  fi
}

# __dk_session_id_for_workspace <workspace_mode> <workspace_name>
# Worktree sessions keep the historic "worktree-*" ids. In-place sessions use
# their own prefix so they do not collide with a same-ticket worktree session.
__dk_session_id_for_workspace() {
  local workspace_mode="$1" wt_name="$2"
  if [[ "$workspace_mode" == "in-place" ]]; then
    printf '%s\n' "inplace-${wt_name}"
  else
    dk_session_id "$wt_name"
  fi
}

# __dk_claude_session_name <workspace_mode> <workspace_name>
__dk_claude_session_name() {
  local workspace_mode="$1" wt_name="$2"
  if [[ "$workspace_mode" == "in-place" ]]; then
    printf 'inplace-%s\n' "$wt_name"
  else
    printf '%s\n' "$wt_name"
  fi
}

# __dk_write_last_session <workspace_name> <workspace_dir> <workspace_mode>
__dk_write_last_session() {
  __dk_write_state "$DK_STATE_DIR/last-session" "${1}:${2}:${3}"
}

# __dk_parse_last_session <raw_last_session>
# Sets: _dk_wt_name, _dk_wt_dir, _dk_workspace_mode, _dk_session_id.
__dk_parse_last_session() {
  local last_info="$1"
  _dk_wt_name="${last_info%%:*}"
  local rest="${last_info#*:}"
  _dk_workspace_mode="worktree"

  case "$rest" in
    *:in-place)
      _dk_workspace_mode="in-place"
      _dk_wt_dir="${rest%:in-place}"
      ;;
    *:worktree)
      _dk_workspace_mode="worktree"
      _dk_wt_dir="${rest%:worktree}"
      ;;
    *)
      _dk_wt_dir="$rest"
      ;;
  esac

  _dk_session_id=$(__dk_session_id_for_workspace "$_dk_workspace_mode" "$_dk_wt_name")
}

# __dk_setup_worktree <raw_input>
# Sets: _dk_wt_name, _dk_wt_dir, _dk_is_task, _dk_repo_root, _dk_default_branch,
# _dk_workspace_mode, _dk_session_id.
# Returns 0 if worktree exists or was created, 1 on error.
# See: docs/autonomous-mode.md for the full lifecycle that follows worktree creation.
__dk_setup_worktree() {
  local raw_input="$1"

  _dk_repo_root=$(dk_repo_root) || return 1
  __dk_resolve_workspace_name "$raw_input" || return 1

  _dk_wt_dir="${_dk_repo_root}/.doyaken/worktrees/${_dk_wt_name}"
  _dk_default_branch=$(dk_default_branch)
  _dk_workspace_mode="worktree"
  _dk_session_id=$(__dk_session_id_for_workspace "$_dk_workspace_mode" "$_dk_wt_name")

  # If worktree exists, ensure links are set up (retroactive fix) and return
  if [[ -d "$_dk_wt_dir" ]]; then
    dk_link_claude_to_worktree "$_dk_repo_root" "$_dk_wt_dir"
    return 0
  fi

  # Auto-init if .doyaken doesn't exist yet
  if [[ ! -d "${_dk_repo_root}/.doyaken" ]]; then
    echo "Auto-initialising Doyaken for this repo..."
    bash "$DOYAKEN_DIR/bin/init.sh" --skip-analysis --skip-config
  fi

  # Create worktree
  echo "Creating worktree ${_dk_wt_name}..."
  git fetch origin "$_dk_default_branch" --quiet 2>/dev/null || true
  mkdir -p "${_dk_repo_root}/.doyaken/worktrees"

  if ! git worktree add "$_dk_wt_dir" -b "worktree-${_dk_wt_name}" "origin/${_dk_default_branch}" 2>&1; then
    dk_error "Failed to create worktree."
    return 1
  fi

  # Save raw prompt for task worktrees (picked up by SessionStart hook)
  if [[ $_dk_is_task -eq 1 ]]; then
    printf '%s\n' "$raw_input" > "$_dk_wt_dir/.doyaken-prompt"
  fi

  # Share .claude/ config and MCP auth with main repo
  dk_link_claude_to_worktree "$_dk_repo_root" "$_dk_wt_dir"

  return 0
}

# __dk_setup_in_place <raw_input>
# Sets the same workspace variables as __dk_setup_worktree, but points them at
# the current checkout and creates/switches the normal Doyaken branch there.
__dk_setup_in_place() {
  local raw_input="$1"

  _dk_repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  if [[ -z "$_dk_repo_root" ]]; then
    dk_error "Not in a git repository."
    return 1
  fi
  __dk_resolve_workspace_name "$raw_input" || return 1

  _dk_wt_dir="$_dk_repo_root"
  _dk_default_branch=$(dk_default_branch "$_dk_wt_dir")
  _dk_workspace_mode="in-place"
  _dk_session_id=$(__dk_session_id_for_workspace "$_dk_workspace_mode" "$_dk_wt_name")
  local branch_name="worktree-${_dk_wt_name}"

  dk_info "Running lifecycle in current checkout (no worktree): ${_dk_wt_dir}"

  git -C "$_dk_wt_dir" fetch origin "$_dk_default_branch" --quiet 2>/dev/null || true

  local current_branch has_changes
  current_branch=$(git -C "$_dk_wt_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")
  has_changes=0
  git -C "$_dk_wt_dir" status --porcelain 2>/dev/null | head -1 | grep -q . && has_changes=1

  if [[ -f "$(dk_state_file "$_dk_session_id")" ]]; then
    dk_info "Using current checkout for existing in-place session ${_dk_wt_name}"
    if [[ $has_changes -eq 1 ]]; then
      dk_warn "Current checkout already has changes; in-place mode will include them in the lifecycle scope."
    fi
    return 0
  fi

  if [[ "$current_branch" == "$branch_name" ]]; then
    dk_ok "Using existing Doyaken branch ${branch_name}"
  elif git -C "$_dk_wt_dir" show-ref --verify --quiet "refs/heads/${branch_name}" 2>/dev/null; then
    if [[ $has_changes -eq 1 ]]; then
      dk_error "Cannot switch to existing branch ${branch_name} with uncommitted changes in the current checkout."
      dk_info "Commit, stash, or discard those changes, then re-run: dk --no-worktree ${raw_input}"
      return 1
    fi
    dk_info "Switching current checkout to existing Doyaken branch ${branch_name}"
    if ! git -C "$_dk_wt_dir" switch "$branch_name"; then
      dk_error "Failed to switch to ${branch_name}."
      return 1
    fi
  else
    if [[ $has_changes -eq 1 ]]; then
      dk_error "Cannot create branch ${branch_name} from origin/${_dk_default_branch} with uncommitted changes in the current checkout."
      dk_info "Commit, stash, or discard those changes, then re-run: dk --no-worktree ${raw_input}"
      return 1
    fi
    dk_info "Creating branch ${branch_name} from origin/${_dk_default_branch}"
    if ! git -C "$_dk_wt_dir" switch -c "$branch_name" "origin/${_dk_default_branch}"; then
      dk_error "Failed to create branch ${branch_name}."
      return 1
    fi
  fi

  if [[ $has_changes -eq 1 ]]; then
    dk_warn "Current checkout already has changes; in-place mode will include them in the lifecycle scope."
  fi

  # Auto-init after branch setup so a newly initialized repo records .doyaken/
  # on the lifecycle branch instead of dirtying the starting checkout first.
  if [[ ! -d "${_dk_repo_root}/.doyaken" ]]; then
    echo "Auto-initialising Doyaken for this repo..."
    bash "$DOYAKEN_DIR/bin/init.sh" --skip-analysis --skip-config
  fi

  return 0
}

# dk_session_id is provided by lib/session.sh (sourced via lib/common.sh)

# __dk_build_system_context <wt_name> <step> <session_id> <wt_dir> [workspace_mode] [raw_input]
# Write a system prompt context file that persists across conversation compaction.
# Returns the file path on stdout. The file is passed to --append-system-prompt-file
# so Claude always knows which phase it is in, even after compaction.
__dk_build_system_context() {
  local wt_name="$1" step="$2" session_id="$3" wt_dir="$4"
  local workspace_mode="${5:-worktree}" raw_input="${6:-}"
  local ctx_file
  ctx_file=$(dk_context_file "$session_id")
  mkdir -p "$(dirname "$ctx_file")"

  # Build phase-specific scope boundaries
  local scope_lines=""
  case $step in
    2) scope_lines="- Do NOT commit, push, create PRs, or modify git history
- DO implement, test, and verify completeness via the Skill tool" ;;
    3) scope_lines="- Do NOT commit, push, create PRs, or modify git history
- DO run adversarial code review, fix all findings, write review result signal" ;;
    4) scope_lines="- Do NOT create PRs or modify implementation beyond fixing verify failures
- DO run format/lint/typecheck/test, fix failures, commit, push" ;;
    5) scope_lines="- Do NOT mark the PR ready for review (that is Phase 6)
- Do NOT post @mention comments yet (those happen at Phase 6)
- DO create the draft PR, write the description, attach 'request' reviewers from doyaken.md § Reviewers" ;;
    6) scope_lines="- Do NOT modify implementation code unless fixing CI/review failures
- DO mark the PR ready, request reviewers (request type), post @mention comment (mention type),
- DO launch /loop 2m /dkwatchci and /loop 5m /dkwatchpr, address comments, close ticket" ;;
  esac

  cat > "$ctx_file" <<EOF
You are Doyaken, running Phase ${step} (${DK_PHASE_NAMES[$step]}) for ${wt_name}.
Workspace: ${wt_dir}
Workspace mode: ${workspace_mode}

## Requested Work

Original dk request: ${raw_input:-$wt_name}
EOF

  if [[ "$workspace_mode" == "in-place" ]]; then
    cat >> "$ctx_file" <<EOF

This lifecycle is running in-place in the current checkout. No Doyaken worktree
was created. Doyaken still prepared the normal lifecycle branch in this checkout
before launching Claude. Treat existing files, staged changes, unstaged changes,
and the current branch as user-owned context. Do not switch branches or create a
new branch unless ticket setup instructions explicitly require a branch rename.
EOF
  fi

  cat >> "$ctx_file" <<EOF

## Audit Loop

You are running inside a phase audit loop. When you try to stop, a Stop hook
intercepts the attempt, injects a quality audit prompt, and blocks the stop.
The audit loop continues for multiple iterations — you must pass the audit
criteria consistently before the hook authorizes completion.

Do NOT try to stop until you have genuinely completed all work for this phase.
Premature stop attempts will be caught and you will be asked to continue.

Do NOT write any .complete signal files or output completion promise strings
on your own. The Stop hook controls completion and will provide instructions
when enough quality passes have been achieved.

CRITICAL: You MUST invoke skills using the Skill tool (e.g., Skill(skill="dkimplement")).
Do NOT implement skill functionality ad-hoc — invoke the actual skill.

$(__dk_provider_prompt)

## Autonomous Phase Contract

The Doyaken shell wrapper owns phase transitions. After Phase 1 plan approval, run
all remaining phases unattended until either the lifecycle is complete or a real
human decision is required.

Do NOT ask the user whether to continue, do NOT ask for permission to start the
next phase, and do NOT tell the user to run the next skill manually. At normal
phase completion, stop the current session so the wrapper can launch the next
phase automatically.

Human input is required only for:
- Phase 1 plan approval or plan rejection
- Clarifying questions during planning when requirements cannot be resolved
- Scope or acceptance-criteria changes after plan approval
- Destructive git operations, force-push/rebase decisions, or secret handling
- Missing credentials/tooling the agent cannot configure safely
- Repeated CI failures, architectural review disputes, or unclear reviewer
  feedback that cannot be resolved within the approved plan
- Max audit/review iterations or repeated loop stalls without completion
- Phase 6 waiting for CI and configured reviewer approval

If none of those applies, keep working autonomously.

## Scope Boundaries (Phase ${step} ONLY)

${scope_lines}

If you lose context after compaction, re-read the phase audit prompt at:
  ${DOYAKEN_DIR}/prompts/phase-audits/${DK_PHASE_AUDIT_FILES[$step]}.md
EOF

  # Append debt warnings from prior phases so downstream work is aware of accepted gaps
  local debt_file
  debt_file=$(dk_debt_file "$session_id")
  if [[ -f "$debt_file" ]] && [[ -s "$debt_file" ]]; then
    cat >> "$ctx_file" <<DEOF

## Active Technical Debt (from prior phases)

WARNING: The following debt items were accepted in earlier phases. Be aware of
these when implementing — they may affect your work.

$(cat "$debt_file")
DEOF
  fi

  echo "$ctx_file"
}

# __dk_run_review_loop <wt_name> <wt_dir> <session_id> [workspace_mode] [raw_input]
#
# Phase 3 (Review): Shell-managed sub-loop with fresh Claude sessions per iteration.
# Each iteration launches a new Claude session (--fork-session) with the Stop hook
# active (MIN_AUDITS=1). After each session exits, the shell reads the review result
# file to determine if the iteration was CLEAN.
#
# Tracks consecutive clean passes — requires DK_REVIEW_CLEAN_PASSES (default 3)
# consecutive CLEAN iterations to advance. DK_REVIEW_MAX_ITERATIONS (default 10)
# is a safety net.
#
# State is persisted to dk_review_state_file so `dk --resume` can continue where
# it left off mid-review.
#
# Returns 0 on success (enough clean passes), non-zero on interrupt or max iterations.
__dk_run_review_loop() {
  local wt_name="$1" wt_dir="$2" session_id="$3"
  local workspace_mode="${4:-worktree}" raw_input="${5:-}"
  local step=3
  local claude_session_name
  claude_session_name=$(__dk_claude_session_name "$workspace_mode" "$wt_name")

  local clean_passes=0
  local review_iteration=0
  local max_review_iterations="${DOYAKEN_REVIEW_MAX_ITERATIONS:-$DK_REVIEW_MAX_ITERATIONS}"
  local required_clean="${DOYAKEN_REVIEW_CLEAN_PASSES:-$DK_REVIEW_CLEAN_PASSES}"

  # Resume: read persisted clean_passes and iteration count
  local review_state_file
  review_state_file=$(dk_review_state_file "$session_id")
  if [[ -f "$review_state_file" ]]; then
    local raw
    raw=$(cat "$review_state_file" 2>/dev/null || echo "")
    if [[ "$raw" =~ ^([0-9]+):([0-9]+)$ ]]; then
      clean_passes="${match[1]}"
      review_iteration="${match[2]}"
    fi
  fi

  while [[ $review_iteration -lt $max_review_iterations ]] && [[ $clean_passes -lt $required_clean ]]; do
    review_iteration=$((review_iteration + 1))

    echo ""
    echo "  Review iteration ${review_iteration}/${max_review_iterations} (${clean_passes}/${required_clean} clean passes)"
    echo ""

    # Clean stale loop and result state for this iteration
    rm -f "$(dk_review_result_file "$session_id")"
    mkdir -p "$DK_LOOP_DIR"
    touch "$(dk_active_file "$session_id")"
    rm -f "$(dk_complete_file "$session_id")" "$(dk_loop_file "$session_id")" "$(dk_findings_file "$session_id")"

    # Configure Stop hook: MIN_AUDITS=1 (one audit pass per review iteration)
    local audit_file="$DOYAKEN_DIR/prompts/phase-audits/${DK_PHASE_AUDIT_FILES[$step]}.md"
    local audit_prompt=""
    [[ -f "$audit_file" ]] && audit_prompt=$(cat "$audit_file")
    __dk_write_state "$(dk_loop_config_file "$session_id")" "${step}:${DK_PHASE_PROMISES[$step]}:${audit_file}:1"

    # Build system context for this iteration
    local ctx_file
    ctx_file=$(__dk_build_system_context "$wt_name" "$step" "$session_id" "$wt_dir" "$workspace_mode" "$raw_input")

    local claude_args=("${DK_CLAUDE_FLAGS[@]}" -n "$claude_session_name")
    # --resume to reuse session name; --fork-session for fresh context window
    claude_args+=(--resume --fork-session)
    claude_args+=(--append-system-prompt-file "$ctx_file")
    claude_args+=(--settings "{\"statusLine\":{\"type\":\"command\",\"command\":\"bash '${DOYAKEN_DIR}/bin/status-line.sh'\"}}")

    # Launch Claude in foreground subshell (TUI needs terminal access)
    (
      cd "$wt_dir" && \
      DOYAKEN_SESSION_ID="$session_id" \
      DOYAKEN_LOOP_ACTIVE=1 \
      DOYAKEN_LOOP_PROMISE="${DK_PHASE_PROMISES[$step]}" \
      DOYAKEN_LOOP_PROMPT="$audit_prompt" \
      DOYAKEN_LOOP_PHASE="$step" \
      DOYAKEN_DIR="$DOYAKEN_DIR" \
      __dk_claude "${claude_args[@]}" "$(__dk_phase_message "$step" "$raw_input" "$workspace_mode" "$wt_dir")"
    )
    local exit_code=$?
    local audit_max_iter=0
    if [[ $exit_code -eq 0 ]] && [[ -f "$(dk_loop_file "$session_id")" ]]; then
      audit_max_iter=1
    fi

    # Clean up per-iteration loop state
    rm -f "$(dk_active_file "$session_id")" "$(dk_loop_config_file "$session_id")" "$(dk_loop_file "$session_id")" 2>/dev/null

    if [[ $audit_max_iter -eq 1 ]]; then
      __dk_write_state "$review_state_file" "${clean_passes}:${review_iteration}"
      return 88
    fi

    # Non-zero exit = user interrupt or error — save state for resume
    if [[ $exit_code -ne 0 ]]; then
      __dk_write_state "$review_state_file" "${clean_passes}:${review_iteration}"
      return $exit_code
    fi

    # Read review result signal file (written by Claude in the audit prompt)
    local result_file
    result_file=$(dk_review_result_file "$session_id")
    local result="UNKNOWN"
    [[ -f "$result_file" ]] && result=$(cat "$result_file" 2>/dev/null || echo "UNKNOWN")

    if [[ "$result" == "CLEAN" ]]; then
      clean_passes=$((clean_passes + 1))
      echo "  Review iteration ${review_iteration}: CLEAN (${clean_passes}/${required_clean})"
    else
      clean_passes=0
      echo "  Review iteration ${review_iteration}: ${result} — resetting clean pass counter"
    fi

    # Persist state for resume
    __dk_write_state "$review_state_file" "${clean_passes}:${review_iteration}"
  done

  if [[ $clean_passes -ge $required_clean ]]; then
    rm -f "$review_state_file" "$(dk_review_result_file "$session_id")" 2>/dev/null
    echo "  Review complete: ${clean_passes} consecutive clean passes achieved."
    return 0
  else
    __dk_write_state "$review_state_file" "${clean_passes}:${review_iteration}"
    rm -f "$(dk_review_result_file "$session_id")" 2>/dev/null
    echo "  Review reached max iterations (${max_review_iterations}) with ${clean_passes}/${required_clean} clean passes."
    echo "  Pausing before advancing so the review result can be inspected."
    return 88
  fi
}

# __dk_run_phases <wt_name> <wt_dir> <default_branch> <start_step> <state_file> <times_file> <resume_hint> [workspace_mode] [session_id] [raw_input]
#
# Phase loop state machine: runs autonomous phases start_step through 6 sequentially.
# Phase 6 (Complete) is autonomous: it marks the PR ready, requests configured
# reviewers (see doyaken.md § Reviewers), monitors CI/reviews, addresses comments,
# and closes the ticket. The user is in the loop only as a configured reviewer.
# Each phase launches a Claude Code session with:
#   - A phase-specific message (DK_PHASE_MESSAGES) that tells Claude which skills to run
#   - An audit loop (DOYAKEN_LOOP_* env vars) that prevents premature exit
#   - Session naming (-n) so --resume can reconnect across phase boundaries
#
# Phase transitions:
#   Phase N completes (exit 0) → state_file written with N+1 → loop continues
#   Phase N interrupted (exit != 0) → state_file written with N → function returns
#   All 5 autonomous phases complete → state_file written with 6 (sentinel for "ready for review")
#
# The .complete signal file (managed by phase-loop.sh) is the bridge between
# Claude's intent to stop and the wrapper's phase advancement. See docs/autonomous-mode.md.
#
# Returns non-zero if user interrupts or an error occurs.
__dk_run_phases() {
  local wt_name="$1" wt_dir="$2" default_branch="$3" step="$4"
  local state_file="$5" times_file="$6" resume_hint="$7"
  local workspace_mode="${8:-worktree}"
  local session_id="${9:-}" raw_input="${10:-}"
  local claude_session_name
  claude_session_name=$(__dk_claude_session_name "$workspace_mode" "$wt_name")

  # Ensure Claude Code CLI is installed — all phases depend on it
  if ! command -v claude &>/dev/null; then
    dk_error "Claude Code CLI not found in PATH."
    dk_info "Install it from https://docs.anthropic.com/en/docs/claude-code then try again."
    return 1
  fi

  # Session ID — derived once, used for checkpoints, logging, and status classification.
  [[ -n "$session_id" ]] || session_id=$(__dk_session_id_for_workspace "$workspace_mode" "$wt_name")

  # Session-level timeout watchdog — single budget for the entire dk run.
  # Sends SIGTERM to this shell's process group when the budget expires.
  local session_timeout="${DOYAKEN_SESSION_TIMEOUT:-$DK_SESSION_TIMEOUT}"
  local _dk_session_watchdog_pid=""
  if [[ "$session_timeout" -gt 0 ]]; then
    (
      sleep "$session_timeout" 2>/dev/null
      kill -TERM -$$ 2>/dev/null
    ) &
    _dk_session_watchdog_pid=$!
    disown "$_dk_session_watchdog_pid" 2>/dev/null
  fi

  while [[ $step -le 6 ]]; do
    __dk_show_header "$wt_name" "$step" "$wt_dir" "$default_branch" "$session_id" "$workspace_mode"

    local claude_args=()
    if [[ $step -eq 1 ]]; then
      # Phase 1: bypassPermissions + EnterPlanMode — read-only without interactive prompts.
      # Plan mode's built-in approval is the quality gate. The Stop hook owns
      # the process handoff after approval so the wrapper can continue.
      claude_args=("${DK_PLAN_FLAGS[@]}" -n "$claude_session_name")
      claude_args+=(--append-system-prompt "You MUST be in plan mode — if not, call EnterPlanMode immediately. Phase 1 handoff is automatic: after ExitPlanMode is approved, stop this Claude Code session immediately so the dk shell wrapper regains control and starts Phase 2. Do NOT say 'run /dkimplement when ready', do NOT ask whether to continue, and do NOT wait for another user prompt.")
      # Resume only if re-entering Phase 1 (prior session exists)
      if [[ -f "$times_file" ]]; then
        claude_args+=(--resume)
      fi
    else
      # Phases 2, 4-6: autonomous with stop hook audit loop (Phase 3 has its own sub-loop)
      claude_args=("${DK_CLAUDE_FLAGS[@]}" -n "$claude_session_name")
      # Resume only if a prior phase actually ran (times_file has entries).
      # Handles edge case where state_file advanced but session was never created.
      if [[ -f "$times_file" ]]; then
        claude_args+=(--resume)
      fi

      # System prompt context file — survives conversation compaction so Claude
      # always knows which phase it is in and how to signal completion.
      local ctx_file
      ctx_file=$(__dk_build_system_context "$wt_name" "$step" "$session_id" "$wt_dir" "$workspace_mode" "$raw_input")
      claude_args+=(--append-system-prompt-file "$ctx_file")

      # Live status line — shows phase, audit iteration, and elapsed time in TUI
      claude_args+=(--settings "{\"statusLine\":{\"type\":\"command\",\"command\":\"bash '${DOYAKEN_DIR}/bin/status-line.sh'\"}}")

      # Fork session at every phase boundary so Claude exits and restarts with
      # a fresh context window. The system prompt file carries essential context
      # (phase number, scope boundaries, completion protocol) across the fork.
      claude_args+=(--fork-session)
    fi

    # Git checkpoint — snapshot HEAD before the phase runs so we can revert
    # on failure (inspired by autoresearch's commit-before-experiment pattern).
    # Phase 1 is read-only (plan mode) so no checkpoint needed.
    if [[ $step -ge 2 ]]; then
      dk_checkpoint_tag "$step" "$wt_dir"
    fi

    # Record phase start time (written to times_file AFTER claude exits so
    # the file serves as a reliable "session exists" marker for --resume)
    local phase_start_epoch
    phase_start_epoch=$(date +%s)

    # Resolve phase timeout (0 = disabled). Watchdog runs in the background
    # and sends SIGTERM if the phase exceeds its wall-clock budget.
    local phase_timeout
    phase_timeout=$(__dk_phase_timeout "$step")
    local _dk_watchdog_pid=""

    # PID file lets the watchdog discover the foreground subshell's PID.
    # Claude is a TUI — it MUST run in the foreground (not &) or the kernel
    # suspends it with SIGTTOU. The old pattern backgrounded the subshell to
    # capture $!, but that broke terminal access.
    local _dk_pidfile=""
    _dk_pidfile=$(mktemp "${TMPDIR:-/tmp}/dk-phase.XXXXXX")

    # Start timeout watchdog BEFORE the foreground process (which blocks).
    # It polls the PID file until the subshell writes its PID, then sleeps
    # for the budget duration before sending SIGTERM to the process group.
    if [[ "$phase_timeout" -gt 0 ]]; then
      (
        local tgt=""
        while [[ -z "$tgt" ]]; do
          [[ -s "$_dk_pidfile" ]] && tgt=$(<"$_dk_pidfile")
          [[ -z "$tgt" ]] && sleep 0.2
        done
        sleep "$phase_timeout" 2>/dev/null
        kill -TERM -"$tgt" 2>/dev/null
      ) &
      _dk_watchdog_pid=$!
      # Disown so zsh doesn't print "[N] + done ..." when the watchdog exits.
      # We still have the PID to kill/wait on — disown only suppresses the
      # job table notification, not the ability to signal the process.
      disown "$_dk_watchdog_pid" 2>/dev/null
    fi

    if [[ $step -eq 1 ]]; then
      # Phase 1: EnterPlanMode called by Claude. ExitPlanMode handles approval.
      # The Stop hook still owns the process handoff: once the approved plan is
      # audited and the .complete file is written, it returns continue=false so
      # Claude Code exits and the shell wrapper can launch Phase 2.
      local audit_file="$DOYAKEN_DIR/prompts/phase-audits/${DK_PHASE_AUDIT_FILES[$step]}.md"
      mkdir -p "$DK_LOOP_DIR"
      touch "$(dk_active_file "$session_id")"
      rm -f "$(dk_complete_file "$session_id")" "$(dk_loop_file "$session_id")" "$(dk_findings_file "$session_id")"
      __dk_write_state "$(dk_loop_config_file "$session_id")" "${step}:${DK_PHASE_PROMISES[$step]}:${audit_file}:1"

      (
        sh -c 'echo $PPID' > "$_dk_pidfile"
        cd "$wt_dir" && \
        DOYAKEN_SESSION_ID="$session_id" \
        DOYAKEN_LOOP_ACTIVE=1 \
        DOYAKEN_LOOP_PROMISE="${DK_PHASE_PROMISES[$step]}" \
        DOYAKEN_LOOP_PHASE="$step" \
        DOYAKEN_DIR="$DOYAKEN_DIR" \
        __dk_claude "${claude_args[@]}" "$(__dk_phase_message "$step" "$raw_input" "$workspace_mode" "$wt_dir")"
      )
    elif [[ $step -eq 3 ]]; then
      # Phase 3: Review — shell-managed sub-loop with fresh sessions per iteration.
      # The review loop runs multiple Claude sessions internally (each with
      # --fork-session). The Stop hook (MIN_AUDITS=1) enforces one audit pass per
      # iteration. The shell tracks consecutive CLEAN results and requires
      # DK_REVIEW_CLEAN_PASSES before advancing. See: __dk_run_review_loop.
      (
        sh -c 'echo $PPID' > "$_dk_pidfile"
        __dk_run_review_loop "$wt_name" "$wt_dir" "$session_id" "$workspace_mode" "$raw_input"
      )
    else
      # Phases 2, 4-6: audit loop active (single Claude session per phase).
      # Load phase-specific audit prompt from file
      local audit_prompt=""
      local audit_file="$DOYAKEN_DIR/prompts/phase-audits/${DK_PHASE_AUDIT_FILES[$step]}.md"
      [[ -f "$audit_file" ]] && audit_prompt=$(cat "$audit_file")

      # Write file-based activation signals — belt-and-suspenders alongside env vars.
      # Claude Code runs hooks as separate subprocesses that may not inherit inline
      # env vars from the parent process. These files ensure the hook activates
      # even when DOYAKEN_LOOP_ACTIVE is not visible to the hook subprocess.
      mkdir -p "$DK_LOOP_DIR"
      touch "$(dk_active_file "$session_id")"
      rm -f "$(dk_complete_file "$session_id")" "$(dk_loop_file "$session_id")" "$(dk_findings_file "$session_id")"

      # Resolve minimum audit iterations for this phase.
      # Priority: DOYAKEN_PHASE_N_MIN_AUDITS env var > DK_PHASE_MIN_AUDITS[step]
      # shellcheck disable=SC2034  # used via zsh ${(P)min_audits_env} indirect expansion below
      local min_audits_env="DOYAKEN_PHASE_${step}_MIN_AUDITS"
      local min_audits="${(P)min_audits_env:-${DK_PHASE_MIN_AUDITS[$step]:-1}}"

      # Config file format: "phase:promise:audit_file:min_audits"
      __dk_write_state "$(dk_loop_config_file "$session_id")" "${step}:${DK_PHASE_PROMISES[$step]}:${audit_file}:${min_audits}"

      # The Stop hook (phase-loop.sh) reads activation from two sources:
      #   1. File-based: .active file + .config file (primary — always works)
      #   2. Env vars: DOYAKEN_LOOP_ACTIVE, etc. (belt-and-suspenders)
      # Claude exits 0 when the .complete file is written (hook returns continue=false) or
      # max iterations reached. Non-zero means user interrupt or error.
      # See: docs/autonomous-mode.md for the full architecture.
      # Runs in a subshell so `cd` doesn't affect the parent shell. Environment
      # variables are set inline (not exported) to scope them to this invocation.
      (
        sh -c 'echo $PPID' > "$_dk_pidfile"
        cd "$wt_dir" && \
        DOYAKEN_SESSION_ID="$session_id" \
        DOYAKEN_LOOP_ACTIVE=1 \
        DOYAKEN_LOOP_PROMISE="${DK_PHASE_PROMISES[$step]}" \
        DOYAKEN_LOOP_PROMPT="$audit_prompt" \
        DOYAKEN_LOOP_PHASE="$step" \
        DOYAKEN_COMPLETE_MAX_CYCLES="${DOYAKEN_COMPLETE_MAX_CYCLES:-$DK_COMPLETE_MAX_CYCLES}" \
        DOYAKEN_COMPLETE_WAIT_MINUTES="${DOYAKEN_COMPLETE_WAIT_MINUTES:-$DK_COMPLETE_WAIT_MINUTES}" \
        DOYAKEN_DIR="$DOYAKEN_DIR" \
        __dk_claude "${claude_args[@]}" "$(__dk_phase_message "$step" "$raw_input" "$workspace_mode" "$wt_dir")"
      )
    fi

    local exit_code=$?
    rm -f "$_dk_pidfile"

    # Write phase timing now that claude actually ran. This must happen AFTER
    # claude exits so times_file only exists when a real session was created —
    # the --resume guard on phase 1 (and phases 2-6) checks this file.
    # Skip writing on non-zero exit when no prior entry exists — this means
    # Claude was interrupted before it could create a persistent session, so
    # --resume would fail with a session picker instead of resuming.
    if [[ $exit_code -eq 0 ]] || [[ -f "$times_file" ]]; then
      mkdir -p "$(dirname "$times_file")"
      echo "${step}:${phase_start_epoch}" >> "$times_file"
    fi

    local phase_end_epoch
    phase_end_epoch=$(date +%s)

    # Kill the timeout watchdog if it's still running.
    # No wait needed — disown (above) removed it from the job table.
    if [[ -n "$_dk_watchdog_pid" ]]; then
      kill "$_dk_watchdog_pid" 2>/dev/null
    fi

    # Classify the phase outcome (autoresearch-inspired status markers)
    local phase_status
    phase_status=$(__dk_classify_exit "$exit_code" "$step" "$session_id")

    # Read iteration count from loop state file before cleaning up.
    # On max-iter, phase-loop.sh leaves this file intact for classification;
    # on .complete, it's already removed. Clean up after reading.
    local iterations=0
    local loop_file
    loop_file=$(dk_loop_file "$session_id")
    if [[ -f "$loop_file" ]]; then
      local raw_iter
      raw_iter=$(cat "$loop_file" 2>/dev/null || echo "0")
      # Handle both old format (bare number) and new format (number:epoch:stall)
      iterations="${raw_iter%%:*}"
      [[ "$iterations" =~ ^[0-9]+$ ]] || iterations=0
      rm -f "$loop_file"
    fi
    # Clean up file-based activation signals (idempotent — hook may have already removed some)
    rm -f "$(dk_active_file "$session_id")" "$(dk_loop_config_file "$session_id")" 2>/dev/null

    # Log phase result (TSV)
    local duration_s=$((phase_end_epoch - phase_start_epoch))
    __dk_log_phase "$session_id" "$step" "${DK_PHASE_NAMES[$step]}" \
      "$phase_start_epoch" "$phase_end_epoch" "$duration_s" \
      "$iterations" "$phase_status" "$exit_code"

    # Anything other than an explicit advance means user input or intervention
    # is required before the lifecycle can safely continue.
    if [[ "$phase_status" != "advance" ]]; then
      __dk_write_state "$state_file" "$step"
      echo ""
      case "$phase_status" in
        max-iter)
          echo "Paused at Phase ${step}: ${DK_PHASE_NAMES[$step]} (max audit iterations reached)"
          ;;
        timeout)
          echo "Phase ${step} (${DK_PHASE_NAMES[$step]}) timed out after ${phase_timeout}s."
          ;;
        interrupt)
          echo "Paused at Phase ${step}: ${DK_PHASE_NAMES[$step]} (interrupted)"
          ;;
        *)
          echo "Paused at Phase ${step}: ${DK_PHASE_NAMES[$step]} (${phase_status}, exit ${exit_code})"
          ;;
      esac
      echo "Resume with: ${resume_hint}"
      if [[ $step -ge 2 ]] && git -C "$wt_dir" rev-parse --verify "dk-checkpoint/phase-${step}" &>/dev/null; then
        if [[ "$workspace_mode" == "worktree" ]]; then
          echo "Revert to pre-phase state with: dk revert ${wt_name} ${step}"
        else
          echo "Checkpoint tag available: dk-checkpoint/phase-${step}"
        fi
      fi
      dk_provider_cleanup_session_state "$session_id"
      [[ -n "$_dk_session_watchdog_pid" ]] && kill "$_dk_session_watchdog_pid" 2>/dev/null
      local return_code="$exit_code"
      [[ "$return_code" -eq 0 ]] && return_code=1
      return "$return_code"
    fi

    # Advance to next phase
    step=$((step + 1))
    __dk_write_state "$state_file" "$step"
  done

  # Kill session watchdog — all phases done
  [[ -n "$_dk_session_watchdog_pid" ]] && kill "$_dk_session_watchdog_pid" 2>/dev/null

  # All autonomous phases complete — write step=7 so re-running `dk <ticket>` or
  # `dk --resume` detects "fully complete" instead of restarting from Phase 1.
  # Worktree state files are cleaned up by dkrm / dkclean. In-place state is
  # retained so `dk --resume` can report completion for the last run.
  __dk_write_state "$state_file" "7"
  dk_provider_cleanup_session_state "$session_id"
  __dk_show_header "$wt_name" 7 "$wt_dir" "$default_branch" "$session_id" "$workspace_mode"
  echo ""
  echo "Ticket lifecycle complete — PR has been merged-eligible (CI green, reviews approved)."
  if [[ "$workspace_mode" == "worktree" ]]; then
    echo "Run dkrm ${wt_name} to clean up the worktree when you're done."
  else
    echo "No worktree cleanup is needed; this lifecycle ran in the current checkout."
  fi
}

# __dk_format_elapsed <seconds>
# Format seconds as "Xm Ys"
__dk_format_elapsed() {
  local secs=$1
  if [[ $secs -lt 60 ]]; then
    echo "${secs}s"
  else
    echo "$((secs / 60))m $((secs % 60))s"
  fi
}

# __dk_show_header <wt_name> <current_step> <wt_dir> [default_branch] [session_id] [workspace_mode]
# Display lifecycle progress between phases
__dk_show_header() {
  local wt_name="$1" step="$2" wt_dir="$3" default_branch="${4:-main}"
  local session_id="${5:-}" workspace_mode="${6:-worktree}"
  [[ -n "$session_id" ]] || session_id=$(__dk_session_id_for_workspace "$workspace_mode" "$wt_name")
  local times_file
  times_file=$(dk_times_file "$session_id")

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  DOYAKEN — ${wt_name}"
  echo ""

  # Phase progress line (6 autonomous phases)
  local progress="  "
  local i
  for i in 1 2 3 4 5 6; do
    if [[ $i -lt $step ]]; then
      progress+="✓ ${DK_PHASE_NAMES[$i]}"
    elif [[ $i -eq $step ]]; then
      progress+="→ ${DK_PHASE_NAMES[$i]}"
    else
      progress+="○ ${DK_PHASE_NAMES[$i]}"
    fi
    [[ $i -lt 6 ]] && progress+="  "
  done
  # Show completion suffix when all autonomous phases are done (step=7 sentinel)
  if [[ $step -ge 7 ]]; then
    progress+="  ✓ ticket complete"
  fi
  echo "$progress"
  echo ""

  # Metadata (only if worktree exists and has commits).
  # Parses "X files changed" from `git diff --stat` summary line; falls back to "0"
  # if the diff is empty (no changes yet) or the base branch is unreachable.
  if [[ -d "$wt_dir" ]]; then
    local files_changed commits_count
    files_changed=$(git -C "$wt_dir" diff --stat "origin/${default_branch}" 2>/dev/null | tail -1 | grep -oE '[0-9]+ file' | grep -oE '[0-9]+' || echo "0")
    commits_count=$(git -C "$wt_dir" log --oneline "origin/${default_branch}..HEAD" 2>/dev/null | wc -l | tr -d ' ')

    local actual_branch
    if [[ "$workspace_mode" == "in-place" ]]; then
      actual_branch=$(dk_wt_branch "$wt_dir" "current-checkout")
    else
      actual_branch=$(dk_wt_branch "$wt_dir" "worktree-${wt_name}")
    fi
    local meta="  Branch: ${actual_branch}"
    [[ "$workspace_mode" == "in-place" ]] && meta+=" | mode: in-place"
    [[ "$files_changed" != "0" ]] && meta+=" | ${files_changed} files changed"
    [[ "$commits_count" != "0" ]] && meta+=" | ${commits_count} commits"
    echo "$meta"
  fi

  # Timing info
  if [[ -f "$times_file" ]] && [[ $step -gt 1 ]]; then
    local prev_step=$((step - 1))
    local prev_start total_start now phase_elapsed total_elapsed
    now=$(date +%s)

    # Previous phase elapsed
    prev_start=$(grep "^${prev_step}:" "$times_file" 2>/dev/null | tail -1 | cut -d: -f2)
    total_start=$(head -1 "$times_file" 2>/dev/null | cut -d: -f2)

    local timing=""
    if [[ -n "$prev_start" ]]; then
      phase_elapsed=$((now - prev_start))
      timing+="  Phase ${prev_step} took $(__dk_format_elapsed $phase_elapsed)"
    fi
    if [[ -n "$total_start" ]]; then
      total_elapsed=$((now - total_start))
      timing+=" | Total: $(__dk_format_elapsed $total_elapsed)"
    fi
    [[ -n "$timing" ]] && echo "$timing"
  fi

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}

# ─── dk — phased lifecycle wrapper ──────────────────────────────────────────

unalias dk 2>/dev/null; unfunction dk 2>/dev/null
dk() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: dk <NUMBER>        (e.g. dk 999, dk ENG-999)"
    echo "       dk \"<description>\" (e.g. dk \"fix login bug\")"
    echo "       dk --no-worktree <task>"
    echo "       dk --resume        Resume the most recent session"
    echo "       dk --from-pr <N>   Resume session linked to a PR"
    echo ""
    echo "       dk init|config|install|uninstall|uninit|status|reload|help"
    return 1
  fi

  local use_worktree=1
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --no-worktree|--in-place|--here)
        use_worktree=0
        shift
        ;;
      --worktree)
        use_worktree=1
        shift
        ;;
      *)
        break
        ;;
    esac
  done

  if [[ $# -eq 0 ]]; then
    echo "Usage: dk --no-worktree <NUMBER|description>"
    return 1
  fi

  # Route management subcommands to doyaken
  case "$1" in
    init|config|provider|install|uninstall|uninit|status|reload|help|--help|-h|revert|log)
      doyaken "$@"
      return $?
      ;;
  esac

  __dk_refresh_provider || return 1

  # Resume mode — find most recent session and continue from tracked phase
  if [[ "$1" == "--resume" ]]; then
    local last_session_file="$DK_STATE_DIR/last-session"
    if [[ ! -f "$last_session_file" ]]; then
      dk_error "No previous session found."
      dk_info "Start a new session with: dk <number>"
      return 1
    fi
    # last-session file format: "wt_name:wt_dir:mode". Older "wt_name:wt_dir"
    # files are still treated as worktree sessions.
    local last_info
    last_info=$(cat "$last_session_file" 2>/dev/null)
    __dk_parse_last_session "$last_info"
    if [[ ! -d "$_dk_wt_dir" ]]; then
      if [[ "$_dk_workspace_mode" == "in-place" ]]; then
        dk_error "Checkout for in-place session ${_dk_wt_name} no longer exists."
      else
        dk_error "Worktree ${_dk_wt_name} no longer exists."
      fi
      rm -f "$last_session_file"
      return 1
    fi

    # Validate workspace git state
    if ! git -C "$_dk_wt_dir" rev-parse --git-dir &>/dev/null; then
      dk_error "Workspace ${_dk_wt_name} has corrupted git state."
      if [[ "$_dk_workspace_mode" == "worktree" ]]; then
        dk_info "Run dkrm ${_dk_wt_name} and start fresh."
      fi
      return 1
    fi

    # Reconstruct raw_input for resume message
    local raw_input="$_dk_wt_name"
    _dk_default_branch=$(dk_default_branch "$_dk_wt_dir")

    # Fall through to the phase loop below
    local session_id state_file times_file
    session_id="$_dk_session_id"
    state_file=$(dk_state_file "$session_id")
    times_file=$(dk_times_file "$session_id")
    local step=1
    [[ -f "$state_file" ]] && step=$(cat "$state_file" 2>/dev/null)
    [[ "$step" =~ ^[1-7]$ ]] || step=1

    if [[ $step -gt 6 ]]; then
      echo "Ticket lifecycle already complete for ${_dk_wt_name}."
      if [[ "$_dk_workspace_mode" == "worktree" ]]; then
        echo "Run dkrm ${_dk_wt_name} to clean up after merging."
      else
        echo "No worktree cleanup is needed for this in-place session."
      fi
      return 0
    fi

    echo "Resuming ${_dk_wt_name} from Phase ${step}: ${DK_PHASE_NAMES[$step]}..."

    cd "$_dk_wt_dir" 2>/dev/null || return 1
    __dk_run_phases "$_dk_wt_name" "$_dk_wt_dir" "$_dk_default_branch" "$step" "$state_file" "$times_file" "dk --resume" "$_dk_workspace_mode" "$session_id" "$raw_input"
    return $?
  fi

  # PR-linked mode — resume a session associated with a GitHub PR
  if [[ "$1" == "--from-pr" ]]; then
    if [[ -z "${2:-}" ]]; then
      echo "Usage: dk --from-pr <PR_NUMBER|URL>"
      return 1
    fi
    local provider_prompt
    provider_prompt=$(__dk_provider_prompt)
    local pr_args=("${DK_CLAUDE_FLAGS[@]}")
    [[ -n "$provider_prompt" ]] && pr_args+=(--append-system-prompt "$provider_prompt")
    pr_args+=(--from-pr "$2")
    local session_id
    session_id="from-pr-$(dk_unique_session_id)"
    dk_provider_cleanup_session_state "$session_id"
    DOYAKEN_SESSION_ID="$session_id" __dk_claude "${pr_args[@]}"
    local exit_code=$?
    dk_provider_cleanup_session_state "$session_id"
    return $exit_code
  fi

  # Normal mode — setup workspace and run phased lifecycle
  local raw_input="${(j: :)@}"  # zsh: join all args with spaces

  if [[ $use_worktree -eq 1 ]]; then
    if ! __dk_setup_worktree "$raw_input"; then
      return 1
    fi
  else
    if ! __dk_setup_in_place "$raw_input"; then
      return 1
    fi
  fi

  local session_id state_file times_file
  session_id="$_dk_session_id"
  state_file=$(dk_state_file "$session_id")
  times_file=$(dk_times_file "$session_id")

  # Save as last session for --resume (atomic write to avoid corruption on interrupt)
  __dk_write_last_session "$_dk_wt_name" "$_dk_wt_dir" "$_dk_workspace_mode"

  # Read current phase (default: 1)
  local step=1
  if [[ -f "$state_file" ]]; then
    step=$(cat "$state_file" 2>/dev/null)
    [[ "$step" =~ ^[1-7]$ ]] || step=1
  fi

  if [[ $step -gt 6 ]]; then
    echo "Ticket lifecycle already complete for ${_dk_wt_name}."
    if [[ "$_dk_workspace_mode" == "worktree" ]]; then
      echo "Run dkrm ${raw_input} to clean up after merging."
    else
      echo "No worktree cleanup is needed for this in-place session."
    fi
    return 0
  fi

  if [[ $step -gt 1 ]]; then
    echo "Resuming ${_dk_wt_name} from Phase ${step}: ${DK_PHASE_NAMES[$step]}..."
  fi

  # ── Phase loop ──
  local resume_hint="dk ${raw_input}"
  [[ "$_dk_workspace_mode" == "in-place" ]] && resume_hint="dk --no-worktree ${raw_input}"
  cd "$_dk_wt_dir" 2>/dev/null || return 1
  __dk_run_phases "$_dk_wt_name" "$_dk_wt_dir" "$_dk_default_branch" "$step" "$state_file" "$times_file" "$resume_hint" "$_dk_workspace_mode" "$session_id" "$raw_input"
  return $?
}

# ─── dkloop — prompt loop (run until done) ─────────────────────────────────

unalias dkloop 2>/dev/null; unfunction dkloop 2>/dev/null
dkloop() {
  __dk_refresh_provider || return 1

  local prompt=""
  if [[ $# -eq 0 ]]; then
    # No prompt given — load the default codebase improvement prompt
    local default_prompt_file="$DOYAKEN_DIR/prompts/default-loop.md"
    if [[ ! -f "$default_prompt_file" ]]; then
      dk_error "Default prompt not found at $default_prompt_file"
      return 1
    fi
    prompt=$(cat "$default_prompt_file")
    dk_info "No prompt given — using default: review, improve, and harden the codebase"
  else
    prompt="${(j: :)@}"
  fi

  if ! command -v claude &>/dev/null; then
    dk_error "Claude Code CLI not found in PATH."
    dk_info "Install it from https://docs.anthropic.com/en/docs/claude-code then try again."
    return 1
  fi

  # Validate we're in a git repo (needed for session ID derivation)
  local repo_root
  repo_root=$(dk_repo_root) || return 1

  # Derive a unique session ID so concurrent dkloops on the same branch don't collide
  local session_id
  session_id=$(dk_unique_session_id)

  # Remove any loop files that happen to share this unique session ID (harmless
  # no-op in practice since each dkloop gets a fresh ID via dk_unique_session_id).
  dk_provider_cleanup_session_state "$session_id"
  rm -f "$(dk_loop_file "$session_id")" "$(dk_complete_file "$session_id")" "$(dk_active_file "$session_id")"

  # Persist the original prompt so the Stop hook can re-inject it on each audit
  # iteration. Context compaction may lose the initial message after several rounds.
  local prompt_file
  prompt_file="$(dk_prompt_file "$session_id")"
  mkdir -p "$(dirname "$prompt_file")"
  printf '%s\n' "$prompt" > "$prompt_file"

  # Show header
  local branch
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  local prompt_slug
  prompt_slug=$(dk_slugify "${prompt:0:40}")
  local session_name=""
  if [[ -n "$prompt_slug" ]]; then
    session_name="dkloop-${prompt_slug}"
  else
    session_name="dkloop-$(date +%s)"
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  DOYAKEN — dkloop (prompt loop)"
  echo ""
  echo "  Branch: ${branch}"
  echo "  Prompt: ${prompt:0:72}$([ ${#prompt} -gt 72 ] && echo '...')"
  echo "  Phase:  Plan → Implement"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # ── Session 1: Plan ──
  # bypassPermissions + EnterPlanMode — read-only without interactive prompts.
  # Plan mode's built-in approval is the quality gate. The Stop hook owns the
  # process handoff after approval so dkloop can continue to implementation.
  local plan_args=("${DK_PLAN_FLAGS[@]}")
  [[ -n "$session_name" ]] && plan_args+=(-n "$session_name")
  plan_args+=(--append-system-prompt "You are in a dkloop planning session. You MUST be in plan mode — if not, call EnterPlanMode immediately. Your original task prompt is saved at ${prompt_file}. Re-read it with the Read tool if you lose track of the task. After ExitPlanMode is approved, stop this Claude Code session immediately so the dkloop wrapper can launch implementation. Do NOT ask whether to continue and do NOT wait for another user prompt. The Stop hook handles the process handoff back to dkloop.")

  local plan_audit_file="$DOYAKEN_DIR/prompts/phase-audits/1-plan.md"
  mkdir -p "$DK_LOOP_DIR"
  touch "$(dk_active_file "$session_id")"
  rm -f "$(dk_complete_file "$session_id")" "$(dk_loop_file "$session_id")" "$(dk_findings_file "$session_id")"
  __dk_write_state "$(dk_loop_config_file "$session_id")" "1:PHASE_1_COMPLETE:${plan_audit_file}:1"

  dk_info "Phase: Plan (read-only until approved)"
  DOYAKEN_SESSION_ID="$session_id" \
  DOYAKEN_LOOP_ACTIVE=1 \
  DOYAKEN_LOOP_PROMISE="PHASE_1_COMPLETE" \
  DOYAKEN_LOOP_PHASE="1" \
  DOYAKEN_DIR="$DOYAKEN_DIR" \
  __dk_claude "${plan_args[@]}" "Call EnterPlanMode now, then run /dkplan for the following task:

${prompt}

Gather context, explore the codebase, and create your implementation plan. When the plan is ready, use ExitPlanMode to present it for approval. After approval, stop this session immediately so dkloop can launch implementation automatically.
$(__dk_provider_prompt)"

  local plan_exit=$?
  local plan_status="advance"
  if [[ $plan_exit -eq 0 ]] && [[ -f "$(dk_loop_file "$session_id")" ]]; then
    plan_status="max-iter"
    plan_exit=1
  fi
  rm -f "$(dk_active_file "$session_id")" "$(dk_loop_config_file "$session_id")" "$(dk_loop_file "$session_id")" 2>/dev/null
  if [[ $plan_exit -ne 0 ]]; then
    rm -f "$(dk_loop_file "$session_id")" \
          "$(dk_complete_file "$session_id")" \
          "$(dk_active_file "$session_id")" \
          "$(dk_prompt_file "$session_id")" 2>/dev/null
    dk_provider_cleanup_session_state "$session_id"
    echo ""
    if [[ "$plan_status" == "max-iter" ]]; then
      dk_info "dkloop paused during planning: max audit iterations reached without completion."
    else
      dk_info "dkloop interrupted during planning (exit code: $plan_exit)."
    fi
    return $plan_exit
  fi

  # ── Session 2: Implement ──
  # Autonomous mode with stop hook audit loop. Resumes the plan session.
  local impl_args=("${DK_CLAUDE_FLAGS[@]}" --resume)
  [[ -n "$session_name" ]] && impl_args+=(-n "$session_name")
  impl_args+=(--append-system-prompt "You are in a dkloop session. Your original task prompt is saved at ${prompt_file}. Re-read it with the Read tool before any audit step, or when you lose track of what you are working on.")

  dk_info "Phase: Implement (autonomous)"
  DOYAKEN_SESSION_ID="$session_id" \
  DOYAKEN_LOOP_ACTIVE=1 \
  DOYAKEN_LOOP_PROMISE="PROMPT_COMPLETE" \
  DOYAKEN_LOOP_PHASE="prompt-loop" \
  DOYAKEN_DIR="$DOYAKEN_DIR" \
  __dk_claude "${impl_args[@]}" "The plan is approved. Implement it now. Work through all tasks, following TDD where the project has tests. The stop hook audit will guide you through quality verification and final review when you are done.
$(__dk_provider_prompt)"

  local exit_code=$?
  local loop_status="advance"
  if [[ $exit_code -eq 0 ]] && [[ -f "$(dk_loop_file "$session_id")" ]]; then
    loop_status="max-iter"
    exit_code=1
  fi

  # Clean up state files
  rm -f "$(dk_loop_file "$session_id")" \
        "$(dk_complete_file "$session_id")" \
        "$(dk_active_file "$session_id")" \
        "$(dk_prompt_file "$session_id")" 2>/dev/null
  dk_provider_cleanup_session_state "$session_id"

  if [[ $exit_code -eq 0 ]]; then
    echo ""
    dk_done "dkloop complete."
  else
    echo ""
    if [[ "$loop_status" == "max-iter" ]]; then
      dk_info "dkloop paused: max audit iterations reached without completion."
    else
      dk_info "dkloop interrupted (exit code: $exit_code)."
    fi
  fi

  return $exit_code
}

# ─── dkcomplete — standalone Phase 6 (recovery / non-dk PRs) ───────────────

unalias dkcomplete 2>/dev/null; unfunction dkcomplete 2>/dev/null
dkcomplete() {
  __dk_refresh_provider || return 1

  if ! command -v claude &>/dev/null; then
    dk_error "Claude Code CLI not found in PATH."
    dk_info "Install it from https://docs.anthropic.com/en/docs/claude-code then try again."
    return 1
  fi

  # Must be in a git repo (PR is required)
  if ! git rev-parse --git-dir &>/dev/null; then
    dk_error "Not in a git repository."
    return 1
  fi

  # Check that a PR exists for the current branch
  if ! command -v gh &>/dev/null; then
    dk_error "GitHub CLI (gh) not found in PATH."
    return 1
  fi

  local pr_num
  pr_num=$(gh pr view --json number -q .number 2>/dev/null)
  if [[ -z "$pr_num" ]]; then
    dk_error "No PR found for the current branch."
    dk_info "Run the autonomous lifecycle first: dk <ticket>"
    return 1
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  DOYAKEN — dkcomplete (Phase 6: monitor, address, close)"
  echo ""
  echo "  PR:    #${pr_num}"
  echo "  Phase: Monitor CI → Address reviews → Close ticket"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # Use a session ID derived from the current location (worktree-aware via dk_session_id)
  local session_id
  session_id=$(dk_session_id)

  # Activate the prompt-loop variant of the audit loop so the Stop hook
  # enforces completion criteria. See: hooks/phase-loop.sh prompt-loop branch.
  mkdir -p "$DK_LOOP_DIR"
  touch "$(dk_active_file "$session_id")"
  rm -f "$(dk_complete_file "$session_id")" "$(dk_loop_file "$session_id")"

  DOYAKEN_SESSION_ID="$session_id" \
  DOYAKEN_LOOP_ACTIVE=1 \
  DOYAKEN_LOOP_PROMISE="DOYAKEN_TICKET_COMPLETE" \
  DOYAKEN_LOOP_PHASE="6" \
  DOYAKEN_COMPLETE_MAX_CYCLES="${DOYAKEN_COMPLETE_MAX_CYCLES:-$DK_COMPLETE_MAX_CYCLES}" \
  DOYAKEN_COMPLETE_WAIT_MINUTES="${DOYAKEN_COMPLETE_WAIT_MINUTES:-$DK_COMPLETE_WAIT_MINUTES}" \
  DOYAKEN_DIR="$DOYAKEN_DIR" \
  __dk_claude "${DK_CLAUDE_FLAGS[@]}" -n "dkcomplete-pr-${pr_num}" \
    "Invoke the Skill tool with skill: \"dkcomplete\". Run the full completion workflow: verify the PR is ready for review, request configured reviewers, post @mention comments, monitor CI via /loop 2m /dkwatchci, monitor reviews via /loop 5m /dkwatchpr, address review comments, and close the ticket when all checks pass and reviewers have approved.
$(__dk_provider_prompt)"

  local exit_code=$?
  local loop_status="advance"
  if [[ $exit_code -eq 0 ]] && [[ -f "$(dk_loop_file "$session_id")" ]]; then
    loop_status="max-iter"
    exit_code=1
  fi

  # Clean up
  rm -f "$(dk_active_file "$session_id")" "$(dk_loop_file "$session_id")" "$(dk_complete_file "$session_id")" 2>/dev/null
  dk_provider_cleanup_session_state "$session_id"

  if [[ "$loop_status" == "max-iter" ]]; then
    dk_info "dkcomplete paused: max audit iterations reached without completion."
  fi

  return $exit_code
}

# ─── dkreviewloop — standalone 3-clean-passes review ─────────────────────
#
# Runs the same adversarial review loop dk Phase 3 uses, without requiring
# the full lifecycle. Scope is auto-detected in this priority order:
#   1. Staged changes      → git diff --cached
#   2. Unstaged changes    → git diff
#   3. Unpushed commits    → git diff @{u}...HEAD
#   4. PR diff vs default  → git diff origin/<default>...HEAD
#
# Each iteration is a fresh Claude session that runs /dkreview --single-pass, performs
# the manual review passes, spawns the self-reviewer agent, builds a
# merged findings inventory, fixes everything, and writes a CLEAN /
# FINDINGS:N review-result signal. The shell tracks consecutive CLEAN
# results — DK_REVIEW_CLEAN_PASSES (default 3) in a row to advance,
# DK_REVIEW_MAX_ITERATIONS (default 10) safety net before pausing.

unalias dkreviewloop 2>/dev/null; unfunction dkreviewloop 2>/dev/null
dkreviewloop() {
  __dk_refresh_provider || return 1

  if ! command -v claude &>/dev/null; then
    dk_error "Claude Code CLI not found in PATH."
    dk_info "Install it from https://docs.anthropic.com/en/docs/claude-code then try again."
    return 1
  fi

  if ! git rev-parse --git-dir &>/dev/null; then
    dk_error "Not in a git repository."
    return 1
  fi

  # Detect scope using priority order
  local scope_name="" diff_cmd="" stat_cmd="" name_cmd=""
  if ! git diff --cached --quiet 2>/dev/null; then
    scope_name="staged changes"
    diff_cmd="git diff --cached"
    stat_cmd="git diff --cached --stat"
    name_cmd="git diff --cached --name-only"
  elif ! git diff --quiet 2>/dev/null; then
    scope_name="unstaged changes"
    diff_cmd="git diff"
    stat_cmd="git diff --stat"
    name_cmd="git diff --name-only"
  elif git rev-parse --abbrev-ref --symbolic-full-name '@{u}' &>/dev/null && \
       [[ -n "$(git log '@{u}..HEAD' --oneline 2>/dev/null)" ]]; then
    scope_name="unpushed commits (vs upstream)"
    diff_cmd="git diff @{u}...HEAD"
    stat_cmd="git diff @{u}...HEAD --stat"
    name_cmd="git diff @{u}...HEAD --name-only"
  else
    local default_branch
    default_branch=$(dk_default_branch)
    if [[ -n "$default_branch" ]] && \
       [[ -n "$(git log "origin/${default_branch}..HEAD" --oneline 2>/dev/null)" ]]; then
      scope_name="PR diff (vs origin/${default_branch})"
      diff_cmd="git diff origin/${default_branch}...HEAD"
      stat_cmd="git diff origin/${default_branch}...HEAD --stat"
      name_cmd="git diff origin/${default_branch}...HEAD --name-only"
    fi
  fi

  if [[ -z "$scope_name" ]]; then
    dk_error "No changes detected to review."
    dk_info "Tried in order: staged, unstaged, unpushed, PR diff vs default branch."
    return 1
  fi

  local branch
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")

  # File count preview (parsed from --stat tail line)
  local files_changed
  files_changed=$(eval "$stat_cmd" 2>/dev/null | tail -1 | grep -oE '[0-9]+ files? changed' | grep -oE '[0-9]+' || echo "?")

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  DOYAKEN — dkreviewloop (3-clean-passes review)"
  echo ""
  echo "  Branch: ${branch}"
  echo "  Scope:  ${scope_name} (${files_changed} files)"
  echo "  Diff:   ${diff_cmd}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  local session_id
  session_id=$(dk_session_id)

  local clean_passes=0
  local review_iteration=0
  local max_iter="${DOYAKEN_REVIEW_MAX_ITERATIONS:-$DK_REVIEW_MAX_ITERATIONS}"
  local required_clean="${DOYAKEN_REVIEW_CLEAN_PASSES:-$DK_REVIEW_CLEAN_PASSES}"

  # Reuse the Phase 3 audit prompt — same one dk wrapper Phase 3 uses.
  local audit_file="$DOYAKEN_DIR/prompts/phase-audits/3-review.md"
  local audit_prompt=""
  [[ -f "$audit_file" ]] && audit_prompt=$(cat "$audit_file")

  local session_name
  session_name="dkreviewloop-$(dk_slugify "$branch")"

  local message
  message="Run an adversarial code review using /dkreview --single-pass, scoped to **${scope_name}** on branch \`${branch}\`.

IMPORTANT: When the audit prompt or /dkreview SKILL.md tells you to scope with \`git diff origin/<default>...HEAD\`, override that — use these commands instead:

- Diff:        \`${diff_cmd}\`
- Stat:        \`${stat_cmd}\`
- File names:  \`${name_cmd}\`

Follow the audit prompt: run /dkreview --single-pass, perform the manual passes, spawn the self-reviewer agent, build the merged findings inventory, fix all issues, and write the review result signal file.

If no approved plan / acceptance criteria are available for this scope, mark plan-dependent sections (acceptance criteria verification, evidence table) as N/A and proceed without them.

SCOPE BOUNDARIES: review and fix the diff above ONLY. Do NOT commit, push, or create PRs.

When the review is clean, stop — the audit loop will verify.
$(__dk_provider_prompt)"

  while [[ $review_iteration -lt $max_iter ]] && [[ $clean_passes -lt $required_clean ]]; do
    review_iteration=$((review_iteration + 1))

    echo ""
    echo "  Iteration ${review_iteration}/${max_iter} (${clean_passes}/${required_clean} clean passes)"
    echo ""

    rm -f "$(dk_review_result_file "$session_id")"
    mkdir -p "$DK_LOOP_DIR"
    touch "$(dk_active_file "$session_id")"
    rm -f "$(dk_complete_file "$session_id")" "$(dk_loop_file "$session_id")" "$(dk_findings_file "$session_id")"

    # Stop hook config: phase 3, MIN_AUDITS=1
    __dk_write_state "$(dk_loop_config_file "$session_id")" "3:${DK_PHASE_PROMISES[3]}:${audit_file}:1"

    local claude_args=("${DK_CLAUDE_FLAGS[@]}" -n "$session_name")
    if [[ $review_iteration -gt 1 ]]; then
      # Reuse session name across iterations, fresh context window each time
      claude_args+=(--resume --fork-session)
    fi

    DOYAKEN_SESSION_ID="$session_id" \
    DOYAKEN_LOOP_ACTIVE=1 \
    DOYAKEN_LOOP_PROMISE="${DK_PHASE_PROMISES[3]}" \
    DOYAKEN_LOOP_PROMPT="$audit_prompt" \
    DOYAKEN_LOOP_PHASE="3" \
    DOYAKEN_DIR="$DOYAKEN_DIR" \
    __dk_claude "${claude_args[@]}" "$message"

    local exit_code=$?
    local audit_max_iter=0
    if [[ $exit_code -eq 0 ]] && [[ -f "$(dk_loop_file "$session_id")" ]]; then
      audit_max_iter=1
    fi

    rm -f "$(dk_active_file "$session_id")" "$(dk_loop_config_file "$session_id")" "$(dk_loop_file "$session_id")" 2>/dev/null

    if [[ $audit_max_iter -eq 1 ]]; then
      echo ""
      dk_info "dkreviewloop paused: max audit iterations reached without completion."
      dk_provider_cleanup_session_state "$session_id"
      return 1
    fi

    if [[ $exit_code -ne 0 ]]; then
      echo ""
      dk_info "dkreviewloop interrupted (exit code: $exit_code)."
      dk_provider_cleanup_session_state "$session_id"
      return $exit_code
    fi

    local result="UNKNOWN"
    local result_file
    result_file=$(dk_review_result_file "$session_id")
    [[ -f "$result_file" ]] && result=$(cat "$result_file" 2>/dev/null || echo "UNKNOWN")

    if [[ "$result" == "CLEAN" ]]; then
      clean_passes=$((clean_passes + 1))
      echo "  Iteration ${review_iteration}: CLEAN (${clean_passes}/${required_clean})"
    else
      clean_passes=0
      echo "  Iteration ${review_iteration}: ${result} — resetting clean pass counter"
    fi
  done

  rm -f "$(dk_review_result_file "$session_id")" 2>/dev/null
  dk_provider_cleanup_session_state "$session_id"

  echo ""
  if [[ $clean_passes -ge $required_clean ]]; then
    dk_done "Review complete: ${clean_passes} consecutive clean passes."
    return 0
  else
    dk_info "Review reached max iterations (${max_iter}) with ${clean_passes}/${required_clean} clean passes."
    return 1
  fi
}

# ─── dkrm — remove worktrees ──────────────────────────────────────────────

unalias dkrm 2>/dev/null; unfunction dkrm 2>/dev/null
dkrm() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: dkrm <NUMBER>     (e.g. dkrm 999)"
    echo "       dkrm <name>       (e.g. dkrm task-fix-login)"
    echo "       dkrm --all        Remove all worktrees"
    return 1
  fi

  # Find repo root — dk_repo_root handles worktree escaping.
  # If git fails (cwd was deleted), fall back to parsing the cwd path.
  local repo_root
  repo_root=$(dk_repo_root 2>/dev/null)
  if [[ -z "$repo_root" ]]; then
    local cwd
    cwd="$(pwd 2>/dev/null || echo "")"
    if [[ "$cwd" == *"/.doyaken/worktrees/"* ]]; then
      repo_root="${cwd%%/.doyaken/worktrees/*}"
    fi
  fi
  if [[ -z "$repo_root" ]]; then
    dk_error "Could not determine repo root. cd to the repo and try again."
    return 1
  fi

  local worktrees_dir="${repo_root}/.doyaken/worktrees"

  # Move to repo root first in case we're inside a worktree being removed.
  # Must succeed — subsequent git operations depend on being in the right directory.
  # Note: this intentionally does not restore the original cwd — if the user was
  # inside a worktree that got deleted, returning there would fail.
  cd "$repo_root" || return 1

  if [[ "$1" == "--all" ]]; then
    local found=0
    local renamed_branches=()
    local session_ids=()

    if [[ -d "$worktrees_dir" ]]; then
      for wt_dir in "$worktrees_dir"/*/; do
        [[ -d "$wt_dir" ]] || continue
        found=1
        local wt_name
        wt_name="$(basename "$wt_dir")"
        session_ids+=("worktree-${wt_name}")

        # The SessionStart hook may rename the worktree branch (e.g. from
        # worktree-ticket-999 to feat/ENG-999-description) to follow project
        # conventions. Track these renamed branches so we can delete them below
        # — they won't match the 'worktree-*' glob pattern.
        local actual_branch
        actual_branch=$(dk_wt_branch "$wt_dir")
        if [[ -n "$actual_branch" && "$actual_branch" != "worktree-${wt_name}" ]]; then
          renamed_branches+=("$actual_branch")
        fi

        echo "Removing ${wt_name}..."
        dk_cleanup_checkpoints "$wt_dir"
        dk_unlink_claude_from_worktree "$wt_dir"
        dk_wt_remove "$wt_dir"
      done
    fi

    local branch
    while IFS= read -r branch; do
      [[ -z "$branch" ]] && continue
      found=1
      echo "Deleting branch ${branch}..."
      git branch -D "$branch" 2>/dev/null || true
    done < <(git branch --list 'worktree-ticket-*' 'worktree-task-*' 2>/dev/null | sed 's/^[* ]*//')

    # Delete renamed branches that wouldn't match the worktree-* pattern
    for branch in "${renamed_branches[@]}"; do
      echo "Deleting renamed branch ${branch}..."
      git branch -D "$branch" 2>/dev/null || true
      found=1
    done

    git worktree prune 2>/dev/null

    # Clean up last-session pointer (all worktrees gone, nothing to resume)
    rm -f "$DK_STATE_DIR/last-session" 2>/dev/null

    # Clean up state files for THIS repo's worktrees only (not cross-repo globs)
    local sid
    for sid in "${session_ids[@]}"; do
      dk_cleanup_session "$sid"
    done

    if [[ $found -eq 0 ]]; then
      dk_info "No worktrees or branches found."
    else
      echo "All worktrees removed."
    fi
    return 0
  fi

  local raw_input="${(j: :)@}"  # zsh: join all args with spaces

  local wt_name
  if __dk_is_ticket "$raw_input"; then
    local num="${raw_input//[^0-9]/}"  # strip everything except digits
    wt_name="ticket-${num}"
  else
    # For freeform names, try multiple matches so the user can pass:
    #   "task-fix-login"  → exact dir name from dkls output
    #   "fix login"       → slugified to "fix-login", then prefixed with "task-"
    #   "fix-login"       → same after slugify
    local slug
    slug=$(dk_slugify "$raw_input")
    if [[ -z "$slug" ]]; then
      dk_error "Could not create a valid name from '$raw_input'"
      return 1
    fi
    if [[ -d "${worktrees_dir}/${slug}" ]]; then
      wt_name="$slug"
    elif [[ -d "${worktrees_dir}/task-${slug}" ]]; then
      wt_name="task-${slug}"
    else
      dk_error "No worktree found matching '${raw_input}'."
      dk_info "Run dkls to see available worktrees."
      return 1
    fi
  fi

  local wt_dir="${worktrees_dir}/${wt_name}"
  local branch_name="worktree-${wt_name}"

  # Detect actual branch name (may have been renamed by ticket instructions)
  local actual_branch=""
  [[ -d "$wt_dir" ]] && actual_branch=$(dk_wt_branch "$wt_dir")

  local has_dir=0 has_branch=0
  [[ -d "$wt_dir" ]] && has_dir=1
  git show-ref --verify --quiet "refs/heads/${branch_name}" 2>/dev/null && has_branch=1

  # Also check for the actual branch if it differs from the expected name
  local has_actual_branch=0
  if [[ -n "$actual_branch" && "$actual_branch" != "$branch_name" ]]; then
    git show-ref --verify --quiet "refs/heads/${actual_branch}" 2>/dev/null && has_actual_branch=1
  fi

  if [[ $has_dir -eq 0 ]] && [[ $has_branch -eq 0 ]] && [[ $has_actual_branch -eq 0 ]]; then
    dk_error "No worktree or branch found for '${wt_name}'."
    return 1
  fi

  echo "Removing ${wt_name}..."

  [[ $has_dir -eq 1 ]] && dk_cleanup_checkpoints "$wt_dir"
  [[ $has_dir -eq 1 ]] && dk_unlink_claude_from_worktree "$wt_dir"
  [[ $has_dir -eq 1 ]] && dk_wt_remove "$wt_dir"

  if [[ $has_branch -eq 1 ]]; then
    echo "  Deleting branch ${branch_name}..."
    git branch -D "$branch_name" 2>/dev/null || true
  fi

  if [[ $has_actual_branch -eq 1 ]]; then
    echo "  Deleting renamed branch ${actual_branch}..."
    git branch -D "$actual_branch" 2>/dev/null || true
  fi

  # Clean up state files and last-session pointer
  local session_id
  session_id=$(dk_session_id "$wt_name")
  dk_cleanup_session "$session_id"
  dk_cleanup_last_session "$wt_name"

  git worktree prune 2>/dev/null
  echo "Done."
}

# ─── dkls — list worktrees ────────────────────────────────────────────────

unalias dkls 2>/dev/null; unfunction dkls 2>/dev/null
dkls() {
  local repo_root
  repo_root=$(dk_repo_root) || return 1

  local worktrees_dir="${repo_root}/.doyaken/worktrees"
  if [[ ! -d "$worktrees_dir" ]]; then
    dk_info "No worktrees."
    return 0
  fi

  local count=0
  for wt_dir in "$worktrees_dir"/*/; do
    [[ -d "$wt_dir" ]] || continue
    count=$((count + 1))
    local wt_name
    wt_name="$(basename "$wt_dir")"
    local wt_status=""

    # Check git state is valid before querying status/branch
    if ! git -C "$wt_dir" rev-parse --git-dir &>/dev/null; then
      wt_status=" [corrupted git state]"
      echo "  ${wt_name}  (?)${wt_status}"
      continue
    fi

    if git -C "$wt_dir" status --porcelain 2>/dev/null | head -1 | grep -q .; then
      wt_status="${wt_status} [changes]"
    fi

    local branch
    branch=$(dk_wt_branch "$wt_dir" "?")

    # Show phase status
    local session_id
    session_id=$(dk_session_id "$wt_name")
    local phase_file
    phase_file=$(dk_state_file "$session_id")
    if [[ -f "$phase_file" ]]; then
      local phase_num
      phase_num=$(cat "$phase_file" 2>/dev/null)
      if [[ "$phase_num" =~ ^[1-6]$ ]]; then
        wt_status="${wt_status} [phase ${phase_num}/6: ${DK_PHASE_NAMES[$phase_num]}]"
      elif [[ "$phase_num" =~ ^[0-9]+$ ]] && [[ "$phase_num" -gt 6 ]]; then
        wt_status="${wt_status} [complete]"
      fi
    fi

    [[ -z "$wt_status" ]] && wt_status=" [idle]"
    echo "  ${wt_name}  (${branch})${wt_status}"
  done

  if [[ $count -eq 0 ]]; then
    dk_info "No worktrees."
  fi
}

# ─── dkcd — navigate to a worktree or repo root ─────────────────────────────

unalias dkcd 2>/dev/null; unfunction dkcd 2>/dev/null
dkcd() {
  local repo_root
  repo_root=$(dk_repo_root) || return 1

  # No args → repo root
  if [[ $# -eq 0 ]]; then
    cd "$repo_root" || return 1
    return 0
  fi

  local target="$1"
  local worktrees_dir="${repo_root}/.doyaken/worktrees"

  if [[ ! -d "$worktrees_dir" ]]; then
    dk_error "No worktrees found."
    return 1
  fi

  # Exact match first
  if [[ -d "$worktrees_dir/$target" ]]; then
    cd "$worktrees_dir/$target" || return 1
    return 0
  fi

  # Prefix match: "ticket-123" or just "123" matches worktree names containing that string
  local matches=()
  for wt_dir in "$worktrees_dir"/*/; do
    [[ -d "$wt_dir" ]] || continue
    local name
    name="$(basename "$wt_dir")"
    if [[ "$name" == *"$target"* ]]; then
      matches+=("$wt_dir")
    fi
  done

  if [[ ${#matches[@]} -eq 0 ]]; then
    dk_error "No worktree matching '$target'. Run dkls to see active worktrees."
    return 1
  elif [[ ${#matches[@]} -eq 1 ]]; then
    cd "${matches[1]}" || return 1
    return 0
  else
    dk_error "Multiple worktrees match '$target':"
    for m in "${matches[@]}"; do
      echo "  $(basename "$m")"
    done
    echo "Be more specific."
    return 1
  fi
}

# ─── dkclean — prune stale worktrees + gone branches ─────────────────────────

unalias dkclean 2>/dev/null; unfunction dkclean 2>/dev/null
dkclean() {
  local repo_root
  repo_root=$(dk_repo_root) || return 1

  # cd to repo root so bare git commands (fetch, branch -D, branch --list) operate
  # on the correct repository. Note: this intentionally does not restore the original
  # cwd — if the user was inside a removed worktree, returning there would fail.
  cd "$repo_root" || return 1
  local cleaned=0

  # 1. Prune stale worktrees (no uncommitted changes)
  local worktrees_dir="${repo_root}/.doyaken/worktrees"
  if [[ -d "$worktrees_dir" ]]; then
    for wt_dir in "$worktrees_dir"/*/; do
      [[ -d "$wt_dir" ]] || continue
      local wt_name
      wt_name="$(basename "$wt_dir")"

      # Skip worktrees with active phase state (still in a lifecycle)
      local session_id phase_file
      session_id=$(dk_session_id "$wt_name")
      phase_file=$(dk_state_file "$session_id")
      if [[ -f "$phase_file" ]]; then
        local phase_val
        phase_val=$(cat "$phase_file" 2>/dev/null)
        if [[ "$phase_val" =~ ^[1-6]$ ]]; then
          echo "  Skipping ${wt_name} (active phase ${phase_val}/6: ${DK_PHASE_NAMES[$phase_val]})"
          continue
        fi
      fi

      # Skip worktrees with uncommitted changes
      if git -C "$wt_dir" status --porcelain 2>/dev/null | head -1 | grep -q .; then
        echo "  Skipping ${wt_name} (has uncommitted changes)"
        continue
      fi

      # Skip worktrees with unpushed commits
      local wt_branch
      wt_branch=$(dk_wt_branch "$wt_dir")
      if [[ -n "$wt_branch" ]]; then
        if ! git -C "$wt_dir" rev-parse "origin/${wt_branch}" &>/dev/null; then
          echo "  Skipping ${wt_name} (branch not pushed to remote)"
          continue
        fi
        if git -C "$wt_dir" log --oneline "origin/${wt_branch}..HEAD" 2>/dev/null | head -1 | grep -q .; then
          echo "  Skipping ${wt_name} (has unpushed commits)"
          continue
        fi
      fi

      echo "  Removing stale worktree: ${wt_name}"
      dk_unlink_claude_from_worktree "$wt_dir"
      dk_wt_remove "$wt_dir"

      # Delete the branch (wt_branch captured above; handles renamed branches too)
      [[ -n "$wt_branch" ]] && git branch -D "$wt_branch" 2>/dev/null || true

      # Clean up state files and last-session pointer
      dk_cleanup_session "$session_id"
      dk_cleanup_last_session "$wt_name"

      cleaned=$((cleaned + 1))
    done
  fi

  # 2. Prune doyaken branches whose remote tracking branch is gone.
  # Only targets worktree-* branches to avoid deleting non-doyaken feature branches.
  git fetch --prune 2>/dev/null || true

  local branch
  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    # Only clean doyaken-managed branches (worktree-ticket-* or worktree-task-*)
    if [[ "$branch" != worktree-ticket-* ]] && [[ "$branch" != worktree-task-* ]]; then
      continue
    fi
    # Don't delete branches with active worktrees
    local has_worktree=0
    if [[ -d "$worktrees_dir" ]]; then
      for wt_dir in "$worktrees_dir"/*/; do
        [[ -d "$wt_dir" ]] || continue
        local wt_branch
        wt_branch=$(dk_wt_branch "$wt_dir")
        if [[ "$wt_branch" == "$branch" ]]; then
          has_worktree=1
          break
        fi
      done
    fi

    if [[ $has_worktree -eq 1 ]]; then
      echo "  Skipping branch ${branch} (has active worktree)"
      continue
    fi

    echo "  Deleting gone branch: ${branch}"
    git branch -D "$branch" 2>/dev/null || true
    cleaned=$((cleaned + 1))
  done < <(git branch -vv 2>/dev/null | grep ': gone]' | sed 's/^[* ]*//' | awk '{print $1}')

  # 3. Prune worktree branches that have no worktree directory
  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    local ticket_name="${branch#worktree-}"
    if [[ ! -d "$worktrees_dir/$ticket_name" ]]; then
      echo "  Deleting orphan branch: ${branch}"
      git branch -D "$branch" 2>/dev/null || true
      cleaned=$((cleaned + 1))
    fi
  done < <(git branch --list 'worktree-ticket-*' 'worktree-task-*' 2>/dev/null | sed 's/^[* ]*//')

  git worktree prune 2>/dev/null

  # 4. Clean up old loop state files (older than 7 days).
  # 7 days gives enough time to resume interrupted sessions while preventing
  # indefinite accumulation. Most tickets complete within a day or two.
  local old_files
  old_files=$(dk_cleanup_stale_files "$DK_LOOP_DIR" "state complete active prompt config findings debt provider" 7)
  if [[ "$old_files" -gt 0 ]]; then
    echo "  Cleaned ${old_files} old loop state file(s)"
    cleaned=$((cleaned + old_files))
  fi

  # 5. Clean up old phase state files (older than 7 days)
  local old_phase_files
  old_phase_files=$(dk_cleanup_stale_files "$DK_STATE_DIR" "phase times system-context log" 7)
  if [[ "$old_phase_files" -gt 0 ]]; then
    echo "  Cleaned ${old_phase_files} old phase state file(s)"
    cleaned=$((cleaned + old_phase_files))
  fi

  if [[ $cleaned -eq 0 ]]; then
    echo "Nothing to clean."
  else
    echo "Cleaned ${cleaned} item(s)."
  fi
}
