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
      echo "Refinement (pre-implementation):"
      echo "  dk refine <N|description>  Refine a ticket — clarify with the user, raise risks, propose sub-tickets"
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
#   --dangerously-skip-permissions       No interactive permission prompts.
#   --permission-mode bypassPermissions  Keep Claude's permission mode explicit.
#   --effort           Maximum reasoning effort for complex tasks by default.
#                      Override with DK_CLAUDE_EFFORT if the provider differs.
unalias __dk_refresh_provider 2>/dev/null; unfunction __dk_refresh_provider 2>/dev/null
__dk_refresh_provider() {
  dk_provider_apply || return 1
  DK_CLAUDE_FLAGS=(--chrome --model "$DK_CLAUDE_MODEL" --dangerously-skip-permissions --permission-mode bypassPermissions --effort "$DK_CLAUDE_EFFORT")
  DK_PLAN_FLAGS=(--chrome --model "$DK_PLAN_MODEL" --dangerously-skip-permissions --permission-mode bypassPermissions --effort "$DK_PLAN_EFFORT")
}

DK_CLAUDE_FLAGS=(--chrome --model "${DK_CLAUDE_MODEL:-opus}" --dangerously-skip-permissions --permission-mode bypassPermissions --effort "${DK_CLAUDE_EFFORT:-max}")
DK_PLAN_FLAGS=(--chrome --model "${DK_PLAN_MODEL:-${DK_CLAUDE_MODEL:-opus}}" --dangerously-skip-permissions --permission-mode bypassPermissions --effort "${DK_PLAN_EFFORT:-${DK_CLAUDE_EFFORT:-max}}")

# Phase 1 uses dangerous skip permissions plus bypassPermissions to avoid
# interactive prompts. Claude calls EnterPlanMode as its first action to
# enforce read-only until user approves via ExitPlanMode.

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
  if [[ "$step" -eq 1 ]]; then
    cat <<'EOF'
Call EnterPlanMode now. Then immediately invoke the dkplan skill using the Skill tool with skill: "dkplan" (or /dkplan if slash skills are the available interface). Do not fetch the ticket, rename branches, update tracker status, explore the codebase, or draft the plan by hand outside the dkplan skill unless the skill explicitly instructs you to.

The dkplan skill writes the required Phase 1 lifecycle markers. After the user approves the plan via ExitPlanMode, follow the dkplan completion instructions, then stop once so the Doyaken Stop hook can audit the approved plan and advance to Phase 2 automatically. Do NOT tell the user to run /dkimplement and do NOT wait for another prompt.
EOF
  else
    printf '%s\n' "${DK_PHASE_MESSAGES[$step]}"
  fi
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
  "Call EnterPlanMode now, then immediately invoke the dkplan skill. Do not perform ticket setup, exploration, or planning by hand outside dkplan unless the skill explicitly instructs you to. After the user approves the plan via ExitPlanMode, write the Phase 1 approval marker and stop once so the Stop hook can audit the approved plan and advance to Phase 2 automatically. Do NOT tell the user to run /dkimplement and do NOT wait for another prompt." \
  "The plan is approved. You MUST invoke the Skill tool with skill: \"dkimplement\" to begin implementation. Do NOT implement ad-hoc — the skill enforces TDD and quality gates. For UI-affecting changes, Phase 2 must invoke dkuicapture and link screenshots/videos/traces before stopping. SCOPE BOUNDARIES: implementation, testing, and UI capture evidence ONLY. Do NOT commit, push, create branches, or create PRs during this phase — those are handled by later phases. When done, stop — the audit loop will verify your work." \
  "Begin Phase 3: Review. Invoke the Skill tool with skill: \"dkreviewloop\" to run the 3-clean-pass review loop. Fix any findings it reports and rerun until it reports SUCCESS. SCOPE BOUNDARIES: review and fix ONLY. Do NOT commit, push, create branches, or create PRs. When the review loop is successful, stop — the audit loop will verify." \
  "Invoke the Skill tool with skill: \"dkverify\" to run the quality pipeline (format, lint, typecheck, test). Fix any failures and re-run until all green. Then invoke skill: \"dkcommit\" to commit and push. SCOPE BOUNDARIES: verify and commit ONLY. Do NOT create PRs or modify implementation beyond fixing verify failures. When pushed, stop — the audit loop will verify." \
  "Invoke the Skill tool with skill: \"dkpr\" to generate the PR description, create the draft PR, and attach the configured 'request' reviewers from doyaken.md § Reviewers. SCOPE BOUNDARIES: PR creation and description ONLY. Do NOT mark the PR ready for review (Phase 6 owns that), do NOT post @mention comments, do NOT modify implementation code. When done, stop — the audit loop will verify." \
  "Invoke the Skill tool with skill: \"dkcomplete\". Phase 6 follows the cycle-loop audit prompt: mark the PR ready, request reviewers from doyaken.md § Reviewers, post @mention comments for mention-type reviewers, launch /loop 2m /dkwatchci and /loop 5m /dkwatchpr, wait DOYAKEN_COMPLETE_WAIT_MINUTES per cycle, address comments via /dkprreview, re-request reviewers after each push, and close the ticket when CI is green and all reviewers have approved. Stop — the audit loop will verify." \
)

# Audit prompt file basenames (must match prompts/phase-audits/ filenames)
DK_PHASE_AUDIT_FILES=("1-plan" "2-implement" "3-review-loop" "4-verify" "5-pr" "6-complete")

# Session timeout in seconds — single budget for the entire dk run (all phases).
# Default: 86400 (24 hours). Set to 0 to disable.
# Override: DOYAKEN_SESSION_TIMEOUT=14400 (4h)
DK_SESSION_TIMEOUT=86400

# Minimum audit iterations per phase before the Stop hook authorizes completion.
# Phase 2 (Implement) requires 1 pass (completeness check; deep review is Phase 3).
# Phase 3 (Review) uses /dkreviewloop; the audit verifies that loop's SUCCESS report.
# Phase 6 (Complete) wait windows are enforced inside the audit prompt; min 1 here.
# Other phases require 1 pass (the audit prompt must be followed at least once).
# Override: DOYAKEN_PHASE_2_MIN_AUDITS=5
# zsh 1-indexed: [1]=Plan, [2]=Implement, [3]=Review, [4]=Verify, [5]=PR, [6]=Complete
DK_PHASE_MIN_AUDITS=("1" "1" "1" "1" "1" "1")

# Review sub-loop configuration.
# Lifecycle Phase 3 uses the /dkreviewloop skill in the same Claude session.
# The standalone dkreviewloop shell command also uses these defaults.
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
  if ! printf '%s\n' "$content" >| "$tmp" || ! command mv -f "$tmp" "$file"; then
    command rm -f "$tmp" 2>/dev/null
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
    dk_record_session_branch "$_dk_session_id" "$_dk_wt_dir"
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

  if ! git worktree add --no-track "$_dk_wt_dir" -b "worktree-${_dk_wt_name}" "origin/${_dk_default_branch}" 2>&1; then
    dk_error "Failed to create worktree."
    return 1
  fi

  # Share .claude/ config and MCP auth with main repo
  dk_link_claude_to_worktree "$_dk_repo_root" "$_dk_wt_dir"
  dk_record_session_branch "$_dk_session_id" "$_dk_wt_dir"

  return 0
}

# __dk_restore_in_place_session_branch <session_id> <workspace_name> <workspace_dir> <resume_command>
# In-place sessions share the user's checkout, so make sure resume continues on
# the lifecycle branch recorded for this session.
__dk_restore_in_place_session_branch() {
  local session_id="$1" wt_name="$2" wt_dir="$3" resume_command="$4"
  local current_branch has_changes session_branch="" canonical_branch

  current_branch=$(git -C "$wt_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")
  has_changes=0
  git -C "$wt_dir" status --porcelain 2>/dev/null | head -1 | grep -q . && has_changes=1

  [[ -f "$(dk_branch_file "$session_id")" ]] && session_branch=$(cat "$(dk_branch_file "$session_id")" 2>/dev/null || echo "")
  canonical_branch="worktree-${wt_name}"
  if [[ -z "$session_branch" && "$current_branch" != "$canonical_branch" ]] && git -C "$wt_dir" show-ref --verify --quiet "refs/heads/${canonical_branch}" 2>/dev/null; then
    session_branch="$canonical_branch"
  fi
  if [[ -n "$session_branch" && "$current_branch" != "$session_branch" ]]; then
    if [[ $has_changes -eq 1 ]]; then
      dk_error "Cannot resume in-place session ${wt_name}: current checkout is on ${current_branch}, but the session branch is ${session_branch}, and there are uncommitted changes."
      dk_info "Commit or stash the current changes, switch to ${session_branch}, then re-run: ${resume_command}"
      return 1
    fi
    if ! git -C "$wt_dir" show-ref --verify --quiet "refs/heads/${session_branch}" 2>/dev/null; then
      dk_error "Cannot resume in-place session ${wt_name}: saved branch ${session_branch} no longer exists."
      dk_info "Restore or check out the lifecycle branch, or remove the stale session state before starting over."
      return 1
    fi
    dk_info "Switching current checkout back to in-place session branch ${session_branch}"
    if ! git -C "$wt_dir" switch "$session_branch"; then
      dk_error "Failed to switch to ${session_branch}."
      return 1
    fi
    has_changes=0
  fi

  if [[ $has_changes -eq 1 ]]; then
    dk_warn "Current checkout already has changes; in-place mode will include them in the lifecycle scope."
  fi

  dk_record_session_branch "$session_id" "$wt_dir"
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
    __dk_restore_in_place_session_branch "$_dk_session_id" "$_dk_wt_name" "$_dk_wt_dir" "dk --no-worktree ${raw_input}"
    return $?
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
    if ! git -C "$_dk_wt_dir" switch --no-track -c "$branch_name" "origin/${_dk_default_branch}"; then
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

  dk_record_session_branch "$_dk_session_id" "$_dk_wt_dir"
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
    1) scope_lines="- DO invoke the dkplan skill immediately after entering Plan Mode
- Do NOT fetch tickets, rename branches, update tracker status, explore code, or draft a plan by hand outside dkplan unless the skill explicitly instructs you to
- DO wait for explicit user approval via ExitPlanMode before marking Phase 1 ready" ;;
    2) scope_lines="- Do NOT commit, push, create PRs, or modify git history
- DO implement, test, and verify completeness via the Skill tool" ;;
    3) scope_lines="- Do NOT commit, push, create PRs, or modify git history
- DO run /dkreviewloop, fix all findings, and reach a SUCCESS result" ;;
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
You are Doyaken, running the Doyaken lifecycle for ${wt_name}.
Initial phase: Phase ${step} (${DK_PHASE_NAMES[$step]}).
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

The Doyaken lifecycle controller owns phase transitions. After Phase 1 plan
approval, run all remaining phases unattended until either the lifecycle is
complete or a real human decision is required.

Do NOT ask the user whether to continue, do NOT ask for permission to start the
next phase, and do NOT tell the user to run the next skill manually. At normal
phase completion, stop once so the Stop hook can audit the phase and either
advance you to the next phase in this session or pause for a real escalation.
If the Stop hook hands you a new phase in this same session, that latest
handoff instruction supersedes the initial phase label and scope section below.

Same-session handoff rules:
- When a phase is complete, stop once for the Stop hook audit.
- If the Stop hook gives you the next phase, continue immediately without asking
  the user.
- Phase 3 must use /dkreviewloop for the 3-clean-pass review loop.

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

## Initial Scope Boundaries (Phase ${step})

${scope_lines}

These boundaries apply to the initial phase until the Stop hook hands off to a
later phase. After a same-session handoff, follow the latest handoff prompt and
status line for the current phase.

If you lose context after compaction, re-read the current phase audit prompt.
The initial phase audit prompt was:
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

# __dk_inline_audit_file <step>
# Audit prompt for same-session phase handoff.
__dk_inline_audit_file() {
  local step="$1"
  echo "$DOYAKEN_DIR/prompts/phase-audits/${DK_PHASE_AUDIT_FILES[$step]}.md"
}

# __dk_configure_inline_phase <step> <session_id>
# Prepare the Stop hook to audit the current phase and advance inline.
__dk_configure_inline_phase() {
  local step="$1" session_id="$2" audit_file min_audits_env min_audits
  audit_file=$(__dk_inline_audit_file "$step")
  mkdir -p "$DK_LOOP_DIR"
  touch "$(dk_active_file "$session_id")"
  printf '%s\n' "inline" > "$(dk_handoff_mode_file "$session_id")"
  rm -f "$(dk_complete_file "$session_id")" "$(dk_loop_file "$session_id")" "$(dk_findings_file "$session_id")" "$(dk_paused_file "$session_id")" "$(dk_watch_pause_file "$session_id")"

  # shellcheck disable=SC2034  # used via zsh ${(P)min_audits_env} indirect expansion below
  min_audits_env="DOYAKEN_PHASE_${step}_MIN_AUDITS"
  min_audits="${(P)min_audits_env:-${DK_PHASE_MIN_AUDITS[$step]:-1}}"
  __dk_write_state "$(dk_loop_config_file "$session_id")" "${step}:${DK_PHASE_PROMISES[$step]}:${audit_file}:${min_audits}"
}

# __dk_run_phases_inline <wt_name> <wt_dir> <default_branch> <start_step> <state_file> <times_file> <resume_hint> [workspace_mode] [session_id] [raw_input]
#
# Same-session lifecycle runner. The shell launches Claude once; the Stop hook
# advances phases by updating state/config files and injecting the next phase's
# instructions back into the existing session. This avoids the Claude TUI
# handoff problem where a completed phase leaves the user needing /exit + resume.
__dk_run_phases_inline() {
  local wt_name="$1" wt_dir="$2" default_branch="$3" step="$4"
  local state_file="$5" times_file="$6" resume_hint="$7"
  local workspace_mode="${8:-worktree}"
  local session_id="${9:-}" raw_input="${10:-}"
  local claude_session_name
  claude_session_name=$(__dk_claude_session_name "$workspace_mode" "$wt_name")

  if ! command -v claude &>/dev/null; then
    dk_error "Claude Code CLI not found in PATH."
    dk_info "Install it from https://docs.anthropic.com/en/docs/claude-code then try again."
    return 1
  fi

  [[ -n "$session_id" ]] || session_id=$(__dk_session_id_for_workspace "$workspace_mode" "$wt_name")

  local had_times_file=0
  [[ -f "$times_file" ]] && had_times_file=1

  __dk_show_header "$wt_name" "$step" "$wt_dir" "$default_branch" "$session_id" "$workspace_mode"
  dk_record_session_branch "$session_id" "$wt_dir"
  __dk_write_state "$state_file" "$step"
  __dk_configure_inline_phase "$step" "$session_id"

  if [[ $step -ge 2 ]]; then
    dk_checkpoint_tag "$step" "$wt_dir"
  fi

  local phase_start_epoch
  phase_start_epoch=$(date +%s)
  mkdir -p "$(dirname "$times_file")"
  echo "${step}:${phase_start_epoch}" >> "$times_file"

  local ctx_file
  ctx_file=$(__dk_build_system_context "$wt_name" "$step" "$session_id" "$wt_dir" "$workspace_mode" "$raw_input")

  local claude_args=("${DK_CLAUDE_FLAGS[@]}" -n "$claude_session_name")
  [[ $had_times_file -eq 1 ]] && claude_args+=(--resume)
  claude_args+=(--append-system-prompt-file "$ctx_file")
  claude_args+=(--settings "{\"statusLine\":{\"type\":\"command\",\"command\":\"bash '${DOYAKEN_DIR}/bin/status-line.sh'\"}}")

  local message
  message=$(__dk_phase_message "$step" "$raw_input" "$workspace_mode" "$wt_dir")
  if [[ $step -eq 3 ]]; then
    message="Begin Phase 3: Review. Invoke the Skill tool with skill: \"dkreviewloop\" to run the 3-clean-pass review loop. Fix any findings it reports and rerun until it reports SUCCESS. Scope boundaries: review and fix only; do not commit, push, create branches, or create PRs. When the review loop is successful, stop so the Stop hook can audit and advance."
  fi

  local session_timeout="${DOYAKEN_SESSION_TIMEOUT:-$DK_SESSION_TIMEOUT}"
  local _dk_watchdog_pid="" _dk_pidfile=""
  _dk_pidfile=$(mktemp "${TMPDIR:-/tmp}/dk-inline.XXXXXX")

  if [[ "$session_timeout" -gt 0 ]]; then
    eval '(
      local tgt=""
      while [[ -z "$tgt" ]]; do
        [[ -s "$_dk_pidfile" ]] && tgt=$(<"$_dk_pidfile")
        [[ -z "$tgt" ]] && sleep 0.2
      done
      sleep "$session_timeout" 2>/dev/null
      kill -TERM -"$tgt" 2>/dev/null
    ) &!
    _dk_watchdog_pid=$!'
  fi

  (
    sh -c 'echo $PPID' > "$_dk_pidfile"
    cd "$wt_dir" && \
    DOYAKEN_SESSION_ID="$session_id" \
    DOYAKEN_LOOP_ACTIVE=1 \
    DOYAKEN_LOOP_PROMISE="${DK_PHASE_PROMISES[$step]}" \
    DOYAKEN_LOOP_PHASE="$step" \
    DOYAKEN_PHASE_HANDOFF=inline \
    DOYAKEN_COMPLETE_MAX_CYCLES="${DOYAKEN_COMPLETE_MAX_CYCLES:-$DK_COMPLETE_MAX_CYCLES}" \
    DOYAKEN_COMPLETE_WAIT_MINUTES="${DOYAKEN_COMPLETE_WAIT_MINUTES:-$DK_COMPLETE_WAIT_MINUTES}" \
    DOYAKEN_DIR="$DOYAKEN_DIR" \
    __dk_claude "${claude_args[@]}" "$message"
  )
  local exit_code=$?
  rm -f "$_dk_pidfile"
  [[ -n "$_dk_watchdog_pid" ]] && kill "$_dk_watchdog_pid" 2>/dev/null

  local final_step="$step"
  [[ -f "$state_file" ]] && final_step=$(cat "$state_file" 2>/dev/null || echo "$step")
  [[ "$final_step" =~ ^[1-7]$ ]] || final_step="$step"

  local loop_file
  loop_file=$(dk_loop_file "$session_id")
  if [[ "$final_step" -lt 7 && -f "$loop_file" ]]; then
    local raw_iter iterations max_iterations pause_reason
    raw_iter=$(cat "$loop_file" 2>/dev/null || echo "0")
    iterations="${raw_iter%%:*}"
    [[ "$iterations" =~ ^[0-9]+$ ]] || iterations=0
    max_iterations="${DOYAKEN_LOOP_MAX_ITERATIONS:-30}"
    pause_reason="phase did not complete"
    if [[ "$iterations" -ge "$max_iterations" ]]; then
      pause_reason="max audit iterations reached (${iterations}/${max_iterations})"
    fi

    rm -f "$loop_file" "$(dk_active_file "$session_id")" "$(dk_loop_config_file "$session_id")" "$(dk_handoff_mode_file "$session_id")" "$(dk_paused_file "$session_id")" 2>/dev/null
    dk_provider_cleanup_session_state "$session_id"

    echo ""
    echo "Paused at Phase ${final_step}: ${DK_PHASE_NAMES[$final_step]} (${pause_reason})"
    echo "Resume with: ${resume_hint}"
    return 1
  fi

  if [[ "$final_step" -ge 7 ]]; then
    dk_provider_cleanup_session_state "$session_id"
    rm -f "$(dk_active_file "$session_id")" "$(dk_loop_config_file "$session_id")" "$(dk_handoff_mode_file "$session_id")" 2>/dev/null
    __dk_show_header "$wt_name" 7 "$wt_dir" "$default_branch" "$session_id" "$workspace_mode"
    echo ""
    echo "Ticket lifecycle complete."
    if [[ "$workspace_mode" == "worktree" ]]; then
      echo "Run dkrm ${wt_name} to clean up the worktree when you're done."
    else
      echo "No worktree cleanup is needed; this lifecycle ran in the current checkout."
    fi
    return 0
  fi

  if [[ $exit_code -ne 0 ]]; then
    echo ""
    echo "Paused at Phase ${final_step}: ${DK_PHASE_NAMES[$final_step]} (exit ${exit_code})"
    echo "Resume with: ${resume_hint}"
    return "$exit_code"
  fi

  echo ""
  echo "Claude session exited at Phase ${final_step}: ${DK_PHASE_NAMES[$final_step]}."
  echo "Resume with: ${resume_hint}"
  return 0
}

# __dk_run_phases <wt_name> <wt_dir> <default_branch> <start_step> <state_file> <times_file> <resume_hint> [workspace_mode] [session_id] [raw_input]
#
# Phase lifecycle entrypoint. Launches one Claude session and lets the Stop hook
# advance phases inline.
# Phase 6 (Complete) is autonomous: it marks the PR ready, requests configured
# reviewers (see doyaken.md § Reviewers), monitors CI/reviews, addresses comments,
# and closes the ticket. The user is in the loop only as a configured reviewer.
# Returns non-zero if user interrupts or an error occurs.
__dk_run_phases() {
  __dk_run_phases_inline "$@"
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
    echo "       dk refine <N|description>  Refine a ticket before implementation"
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

  # Refine subcommand — intercept before worktree setup (read-only flow)
  if [[ "$1" == "refine" ]]; then
    shift
    dkrefine "$@"
    return $?
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

    if [[ "$_dk_workspace_mode" == "in-place" ]]; then
      __dk_restore_in_place_session_branch "$_dk_session_id" "$_dk_wt_name" "$_dk_wt_dir" "dk --resume" || return 1
    else
      dk_record_session_branch "$_dk_session_id" "$_dk_wt_dir"
    fi

    # Reconstruct the original request for resume prompts. Freeform task
    # sessions persist the human-readable prompt; ticket sessions fall back to
    # the stable workspace name.
    local session_id state_file times_file
    session_id="$_dk_session_id"
    state_file=$(dk_state_file "$session_id")
    times_file=$(dk_times_file "$session_id")
    local raw_input="$_dk_wt_name"
    local prompt_file
    prompt_file=$(dk_prompt_file "$session_id")
    if [[ -s "$prompt_file" ]]; then
      raw_input=$(cat "$prompt_file" 2>/dev/null || echo "$raw_input")
    fi
    _dk_default_branch=$(dk_default_branch "$_dk_wt_dir")

    # Fall through to the phase loop below
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

  if [[ $_dk_is_task -eq 1 ]]; then
    mkdir -p "$DK_LOOP_DIR"
    __dk_write_state "$(dk_prompt_file "$session_id")" "$raw_input"
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
  # Dangerous skip permissions + EnterPlanMode — read-only without interactive prompts.
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

# ─── dkrefine — standalone ticket refinement (pre-implementation) ─────────
#
# Single Claude session in plan mode. Drives the user through 3+ batches of
# clarifying questions focused on high-level architecture and risks, then
# presents a PO-grade refined ticket via ExitPlanMode. On approval, the
# dkrefine skill posts architecture/risk comments and creates sub-tickets on
# the configured tracker; the parent ticket's description is left untouched.
#
# No worktree, no commits, no branch rename. No phase-loop participation.

unalias dkrefine 2>/dev/null; unfunction dkrefine 2>/dev/null
dkrefine() {
  __dk_refresh_provider || return 1

  if [[ $# -eq 0 ]]; then
    echo "Usage: dkrefine <NUMBER>           (e.g. dkrefine 123, dkrefine ENG-123)"
    echo "       dkrefine \"<description>\"    (e.g. dkrefine \"streaming export pipeline\")"
    return 1
  fi

  if ! command -v claude &>/dev/null; then
    dk_error "Claude Code CLI not found in PATH."
    dk_info "Install it from https://docs.anthropic.com/en/docs/claude-code then try again."
    return 1
  fi

  # Must be in a git repo so the skill can read AGENTS.md and codebase context.
  local repo_root
  repo_root=$(dk_repo_root) || return 1

  local raw_input="${(j: :)@}"

  # Session label for the Claude session name — stable across invocations on
  # the same input so the user can recognize it.
  local session_label
  if __dk_is_ticket "$raw_input"; then
    session_label="ticket-${raw_input//[^0-9]/}"
  else
    local slug
    slug=$(dk_slugify "${raw_input:0:40}")
    session_label="${slug:-$(date +%s)}"
  fi
  local session_name="dkrefine-${session_label}"

  # Unique state id so concurrent dkrefines don't collide on provider state.
  local session_id
  session_id="refine-$(dk_unique_session_id)"
  dk_provider_cleanup_session_state "$session_id"

  local branch
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  DOYAKEN — dkrefine (ticket refinement)"
  echo ""
  echo "  Branch: ${branch}"
  echo "  Input:  ${raw_input:0:72}$([ ${#raw_input} -gt 72 ] && echo '...')"
  echo "  Phase:  Refine (read-only until ExitPlanMode is approved)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  local plan_args=("${DK_PLAN_FLAGS[@]}" -n "$session_name")
  plan_args+=(--append-system-prompt "You are in a dkrefine session — refinement only. Do NOT implement, do NOT commit, do NOT rename branches, do NOT set ticket status to In Progress. Stay in plan mode until you call ExitPlanMode. After approval, follow the dkrefine skill's write-back steps and stop.

Standing platform constraints (apply to every refinement):
- The system is multi-tenant. All new configuration, data, and computation must be tenant-scoped; cross-tenant isolation must be preserved.
- The system is compute-heavy with a low user count (not high-traffic). Performance targets are about latency of a single computation and the scope of cascade recomputes, not requests-per-second. Naive whole-plan recomputes on every edit are a red flag — call out cascade scope, memoization, and incremental recomputation in the NFRs.

Anchor every claim about where something lives to a real path in this repo. Reuse beats invent — justify every 'new X' against the existing X you found.")

  DOYAKEN_SESSION_ID="$session_id" \
  DOYAKEN_DIR="$DOYAKEN_DIR" \
  __dk_claude "${plan_args[@]}" \
    "This is a TECHNICAL refinement, not product discovery.

Input: ${raw_input}

Pre-flight (BEFORE EnterPlanMode — plan mode is read-only, so the architecture-map file write must happen first):
 0. Run: bash -lc 'test -f \"\$(git rev-parse --show-toplevel)/.doyaken/architecture.md\" && echo MAP_PRESENT || echo MAP_MISSING'
    - If MAP_MISSING: invoke the Skill tool with skill: \"dkarchitect\" to bootstrap .doyaken/architecture.md (it writes the file directly; the user reviews and commits it themselves — the skill does NOT commit). Remember in working memory that the map was freshly built so you can flag it in the final summary.
    - If MAP_PRESENT: continue.

Now call EnterPlanMode, then invoke the Skill tool with skill: \"dkrefine\". Skill flow:
 1. Gather ticket context (if a ticket id).
 2. Read .doyaken/architecture.md (C4 levels 1-3) — this is the canonical current-state map and the source of valid Domain values for sub-tickets.
 3. Ask the user at least four batches of clarifying questions covering scope, architecture & integration, scale & multi-tenancy, and operational risk. Skip PO-flavor probes (value hypothesis, user stories).
 4. Identify the design patterns that fit, with each tied to a sub-ticket (or record '— none, all sub-tickets are mechanical' if genuinely mechanical).
 5. Decompose into AT LEAST TWO sub-tickets, each tagged with a Domain (a C4 container or component name from the architecture map verbatim), a t-shirt size (XS/S/M/L/XL), and a dominant design pattern. Decomposition is the defining output of dkrefine — if the work cannot be split, bail out and tell the user to run dk <ticket> directly.
 6. Present a /dkplan-style summary via ExitPlanMode, including a per-Domain rollup so the user can dispatch sub-tickets to owners.
 7. After approval, create the sub-tickets (with Domain in body and as a label if the tracker supports it) and post five comments on the parent (architecture+component map, design patterns, risks, NFRs, open questions+decision log). Do NOT modify the parent ticket's description. If the architecture map was bootstrapped in step 0, remind the user to commit .doyaken/architecture.md themselves.
$(__dk_provider_prompt)"

  local exit_code=$?
  dk_provider_cleanup_session_state "$session_id"
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
  rm -f "$(dk_complete_file "$session_id")" "$(dk_loop_file "$session_id")" "$(dk_watch_pause_file "$session_id")"

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

  # Standalone review uses the detailed single-pass adversarial audit.
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
  old_files=$(dk_cleanup_stale_files "$DK_LOOP_DIR" "state complete active prompt config findings debt provider busy busy-notice started ready watch-pause watch-lock" 7)
  if [[ "$old_files" -gt 0 ]]; then
    echo "  Cleaned ${old_files} old loop state file(s)"
    cleaned=$((cleaned + old_files))
  fi

  # 5. Clean up old phase state files (older than 7 days)
  local old_phase_files
  old_phase_files=$(dk_cleanup_stale_files "$DK_STATE_DIR" "phase times system-context log branch" 7)
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
