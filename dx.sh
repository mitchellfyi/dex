# shellcheck shell=bash disable=SC1091,SC2296
# ^ dx.sh is zsh-only; SC2296 suppresses zsh parameter expansion syntax warnings.
# Dex — Shell functions (zsh only)
#
# Source this in ~/.zshrc:
#   source $DEX_DIR/dx.sh
#
# Requires zsh — uses zsh-specific syntax (e.g., ${(j: :)@} for array joining).
# Hook scripts (hooks/*.sh) use #!/usr/bin/env bash. Library files (lib/*.sh)
# use bash/zsh-compatible syntax and are sourced by both dx.sh and hook scripts.
#
# Provides:
#   dx <number>             Start/resume the full autonomous lifecycle (Plan → Complete) for a ticket
#   dx "description"        Same, for a task without a ticket
#   dx --agent codex <task> Use a different agent for this invocation
#   dx --model <model>      Pass a model override to the selected agent
#   dx --resume             Resume the most recent session
#   dx --from-pr <N>        Resume session linked to a PR
#   dxcomplete              Standalone completion workflow (recovery / non-dx PRs)
#   dxreviewloop            Standalone adaptive review of changes, or whole codebase if clean
#   dxrm <number|name|--all>  Remove a worktree
#   dxls                   List worktrees
#   dxcd [number|name]      Navigate to a worktree, or the repo root with no argument
#   dxclean                Clean stale worktrees + gone branches
#   dxloop <prompt>         Run a prompt until fully implemented
#   dx sync                 Refresh repo memory/rules from verified observations
#   dx login                Connect this CLI to DexCode sync
#   dx maintain             Run background maintenance or install workflow
#   dx tools                Check or install Claude/Codex tooling bootstrap
#   dx test [dex|project]   Run Dex checks or verify the current project
#   dx run --spec <file>    Run from a structured headless run spec
#   dx control <action>     Pause, stop, advance, jump, or resume a lifecycle
#   dx sessions             Inspect and diagnose lifecycle sessions
#   dex                   Alias for dx
#   dexter                Alias for dx

if [ -n "${BASH_VERSION:-}" ]; then
  printf '%s\n' "ERROR: dx.sh requires zsh. Run it with 'zsh dx.sh ...' or source it from a zsh session." >&2
  if [ "${BASH_SOURCE[0]:-}" != "$0" ]; then
    return 2
  else
    exit 2
  fi
fi

__DX_SH_LOADED_PATH="${(%):-%N}"
__DX_SH_EXECUTED=0
if [[ ":${ZSH_EVAL_CONTEXT:-}:" != *":file:"* ]]; then
  __DX_SH_EXECUTED=1
fi

if [[ -z "${DEX_DIR:-}" ]]; then
  if [[ -n "$__DX_SH_LOADED_PATH" && -f "$__DX_SH_LOADED_PATH" ]]; then
    __DX_SH_LOADED_ABS="${__DX_SH_LOADED_PATH:A}"
    export DEX_DIR="${__DX_SH_LOADED_ABS:h}"
  else
    echo "ERROR: DEX_DIR not set. Run 'dx install' first." >&2
    return 1
  fi
fi
source "$DEX_DIR/lib/common.sh"

# ─── Dex management CLI ──────────────────────────────────────────────
# unalias/unfunction before each function definition so this file can be
# re-sourced (e.g. via `dx reload`) without "already defined" errors.

unalias __dx_cli 2>/dev/null; unfunction __dx_cli 2>/dev/null
__dx_cli() {
  local cmd="${1:-help}"
  shift 2>/dev/null || true

  case "$cmd" in
    install)   bash "$DEX_DIR/bin/install.sh" "$@" ;;
    uninstall) bash "$DEX_DIR/bin/uninstall.sh" "$@" ;;
    init)      bash "$DEX_DIR/bin/init.sh" "$@" ;;
    sync)      bash "$DEX_DIR/bin/sync.sh" "$@" ;;
    login)     dx_dexcode_login "$@" ;;
    logout)    dx_dexcode_logout "$@" ;;
    whoami)    dx_dexcode_whoami "$@" ;;
    dexcode)   dx_dexcode_command "$@" ;;
    worker)    dx_worker_command "$@" ;;
    maintain)  bash "$DEX_DIR/bin/maintain.sh" "$@" ;;
    tools)     bash "$DEX_DIR/bin/tools.sh" "$@" ;;
    test)      bash "$DEX_DIR/bin/test.sh" "$@" ;;
    config)    bash "$DEX_DIR/bin/config.sh" "$@" ;;
    provider)  dx_provider_command "$@" ;;
    run)       __dx_run_spec_cli "$@" ;;
    control)   bash "$DEX_DIR/bin/control.sh" "$@" ;;
    sessions)  bash "$DEX_DIR/bin/sessions.sh" "$@" ;;
    research)
      local _dx_has_max_cycles=0 _dx_has_runner=0 _dx_research_help=0 _dx_arg
      local _dx_research_args=("$@")
      for _dx_arg in "$@"; do
        if [[ "$_dx_arg" == "--max-cycles" || "$_dx_arg" == --max-cycles=* ]]; then
          _dx_has_max_cycles=1
        elif [[ "$_dx_arg" == "--runner" || "$_dx_arg" == --runner=* ]]; then
          _dx_has_runner=1
        elif [[ "$_dx_arg" == "--help" || "$_dx_arg" == "-h" ]]; then
          _dx_research_help=1
        fi
      done
      if [[ $_dx_research_help -eq 0 && $_dx_has_runner -eq 0 ]]; then
        dx_provider_apply || return 1
        if [[ "${DX_PROVIDER_AGENT:-claude}" == "codex" ]]; then
          _dx_research_args=(--runner codex "${_dx_research_args[@]}")
        fi
      fi
      if [[ $_dx_has_max_cycles -eq 0 ]]; then
        bash "$DEX_DIR/research/orchestrate.sh" --max-cycles 20 "${_dx_research_args[@]}"
      else
        bash "$DEX_DIR/research/orchestrate.sh" "${_dx_research_args[@]}"
      fi
      ;;
    uninit)    bash "$DEX_DIR/bin/uninit.sh" "$@" ;;
    reload)
      if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
        echo "Usage: dx reload"
        echo ""
        echo "Reload Dex shell functions after updating the installation."
        return 0
      fi
      if [[ $# -gt 0 ]]; then
        dx_error "dx reload does not accept arguments."
        dx_info "Usage: dx reload"
        return 1
      fi
      source "$DEX_DIR/dx.sh"
      echo "Reloaded Dex shell functions."
      ;;
    status)    bash "$DEX_DIR/bin/status.sh" "$@" ;;
    help|--help|-h)
      echo "Dex — workflow automation for Claude Code"
      echo ""
      echo "Global options:"
      echo "  --agent <claude|codex>  Use this agent for the current invocation"
      echo "  --model <model>         Pass this model to the selected agent"
      echo ""
      echo "Commands:"
      echo "  dx install          Global install (skills, hooks, zshrc)"
      echo "  dx uninstall        Global uninstall"
      echo "  dx init             Bootstrap current repo for Dex"
      echo "  dx sync             Refresh repo memory/rules from verified observations"
      echo "  dx login            Connect this machine to DexCode sync"
      echo "  dx whoami           Show the active DexCode account and project"
      echo "  dx logout           Disconnect DexCode sync on this machine"
      echo "  dx dexcode          Manage the DexCode connection and selected project"
      echo "  dx worker           Register this machine and run DexCode-dispatched work"
      echo "  dx maintain         Run background maintenance or install the GitHub workflow"
      echo "  dx tools            Check or install Claude/Codex tooling bootstrap"
      echo "  dx test             Run Dex checks or verify the current project"
      echo "  dx config           Configure integrations (ticket tracker, Figma, etc.)"
      echo "  dx provider         Configure provider/model execution profiles"
      echo "  dx run --spec FILE  Run the lifecycle from a structured headless run spec"
      echo "  dx run --spec-url URL --run-token TOKEN"
      echo "  dx control          Pause, stop, advance, jump, or resume the current lifecycle"
      echo "  dx sessions         Inspect and diagnose lifecycle sessions"
      echo "  dx research         Run autonomous research orchestrator"
      echo "                        Defaults: --max-cycles 20; SCENARIO_TIMEOUT 3600s (1h) per scenario"
      echo "                        Override timeout: dx research --scenario-timeout 7200"
      echo "                        On main/master, pass --allow-main"
      echo "  dx uninit           Remove Dex from current repo"
      echo "  dx reload           Reload shell functions after editing dx.sh"
      echo "  dx status           Show installation status"
      echo "  dex                 Alias for dx"
      echo "  dexter              Alias for dx"
      echo ""
      echo "Worktree commands:"
      echo "  dx <number>            Run autonomous lifecycle (Plan → Complete) for a ticket"
      echo "  dx \"<description>\"     Same, for a task without a ticket"
      echo "                         (a single word that looks like a mistyped command asks first)"
      echo "  dx --agent codex --model gpt-5.3-codex \"<task>\""
      echo "  dx --no-worktree <task> Run lifecycle in the current checkout instead"
      echo "  dx --resume            Resume the most recent session"
      echo "  dx --from-pr <N>      Resume session linked to a PR"
      echo "  dx revert <N> [phase] Revert worktree to a phase checkpoint"
      echo "  dx log [session_id]   Show structured phase execution log"
      echo "  dxrm <number|name>    Remove a worktree"
      echo "  dxrm --all            Remove all worktrees"
      echo "  dxls                  List worktrees"
      echo "  dxcd [number|name]    Open a worktree, or the repo root with no argument"
      echo "  dxclean               Clean stale worktrees + gone branches"
      echo ""
      echo "Refinement (pre-implementation):"
      echo "  dx refine <N|description>  Refine a ticket — clarify with the user, raise risks, propose sub-tickets"
      echo ""
      echo "Standalone completion (recovery / non-dx PRs):"
      echo "  dxcomplete             Monitor CI/reviews, address comments, close ticket"
      echo ""
      echo "Standalone review (agent-selected risk tier with a trusted clean-pass gate):"
      echo "  dxreviewloop           Review current changes, or whole codebase if clean"
      echo ""
      echo "Prompt loop:"
      echo "  dxloop <prompt>          Run a prompt until fully implemented"
      echo ""
      echo "Autonomous lifecycle phases (run automatically by dx):"
      echo "  1. Plan            Gather context, draft plan, get approval"
      echo "  2. Implement       Work through tasks with TDD; capture UI before/after evidence"
      echo "  3. Review          Adaptive adversarial code review"
      echo "  4. Verify & Commit Format, lint, typecheck, test, then commit + push"
      echo "  5. PR              Generate PR description, prepare visual handoff, create draft PR + attach reviewers"
      echo "  6. Complete        Mark ready, request reviewers, monitor CI/reviews, close ticket"
      ;;
    revert)
      # dx revert <ticket> [phase] — revert worktree to a phase checkpoint
      local raw="${1:-}"
      if [[ -z "$raw" ]]; then
        echo "Usage: dx revert <ticket|name> [phase]"
        return 1
      fi
      local rev_phase="${2:-}"
      local rev_name ticket_number=""
      if __dx_is_ticket "$raw"; then
        ticket_number="${raw//[^0-9]/}"
        rev_name="ticket-${ticket_number}"
      else
        rev_name="task-$(dx_slugify "$raw")"
      fi
      local rev_root
      rev_root=$(dx_repo_root) || return 1
      local rev_dir="${rev_root}/.dex/worktrees/${rev_name}"
      if [[ -n "$ticket_number" && ! -d "$rev_dir" ]]; then
        local resolution_status=0
        __dx_resolve_existing_workspace_by_ticket "$ticket_number" || resolution_status=$?
        if [[ $resolution_status -eq 0 ]]; then
          if [[ "$_dx_workspace_mode" != "worktree" ]]; then
            dx_error "Ticket ${ticket_number} uses an in-place lifecycle; dx revert only accepts linked worktrees."
            return 1
          fi
          rev_name="$_dx_wt_name"
          rev_dir="${rev_root}/.dex/worktrees/${rev_name}"
          dx_info "Resolved ticket ${ticket_number} to existing workspace ${rev_name}"
        elif [[ $resolution_status -ne 1 ]]; then
          return 1
        fi
      fi
      if [[ ! -d "$rev_dir" ]]; then
        dx_error "Worktree ${rev_name} not found."
        return 1
      fi
      if ! dx_wt_is_registered "$rev_root" "$rev_dir"; then
        dx_error "Workspace path is not a registered Git worktree: ${rev_dir}"
        return 1
      fi
      if [[ -z "$rev_phase" ]]; then
        # Find the most recent checkpoint owned by this worktree.
        local latest_phase
        latest_phase=$(dx_latest_checkpoint_phase "$rev_dir" 2>/dev/null || true)
        if [[ -z "$latest_phase" ]]; then
          dx_info "No checkpoints found for ${rev_name}."
          return 1
        fi
        rev_phase="$latest_phase"
      fi
      echo "Reverting ${rev_name} to checkpoint for phase ${rev_phase}..."
      dx_revert_to_checkpoint "$rev_phase" "$rev_dir"
      ;;
    log)
      bash "$DEX_DIR/bin/log.sh" "$@"
      ;;
    *)
      dx_error "Unknown command: $cmd"
      dx_info "Run 'dx help' for usage."
      return 1
      ;;
  esac
}

# ─── Phase configuration ────────────────────────────────────────────────────

# Capture explicit user overrides before provider profiles fill defaults.
# shellcheck disable=SC2034
DX_USER_CLAUDE_MODEL="${DX_CLAUDE_MODEL:-}"
if [[ -n "${DX_PROVIDER_LAST_CLAUDE_MODEL:-}" && "$DX_USER_CLAUDE_MODEL" == "$DX_PROVIDER_LAST_CLAUDE_MODEL" ]] || [[ -n "${DX_PROVIDER_LAST_PROVIDER_MODEL:-}" && "$DX_USER_CLAUDE_MODEL" == "$DX_PROVIDER_LAST_PROVIDER_MODEL" ]]; then
  DX_USER_CLAUDE_MODEL=""
fi
# shellcheck disable=SC2034
DX_USER_PLAN_MODEL="${DX_PLAN_MODEL:-}"
if [[ -n "${DX_PROVIDER_LAST_PLAN_MODEL:-}" && "$DX_USER_PLAN_MODEL" == "$DX_PROVIDER_LAST_PLAN_MODEL" ]] || [[ -n "${DX_PROVIDER_LAST_PROVIDER_PLAN_MODEL:-}" && "$DX_USER_PLAN_MODEL" == "$DX_PROVIDER_LAST_PROVIDER_PLAN_MODEL" ]]; then
  DX_USER_PLAN_MODEL=""
fi
# shellcheck disable=SC2034
DX_USER_CLAUDE_EFFORT="${DX_CLAUDE_EFFORT:-}"
if [[ -n "${DX_PROVIDER_LAST_CLAUDE_EFFORT:-}" && "$DX_USER_CLAUDE_EFFORT" == "$DX_PROVIDER_LAST_CLAUDE_EFFORT" ]] || [[ -n "${DX_PROVIDER_LAST_PROVIDER_EFFORT:-}" && "$DX_USER_CLAUDE_EFFORT" == "$DX_PROVIDER_LAST_PROVIDER_EFFORT" ]]; then
  DX_USER_CLAUDE_EFFORT=""
fi
# shellcheck disable=SC2034
DX_USER_PLAN_EFFORT="${DX_PLAN_EFFORT:-}"
if [[ -n "${DX_PROVIDER_LAST_PLAN_EFFORT:-}" && "$DX_USER_PLAN_EFFORT" == "$DX_PROVIDER_LAST_PLAN_EFFORT" ]] || [[ -n "${DX_PROVIDER_LAST_PROVIDER_PLAN_EFFORT:-}" && "$DX_USER_PLAN_EFFORT" == "$DX_PROVIDER_LAST_PROVIDER_PLAN_EFFORT" ]]; then
  DX_USER_PLAN_EFFORT=""
fi


DX_CLAUDE_FLAGS=(--chrome --dangerously-skip-permissions --permission-mode bypassPermissions)
if [[ -n "${DX_CLAUDE_MODEL:-}" ]]; then
  DX_CLAUDE_FLAGS+=(--model "$DX_CLAUDE_MODEL")
fi
if [[ -n "${DX_CLAUDE_EFFORT:-}" ]]; then
  DX_CLAUDE_FLAGS+=(--effort "$DX_CLAUDE_EFFORT")
fi
DX_PLAN_FLAGS=(--chrome --dangerously-skip-permissions --permission-mode bypassPermissions)
if [[ -n "${DX_PLAN_MODEL:-${DX_CLAUDE_MODEL:-}}" ]]; then
  DX_PLAN_FLAGS+=(--model "${DX_PLAN_MODEL:-$DX_CLAUDE_MODEL}")
fi
if [[ -n "${DX_PLAN_EFFORT:-${DX_CLAUDE_EFFORT:-}}" ]]; then
  DX_PLAN_FLAGS+=(--effort "${DX_PLAN_EFFORT:-$DX_CLAUDE_EFFORT}")
fi

# Phase 1 uses dangerous skip permissions plus bypassPermissions to avoid
# interactive prompts. Claude calls EnterPlanMode as its first action to
# enforce read-only until user approves via ExitPlanMode.





unalias __dx_phase_message 2>/dev/null; unfunction __dx_phase_message 2>/dev/null
__dx_phase_message() {
  local step="$1"
  local raw_input="${2:-}"
  local workspace_mode="${3:-worktree}"
  local wt_dir="${4:-}"
  if [[ "$step" -eq 0 ]]; then
    printf '%s\n' "$DX_PHASE_0_MESSAGE"
  else
    printf '%s\n' "${DX_PHASE_MESSAGES[$step]}"
  fi
  __dx_provider_prompt
  if [[ -n "$raw_input" ]] || [[ "$workspace_mode" == "in-place" ]]; then
    printf '%s\n' ""
    printf '%s\n' "## Dex Request Context"
    [[ -n "$raw_input" ]] && printf 'Original request: %s\n' "$raw_input"
    if [[ "$workspace_mode" == "in-place" ]]; then
      printf '%s\n' "Workspace mode: in-place. No Dex worktree was created."
      [[ -n "$wt_dir" ]] && printf 'Current checkout: %s\n' "$wt_dir"
      printf '%s\n' "Use the current checkout and Dex-managed branch; do not create or switch branches unless ticket setup instructions explicitly require a branch rename."
    fi
  fi
}

# Phase launch messages (zsh array, 1-indexed, so index 1 = Phase 1). Phase 0
# (Setup) bootstraps ticket state before planning begins; its message lives in
# DX_PHASE_0_MESSAGE because zsh aliases arr[0] to arr[1]. Phases 1-6 then run
# autonomously via `dx`. Phase 6 marks the PR ready, requests the configured
# reviewers, monitors CI/reviews, and closes the ticket. Phase names,
# completion promises, audit basenames, and min-audit counts come from the
# shared tables in lib/lifecycle-control.sh via the __dx_phase_* helpers below.
DX_PHASE_MESSAGES=(\
  "Phase 0 setup (branch rename, push, ticket status → In Progress, assignment) is already complete. Do NOT redo it unless you find it missing.

Call EnterPlanMode now. Then immediately invoke the dxplan skill using the Skill tool with skill: \"dxplan\" (or /dxplan if slash skills are the available interface). Do not fetch the ticket again, rename branches, update tracker status, explore the codebase, or draft the plan by hand outside the dxplan skill unless the skill explicitly instructs you to.

The dxplan skill writes the required Phase 1 lifecycle markers. For freeform \`dx \"<task>\"\` requests with a configured tracker, after the user approves the plan, offer the dxplan tracker intake choices before writing the Phase 1 ready marker: continue without tracker write-back, create a parent ticket, or create a parent plus sub-issues and select the first implementation ticket. After that gate is complete or explicitly skipped, follow the dxplan completion instructions, then stop once so the Dex Stop hook can audit the approved plan and advance to Phase 2 automatically. Do NOT tell the user to run /dximplement and do NOT wait for another prompt.

For headless dx run sessions with workflow.requires_plan_approval=false, the run spec authorizes Phase 1 after the normal plan quality checks pass; follow the dxplan headless instructions instead of waiting for interactive approval." \
  "The plan is approved. You MUST invoke the Skill tool with skill: \"dximplement\" to begin implementation. Do NOT implement ad-hoc — the skill enforces TDD and quality gates. For UI-affecting changes, Phase 2 must invoke dxuicapture before UI edits for baseline evidence, then capture after evidence and link the visual manifest/screenshots/videos/traces before stopping. Phase focus: implementation, testing, and UI capture evidence. Commit, push, branch, and PR actions remain available when useful; later phases still perform the canonical verification, commit, and PR handoff. When done, stop — the audit loop will verify your work." \
  "Begin Phase 3: Review. Invoke the Skill tool with skill: \"dxreviewloop\". Use the current Phase 2 risk selection: small requires 1, normal 3, and complex 6 consecutive independent CLEAN waves. Each fresh wave builds its own context pack, runs deterministic checks and domain review, verifies findings, batch-fixes safe issues, and rechecks. Fixes reset the clean streak; residual findings, blockers, churn, invalid results, and provider failures pause the loop. Phase focus: review and fixes. Commit, push, branch, and PR actions remain available when useful; later phases still perform their normal handoff steps. When the loop writes a valid success receipt, stop — the audit loop will verify." \
  "Invoke the Skill tool with skill: \"dxverify\" to run the quality pipeline (format, lint, typecheck, test). Fix any failures and re-run until all green. Then invoke skill: \"dxcommit\" to commit and push. Phase focus: verification and the canonical commit, but PR creation and implementation fixes remain available when useful. When pushed, stop — the audit loop will verify." \
  "Invoke the Skill tool with skill: \"dxpr\" to generate the PR description, prepare any UI visual evidence handoff, create the draft PR, and attach the configured 'request' reviewers from dex.md § Reviewers. Phase focus: PR creation, description, and artifact handoff. Marking ready, posting @mentions, implementation changes, commits, and pushes remain available when useful; Phase 6 still performs the normal completion workflow. When done, stop — the audit loop will verify." \
  "Invoke the Skill tool with skill: \"dxcomplete\". Phase 6 follows the cycle-loop audit prompt: mark the PR ready, request reviewers from dex.md § Reviewers, post @mention comments for mention-type reviewers, launch /loop 5m /dxwatchpr, re-read the current completion wait/cycle defaults, address CI failures and review comments via the PR watcher, re-request reviewers after each push, and close the ticket when CI is green and all successfully requested reviewers have approved. If the current bounded wait expires, pause with manual follow-up instructions. Stop — the audit loop will verify." \
)

DX_PHASE_0_TIMEOUT="0"
DX_PHASE_0_MESSAGE="Begin Phase 0: Setup. This phase runs in NORMAL mode (no plan mode) so you can write to git and the tracker. Follow prompts/ticket-instructions.md (printed at SessionStart) end to end before doing anything else: (a) read the ticket from the configured tracker, including comments; (b) check the assignee — if unassigned, assign to the authenticated user; if assigned to someone else, STOP and warn; (c) rename the lifecycle branch to the tracker's git branch name and push it; PR creation is normally deferred until Phase 5 but remains available when useful; (d) set ticket status to In Progress; (e) if the description is empty/unclear, draft acceptance criteria, present to the user, and update the ticket. If no tracker is configured, push the current lifecycle branch and proceed. Phase focus: ticket setup. Planning and implementation normally begin in later phases, but commits, pushes, branches, and PR actions remain available. When setup is complete, write the Phase 0 ready marker (\`dx_phase_ready_file\` for step 0) and stop once so the Stop hook can audit and advance to Phase 1 automatically. Do NOT tell the user to run /dxplan and do NOT wait for another prompt."

# Thin wrappers over the shared phase tables in lib/lifecycle-control.sh; the
# __dx_ names stay because dx.sh uses them throughout.

# __dx_phase_name <step>
__dx_phase_name() { dx_lifecycle_phase_label "$1"; }

# __dx_phase_promise <step>
__dx_phase_promise() { dx_lifecycle_phase_promise "$1"; }

# __dx_phase_audit_basename <step>
__dx_phase_audit_basename() { dx_lifecycle_phase_audit_basename "$1"; }

# __dx_phase_min_audits <step>
# Respects the DEX_PHASE_<step>_MIN_AUDITS env override; defaults to 1.
__dx_phase_min_audits() { dx_lifecycle_phase_min_audits "$1"; }

# Session timeout in seconds — single budget for the entire dx run (all phases).
# Default: 86400 (24 hours). Set to 0 to disable.
# Override: DEX_SESSION_TIMEOUT=14400 (4h)
DX_SESSION_TIMEOUT=86400

# Review sub-loop configuration.
# Lifecycle Phase 3 uses the /dxreviewloop skill in the same Claude session.
# A risk assessment selects small/normal/complex before the first review wave.
# The trusted default-branch policy (lib/review-policy.sh) maps that tier to a
# clean-pass gate, using 1/3/6 by default. Legacy light/standard/thorough
# profile names remain accepted. There is no outer iteration limit; verified
# churn, provider failures, timeouts, invalid evidence, and user interrupts
# pause it.
# Override risk: DEX_REVIEW_TIER=complex
# Raise the loop gate: DEX_REVIEW_CLEAN_PASSES=12
# Review waves launch with MCP servers disabled (waves only use local tools);
# this avoids each spawned session forking node/Chromium MCP processes. Restore
# the inherited MCP config with DEX_REVIEW_DISABLE_MCP=0.

# Phase 6 (Complete) cycle configuration.
# DX_COMPLETE_MAX_CYCLES: max review cycles before escalating to user (default 3).
# DX_COMPLETE_WAIT_MINUTES: minimum wait window per cycle in minutes (default 5).
# Override: DEX_COMPLETE_MAX_CYCLES=5, DEX_COMPLETE_WAIT_MINUTES=10
DX_COMPLETE_MAX_CYCLES=3
DX_COMPLETE_WAIT_MINUTES=5

# Per-phase timeouts are disabled by default (session timeout covers them).
# Set per-phase: DEX_PHASE_2_TIMEOUT=3600
# Set all phases: DEX_PHASE_TIMEOUT=7200
# zsh 1-indexed: [1]=Plan, [2]=Implement, [3]=Review, [4]=Verify, [5]=PR, [6]=Complete
DX_PHASE_TIMEOUTS=("0" "0" "0" "0" "0" "0")

# ─── Internal helpers ───────────────────────────────────────────────────────


# __dx_phase_timeout <step> [session_id]
# Resolve the effective timeout for a phase (seconds). Returns 0 to disable.
# Priority: DEX_PHASE_N_TIMEOUT > DEX_PHASE_TIMEOUT > DX_PHASE_TIMEOUTS[step]
__dx_phase_timeout() {
  local step="$1"
  local session_id="${2:-${DEX_SESSION_ID:-}}" resolved_timeout
  # shellcheck disable=SC2034  # used via zsh ${(P)env_var} indirect expansion below
  local env_var="DEX_PHASE_${step}_TIMEOUT"
  if [[ -n "${(P)env_var:-}" ]]; then
    resolved_timeout="${(P)env_var}"
  elif [[ -n "${DEX_PHASE_TIMEOUT:-}" ]]; then
    resolved_timeout="$DEX_PHASE_TIMEOUT"
  else
    case "$step" in
      0) resolved_timeout="$DX_PHASE_0_TIMEOUT" ;;
      *) resolved_timeout="${DX_PHASE_TIMEOUTS[$step]:-0}" ;;
    esac
  fi
  if dx_lifecycle_session_id_valid "$session_id"; then
    resolved_timeout=$(dx_override_effective "$session_id" phase.timeout \
      "$resolved_timeout" "$step") || return 1
  fi
  echo "$resolved_timeout"
}






# dx_default_branch is provided by lib/git.sh (sourced via lib/common.sh)

# __dx_child_pids <pid>
# Print child PIDs for a process using pgrep when available, with a ps fallback.
unalias __dx_child_pids 2>/dev/null; unfunction __dx_child_pids 2>/dev/null
__dx_child_pids() {
  local pid="$1"
  if command -v pgrep >/dev/null 2>&1; then
    pgrep -P "$pid" 2>/dev/null || true
  else
    ps -axo pid=,ppid= 2>/dev/null | awk -v parent="$pid" '$2 == parent { print $1 }'
  fi
}

# __dx_kill_process_tree <pid> [signal]
# Kill a process and its descendants without assuming the process owns a pgroup.
unalias __dx_kill_process_tree 2>/dev/null; unfunction __dx_kill_process_tree 2>/dev/null
__dx_kill_process_tree() {
  local pid="$1" signal="${2:-TERM}" child
  [[ "$pid" =~ ^[0-9]+$ ]] || return 0

  while IFS= read -r child; do
    [[ "$child" =~ ^[0-9]+$ ]] || continue
    [[ "$child" == "$$" ]] && continue
    __dx_kill_process_tree "$child" "$signal"
  done < <(__dx_child_pids "$pid")

  kill "-${signal}" "$pid" 2>/dev/null || true
}

# __dx_is_ticket <string>
# Returns 0 if the string looks like a ticket reference (bare number, prefixed
# like ENG-999, ticket-999). Returns 1 otherwise (freeform task description).
# Used by __dx_setup_worktree and dxrm to consistently classify user input.
__dx_is_ticket() {
  [[ "$1" =~ ^[[:space:]]*[a-zA-Z]*-?[0-9]+[[:space:]]*$ ]]
}

# __dx_resolve_workspace_name <raw_input>
# Sets: _dx_wt_name, _dx_is_task.
__dx_resolve_workspace_name() {
  local raw_input="$1"

  _dx_is_task=0
  if __dx_is_ticket "$raw_input"; then
    local num="${raw_input//[^0-9]/}"  # strip everything except digits
    _dx_wt_name="ticket-${num}"
  else
    local slug
    slug=$(dx_slugify "$raw_input")
    if [[ -z "$slug" ]]; then
      dx_error "Could not create a valid name from '$raw_input'"
      return 1
    fi
    _dx_wt_name="task-${slug}"
    _dx_is_task=1
  fi
}

# __dx_session_id_for_workspace <workspace_mode> <workspace_name>
# Worktree sessions keep the historic "worktree-*" ids. In-place sessions use
# their own prefix so they do not collide with a same-ticket worktree session.
__dx_session_id_for_workspace() {
  local workspace_mode="$1" wt_name="$2"
  if [[ "$workspace_mode" == "in-place" ]]; then
    local raw_id="inplace-${wt_name}" scoped_id
    scoped_id=$(dx_scoped_session_id "$raw_id")
    printf '%s\n' "$scoped_id"
  else
    dx_session_id "$wt_name"
  fi
}

# Persist the branch before lifecycle work continues. A failed private-state
# write leaves in-place resume without an authoritative branch to restore.
unalias __dx_record_session_branch 2>/dev/null; unfunction __dx_record_session_branch 2>/dev/null
__dx_record_session_branch() {
  local session_id="$1" workspace_dir="$2"
  if dx_record_session_branch "$session_id" "$workspace_dir"; then
    return 0
  fi
  dx_error "Dex could not safely record the lifecycle branch."
  dx_info "Repair or remove the unsafe saved branch file, then try again: $(dx_branch_file "$session_id")"
  return 1
}

# __dx_active_in_place_phase_for_branch <branch>
# Prints the active phase number when a worktree-* branch belongs to an
# in-place lifecycle that is still resumable. Returns 1 when no lifecycle
# matches and 2 when a matching decision cannot trust its saved branch state.
__dx_active_in_place_phase_for_branch() {
  local branch="$1" wt_name phase_val branch_result=0

  if [[ "$branch" == worktree-ticket-* ]] || [[ "$branch" == worktree-task-* ]]; then
    wt_name="${branch#worktree-}"
    phase_val=$(__dx_active_in_place_phase_for_workspace "$wt_name" "$branch") \
      || branch_result=$?
    if [[ "$branch_result" -eq 0 ]]; then
      printf '%s\n' "$phase_val"
      return 0
    elif [[ "$branch_result" -eq 2 ]]; then
      return 2
    fi
  fi

  local repo_key phase_path candidate_session candidate_branch candidate_result
  repo_key=$(dx_session_repo_key)
  [[ -d "$DX_STATE_DIR" ]] || return 1

  while IFS= read -r phase_path; do
    [[ -n "$phase_path" && -f "$phase_path" ]] || continue
    candidate_session="$(basename "$phase_path" .phase)"
    candidate_result=0
    candidate_branch=$(dx_session_branch_read "$candidate_session" 2>/dev/null) \
      || candidate_result=$?
    [[ "$candidate_result" -eq 0 ]] || return 2
    [[ "$candidate_branch" == "$branch" ]] || continue

    phase_val=$(cat "$phase_path" 2>/dev/null || echo "")
    [[ "$phase_val" =~ ^[0-6]$ ]] || continue
    printf '%s\n' "$phase_val"
    return 0
  done < <(find "$DX_STATE_DIR" -maxdepth 1 -type f -name "${repo_key}-inplace-*.phase" -print 2>/dev/null)

  return 1
}

# __dx_active_in_place_phase_for_workspace <workspace_name> [expected_branch]
# Prints the active phase number for an in-place lifecycle workspace when its
# saved branch still exists. If expected_branch is provided, it must match.
# Returns 2 when saved branch state is missing, unsafe, or malformed.
__dx_active_in_place_phase_for_workspace() {
  local wt_name="$1" expected_branch="${2:-}" session_id phase_file phase_val
  local session_branch="" branch_result=0

  session_id=$(__dx_session_id_for_workspace "in-place" "$wt_name")
  phase_file=$(dx_state_file "$session_id")
  [[ -f "$phase_file" ]] || return 1

  phase_val=$(cat "$phase_file" 2>/dev/null || echo "")
  [[ "$phase_val" =~ ^[0-6]$ ]] || return 1

  session_branch=$(dx_session_branch_read "$session_id" 2>/dev/null) \
    || branch_result=$?
  [[ "$branch_result" -eq 0 ]] || return 2
  [[ -z "$expected_branch" || "$session_branch" == "$expected_branch" ]] \
    || return 1
  git show-ref --verify --quiet "refs/heads/${session_branch}" \
    2>/dev/null || return 2

  printf '%s\n' "$phase_val"
}

# __dx_last_session_active_in_place
# Returns 0 when last-session still points at a resumable in-place lifecycle.
__dx_last_session_active_in_place() {
  local last_session_file="$DX_STATE_DIR/last-session" last_info wt_name rest workspace_mode
  [[ -f "$last_session_file" ]] || return 1

  last_info=$(cat "$last_session_file" 2>/dev/null || echo "")
  [[ -n "$last_info" ]] || return 1
  wt_name="${last_info%%:*}"
  rest="${last_info#*:}"
  workspace_mode="worktree"
  [[ "$rest" == *:in-place ]] && workspace_mode="in-place"
  [[ "$workspace_mode" == "in-place" ]] || return 1

  __dx_active_in_place_phase_for_workspace "$wt_name" >/dev/null
}

# __dx_cleanup_lifecycle_state_for_branch <branch>
# Remove state tied to a deleted canonical Dex lifecycle branch.
__dx_cleanup_lifecycle_state_for_branch() {
  local branch="$1" wt_name worktree_session_id in_place_session_id

  if [[ "$branch" != worktree-ticket-* ]] && [[ "$branch" != worktree-task-* ]]; then
    return 0
  fi

  wt_name="${branch#worktree-}"
  worktree_session_id=$(dx_session_id "$wt_name")
  in_place_session_id=$(__dx_session_id_for_workspace "in-place" "$wt_name")

  dx_cleanup_session "$worktree_session_id"
  dx_cleanup_session "$in_place_session_id"
  dx_cleanup_last_session "$wt_name"
}

# __dx_claude_session_name <workspace_mode> <workspace_name>
__dx_claude_session_name() {
  local workspace_mode="$1" wt_name="$2"
  if [[ "$workspace_mode" == "in-place" ]]; then
    printf 'inplace-%s\n' "$wt_name"
  else
    printf '%s\n' "$wt_name"
  fi
}

# __dx_write_last_session <workspace_name> <workspace_dir> <workspace_mode>
__dx_write_last_session() {
  __dx_write_state "$DX_STATE_DIR/last-session" "${1}:${2}:${3}"
}

# __dx_parse_last_session <raw_last_session>
# Sets: _dx_wt_name, _dx_wt_dir, _dx_workspace_mode, _dx_session_id.
__dx_parse_last_session() {
  local last_info="$1"
  _dx_wt_name="${last_info%%:*}"
  local rest="${last_info#*:}"
  _dx_workspace_mode="worktree"

  case "$rest" in
    *:in-place)
      _dx_workspace_mode="in-place"
      _dx_wt_dir="${rest%:in-place}"
      ;;
    *:worktree)
      _dx_workspace_mode="worktree"
      _dx_wt_dir="${rest%:worktree}"
      ;;
    *)
      _dx_wt_dir="$rest"
      ;;
  esac

  _dx_session_id=$(__dx_session_id_for_workspace "$_dx_workspace_mode" "$_dx_wt_name")
}

# __dx_resolve_existing_workspace_by_ticket <ticket_number>
# Look up an already-created worktree/in-place workspace for a given ticket
# number using the meta sidecars written at creation time. Sets the same
# globals __dx_setup_worktree would set when a matching workspace is found.
# Returns 0 on match, 1 otherwise. Used as a fallback when the conventional
# ticket-N directory does not exist (e.g. the worktree was originally created
# with a freeform description and the agent later linked it to a ticket).
__dx_resolve_existing_workspace_by_ticket() {
  local ticket="$1" record session_id wt_name wt_dir workspace_mode repo_root expected_dir lookup_status
  [[ -n "$ticket" ]] || return 1

  record=$(dx_meta_find_workspace_by_ticket "$ticket") || {
    lookup_status=$?
    return "$lookup_status"
  }
  [[ -n "$record" ]] || return 1

  session_id="${record%%$'\t'*}"
  record="${record#*$'\t'}"
  wt_name="${record%%$'\t'*}"
  record="${record#*$'\t'}"
  wt_dir="${record%%$'\t'*}"
  workspace_mode="${record#*$'\t'}"

  [[ "$wt_name" =~ ^ticket-[0-9]+$ || "$wt_name" =~ ^task-[a-z0-9]+(-[a-z0-9]+)*$ ]] || return 1
  repo_root=$(dx_repo_root) || return 1
  case "$workspace_mode" in
    worktree)
      expected_dir="${repo_root}/.dex/worktrees/${wt_name}"
      [[ "${wt_dir:A}" == "${expected_dir:A}" ]] || return 1
      ;;
    in-place)
      [[ "${wt_dir:A}" == "${repo_root:A}" ]] || return 1
      ;;
    *) return 1 ;;
  esac

  _dx_wt_name="$wt_name"
  _dx_wt_dir="$wt_dir"
  _dx_workspace_mode="${workspace_mode:-worktree}"
  _dx_session_id="$session_id"
  _dx_is_task=0
  [[ "$wt_name" == task-* ]] && _dx_is_task=1
  return 0
}

# Re-open a ticket lookup only after the selected session's startup claim is
# held. A lookup performed before the claim is only a candidate: cleanup may
# remove or replace it before this launcher can act on it.
unalias __dx_pin_ticket_workspace_claim 2>/dev/null; unfunction __dx_pin_ticket_workspace_claim 2>/dev/null
__dx_pin_ticket_workspace_claim() {
  local ticket_number="$1" expected_session="$_dx_session_id"
  local expected_name="$_dx_wt_name" expected_dir="$_dx_wt_dir"
  local expected_mode="$_dx_workspace_mode" verify_result=0

  if [[ "${DX_SESSION_CLAIM_SESSION:-}" != "$expected_session" ]]; then
    __dx_startup_claim_release || return 1
    __dx_startup_claim_acquire "$expected_session" || return 1
  fi
  __dx_resolve_existing_workspace_by_ticket "$ticket_number" \
    || verify_result=$?
  if [[ "$verify_result" -ne 0 \
    || "$_dx_session_id" != "$expected_session" \
    || "$_dx_wt_name" != "$expected_name" \
    || "$_dx_wt_dir" != "$expected_dir" \
    || "$_dx_workspace_mode" != "$expected_mode" ]]; then
    dx_error "The saved ticket workspace changed while Dex was preparing it. Run the command again to use fresh state."
    return 1
  fi
}

# __dx_setup_worktree <raw_input>
# Sets: _dx_wt_name, _dx_wt_dir, _dx_is_task, _dx_repo_root, _dx_default_branch,
# _dx_workspace_mode, _dx_session_id.
# Returns 0 if worktree exists or was created, 1 on error.
# See: docs/autonomous-mode.md for the full lifecycle that follows worktree creation.
unalias __dx_startup_claim_acquire 2>/dev/null; unfunction __dx_startup_claim_acquire 2>/dev/null
__dx_startup_claim_acquire() {
  local session_id="$1" claim_result=0
  dx_session_claim_acquire "$session_id" startup || claim_result=$?
  if [[ "$claim_result" -eq 0 ]]; then
    return 0
  elif [[ "$claim_result" -eq 75 ]]; then
    dx_error "Another startup or cleanup changed this session while Dex was waiting. Run the command again to use fresh state."
  else
    dx_error "Dex could not establish the session startup claim safely."
  fi
  return 1
}

unalias __dx_startup_claim_release 2>/dev/null; unfunction __dx_startup_claim_release 2>/dev/null
__dx_startup_claim_release() {
  local claimed_session="${DX_SESSION_CLAIM_SESSION:-}"
  [[ -n "$claimed_session" ]] || return 0
  if dx_session_claim_release_checked "$claimed_session"; then
    return 0
  fi
  dx_error "Dex could not release the session startup claim safely."
  return 1
}

unalias __dx_setup_worktree 2>/dev/null; unfunction __dx_setup_worktree 2>/dev/null
__dx_setup_worktree() {
  local raw_input="$1" setup_result=0

  _dx_repo_root=$(dx_repo_root) || return 1
  __dx_resolve_workspace_name "$raw_input" || return 1

  _dx_wt_dir="${_dx_repo_root}/.dex/worktrees/${_dx_wt_name}"
  _dx_default_branch=$(dx_default_branch "$_dx_repo_root")
  _dx_workspace_mode="worktree"
  _dx_session_id=$(__dx_session_id_for_workspace "$_dx_workspace_mode" "$_dx_wt_name")
  __dx_startup_claim_acquire "$_dx_session_id" || return 1
  __dx_setup_worktree_claimed "$raw_input" || setup_result=$?
  if [[ "$setup_result" -ne 0 ]]; then
    __dx_startup_claim_release || true
  fi
  return "$setup_result"
}

unalias __dx_setup_worktree_claimed 2>/dev/null; unfunction __dx_setup_worktree_claimed 2>/dev/null
__dx_setup_worktree_claimed() {
  local raw_input="$1"
  # If worktree exists, ensure links are set up (retroactive fix) and return
  if [[ -d "$_dx_wt_dir" ]]; then
    if ! dx_wt_is_registered "$_dx_repo_root" "$_dx_wt_dir"; then
      dx_error "Workspace path exists but is not a registered Git worktree: $_dx_wt_dir"
      dx_info "Move or remove that directory, then run the command again."
      return 1
    fi
    dx_link_claude_to_worktree "$_dx_repo_root" "$_dx_wt_dir"
    __dx_record_session_branch "$_dx_session_id" "$_dx_wt_dir" || return 1
    dx_meta_write "$_dx_session_id" "wt_name=${_dx_wt_name}" "wt_dir=${_dx_wt_dir}" "workspace_mode=worktree" "raw_input=${raw_input}"
    [[ $_dx_is_task -eq 0 ]] && dx_meta_write "$_dx_session_id" "ticket_number=${_dx_wt_name#ticket-}"
    return 0
  fi

  # Ticket-aware fallback: when the caller passed a numeric/ticket-like ID but
  # the conventional ticket-N directory is missing, scan meta sidecars to see
  # if another worktree (e.g. a task-* dir created before the ticket existed)
  # already represents this ticket. Resume that one instead of creating a new
  # worktree.
  if [[ $_dx_is_task -eq 0 ]]; then
    local ticket_number="${_dx_wt_name#ticket-}"
    if [[ -n "$ticket_number" ]]; then
      local resolution_status=0
      __dx_resolve_existing_workspace_by_ticket "$ticket_number" || resolution_status=$?
      if [[ $resolution_status -eq 0 ]]; then
        __dx_pin_ticket_workspace_claim "$ticket_number" || return 1
        if [[ "$_dx_workspace_mode" == "worktree" ]]; then
          if ! dx_wt_is_registered "$_dx_repo_root" "$_dx_wt_dir"; then
            dx_error "Saved workspace is not a registered Git worktree: $_dx_wt_dir"
            dx_info "Remove the stale Dex session metadata or recreate the worktree."
            return 1
          fi
          dx_link_claude_to_worktree "$_dx_repo_root" "$_dx_wt_dir"
        fi
        _dx_default_branch=$(dx_default_branch "$_dx_wt_dir")
        __dx_record_session_branch "$_dx_session_id" "$_dx_wt_dir" || return 1
        dx_meta_write "$_dx_session_id" "ticket_number=${ticket_number}"
        dx_info "Resuming existing workspace ${_dx_wt_name} for ticket ${ticket_number}"
        return 0
      elif [[ $resolution_status -ne 1 ]]; then
        return 1
      fi
    fi
  fi

  # Auto-init if .dex doesn't exist yet
  if [[ ! -d "${_dx_repo_root}/.dex" ]]; then
    echo "Auto-initialising Dex for this repo..."
    (cd "$_dx_repo_root" && bash "$DEX_DIR/bin/init.sh" --skip-analysis --skip-config)
  fi

  # Create worktree
  local _dx_base_ref
  if ! _dx_base_ref=$(dx_default_branch_base_ref "$_dx_repo_root" "$_dx_default_branch"); then
    return 1
  fi

  echo "Creating worktree ${_dx_wt_name} from ${_dx_base_ref}..."
  mkdir -p "${_dx_repo_root}/.dex/worktrees"

  if ! git -C "$_dx_repo_root" worktree add --no-track "$_dx_wt_dir" -b "worktree-${_dx_wt_name}" "$_dx_base_ref" 2>&1; then
    dx_error "Failed to create worktree."
    return 1
  fi

  # Share .claude/ config and MCP auth with main repo
  dx_link_claude_to_worktree "$_dx_repo_root" "$_dx_wt_dir"
  __dx_record_session_branch "$_dx_session_id" "$_dx_wt_dir" || return 1
  dx_meta_write "$_dx_session_id" "wt_name=${_dx_wt_name}" "wt_dir=${_dx_wt_dir}" "workspace_mode=worktree" "raw_input=${raw_input}" "original_branch=worktree-${_dx_wt_name}"
  [[ $_dx_is_task -eq 0 ]] && dx_meta_write "$_dx_session_id" "ticket_number=${_dx_wt_name#ticket-}"

  return 0
}

# __dx_restore_in_place_session_branch <session_id> <workspace_name> <workspace_dir> <resume_command>
# In-place sessions share the user's checkout, so make sure resume continues on
# the lifecycle branch recorded for this session.
__dx_restore_in_place_session_branch() {
  local session_id="$1" wt_name="$2" wt_dir="$3" resume_command="$4"
  local current_branch has_changes session_branch="" branch_result=0

  current_branch=$(git -C "$wt_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")
  has_changes=0
  git -C "$wt_dir" status --porcelain 2>/dev/null | head -1 | grep -q . && has_changes=1

  session_branch=$(dx_session_branch_read "$session_id" 2>/dev/null) \
    || branch_result=$?
  if [[ "$branch_result" -ne 0 ]]; then
    dx_error "Cannot resume in-place session ${wt_name}: its saved branch state is missing, unsafe, or malformed."
    dx_info "Repair the private branch record before re-running: ${resume_command}"
    return 1
  fi
  if [[ "$current_branch" != "$session_branch" ]]; then
    if [[ $has_changes -eq 1 ]]; then
      dx_error "Cannot resume in-place session ${wt_name}: current checkout is on ${current_branch}, but the session branch is ${session_branch}, and there are uncommitted changes."
      dx_info "Commit or stash the current changes, switch to ${session_branch}, then re-run: ${resume_command}"
      return 1
    fi
    if ! git -C "$wt_dir" show-ref --verify --quiet "refs/heads/${session_branch}" 2>/dev/null; then
      dx_error "Cannot resume in-place session ${wt_name}: saved branch ${session_branch} no longer exists."
      dx_info "Restore or check out the lifecycle branch, or remove the stale session state before starting over."
      return 1
    fi
    dx_info "Switching current checkout back to in-place session branch ${session_branch}"
    if ! git -C "$wt_dir" switch "$session_branch"; then
      dx_error "Failed to switch to ${session_branch}."
      return 1
    fi
    has_changes=0
  fi

  if [[ $has_changes -eq 1 ]]; then
    dx_warn "Current checkout already has changes; in-place mode will include them in the lifecycle scope."
  fi

  __dx_record_session_branch "$session_id" "$wt_dir" || return 1
}

# __dx_setup_in_place <raw_input>
# Sets the same workspace variables as __dx_setup_worktree, but points them at
# the current checkout and creates/switches the normal Dex branch there.
unalias __dx_setup_in_place 2>/dev/null; unfunction __dx_setup_in_place 2>/dev/null
__dx_setup_in_place() {
  local raw_input="$1" setup_result=0

  _dx_repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  if [[ -z "$_dx_repo_root" ]]; then
    dx_error "Not in a git repository."
    return 1
  fi
  __dx_resolve_workspace_name "$raw_input" || return 1

  _dx_wt_dir="$_dx_repo_root"
  _dx_default_branch=$(dx_default_branch "$_dx_wt_dir")
  if [[ "${DEX_HEADLESS_RUN:-0}" == "1" && -n "${DEX_HEADLESS_DEFAULT_BRANCH:-}" ]]; then
    _dx_default_branch="$DEX_HEADLESS_DEFAULT_BRANCH"
  fi
  _dx_workspace_mode="in-place"
  _dx_session_id=$(__dx_session_id_for_workspace "$_dx_workspace_mode" "$_dx_wt_name")
  __dx_startup_claim_acquire "$_dx_session_id" || return 1
  __dx_setup_in_place_claimed "$raw_input" || setup_result=$?
  if [[ "$setup_result" -ne 0 ]]; then
    __dx_startup_claim_release || true
  fi
  return "$setup_result"
}

unalias __dx_setup_in_place_claimed 2>/dev/null; unfunction __dx_setup_in_place_claimed 2>/dev/null
__dx_setup_in_place_claimed() {
  local raw_input="$1"
  local branch_name="worktree-${_dx_wt_name}"

  dx_info "Running lifecycle in current checkout (no worktree): ${_dx_wt_dir}"

  local current_branch has_changes
  current_branch=$(git -C "$_dx_wt_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")
  has_changes=0
  git -C "$_dx_wt_dir" status --porcelain 2>/dev/null | head -1 | grep -q . && has_changes=1

  local existing_phase_file existing_phase_rc=0
  existing_phase_file=$(dx_state_file "$_dx_session_id")
  if [[ -e "$existing_phase_file" || -L "$existing_phase_file" ]]; then
    dx_lifecycle_phase_state "$_dx_session_id" >/dev/null 2>&1 \
      || existing_phase_rc=$?
    if [[ "$existing_phase_rc" -ne 0 ]]; then
      dx_error "Dex found an unsafe or malformed phase state for this in-place lifecycle. Repair it before resuming."
      return 1
    fi
    dx_info "Using current checkout for existing in-place session ${_dx_wt_name}"
    __dx_restore_in_place_session_branch "$_dx_session_id" "$_dx_wt_name" "$_dx_wt_dir" "dx --no-worktree ${raw_input}"
    local _rc=$?
    if [[ $_rc -eq 0 ]]; then
      dx_meta_write "$_dx_session_id" "wt_name=${_dx_wt_name}" "wt_dir=${_dx_wt_dir}" "workspace_mode=in-place" "raw_input=${raw_input}"
      [[ $_dx_is_task -eq 0 ]] && dx_meta_write "$_dx_session_id" "ticket_number=${_dx_wt_name#ticket-}"
    fi
    return $_rc
  fi

  # Ticket-aware fallback: if the user passed a numeric ticket but no in-place
  # session exists yet for ticket-N, see if another workspace already represents
  # this ticket (created earlier with a freeform description) and resume that.
  if [[ $_dx_is_task -eq 0 ]]; then
    local _ticket_number="${_dx_wt_name#ticket-}"
    if [[ -n "$_ticket_number" ]]; then
      local _resolution_status=0
      __dx_resolve_existing_workspace_by_ticket "$_ticket_number" || _resolution_status=$?
      if [[ $_resolution_status -eq 0 ]]; then
        __dx_pin_ticket_workspace_claim "$_ticket_number" || return 1
        if [[ "$_dx_workspace_mode" == "worktree" ]]; then
          dx_link_claude_to_worktree "$_dx_repo_root" "$_dx_wt_dir"
        fi
        _dx_default_branch=$(dx_default_branch "$_dx_wt_dir")
        __dx_record_session_branch "$_dx_session_id" "$_dx_wt_dir" || return 1
        dx_meta_write "$_dx_session_id" "ticket_number=${_ticket_number}"
        dx_info "Resuming existing workspace ${_dx_wt_name} for ticket ${_ticket_number}"
        return 0
      elif [[ $_resolution_status -ne 1 ]]; then
        return 1
      fi
    fi
  fi

  if [[ "$current_branch" == "$branch_name" ]]; then
    dx_ok "Using existing Dex branch ${branch_name}"
  elif git -C "$_dx_wt_dir" show-ref --verify --quiet "refs/heads/${branch_name}" 2>/dev/null; then
    if [[ $has_changes -eq 1 ]]; then
      dx_error "Cannot switch to existing branch ${branch_name} with uncommitted changes in the current checkout."
      dx_info "Commit, stash, or discard those changes, then re-run: dx --no-worktree ${raw_input}"
      return 1
    fi
    dx_info "Switching current checkout to existing Dex branch ${branch_name}"
    if ! git -C "$_dx_wt_dir" switch "$branch_name"; then
      dx_error "Failed to switch to ${branch_name}."
      return 1
    fi
  else
    if [[ $has_changes -eq 1 ]]; then
      dx_error "Cannot create branch ${branch_name} from the default branch with uncommitted changes in the current checkout."
      dx_info "Commit, stash, or discard those changes, then re-run: dx --no-worktree ${raw_input}"
      return 1
    fi
    local _dx_base_ref
    if ! _dx_base_ref=$(dx_default_branch_base_ref "$_dx_wt_dir" "$_dx_default_branch"); then
      return 1
    fi
    dx_info "Creating branch ${branch_name} from ${_dx_base_ref}"
    if ! git -C "$_dx_wt_dir" switch --no-track -c "$branch_name" "$_dx_base_ref"; then
      dx_error "Failed to create branch ${branch_name}."
      return 1
    fi
  fi

  if [[ $has_changes -eq 1 ]]; then
    dx_warn "Current checkout already has changes; in-place mode will include them in the lifecycle scope."
  fi

  # Auto-init after branch setup so a newly initialized repo records .dex/
  # on the lifecycle branch instead of dirtying the starting checkout first.
  if [[ ! -d "${_dx_repo_root}/.dex" ]]; then
    echo "Auto-initialising Dex for this repo..."
    bash "$DEX_DIR/bin/init.sh" --skip-analysis --skip-config
  fi

  __dx_record_session_branch "$_dx_session_id" "$_dx_wt_dir" || return 1
  dx_meta_write "$_dx_session_id" "wt_name=${_dx_wt_name}" "wt_dir=${_dx_wt_dir}" "workspace_mode=in-place" "raw_input=${raw_input}" "original_branch=${branch_name}"
  [[ $_dx_is_task -eq 0 ]] && dx_meta_write "$_dx_session_id" "ticket_number=${_dx_wt_name#ticket-}"
  return 0
}

# dx_session_id is provided by lib/session.sh (sourced via lib/common.sh)

# __dx_build_system_context <wt_name> <step> <session_id> <wt_dir> [workspace_mode] [raw_input] [completion_generation]
# Write a system prompt context file that persists across conversation compaction.
# Returns the file path on stdout. The file is passed to --append-system-prompt-file
# so Claude always knows which phase it is in, even after compaction.
__dx_build_system_context() {
  local wt_name="$1" step="$2" session_id="$3" wt_dir="$4"
  local workspace_mode="${5:-worktree}" raw_input="${6:-}"
  local completion_generation="${7:-}"
  local ctx_file
  ctx_file=$(dx_context_file "$session_id")
  mkdir -p "$(dirname "$ctx_file")"

  # Build phase-specific scope boundaries
  local scope_lines=""
  case $step in
    0) scope_lines="- DO read the ticket, assign it to the authenticated user (if unassigned), rename the lifecycle branch to the tracker's git branch name, push the renamed branch, and set ticket status to In Progress
- DO operate in NORMAL mode — do NOT call EnterPlanMode in this phase
- Keep the phase focused on ticket bootstrap. Planning and implementation normally follow later; commit and PR actions remain available when the user or active workflow calls for them
- DO write the Phase 0 ready marker (dx_phase_ready_file step 0) when setup is complete, then stop" ;;
    1) scope_lines="- DO invoke the dxplan skill immediately after entering Plan Mode
- Phase 0 already handled branch rename and ticket setup; do not redo them unless the markers are missing
- Do NOT explore code or draft a plan by hand outside dxplan unless the skill explicitly instructs you to
- DO wait for explicit user approval via ExitPlanMode before marking Phase 1 ready" ;;
    2) scope_lines="- DO implement, test, and verify completeness via the Skill tool
- Commits, pushes, branches, and PR actions remain available; Phase 4 and Phase 5 still provide their normal canonical handoffs" ;;
    3) scope_lines="- DO run /dxreviewloop, fix all findings, and reach a SUCCESS result
- Commits, pushes, branches, and PR actions remain available; use them only when they help the current work" ;;
    4) scope_lines="- DO run format/lint/typecheck/test, fix failures, commit, push
- PR creation and broader implementation fixes remain available when useful" ;;
    5) scope_lines="- DO create or update the PR, write the description, and attach 'request' reviewers from dex.md § Reviewers
- Ready-state changes, @mention comments, implementation changes, commits, and pushes remain available; Phase 6 still performs the normal completion workflow" ;;
    6) scope_lines="- Do NOT modify implementation code unless fixing CI/review failures
- DO mark the PR ready, request reviewers (request type), post @mention comment (mention type),
- DO launch /loop 5m /dxwatchpr, address CI/review failures, close ticket only when checks and approvals are green" ;;
  esac

  local phase_label
  phase_label=$(__dx_phase_name "$step")
  local direct_codex_marker_contract=""
  if [[ "${DX_PROVIDER_ENGINE:-}" == "codex-plugin" \
    && "$completion_generation" =~ ^[0-9a-f]{32}$ ]]; then
    case "$step" in
      0|1|2)
        direct_codex_marker_contract="
## Direct Codex Phase Completion

This session is running through the direct Codex provider, so there is no
Claude Stop hook to write the completion receipt for you. First satisfy the
normal Phase ${step} readiness gate, then write this exact receipt before your
final response:

\`\`\`bash
bash \"\$DEX_DIR/bin/complete-receipt.sh\" \"${session_id}\" \"${completion_generation}\"
\`\`\`

If two materially different recovery strategies fail, pause this exact phase
for human help without claiming completion by running exactly:
bash \"\$DEX_DIR/bin/escalate.sh\" \"${session_id}\" \"${completion_generation}\"
" ;;
      3|4|5)
        direct_codex_marker_contract="
## Direct Codex Phase Completion

This session is running through the direct Codex provider, so there is no
Claude Stop hook to write the completion receipt for you. After Phase ${step}
is genuinely complete, write this exact receipt before your final response:

\`\`\`bash
bash \"\$DEX_DIR/bin/complete-receipt.sh\" \"${session_id}\" \"${completion_generation}\"
\`\`\`

If two materially different recovery strategies fail, pause this exact phase
for human help without claiming completion by running exactly:
bash \"\$DEX_DIR/bin/escalate.sh\" \"${session_id}\" \"${completion_generation}\"
" ;;
      6)
        direct_codex_marker_contract="
## Direct Codex Phase Completion

This session is running through the direct Codex provider, so there is no
Claude Stop hook to write the completion receipt for you. If Phase 6 reaches
the successful completion criteria, run the exact success command below before
your final response. If Phase 6 hits a bounded wait or external blocker, run
the exact generation-bound escalation command instead. Escalation pauses and
detaches the run while revoking authorization; it does not create a receipt.

\`\`\`bash
# Success only:
bash \"\$DEX_DIR/bin/complete-receipt.sh\" \"${session_id}\" \"${completion_generation}\"
# Blocked/paused only:
bash \"\$DEX_DIR/bin/escalate.sh\" \"${session_id}\" \"${completion_generation}\"
\`\`\`
" ;;
    esac
  fi
  local _ctx_tmp="${ctx_file}.tmp.$$"
  cat > "$_ctx_tmp" <<EOF
You are Dex, running the Dex lifecycle for ${wt_name}.
Initial phase: Phase ${step} (${phase_label}).
Workspace: ${wt_dir}
Workspace mode: ${workspace_mode}

## Requested Work

Original dx request: ${raw_input:-$wt_name}
EOF
  mv -f "$_ctx_tmp" "$ctx_file"

  if [[ "$workspace_mode" == "in-place" ]]; then
    cat >> "$ctx_file" <<EOF

This lifecycle is running in-place in the current checkout. No Dex worktree
was created. Dex still prepared the normal lifecycle branch in this checkout
before launching Claude. Treat existing files, staged changes, unstaged changes,
and the current branch as user-owned context. Do not switch branches or create a
new branch unless ticket setup instructions explicitly require a branch rename.
EOF
  fi

  if [[ "${DEX_HEADLESS_RUN:-0}" == "1" && -f "${DEX_HEADLESS_RUN_SPEC_FILE:-}" ]]; then
    local headless_plan_approval
    headless_plan_approval=$(dx_run_spec_field "$DEX_HEADLESS_RUN_SPEC_FILE" "workflow.requires_plan_approval" 2>/dev/null || echo "true")
    cat >> "$ctx_file" <<EOF

## Headless Run Spec

This lifecycle was started by \`dx run\` from a structured run spec, not by a
human typing all task context into the CLI. Treat the run spec as the source of
truth for repo, source, harness, workflow, and sync context.

Run spec file: ${DEX_HEADLESS_RUN_SPEC_FILE}
Plan approval required: ${headless_plan_approval}

If \`workflow.requires_plan_approval\` is false, do not wait for interactive
plan approval. The run spec authorizes the plan once the normal plan quality
checks pass. Write the normal Phase 1 ready marker after the plan is complete.

Normalized run spec:

\`\`\`json
$(python3 -m json.tool "$DEX_HEADLESS_RUN_SPEC_FILE" 2>/dev/null || cat "$DEX_HEADLESS_RUN_SPEC_FILE")
\`\`\`
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

Do not create a bare .complete marker or invent a completion command. Claude
sessions receive their exact receipt command from the Stop hook after the audit
gate passes. Direct Codex sessions receive it in the phase contract below.

${direct_codex_marker_contract}

CRITICAL: You MUST invoke skills using the Skill tool (e.g., Skill(skill="dximplement")).
Do NOT implement skill functionality ad-hoc — invoke the actual skill.

$(__dx_provider_prompt)

## Autonomous Phase Contract

The Dex lifecycle controller owns phase transitions. After Phase 1 plan
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
- Phase 3 must use /dxreviewloop with the selected tier's trusted clean-pass gate.

Ask the human by default for:
- Phase 1 plan approval or plan rejection
- Clarifying questions during planning when requirements cannot be resolved
- Scope or acceptance-criteria changes after plan approval
- Destructive git operations, force-push/rebase decisions, or secret handling
- Missing credentials/tooling the agent cannot configure safely
- Repeated CI failures, architectural review disputes, or unclear reviewer
  feedback that cannot be resolved within the approved plan
- Max phase-audit iterations or repeated loop stalls without completion
- Phase 6 waiting for CI and successfully requested reviewer approval

These are escalation defaults, not hard stops. If an outlier makes a default
counterproductive, either ask the human in this session or override it yourself
with a specific reason. Prefer asking when the decision materially changes
scope, security posture, externally visible behavior, or acceptance criteria.
Self-override when delay itself is harmful, the safe choice is clear, or the
restriction is only an operational budget. Never describe an overridden,
waived, skipped, or unverified gate as passed.

## Soft Defaults and Overrides

Dex gates are soft policy defaults. The active agent may change them during
this session without relaunching Claude or Codex:

\`\`\`bash
# Change an operational default for the current phase:
bash "${DEX_DIR}/bin/control.sh" override review.pass-timeout 2400 --source agent --reason "Thorough checks need a longer provider window"

# Apply the same override for the rest of this lifecycle:
bash "${DEX_DIR}/bin/control.sh" override watch.command-timeout 90 --scope session --source agent --reason "The repository API is responding slowly"

# Waive an assurance gate and advance through the safe lifecycle transition:
bash "${DEX_DIR}/bin/control.sh" waive review.clean-passes --source agent --reason "Two provider failures prevent independent waves; direct review and all deterministic checks are complete"
\`\`\`

When the human authorizes an exception in chat, use \`--source human\` and quote
their reason accurately. \`dx control status\` shows active overrides. Use
\`clear-override\` to return to the default.

Operational overrides take effect when their consumer next reads policy. Gate
waivers do not forge success: they record the current phase as waived. Runtime
integrity is not a policy gate, so valid state records, transition ownership,
atomic writes, and quiescing an active child still apply.

## Direct Human Control

A direct human instruction always overrides the autonomous phase contract.
Phrases such as "stop Dex", "leave the review loop", "skip verification",
"mark this phase done", "jump to the PR phase", or "resume Dex" are control
instructions. Follow the latest human request immediately.

Claude sessions receive direct stop/jump phrases through the UserPromptSubmit
hook. Codex sessions, and either provider when applying a reasoned exception,
run the same provider-neutral command before stopping:

\`\`\`bash
bash "${DEX_DIR}/bin/control.sh" stop
bash "${DEX_DIR}/bin/control.sh" done
bash "${DEX_DIR}/bin/control.sh" jump verify
bash "${DEX_DIR}/bin/control.sh" resume
\`\`\`

For a human instruction relayed through Codex, add \`--source human --reason
"<their reason>"\`. Agent-originated controls use \`--source agent --reason\`.
Review-wave isolation remains in force until the active child is quiescent.
A project block guard can be softened explicitly with an override such as
\`guard.<guard-name>=allow\`; built-in Dex guards are advisory by default.

## Initial Scope Boundaries (Phase ${step})

${scope_lines}

These boundaries apply to the initial phase until the Stop hook hands off to a
later phase. After a same-session handoff, follow the latest handoff prompt and
status line for the current phase.

If you lose context after compaction, re-read the current phase audit prompt.
The initial phase audit prompt was:
  ${DEX_DIR}/prompts/phase-audits/$(__dx_phase_audit_basename "$step").md
EOF

  # Append debt warnings from prior phases so downstream work is aware of accepted gaps
  local debt_file
  debt_file=$(dx_debt_file "$session_id")
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

# __dx_inline_audit_file <step>
# Audit prompt for same-session phase handoff.
__dx_inline_audit_file() {
  local step="$1" basename
  basename=$(__dx_phase_audit_basename "$step")
  [[ -n "$basename" ]] || return 0
  echo "$DEX_DIR/prompts/phase-audits/${basename}.md"
}

# __dx_inline_completion_config <step> <generation>
unalias __dx_inline_completion_config 2>/dev/null; unfunction __dx_inline_completion_config 2>/dev/null
__dx_inline_completion_config() {
  local step="$1" generation="$2"
  printf '%s:%s:%s:%s:lifecycle:phase:%s\n' \
    "$step" "$(__dx_phase_promise "$step")" "$(__dx_inline_audit_file "$step")" \
    "$(__dx_phase_min_audits "$step")" "$generation"
}

unalias __dx_abandon_completion_state 2>/dev/null; unfunction __dx_abandon_completion_state 2>/dev/null
__dx_abandon_completion_state() {
  local session_id="$1"
  if dx_completion_abandon "$session_id" 2>/dev/null; then
    return 0
  fi
  __dx_completion_recover_cleanup "$session_id" 2>/dev/null
}

# __dx_configure_inline_phase <step> <session_id>
# Prepare the Stop hook to audit the current phase and advance inline.
# A new launch always gets a new generation, including resume and same-phase
# retry launches. The printed value is the only generation a direct provider
# may receive in its phase prompt.
unalias __dx_configure_inline_phase 2>/dev/null; unfunction __dx_configure_inline_phase 2>/dev/null
__dx_configure_inline_phase() {
  local step="$1" session_id="$2" generation config_file state_file current_phase
  local current_phase_rc=0
  local provider_engine="${DX_PROVIDER_ENGINE:-}" provider_line provider_state
  config_file=$(dx_loop_config_file "$session_id")
  state_file=$(dx_state_file "$session_id")
  provider_state=$(dx_provider_state_file "$session_id")
  if [[ -f "$provider_state" ]]; then
    while IFS= read -r provider_line; do
      case "$provider_line" in
        engine=*) provider_engine="${provider_line#engine=}" ;;
      esac
    done < "$provider_state"
  fi
  mkdir -p "$DX_LOOP_DIR"
  if ! dx_lifecycle_control_lock_acquire "$session_id"; then
    return 1
  fi
  current_phase=$(dx_lifecycle_phase_state "$session_id" 2>/dev/null) \
    || current_phase_rc=$?
  [[ "$current_phase_rc" -ne 2 ]] || {
    dx_lifecycle_control_lock_release_checked "$session_id" \
      2>/dev/null || true
    return 1
  }
  if [[ "$current_phase" =~ ^[0-7]$ && "$current_phase" != "$step" ]]; then
    if ! dx_lifecycle_control_lock_release_checked "$session_id"; then
      return 1
    fi
    return 2
  fi
  if [[ "$current_phase_rc" -eq 1 ]] \
    && ! dx_lifecycle_atomic_write "$state_file" "$step"; then
    dx_lifecycle_control_lock_release_checked "$session_id" \
      2>/dev/null || true
    return 1
  fi
  if ! dx_lifecycle_pause_clear_unlocked "$session_id"; then
    dx_lifecycle_control_lock_release_checked "$session_id" \
      2>/dev/null || true
    return 1
  fi
  if ! generation=$(dx_lifecycle_completion_issue_unlocked \
    "$session_id" lifecycle phase "$step"); then
    dx_lifecycle_control_lock_release_checked "$session_id" \
      2>/dev/null || true
    return 1
  fi
  if ! dx_lifecycle_atomic_write "$config_file" \
    "$(__dx_inline_completion_config "$step" "$generation")"; then
    dx_completion_abandon "$session_id" 2>/dev/null || true
    dx_lifecycle_control_lock_release_checked "$session_id" \
      2>/dev/null || true
    return 1
  fi
  if [[ "$provider_engine" == "codex-plugin" ]]; then
    # Direct Codex has no Stop hook, so file activation would let an unrelated
    # Claude session claim this lifecycle. The wrapper owns the exact receipt.
    rm -f "$(dx_active_file "$session_id")" "$(dx_owner_file "$session_id")" \
      2>/dev/null || true
  elif ! touch "$(dx_active_file "$session_id")"; then
    dx_completion_abandon "$session_id" 2>/dev/null || true
    dx_lifecycle_control_lock_release_checked "$session_id" \
      2>/dev/null || true
    return 1
  fi
  if ! dx_lifecycle_atomic_write "$(dx_handoff_mode_file "$session_id")" inline; then
    dx_completion_abandon "$session_id" 2>/dev/null || true
    rm -f "$(dx_active_file "$session_id")" 2>/dev/null || true
    dx_lifecycle_control_lock_release_checked "$session_id" \
      2>/dev/null || true
    return 1
  fi
  # Clear any ownership claim so the Claude session launched next can claim
  # this loop (relaunch/--resume gets a fresh Claude session id).
  if ! rm -f "$(dx_owner_file "$session_id")" "$(dx_complete_file "$session_id")" \
    "$(dx_loop_file "$session_id")" "$(dx_findings_file "$session_id")" \
    "$(dx_watch_pause_file "$session_id")" \
    "$(dx_lifecycle_terminal_commit_file "$session_id")" \
    "$(dx_lifecycle_human_complete_file "$session_id")" 2>/dev/null; then
    __dx_abandon_completion_state "$session_id" 2>/dev/null || true
    rm -f "$(dx_active_file "$session_id")" "$config_file" 2>/dev/null || true
    dx_lifecycle_control_lock_release_checked "$session_id" \
      2>/dev/null || true
    return 1
  fi
  if ! dx_lifecycle_control_lock_release "$session_id"; then
    __dx_abandon_completion_state "$session_id" 2>/dev/null || true
    rm -f "$(dx_active_file "$session_id")" "$config_file" \
      "$(dx_handoff_mode_file "$session_id")" "$(dx_owner_file "$session_id")" \
      2>/dev/null || true
    dx_lifecycle_control_lock_release_retained "$session_id" \
      2>/dev/null || true
    return 1
  fi
  printf '%s\n' "$generation"
}

unalias __dx_cleanup_completed_workspace 2>/dev/null; unfunction __dx_cleanup_completed_workspace 2>/dev/null
__dx_cleanup_completed_workspace() {
  local wt_name="$1" wt_dir="$2" default_branch="$3" workspace_mode="${4:-worktree}" session_id="${5:-}"

  if [[ "$workspace_mode" == "worktree" ]]; then
    dx_info "Cleaning up local Dex worktree and branch..."
    if dxrm "$wt_name"; then
      dx_done "Local worktree and branch removed."
      return 0
    fi
    dx_warn "Ticket lifecycle completed, but local worktree cleanup failed."
    dx_info "Run dxrm ${wt_name} after resolving the cleanup issue."
    return 1
  fi

  local current_branch
  current_branch=$(git -C "$wt_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "")
  if [[ -z "$current_branch" || "$current_branch" == "HEAD" ]]; then
    dx_warn "Ticket lifecycle completed, but local branch cleanup was skipped because the checkout is detached."
    return 1
  fi

  if [[ "$current_branch" == "$default_branch" ]]; then
    dx_info "No local branch cleanup needed; current checkout is already on ${default_branch}."
    return 0
  fi

  if git -C "$wt_dir" status --porcelain 2>/dev/null | head -1 | grep -q .; then
    dx_warn "Ticket lifecycle completed, but local branch cleanup was skipped because the current checkout has uncommitted changes."
    dx_info "Commit, stash, or discard those changes, then delete branch ${current_branch} manually."
    return 1
  fi

  if ! git -C "$wt_dir" show-ref --verify --quiet "refs/heads/${default_branch}" 2>/dev/null; then
    dx_warn "Ticket lifecycle completed, but local branch cleanup was skipped because local branch ${default_branch} does not exist."
    dx_info "Create or switch to a safe branch, then delete branch ${current_branch} manually."
    return 1
  fi

  dx_info "Switching current checkout to ${default_branch} before deleting local lifecycle branch ${current_branch}..."
  if ! git -C "$wt_dir" switch "$default_branch"; then
    dx_warn "Ticket lifecycle completed, but failed to switch to ${default_branch}; branch ${current_branch} was left intact."
    return 1
  fi

  if ! git -C "$wt_dir" branch -D "$current_branch"; then
    dx_warn "Ticket lifecycle completed, but failed to delete local branch ${current_branch}."
    return 1
  fi

  [[ -n "$session_id" ]] && dx_cleanup_session "$session_id"
  dx_cleanup_last_session "$wt_name"
  dx_done "Local branch ${current_branch} removed."
}

unalias __dx_inline_phase_iteration_count 2>/dev/null; unfunction __dx_inline_phase_iteration_count 2>/dev/null
__dx_inline_phase_iteration_count() {
  local session_id="$1" raw iterations
  raw=$(cat "$(dx_loop_file "$session_id")" 2>/dev/null || echo "0")
  iterations="${raw%%:*}"
  if [[ "$iterations" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$iterations"
  else
    printf '%s\n' "0"
  fi
}

unalias __dx_record_inline_phase_result 2>/dev/null; unfunction __dx_record_inline_phase_result 2>/dev/null
__dx_record_inline_phase_result() {
  local session_id="$1" phase="$2" phase_status="$3" exit_code="$4"
  local start_epoch end_epoch duration iterations phase_name data_json event_type severity message
  local outcome_status=0 outcome_generation outcome="completed" outcome_reason="gates-passed"
  local criteria_binding="" policy_binding="" policy_record=""
  [[ "$phase" =~ ^[0-6]$ ]] || return 0

  end_epoch=$(date +%s)
  start_epoch=$(awk -F: -v phase="$phase" '$1 == phase { start=$2 } END { if (start != "") print start }' "$(dx_times_file "$session_id")" 2>/dev/null || true)
  [[ "$start_epoch" =~ ^[0-9]+$ ]] || start_epoch="$end_epoch"
  duration=$((end_epoch - start_epoch))
  iterations=$(__dx_inline_phase_iteration_count "$session_id")
  phase_name=$(__dx_phase_name "$phase")

  dx_log_phase "$session_id" "$phase" "$phase_name" "$start_epoch" "$end_epoch" "$duration" "$iterations" "$phase_status" "$exit_code"
  if [[ "$phase_status" == "advance" && "$exit_code" == "0" ]]; then
    if [[ "$phase" == "3" ]]; then
      criteria_binding=$(dx_review_read_criteria_approval "$session_id" \
        2>/dev/null || true)
      policy_record=$(dx_review_policy_resolve "$PWD" 2>/dev/null || true)
      IFS=$'\t' read -r _ _ _ policy_binding _ <<< "$policy_record"
    fi
    if [[ "$phase" == "3" ]] \
      && [[ "${criteria_binding:-}" =~ ^[a-f0-9]{64}$ ]] \
      && dx_review_policy_binding_valid "${policy_binding:-}" \
      && [[ "$(dx_review_receipt_outcome "$session_id" "$PWD" \
        "$criteria_binding" "$policy_binding")" == "waived" ]]; then
      outcome="waived"
      outcome_reason="review-clean-passes-overridden"
      event_type="phase.waived"
      severity="warn"
      message="Phase ${phase} completed with an attributed review-policy waiver: ${phase_name}"
    else
      event_type="phase.completed"
      severity="info"
      message="Phase ${phase} completed: ${phase_name}"
    fi
    outcome_generation="direct-codex-${phase}-${end_epoch}-$$-${RANDOM}"
    dx_phase_outcome_record "$session_id" "$phase" "$outcome" "direct-codex" \
      "$outcome_generation" "$outcome_reason" || outcome_status=$?
    if [[ "$outcome_status" -ne 0 && "$outcome_status" -ne 3 ]]; then
      dx_run_log_append_for_session "$session_id" "warn" "dx" \
        "Could not append the explicit Phase ${phase} completion receipt; the successful phase log remains available for progress reconciliation"
    fi
  else
    event_type="phase.failed"
    severity="error"
    message="Phase ${phase} failed: ${phase_name} (${phase_status})"
  fi
  data_json=$(
    DX_PHASE_NAME="$phase_name" \
    DX_PHASE_START_EPOCH="$start_epoch" \
    DX_PHASE_END_EPOCH="$end_epoch" \
    DX_PHASE_DURATION="$duration" \
    DX_PHASE_ITERATIONS="$iterations" \
    DX_PHASE_STATUS="$phase_status" \
    DX_PHASE_EXIT_CODE="$exit_code" \
    dx_phase_result_data
  )
  dx_event_emit_for_session "$session_id" "$event_type" "$severity" "$message" "$phase" "$data_json"
  dx_run_log_append_for_session "$session_id" "$severity" "dx" "${message}; status=${phase_status}; duration_s=${duration}; iterations=${iterations}; exit_code=${exit_code}"
}

unalias __dx_terminal_event_data 2>/dev/null; unfunction __dx_terminal_event_data 2>/dev/null
__dx_terminal_event_data() {
  local terminal_status="$1" reason="$2" phase="$3" phase_name="$4" exit_code="${5:-}" resume_command="${6:-}"
  DX_TERMINAL_STATUS="$terminal_status" \
  DX_TERMINAL_REASON="$reason" \
  DX_TERMINAL_PHASE="$phase" \
  DX_TERMINAL_PHASE_NAME="$phase_name" \
  DX_TERMINAL_EXIT_CODE="$exit_code" \
  DX_TERMINAL_RESUME_COMMAND="$resume_command" \
  python3 - <<'PY'
import json
import os

payload = {
    "status": os.environ.get("DX_TERMINAL_STATUS", ""),
    "reason": os.environ.get("DX_TERMINAL_REASON", ""),
    "phase": os.environ.get("DX_TERMINAL_PHASE", ""),
    "phase_name": os.environ.get("DX_TERMINAL_PHASE_NAME", ""),
}

exit_code = os.environ.get("DX_TERMINAL_EXIT_CODE", "")
if exit_code:
    try:
        payload["exit_code"] = int(exit_code)
    except ValueError:
        payload["exit_code"] = exit_code

resume_command = os.environ.get("DX_TERMINAL_RESUME_COMMAND", "")
if resume_command:
    payload["resume_command"] = resume_command

print(json.dumps(payload, sort_keys=True, separators=(",", ":")))
PY
}

unalias __dx_pause_reason_message 2>/dev/null; unfunction __dx_pause_reason_message 2>/dev/null
__dx_pause_reason_message() {
  local session_id="$1" reason="$2" raw_iter iterations max_iterations current_phase
  case "$reason" in
    max-iter|max-iterations)
      raw_iter=$(cat "$(dx_loop_file "$session_id")" 2>/dev/null || echo "")
      iterations="${raw_iter%%:*}"
      max_iterations="${DEX_LOOP_MAX_ITERATIONS:-30}"
      current_phase=$(dx_lifecycle_current_phase "$session_id")
      [[ -n "$current_phase" ]] || current_phase="prompt-loop"
      max_iterations=$(dx_override_effective "$session_id" loop.max-iterations \
        "$max_iterations" "$current_phase" 2>/dev/null \
        || printf '%s\n' "$max_iterations")
      if [[ "$iterations" =~ ^[0-9]+$ && "$max_iterations" =~ ^[0-9]+$ ]]; then
        echo "max audit iterations reached (${iterations}/${max_iterations})"
      else
        echo "max audit iterations reached"
      fi
      ;;
    manual-intervention) echo "manual intervention requested" ;;
    manual-pause) echo "paused by direct human instruction" ;;
    manual-cancel) echo "cancelled by direct human instruction" ;;
    review-child-active) echo "review child still active" ;;
    review-pass-timeout) echo "review pass timed out" ;;
    *) echo "${reason//-/ }" ;;
  esac
}

unalias __dx_finish_inline_pause 2>/dev/null; unfunction __dx_finish_inline_pause 2>/dev/null
__dx_finish_inline_pause() {
  local session_id="$1" final_step="$2" resume_hint="$3" wt_name="$4"
  local wt_dir="$5" default_branch="$6" workspace_mode="$7"
  local pause_reason pause_source pause_message terminal_data
  pause_reason=$(dx_pause_state_read "$session_id" reason)
  pause_source=$(dx_pause_state_read "$session_id" source)
  [[ -n "$pause_reason" ]] || pause_reason="manual-intervention"
  [[ -n "$pause_source" ]] || pause_source="unknown"
  pause_message=$(__dx_pause_reason_message "$session_id" "$pause_reason")

  terminal_data=$(__dx_terminal_event_data "blocked" "$pause_reason" "$final_step" "$(__dx_phase_name "$final_step")" "" "$resume_hint")
  dx_event_emit_for_session "$session_id" "run.blocked" "warn" "Dex lifecycle paused at Phase ${final_step}: $(__dx_phase_name "$final_step")" "$final_step" "$terminal_data"
  dx_run_log_append_for_session "$session_id" "warn" "dx" "Lifecycle paused at Phase ${final_step}: ${pause_message}; reason=${pause_reason}; source=${pause_source}"
  dx_run_write_summary_for_session "$session_id" "blocked" "Paused at Phase ${final_step}: ${pause_message}"
  rm -f "$(dx_active_file "$session_id")" "$(dx_owner_file "$session_id")" \
    "$(dx_loop_file "$session_id")" "$(dx_phase_busy_notice_file "$session_id" "$final_step")" 2>/dev/null || true
  dx_clear_lifecycle_control "$session_id" 2>/dev/null || true
  dx_provider_cleanup_session_state "$session_id"

  __dx_show_header "$wt_name" "$final_step" "$wt_dir" "$default_branch" "$session_id" "$workspace_mode"
  echo ""
  echo "Paused at Phase ${final_step}: $(__dx_phase_name "$final_step") (${pause_message})"
  echo "Resume with: ${resume_hint}"
  return 1
}

unalias __dx_codex_direct_phase_handoff 2>/dev/null; unfunction __dx_codex_direct_phase_handoff 2>/dev/null
unalias __dx_codex_transition_unlock 2>/dev/null; unfunction __dx_codex_transition_unlock 2>/dev/null
__dx_codex_transition_unlock() {
  local session_id="$1" reason="$2"
  if dx_lifecycle_control_lock_release "$session_id"; then
    return 0
  fi
  dx_lifecycle_completion_brake "$session_id" "${reason}-lock-release" \
    direct-codex 2>/dev/null || true
  dx_lifecycle_control_lock_release_retained "$session_id" \
    2>/dev/null || true
  dx_warn "Dex could not release the direct Codex transition lock. The lifecycle was left inert with completion authorization revoked."
  return 1
}

__dx_codex_direct_phase_handoff() {
  local session_id="$1" phase="$2" state_file="$3" wt_dir="$4"
  local controls_only="${5:-0}"
  local provider_state provider_engine="" line ready_file next_phase criteria_binding=""
  local policy_record="" policy_binding="" policy_small="" policy_normal="" policy_complex="" policy_ref="" policy_oid=""
  local control_action control_target control_expected control_phase control_snapshot control_source control_actor
  local control_generation control_from control_recovery control_busy_token
  local config_file control_file control_config context_record config_phase config_promise config_audit
  local config_handoff
  local config_min config_mode config_purpose config_generation replacement_generation
  local pause_context_rc=0
  provider_state=$(dx_provider_state_file "$session_id")
  [[ -f "$provider_state" ]] || return 1
  while IFS= read -r line; do
    case "$line" in
      engine=*) provider_engine="${line#engine=}" ;;
    esac
  done < "$provider_state"
  [[ "$provider_engine" == "codex-plugin" ]] || return 1
  [[ "$phase" =~ ^[0-6]$ ]] || return 1

  config_file=$(dx_loop_config_file "$session_id")
  control_file=$(dx_lifecycle_control_file "$session_id")
  dx_lifecycle_control_lock_acquire "$session_id" || return 1
  control_snapshot=$(dx_lifecycle_control_snapshot_unlocked "$session_id")
  if [[ -z "$control_snapshot" \
    && ( -e "$control_file" || -L "$control_file" ) ]]; then
    dx_lifecycle_control_lock_release_checked "$session_id" \
      2>/dev/null || true
    [[ "$controls_only" == "control-only" ]] && return 3
    return 1
  fi
  dx_lifecycle_pause_context_state "$session_id" || pause_context_rc=$?
  if [[ "$pause_context_rc" -eq 2 ]]; then
    __dx_abandon_completion_state "$session_id" 2>/dev/null || true
    dx_lifecycle_completion_brake "$session_id" invalid-pause-state \
      direct-codex 2>/dev/null || true
    __dx_codex_transition_unlock "$session_id" invalid-pause || true
    [[ "$controls_only" == "control-only" ]] && return 3
    return 1
  elif [[ "$pause_context_rc" -eq 0 ]]; then
    __dx_abandon_completion_state "$session_id" 2>/dev/null || true
    __dx_codex_transition_unlock "$session_id" pause || return 1
    return 2
  fi
  control_action=$(dx_lifecycle_control_value "$control_snapshot" action)
  control_target=$(dx_lifecycle_control_value "$control_snapshot" target_phase)
  control_expected=$(dx_lifecycle_control_value "$control_snapshot" expected_phase)
  control_source=$(dx_lifecycle_control_value "$control_snapshot" source)
  control_actor=$(dx_lifecycle_control_actor_label "$control_source")
  control_generation=$(dx_lifecycle_control_value "$control_snapshot" generation)
  control_phase=$(dx_lifecycle_current_phase "$session_id")
  if [[ "$control_action" == "pause" || "$control_action" == "cancel" ]]; then
    if ! dx_lifecycle_detach "$session_id" "manual-${control_action}" \
      "${control_source:-terminal}"; then
      dx_lifecycle_control_lock_release_checked "$session_id" \
        2>/dev/null || true
      dx_warn "Dex could not prove that completion authorization was revoked, so the pause was not reported as cleanly detached."
      return 1
    fi
    __dx_codex_transition_unlock "$session_id" pause || return 1
    return 2
  fi
  if [[ "$control_action" == "complete" || "$control_action" == "jump" ]]; then
    if [[ ! "$control_target" =~ ^[0-7]$ \
      || ! "$control_generation" =~ ^[0-9]+-[0-9]+-[0-9]+$ \
      || ( "$control_source" != "agent" && "$control_source" != "user-prompt" \
        && "$control_source" != "terminal" ) ]]; then
      dx_clear_lifecycle_control_unlocked "$session_id"
      dx_lifecycle_control_lock_release_checked "$session_id" \
        2>/dev/null || true
      return 1
    fi

    control_from="$control_phase"
    control_recovery=0
    if [[ "$control_target" == "$control_phase" \
      && "$control_expected" =~ ^[0-7]$ \
      && "$control_expected" != "$control_phase" ]]; then
      control_from="$control_expected"
      control_recovery=1
    elif [[ -n "$control_expected" && "$control_expected" != "$control_phase" ]]; then
      dx_warn "Ignoring stale ${control_actor} transition for Phase ${control_expected}; current phase is ${control_phase}."
      dx_clear_lifecycle_control_unlocked "$session_id"
      dx_lifecycle_control_lock_release_checked "$session_id" \
        2>/dev/null || true
      return 1
    elif [[ "$control_target" == "$control_phase" ]]; then
      dx_clear_lifecycle_control_unlocked "$session_id"
      dx_lifecycle_control_lock_release_checked "$session_id" \
        2>/dev/null || true
      return 1
    fi
    if [[ "$control_action" == "complete" \
      && "$control_target" -ne $((control_from + 1)) ]]; then
      dx_clear_lifecycle_control_unlocked "$session_id"
      dx_lifecycle_control_lock_release_checked "$session_id" \
        2>/dev/null || true
      return 1
    fi
    if dx_phase_busy_transition_blocked "$session_id" 3 "$control_from" "$control_target"; then
      if ! dx_lifecycle_detach "$session_id" "review-child-active" \
        "${control_source:-terminal}"; then
        dx_lifecycle_control_lock_release_checked "$session_id" \
          2>/dev/null || true
        dx_warn "Dex could not prove that completion authorization was revoked while detaching from the active review child."
        return 1
      fi
      __dx_codex_transition_unlock "$session_id" review-child || return 1
      dx_warn "Dex detached at Phase 3 because a review child is still marked in flight."
      return 2
    fi

    if ! __dx_abandon_completion_state "$session_id"; then
      dx_lifecycle_control_lock_release_checked "$session_id" \
        2>/dev/null || true
      dx_warn "Dex could not revoke the current phase completion authorization; the ${control_actor} transition remains pending."
      return 1
    fi
    if [[ "$control_recovery" -eq 0 ]]; then
      if ! dx_lifecycle_atomic_write "$state_file" "$control_target"; then
        dx_lifecycle_control_lock_release_checked "$session_id" \
          2>/dev/null || true
        dx_warn "Dex could not commit the direct Codex phase transition. The current phase remains authoritative; retry its audit."
        return 1
      fi
    fi
    if [[ "$control_target" =~ ^[0-6]$ ]]; then
      if ! replacement_generation=$(dx_lifecycle_completion_issue_unlocked \
        "$session_id" lifecycle phase "$control_target") \
        || ! control_config=$(__dx_inline_completion_config "$control_target" "$replacement_generation") \
        || ! dx_lifecycle_atomic_write "$config_file" "$control_config"; then
        dx_completion_abandon "$session_id" 2>/dev/null || true
        dx_lifecycle_control_lock_release_checked "$session_id" \
          2>/dev/null || true
        dx_warn "Dex changed the authoritative phase but could not prepare its completion authorization. Retry the current phase to recover."
        return 1
      fi
    fi

    if ! dx_record_control_phase_outcomes "$session_id" "$control_from" "$control_target" \
      "$control_action" "$control_generation" "$control_source" "$control_recovery"; then
      dx_lifecycle_control_lock_release_checked "$session_id" \
        2>/dev/null || true
      dx_warn "Dex committed the direct Codex phase transition but could not finish its outcome ledger. Its control receipt remains available for recovery."
      return 1
    fi
    for control_phase in 0 1 2 3 4 5 6; do
      rm -f "$(dx_phase_started_file "$session_id" "$control_phase")" \
        "$(dx_phase_ready_file "$session_id" "$control_phase")" 2>/dev/null || true
      if [[ "$control_phase" != "3" ]]; then
        rm -f "$(dx_phase_busy_file "$session_id" "$control_phase")" \
          "$(dx_phase_busy_notice_file "$session_id" "$control_phase")" 2>/dev/null || true
      fi
    done
    rm -f "$(dx_loop_file "$session_id")" "$(dx_findings_file "$session_id")" \
      "$(dx_paused_file "$session_id")" "$(dx_pause_state_file "$session_id")" 2>/dev/null || true
    if dx_phase_busy_quiesced "$session_id" 3; then
      control_busy_token=$(dx_phase_busy_token "$session_id" 3)
      dx_phase_busy_finish "$session_id" 3 "$control_busy_token" 2>/dev/null || true
    fi
    dx_run_log_append_for_session "$session_id" "warn" "dx" \
      "Direct Codex applied ${control_actor}: phase=${control_from}; target_phase=${control_target}; action=${control_action}; generation=${control_generation}; recovery=${control_recovery}" 2>/dev/null || true
    if [[ "$control_target" == "7" ]]; then
      if ! dx_lifecycle_atomic_write \
        "$(dx_lifecycle_human_complete_file "$session_id")" human-complete; then
        dx_lifecycle_control_lock_release_checked "$session_id" \
          2>/dev/null || true
        dx_warn "Dex could not persist the human-completion workspace marker. Its control receipt remains available for recovery."
        return 1
      fi
      if ! rm -f "$config_file" "$(dx_active_file "$session_id")" \
        "$(dx_owner_file "$session_id")" \
        "$(dx_handoff_mode_file "$session_id")" 2>/dev/null \
        || ! dx_lifecycle_terminal_commit_publish_unlocked "$session_id" \
          "$control_generation"; then
        dx_lifecycle_terminal_failure_rollback_unlocked "$session_id" \
          human-terminal-proof-failed direct-codex 2>/dev/null \
          || dx_lifecycle_completion_brake "$session_id" \
            human-terminal-proof-failed direct-codex 2>/dev/null || true
        dx_lifecycle_control_lock_release_checked "$session_id" \
          2>/dev/null || true
        dx_warn "Dex could not commit the human-authorized terminal proof. It returned to a paused Phase 6 and was not reported complete."
        return 1
      fi
    fi
    dx_clear_lifecycle_control_unlocked "$session_id"
    if ! __dx_codex_transition_unlock "$session_id" human-transition; then
      if [[ "$control_target" == "7" ]]; then
        dx_lifecycle_terminal_failure_rollback "$session_id" \
          human-terminal-commit-failed direct-codex 2>/dev/null \
          || dx_lifecycle_completion_brake "$session_id" \
            human-terminal-commit-failed direct-codex 2>/dev/null || true
      fi
      return 1
    fi
    if [[ "$control_target" == "7" ]] \
      && ! dx_lifecycle_terminal_commit_valid "$session_id"; then
      dx_lifecycle_terminal_failure_rollback "$session_id" \
        human-terminal-commit-failed direct-codex 2>/dev/null \
        || dx_lifecycle_completion_brake "$session_id" \
          human-terminal-commit-failed direct-codex 2>/dev/null || true
      dx_warn "Dex could not validate the human-authorized terminal proof. It returned to a paused Phase 6 and was not reported complete."
      return 1
    fi
    dx_info "The ${control_actor} moved the direct Codex lifecycle from Phase ${control_from} to Phase ${control_target}."
    return 0
  fi

  if [[ "$controls_only" == "control-only" ]]; then
    if ! __dx_codex_transition_unlock "$session_id" preflight; then
      return 3
    fi
    return 1
  fi

  context_record=$(dx_lifecycle_completion_context_read "$session_id" 2>/dev/null) || {
    dx_lifecycle_control_lock_release_checked "$session_id" \
      2>/dev/null || true
    return 1
  }
  IFS=$'\t' read -r config_phase config_promise config_audit config_min \
    config_mode config_purpose config_generation config_handoff \
    <<< "$context_record"
  : "$config_handoff"
  : "$config_promise" "$config_audit" "$config_min"
  if [[ "$config_phase" != "$phase" || "$config_mode" != "lifecycle" \
    || "$config_purpose" != "phase" \
    || ! "$config_generation" =~ ^[0-9a-f]{32}$ ]]; then
    dx_lifecycle_control_lock_release_checked "$session_id" \
      2>/dev/null || true
    return 1
  fi

  # Bare markers from an older launcher are never phase authorization. Rotate
  # before returning so a late writer cannot complete the next retry.
  if [[ -e "$(dx_complete_file "$session_id")" || -L "$(dx_complete_file "$session_id")" ]]; then
    rm -f "$(dx_complete_file "$session_id")" 2>/dev/null || true
    replacement_generation=$(dx_lifecycle_completion_issue_unlocked \
      "$session_id" lifecycle phase "$phase" 2>/dev/null || true)
    if [[ "$replacement_generation" =~ ^[0-9a-f]{32}$ ]]; then
      dx_lifecycle_atomic_write "$config_file" \
        "$(__dx_inline_completion_config "$phase" "$replacement_generation")" 2>/dev/null || true
    fi
    dx_lifecycle_control_lock_release_checked "$session_id" \
      2>/dev/null || true
    dx_warn "Legacy completion marker ignored; this phase requires its exact versioned receipt."
    if [[ "$replacement_generation" =~ ^[0-9a-f]{32}$ ]]; then
      dx_info "Retry the phase, then run: bash \"\$DEX_DIR/bin/complete-receipt.sh\" \"${session_id}\" \"${replacement_generation}\""
    fi
    return 1
  fi

  if ! dx_completion_receipt_valid "$session_id" lifecycle phase "$phase" "$config_generation"; then
    dx_lifecycle_control_lock_release_checked "$session_id" \
      2>/dev/null || true
    return 1
  fi

  ready_file=$(dx_phase_ready_file "$session_id" "$phase")
  case "$phase" in
    0|1|2)
      if [[ ! -f "$ready_file" ]]; then
        replacement_generation=$(dx_lifecycle_completion_issue_unlocked \
          "$session_id" lifecycle phase "$phase" 2>/dev/null || true)
        if [[ "$replacement_generation" =~ ^[0-9a-f]{32}$ ]]; then
          dx_lifecycle_atomic_write "$config_file" \
            "$(__dx_inline_completion_config "$phase" "$replacement_generation")" 2>/dev/null || true
        fi
        dx_lifecycle_control_lock_release_checked "$session_id" \
          2>/dev/null || true
        dx_warn "Phase ${phase} receipt rejected because its readiness gate is not satisfied."
        if [[ "$replacement_generation" =~ ^[0-9a-f]{32}$ ]]; then
          dx_info "Retry the gate, then run: bash \"\$DEX_DIR/bin/complete-receipt.sh\" \"${session_id}\" \"${replacement_generation}\""
        fi
        return 1
      fi
      ;;
  esac

  if [[ "$phase" == "1" && ! -e "$(dx_review_criteria_approval_file "$session_id")" ]]; then
    criteria_binding=$(dx_review_criteria_hash "$(dx_review_criteria_file "$session_id")" 2>/dev/null || true)
    if [[ "$criteria_binding" =~ ^[a-f0-9]{64}$ ]]; then
      dx_review_approve_criteria "$session_id" initial "$criteria_binding" >/dev/null || criteria_binding=""
    fi
  fi
  if [[ "$phase" == "1" || "$phase" == "2" || "$phase" == "3" ]]; then
    criteria_binding=$(dx_review_read_criteria_approval "$session_id" 2>/dev/null || true)
    if [[ ! "$criteria_binding" =~ ^[a-f0-9]{64}$ ]]; then
      replacement_generation=$(dx_lifecycle_completion_issue_unlocked \
        "$session_id" lifecycle phase "$phase" 2>/dev/null || true)
      [[ "$replacement_generation" =~ ^[0-9a-f]{32}$ ]] && dx_lifecycle_atomic_write "$config_file" "$(__dx_inline_completion_config "$phase" "$replacement_generation")" 2>/dev/null || true
      dx_lifecycle_control_lock_release_checked "$session_id" \
        2>/dev/null || true
      dx_warn "Phase ${phase} receipt rejected because its approved review criteria are missing or stale."
      [[ "$replacement_generation" =~ ^[0-9a-f]{32}$ ]] && dx_info "Retry the gate, then run: bash \"\$DEX_DIR/bin/complete-receipt.sh\" \"${session_id}\" \"${replacement_generation}\""
      return 1
    fi
  fi
  if [[ "$phase" == "2" || "$phase" == "3" ]]; then
    policy_record=$(dx_review_policy_resolve "$wt_dir" 2>/dev/null || true)
    IFS=$'\t' read -r policy_small policy_normal policy_complex policy_binding policy_ref policy_oid <<< "$policy_record"
    : "$policy_small" "$policy_normal" "$policy_complex"
    if ! dx_review_policy_binding_valid "$policy_binding" \
      || ! dx_review_policy_provenance_valid "$policy_ref" "$policy_oid"; then
      replacement_generation=$(dx_lifecycle_completion_issue_unlocked \
        "$session_id" lifecycle phase "$phase" 2>/dev/null || true)
      [[ "$replacement_generation" =~ ^[0-9a-f]{32}$ ]] && dx_lifecycle_atomic_write "$config_file" "$(__dx_inline_completion_config "$phase" "$replacement_generation")" 2>/dev/null || true
      dx_lifecycle_control_lock_release_checked "$session_id" \
        2>/dev/null || true
      dx_warn "Phase ${phase} receipt rejected because its review policy binding is invalid."
      [[ "$replacement_generation" =~ ^[0-9a-f]{32}$ ]] && dx_info "Retry the gate, then run: bash \"\$DEX_DIR/bin/complete-receipt.sh\" \"${session_id}\" \"${replacement_generation}\""
      return 1
    fi
  fi

  if [[ "$phase" == "2" ]] && ! dx_review_selection_valid "$session_id" "$wt_dir" "$criteria_binding" "$policy_binding"; then
    replacement_generation=$(dx_lifecycle_completion_issue_unlocked \
      "$session_id" lifecycle phase "$phase" 2>/dev/null || true)
    [[ "$replacement_generation" =~ ^[0-9a-f]{32}$ ]] && dx_lifecycle_atomic_write "$config_file" "$(__dx_inline_completion_config "$phase" "$replacement_generation")" 2>/dev/null || true
    dx_lifecycle_control_lock_release_checked "$session_id" \
      2>/dev/null || true
    dx_warn "Phase 2 receipt rejected because its review risk selection is missing or stale."
    [[ "$replacement_generation" =~ ^[0-9a-f]{32}$ ]] && dx_info "Retry the gate, then run: bash \"\$DEX_DIR/bin/complete-receipt.sh\" \"${session_id}\" \"${replacement_generation}\""
    return 1
  fi

  if [[ "$phase" == "3" ]] && ! dx_review_receipt_valid "$session_id" "$wt_dir" "$criteria_binding" "$policy_binding"; then
    replacement_generation=$(dx_lifecycle_completion_issue_unlocked \
      "$session_id" lifecycle phase "$phase" 2>/dev/null || true)
    [[ "$replacement_generation" =~ ^[0-9a-f]{32}$ ]] && dx_lifecycle_atomic_write "$config_file" "$(__dx_inline_completion_config "$phase" "$replacement_generation")" 2>/dev/null || true
    dx_lifecycle_control_lock_release_checked "$session_id" \
      2>/dev/null || true
    dx_warn "Phase 3 receipt rejected because its review-loop receipt is missing or stale."
    [[ "$replacement_generation" =~ ^[0-9a-f]{32}$ ]] && dx_info "Retry the gate, then run: bash \"\$DEX_DIR/bin/complete-receipt.sh\" \"${session_id}\" \"${replacement_generation}\""
    return 1
  fi

  control_snapshot=$(dx_lifecycle_control_snapshot_unlocked "$session_id")
  if [[ -n "$control_snapshot" || -e "$control_file" || -L "$control_file" ]]; then
    dx_lifecycle_control_lock_release_checked "$session_id" \
      2>/dev/null || true
    return 1
  fi
  if [[ "$phase" -lt 6 ]]; then
    next_phase=$((phase + 1))
    if dx_phase_busy_transition_blocked "$session_id" 3 "$phase" "$next_phase"; then
      if ! dx_lifecycle_detach "$session_id" "review-child-active" "direct-codex"; then
        dx_lifecycle_control_lock_release_checked "$session_id" \
          2>/dev/null || true
        dx_warn "Dex could not prove that completion authorization was revoked while pausing for the active review child."
        return 1
      fi
      __dx_codex_transition_unlock "$session_id" review-child || return 1
      return 2
    fi
    if ! dx_consume_completion_receipt "$session_id" lifecycle phase "$phase" "$config_generation"; then
      dx_lifecycle_control_lock_release_checked "$session_id" \
        2>/dev/null || true
      dx_warn "Dex could not consume the Phase ${phase} completion receipt; retry that phase's audit."
      return 1
    fi
    if ! dx_lifecycle_atomic_write "$state_file" "$next_phase"; then
      replacement_generation=$(dx_lifecycle_completion_issue_unlocked \
        "$session_id" lifecycle phase "$phase" 2>/dev/null || true)
      [[ "$replacement_generation" =~ ^[0-9a-f]{32}$ ]] && dx_lifecycle_atomic_write "$config_file" "$(__dx_inline_completion_config "$phase" "$replacement_generation")" 2>/dev/null || true
      dx_lifecycle_control_lock_release_checked "$session_id" \
        2>/dev/null || true
      return 1
    fi
    if ! replacement_generation=$(dx_lifecycle_completion_issue_unlocked \
      "$session_id" lifecycle phase "$next_phase") \
      || ! control_config=$(__dx_inline_completion_config "$next_phase" "$replacement_generation") \
      || ! dx_lifecycle_atomic_write "$config_file" "$control_config"; then
      dx_completion_abandon "$session_id" 2>/dev/null || true
      dx_lifecycle_control_lock_release_checked "$session_id" \
        2>/dev/null || true
      return 1
    fi
    __dx_record_inline_phase_result "$session_id" "$phase" "advance" "0"
    if [[ "$phase" == "3" ]]; then
      rm -f "$(dx_review_selection_file "$session_id")" "$(dx_review_receipt_file "$session_id")" \
        "$(dx_review_state_file "$session_id")" 2>/dev/null
      dx_review_ledger_reset "$session_id" 2>/dev/null || true
      if dx_phase_busy_quiesced "$session_id" 3; then
        control_busy_token=$(dx_phase_busy_token "$session_id" 3)
        dx_phase_busy_finish "$session_id" 3 "$control_busy_token" 2>/dev/null || true
      fi
    fi
    rm -f "$(dx_loop_file "$session_id")" "$(dx_complete_file "$session_id")" \
      "$(dx_findings_file "$session_id")" "$(dx_paused_file "$session_id")" \
      "$(dx_pause_state_file "$session_id")" "$(dx_phase_started_file "$session_id" "$phase")" \
      "$(dx_phase_ready_file "$session_id" "$phase")" 2>/dev/null || true
    if [[ "$phase" != "3" ]]; then
      rm -f "$(dx_phase_busy_file "$session_id" "$phase")" \
        "$(dx_phase_busy_notice_file "$session_id" "$phase")" 2>/dev/null || true
    fi
    if [[ "$next_phase" -ge 2 ]] && git -C "$wt_dir" rev-parse --git-dir >/dev/null 2>&1; then
      dx_checkpoint_tag "$next_phase" "$wt_dir"
    fi
    __dx_codex_transition_unlock "$session_id" handoff || return 1
    dx_info "Codex completed Phase ${phase}; continuing with Phase ${next_phase}: $(__dx_phase_name "$next_phase")."
    return 0
  fi

  if ! dx_consume_completion_receipt "$session_id" lifecycle phase "$phase" "$config_generation"; then
    dx_lifecycle_control_lock_release_checked "$session_id" \
      2>/dev/null || true
    dx_warn "Dex could not consume the Phase 6 completion receipt; retry that phase's audit."
    return 1
  fi
  if ! dx_lifecycle_atomic_write "$state_file" "7"; then
    replacement_generation=$(dx_lifecycle_completion_issue_unlocked \
      "$session_id" lifecycle phase 6 2>/dev/null || true)
    [[ "$replacement_generation" =~ ^[0-9a-f]{32}$ ]] && dx_lifecycle_atomic_write "$config_file" "$(__dx_inline_completion_config 6 "$replacement_generation")" 2>/dev/null || true
    dx_lifecycle_control_lock_release_checked "$session_id" \
      2>/dev/null || true
    return 1
  fi
  local terminal_commit_rc=0
  __dx_record_inline_phase_result "$session_id" "$phase" "advance" "0" \
    || terminal_commit_rc=1
  rm -f "$(dx_loop_file "$session_id")" "$(dx_complete_file "$session_id")" "$config_file" \
    "$(dx_findings_file "$session_id")" "$(dx_paused_file "$session_id")" \
    "$(dx_pause_state_file "$session_id")" "$(dx_phase_started_file "$session_id" "$phase")" \
    "$(dx_phase_ready_file "$session_id" "$phase")" "$(dx_phase_busy_file "$session_id" "$phase")" \
    "$(dx_phase_busy_notice_file "$session_id" "$phase")" 2>/dev/null \
    || terminal_commit_rc=1
  rm -f "$(dx_active_file "$session_id")" "$(dx_owner_file "$session_id")" \
    "$(dx_handoff_mode_file "$session_id")" "$(dx_paused_file "$session_id")" \
    2>/dev/null || terminal_commit_rc=1
  if [[ "$terminal_commit_rc" -ne 0 ]] \
    || ! dx_lifecycle_terminal_commit_publish_unlocked "$session_id" \
      "$config_generation"; then
    dx_lifecycle_terminal_failure_rollback_unlocked "$session_id" \
      completion-commit-failed direct-codex 2>/dev/null \
      || dx_lifecycle_completion_brake "$session_id" \
        completion-commit-failed direct-codex 2>/dev/null || true
    dx_lifecycle_control_lock_release_checked "$session_id" \
      2>/dev/null || true
    dx_warn "Dex could not commit its terminal transaction. It returned to a paused Phase 6; repair the state error, then use dx control resume."
    return 1
  fi
  if ! __dx_codex_transition_unlock "$session_id" completion; then
    dx_lifecycle_terminal_failure_rollback "$session_id" \
      completion-lock-release direct-codex 2>/dev/null \
      || dx_lifecycle_completion_brake "$session_id" \
        completion-lock-release direct-codex 2>/dev/null || true
    return 1
  fi
  if ! dx_lifecycle_terminal_commit_valid "$session_id"; then
    dx_lifecycle_terminal_failure_rollback "$session_id" \
      terminal-proof-invalid direct-codex 2>/dev/null \
      || dx_lifecycle_completion_brake "$session_id" \
        terminal-proof-invalid direct-codex 2>/dev/null || true
    dx_warn "Dex could not validate its terminal proof. Completion was not reported; resume the paused Phase 6 after repairing the state error."
    return 1
  fi
  dx_event_emit_for_session "$session_id" "run.completed" "info" \
    "Dex lifecycle completed" "6" "{\"final_phase\":6}" \
    || terminal_commit_rc=1
  dx_run_log_append_for_session "$session_id" "info" "dx" \
    "Dex lifecycle completed" || terminal_commit_rc=1
  dx_run_write_summary_for_session "$session_id" "completed" \
    "Dex lifecycle completed" || terminal_commit_rc=1
  if [[ "$terminal_commit_rc" -ne 0 ]]; then
    dx_warn "Dex committed lifecycle completion, but one or more terminal telemetry records could not be written. The local terminal proof remains authoritative; retry telemetry sync separately."
  fi
  return 0
}

unalias __dx_runtime_set_terminal 2>/dev/null; unfunction __dx_runtime_set_terminal 2>/dev/null
__dx_runtime_set_terminal() {
  local terminal_state="$1"
  [[ -n "${_dx_runtime_owner_handle:-}" ]] || return 0
  case "$terminal_state" in
    completed|paused|blocked|failed|stopped|abandoned)
      _dx_runtime_terminal_state="$terminal_state"
      ;;
  esac
}

unalias __dx_run_with_runtime 2>/dev/null; unfunction __dx_run_with_runtime 2>/dev/null
unalias __dx_run_with_runtime_owner_handle 2>/dev/null; unfunction __dx_run_with_runtime_owner_handle 2>/dev/null
__dx_run_with_runtime_owner_handle() {
  local owner_handle="$1" owner_pid="$2" callback_name="$3"
  shift 3
  local callback_result=1 owner_finish_result=0
  local runtime_cleanup_command=""
  local _dx_runtime_owner_handle="$owner_handle" _dx_runtime_owner_pid="$owner_pid"
  local _dx_runtime_signal_code=0
  local _dx_runtime_terminal_state="failed"
  setopt localoptions localtraps
  if [[ -z "$_dx_runtime_owner_handle" || ! "$_dx_runtime_owner_pid" =~ ^[0-9]+$ ]]; then
    if [[ -n "$_dx_runtime_owner_handle" ]]; then
      dx_session_runtime_owner_finish "$_dx_runtime_owner_handle" failed 2>/dev/null || true
    fi
    dx_error "Dex received an invalid runtime-owner handle, so it did not start the provider."
    return 1
  fi

  # EXIT runs after zsh tears down local scope, so bind the fallback handle now.
  runtime_cleanup_command=$(printf \
    'dx_session_runtime_owner_finish %q failed >/dev/null 2>&1 || true' \
    "$_dx_runtime_owner_handle")
  # shellcheck disable=SC2064  # the handle is already shell-quoted
  trap "$runtime_cleanup_command" EXIT
  trap '_dx_runtime_signal_code=130; dx_session_runtime_owner_finish "$_dx_runtime_owner_handle" stopped >/dev/null 2>&1 || true; _dx_runtime_owner_handle=""; trap - EXIT INT TERM HUP; return 130' INT
  trap '_dx_runtime_signal_code=143; dx_session_runtime_owner_finish "$_dx_runtime_owner_handle" stopped >/dev/null 2>&1 || true; _dx_runtime_owner_handle=""; trap - EXIT INT TERM HUP; return 143' TERM
  trap '_dx_runtime_signal_code=129; dx_session_runtime_owner_finish "$_dx_runtime_owner_handle" stopped >/dev/null 2>&1 || true; _dx_runtime_owner_handle=""; trap - EXIT INT TERM HUP; return 129' HUP

  "$callback_name" "$@"
  callback_result=$?
  if [[ "$_dx_runtime_signal_code" -ne 0 ]]; then
    callback_result="$_dx_runtime_signal_code"
  fi
  if [[ "$callback_result" -eq 129 || "$callback_result" -eq 130 \
    || "$callback_result" -eq 143 ]]; then
    _dx_runtime_terminal_state="stopped"
  fi
  if [[ -n "$_dx_runtime_owner_handle" ]]; then
    dx_session_runtime_owner_finish \
      "$_dx_runtime_owner_handle" "$_dx_runtime_terminal_state" \
      || owner_finish_result=$?
    _dx_runtime_owner_handle=""
  fi
  trap - EXIT INT TERM HUP

  if [[ "$owner_finish_result" -ne 0 ]]; then
    dx_error "Dex could not close the runtime lease safely. The provider result was not accepted as success."
    return 1
  fi
  return "$callback_result"
}

__dx_run_with_runtime() {
  local session_id="$1" workspace_dir="$2" callback_name="$3"
  shift 3
  local provider_name owner_start_result=0 owner_handle="" owner_pid=""
  provider_name=$(__dx_resolved_provider_agent) || {
    __dx_startup_claim_release || true
    return 1
  }
  dx_session_runtime_owner_start \
    "$session_id" "$provider_name" "$workspace_dir" || owner_start_result=$?
  if [[ "$owner_start_result" -ne 0 ]]; then
    __dx_startup_claim_release || true
    if [[ "$owner_start_result" -eq 2 ]]; then
      dx_error "Another Dex runtime already owns this checkout. Resume or finish it before starting another provider."
    else
      dx_error "Dex could not establish runtime ownership, so it did not start the provider."
    fi
    return 1
  fi
  owner_handle="${DX_SESSION_RUNTIME_OWNER_HANDLE:-}"
  owner_pid="${DX_SESSION_RUNTIME_OWNER_PID:-}"
  unset DX_SESSION_RUNTIME_OWNER_HANDLE DX_SESSION_RUNTIME_OWNER_PID
  if ! __dx_startup_claim_release; then
    dx_session_runtime_owner_finish "$owner_handle" failed \
      >/dev/null 2>&1 || true
    dx_error "Dex published runtime ownership but could not commit the startup claim release. The provider did not start."
    return 1
  fi
  __dx_run_with_runtime_owner_handle "$owner_handle" "$owner_pid" \
    "$callback_name" "$@"
}

unalias __dx_run_with_recovered_runtime 2>/dev/null; unfunction __dx_run_with_recovered_runtime 2>/dev/null
__dx_run_with_recovered_runtime() {
  local session_id="$1" runtime_snapshot="$2" callback_name="$3"
  shift 3
  local recovery_result=0 owner_handle="" owner_pid=""
  __dx_session_runtime_owner_recovery_start \
    "$session_id" "$runtime_snapshot" || recovery_result=$?
  if [[ "$recovery_result" -ne 0 ]]; then
    if [[ "$recovery_result" -eq 2 ]]; then
      dx_error "Another process claimed this session before Dex could relaunch it."
    else
      dx_error "Dex could not claim the selected dead runtime safely."
    fi
    return 1
  fi
  owner_handle="${DX_SESSION_RUNTIME_OWNER_HANDLE:-}"
  owner_pid="${DX_SESSION_RUNTIME_OWNER_PID:-}"
  unset DX_SESSION_RUNTIME_OWNER_HANDLE DX_SESSION_RUNTIME_OWNER_PID
  __dx_run_with_runtime_owner_handle "$owner_handle" "$owner_pid" \
    "$callback_name" "$@"
}

unalias __dx_selected_resume_workspace_valid 2>/dev/null; unfunction __dx_selected_resume_workspace_valid 2>/dev/null
__dx_selected_resume_workspace_valid() {
  local repo_root="$1" session_id="$2" workspace_dir="$3" workspace_mode="$4"
  local expected_branch="" current_branch="" resolved_repo="" resolved_workspace=""
  [[ -d "$workspace_dir" ]] || return 1
  git -C "$workspace_dir" rev-parse --git-dir >/dev/null 2>&1 || return 1
  expected_branch=$(dx_session_branch_read "$session_id" 2>/dev/null) || return 1
  current_branch=$(git -C "$workspace_dir" symbolic-ref --quiet --short HEAD \
    2>/dev/null) || return 1
  git -C "$workspace_dir" show-ref --verify --quiet \
    "refs/heads/${expected_branch}" 2>/dev/null || return 1
  case "$workspace_mode" in
    worktree)
      [[ "$current_branch" == "$expected_branch" ]] || return 1
      dx_wt_is_registered "$repo_root" "$workspace_dir"
      ;;
    in-place)
      resolved_repo=$(cd "$repo_root" 2>/dev/null && pwd -P) || return 1
      resolved_workspace=$(cd "$workspace_dir" 2>/dev/null && pwd -P) || return 1
      [[ "$resolved_repo" == "$resolved_workspace" ]] || return 1
      if [[ "$current_branch" != "$expected_branch" ]]; then
        [[ -z "$(git -C "$workspace_dir" status --porcelain 2>/dev/null)" ]] \
          || return 1
      fi
      ;;
    *) return 1 ;;
  esac
}

unalias __dx_selected_resume_runtime_matches 2>/dev/null; unfunction __dx_selected_resume_runtime_matches 2>/dev/null
__dx_selected_resume_runtime_matches() {
  local session_id="$1" provider_name="$2" workspace_dir="$3"
  local runtime_record="" runtime_health="" expected_owner_pid="${_dx_runtime_owner_pid:-}"
  [[ "$expected_owner_pid" =~ ^[0-9]+$ ]] || return 1
  runtime_record=$(dx_session_runtime_read "$session_id" 2>/dev/null) || return 1
  runtime_health=$(dx_session_runtime_health "$session_id" 2>/dev/null) || return 1
  python3 - "$session_id" "$provider_name" "$workspace_dir" \
    "$runtime_health" "$expected_owner_pid" 3<<<"$runtime_record" <<'PY'
import json
import os
import sys

record = json.load(os.fdopen(3))
if (
    sys.argv[4] != "live"
    or record.get("session_id") != sys.argv[1]
    or record.get("provider") != sys.argv[2]
    or record.get("status") != "running"
    or record.get("pid") != int(sys.argv[5])
    or not isinstance(record.get("workspace"), str)
    or os.path.realpath(record["workspace"]) != os.path.realpath(sys.argv[3])
):
    raise SystemExit(1)
PY
}

unalias __dx_selected_resume_catalog_matches 2>/dev/null; unfunction __dx_selected_resume_catalog_matches 2>/dev/null
__dx_selected_resume_catalog_matches() {
  local repo_root="$1" session_id="$2" workspace_dir="$3" workspace_name="$4"
  local workspace_mode="$5" provider_name="$6" selected_phase="$7"
  local current_record=""
  current_record=$(dx_session_catalog_record "$session_id" --repo "$repo_root" \
    2>/dev/null) || return 1
  python3 - "$session_id" "$workspace_dir" "$workspace_name" \
    "$workspace_mode" "$provider_name" "$selected_phase" \
    3<<<"$current_record" <<'PY'
import json
import os
import sys

record = json.load(os.fdopen(3))
if (
    record.get("session_id") != sys.argv[1]
    or record.get("is_child") is not False
    or record.get("metadata_health") != "valid"
    or record.get("runtime_health") != "live"
    or record.get("runtime_status") != "running"
    or record.get("unsafe_artifacts") != []
    or record.get("consistency_issues") != []
    or record.get("workspace_name") != sys.argv[3]
    or record.get("workspace_mode") != sys.argv[4]
    or record.get("provider") != sys.argv[5]
    or str(record.get("phase")) != sys.argv[6]
    or not isinstance(record.get("workspace"), str)
    or os.path.realpath(record["workspace"]) != os.path.realpath(sys.argv[2])
):
    raise SystemExit(1)
PY
}

unalias __dx_selected_resume_after_claim 2>/dev/null; unfunction __dx_selected_resume_after_claim 2>/dev/null
__dx_selected_resume_after_claim() {
  local session_id="$1" repo_root="$2" workspace_dir="$3" workspace_name="$4"
  local workspace_mode="$5" provider_name="$6" selected_phase="$7" raw_input="$8"
  local legacy_cwd="${9:-0}" expected_canonical_workspace="${10:-}"
  local review_lock_token="" prepared_phase="" default_branch=""
  local state_file times_file resume_hint transition_locked=0 review_locked=0
  local current_canonical_workspace=""

  [[ "$legacy_cwd" == "0" || "$legacy_cwd" == "1" ]] || {
    __dx_runtime_set_terminal blocked
    return 1
  }
  if [[ "$legacy_cwd" == "1" ]]; then
    [[ "$expected_canonical_workspace" == /* ]] || {
      __dx_runtime_set_terminal blocked
      return 1
    }
    case "$expected_canonical_workspace" in
      *$'\t'*|*$'\r'*|*$'\n'*)
        __dx_runtime_set_terminal blocked
        return 1
        ;;
    esac
  fi

  review_lock_token=$(__dx_review_nonce) || {
    __dx_runtime_set_terminal blocked
    return 1
  }
  if ! dx_review_lock_acquire "$workspace_dir" "$review_lock_token" "$$"; then
    __dx_runtime_set_terminal blocked
    dx_error "Another review or recovery operation already owns this checkout."
    return 1
  fi
  review_locked=1
  if ! __dx_selected_resume_runtime_matches \
      "$session_id" "$provider_name" "$workspace_dir" \
    || ! __dx_selected_resume_catalog_matches "$repo_root" "$session_id" \
      "$workspace_dir" "$workspace_name" "$workspace_mode" "$provider_name" \
      "$selected_phase"; then
    dx_review_lock_release_checked "$workspace_dir" "$review_lock_token" \
      2>/dev/null || true
    __dx_runtime_set_terminal blocked
    dx_error "The selected session changed while Dex was claiming it."
    return 1
  fi
  if ! __dx_selected_resume_workspace_valid \
      "$repo_root" "$session_id" "$workspace_dir" "$workspace_mode"; then
    dx_review_lock_release_checked "$workspace_dir" "$review_lock_token" \
      2>/dev/null || true
    __dx_runtime_set_terminal blocked
    dx_error "The selected workspace is missing, unregistered, dirty, or on the wrong lifecycle branch."
    return 1
  fi
  if [[ "$legacy_cwd" == "1" ]]; then
    current_canonical_workspace=$(
      cd "$workspace_dir" 2>/dev/null && pwd -P
    ) || {
      dx_review_lock_release_checked "$workspace_dir" "$review_lock_token" \
        2>/dev/null || true
      __dx_runtime_set_terminal blocked
      dx_error "The selected workspace changed while Dex was validating the legacy resume."
      return 1
    }
    if [[ "$current_canonical_workspace" != "$expected_canonical_workspace" ]]; then
      dx_review_lock_release_checked "$workspace_dir" "$review_lock_token" \
        2>/dev/null || true
      __dx_runtime_set_terminal blocked
      dx_error "The selected workspace changed while Dex was validating the legacy resume."
      return 1
    fi
  fi
  if [[ "$workspace_mode" == "in-place" ]] \
    && ! __dx_restore_in_place_session_branch "$session_id" "$workspace_name" \
      "$workspace_dir" "dx sessions resume session:${session_id}"; then
    dx_review_lock_release_checked "$workspace_dir" "$review_lock_token" \
      2>/dev/null || true
    __dx_runtime_set_terminal blocked
    return 1
  fi
  if ! dx_lifecycle_control_lock_acquire "$session_id"; then
    dx_review_lock_release_checked "$workspace_dir" "$review_lock_token" \
      2>/dev/null || true
    __dx_runtime_set_terminal blocked
    dx_error "Dex could not lock the selected lifecycle for relaunch."
    return 1
  fi
  transition_locked=1
  prepared_phase=$(dx_lifecycle_relaunch_prepare_unlocked \
    "$session_id" "$selected_phase" 2>/dev/null) || {
    dx_lifecycle_control_lock_release_checked "$session_id" \
      2>/dev/null || true
    dx_review_lock_release_checked "$workspace_dir" "$review_lock_token" \
      2>/dev/null || true
    __dx_runtime_set_terminal blocked
    dx_error "The selected lifecycle is not in a safe, resumable state."
    return 1
  }
  if [[ "$selected_phase" != "$prepared_phase" \
    && "${selected_phase}:${prepared_phase}" != "7:6" ]]; then
    dx_lifecycle_control_lock_release_checked "$session_id" \
      2>/dev/null || true
    dx_review_lock_release_checked "$workspace_dir" "$review_lock_token" \
      2>/dev/null || true
    __dx_runtime_set_terminal blocked
    dx_error "The lifecycle phase changed while Dex was claiming the session."
    return 1
  fi
  if ! dx_lifecycle_control_lock_release_checked "$session_id"; then
    transition_locked=0
    dx_review_lock_release_checked "$workspace_dir" "$review_lock_token" \
      2>/dev/null || true
    __dx_runtime_set_terminal blocked
    dx_error "Dex could not release the lifecycle transition lock safely."
    return 1
  fi
  transition_locked=0
  if ! dx_review_lock_release_checked "$workspace_dir" "$review_lock_token"; then
    review_locked=0
    __dx_runtime_set_terminal blocked
    dx_error "Dex could not release the checkout recovery lock safely."
    return 1
  fi
  review_locked=0
  : "$transition_locked" "$review_locked"

  default_branch=$(dx_default_branch "$workspace_dir") || {
    __dx_runtime_set_terminal blocked
    return 1
  }
  state_file=$(dx_state_file "$session_id")
  times_file=$(dx_times_file "$session_id")
  resume_hint="dx sessions resume session:${session_id}"
  if [[ "$legacy_cwd" == "1" ]] \
    && ! cd "$expected_canonical_workspace" 2>/dev/null; then
    __dx_runtime_set_terminal blocked
    dx_error "The validated legacy workspace could not be opened for provider launch."
    return 1
  fi
  __dx_run_phases_inline "$workspace_name" "$workspace_dir" "$default_branch" \
    "$prepared_phase" "$state_file" "$times_file" "$resume_hint" \
    "$workspace_mode" "$session_id" "$raw_input"
}

unalias __dx_selected_resume_legacy_mapping_matches 2>/dev/null; unfunction __dx_selected_resume_legacy_mapping_matches 2>/dev/null
__dx_selected_resume_legacy_mapping_matches() {
  [[ $# -eq 6 ]] || return 1
  local workspace_name="$1" workspace_dir="$2" workspace_mode="$3"
  local expected_workspace_name="$4" expected_workspace="$5"
  local expected_workspace_mode="$6" resolved_workspace=""
  local resolved_expected_workspace=""

  [[ -n "$expected_workspace_name" && -n "$expected_workspace" ]] || return 1
  [[ "$expected_workspace" == /* ]] || return 1
  case "$expected_workspace_name$expected_workspace$expected_workspace_mode" in
    *$'\t'*|*$'\r'*|*$'\n'*) return 1 ;;
  esac
  [[ "$expected_workspace_mode" == "worktree" \
    || "$expected_workspace_mode" == "in-place" ]] || return 1
  [[ "$workspace_name" == "$expected_workspace_name" \
    && "$workspace_mode" == "$expected_workspace_mode" ]] || return 1
  [[ -d "$workspace_dir" && -d "$expected_workspace" ]] || return 1
  resolved_workspace=$(cd "$workspace_dir" 2>/dev/null && pwd -P) || return 1
  resolved_expected_workspace=$(
    cd "$expected_workspace" 2>/dev/null && pwd -P
  ) || return 1
  [[ "$resolved_workspace" == "$resolved_expected_workspace" ]]
}

unalias __dx_selected_resume_completed_catalog_matches 2>/dev/null; unfunction __dx_selected_resume_completed_catalog_matches 2>/dev/null
__dx_selected_resume_completed_catalog_matches() {
  [[ $# -eq 7 ]] || return 1
  local repo_root="$1" session_id="$2" workspace_dir="$3"
  local workspace_name="$4" workspace_mode="$5" provider_name="$6"
  local runtime_pid="$7" current_record=""
  current_record=$(dx_session_catalog_record "$session_id" --repo "$repo_root" \
    2>/dev/null) || return 1
  python3 - "$session_id" "$workspace_dir" "$workspace_name" \
    "$workspace_mode" "$provider_name" "$runtime_pid" \
    3<<<"$current_record" <<'PY'
import json
import os
import sys

record = json.load(os.fdopen(3))
if (
    record.get("session_id") != sys.argv[1]
    or record.get("is_child") is not False
    or record.get("metadata_health") != "valid"
    or record.get("runtime_health") != "dead"
    or record.get("runtime_status") != "completed"
    or record.get("lifecycle_state") != "completed"
    or record.get("phase") != 7
    or record.get("unsafe_artifacts") != []
    or record.get("consistency_issues") != []
    or record.get("workspace_name") != sys.argv[3]
    or record.get("workspace_mode") != sys.argv[4]
    or record.get("provider") != sys.argv[5]
    or record.get("runtime_pid") != int(sys.argv[6])
    or not isinstance(record.get("workspace"), str)
    or os.path.realpath(record["workspace"]) != os.path.realpath(sys.argv[2])
):
    raise SystemExit(1)
PY
}

unalias __dx_sessions_resume_selected 2>/dev/null; unfunction __dx_sessions_resume_selected 2>/dev/null
__dx_sessions_resume_selected() {
  [[ $# -eq 1 || $# -eq 2 || $# -eq 6 ]] || return 1
  local selector_value="$1" requested_provider="${2:-}"
  local resume_mode="${3:-}" expected_workspace_name="${4:-}"
  local expected_workspace="${5:-}" expected_workspace_mode="${6:-}"
  local selected_record="" runtime_snapshot=""
  local selected_file="" runtime_file="" validated_record="" validation_result=0
  local session_id workspace_dir workspace_name workspace_mode provider_name
  local selected_phase raw_input lifecycle_state runtime_status runtime_pid
  local repo_root resolved_provider legacy_resume=0 legacy_canonical_workspace=""
  local -x DX_AGENT_OVERRIDE=""
  setopt localoptions noxtrace

  if [[ $# -eq 6 ]]; then
    [[ "$resume_mode" == "legacy-last-session" ]] || return 1
    legacy_resume=1
  fi
  if [[ -n "$requested_provider" ]]; then
    requested_provider=$(dx_agent_normalize "$requested_provider") || return 1
  fi
  repo_root=$(dx_repo_root) || return 1
  if selected_record=$(dx_session_catalog_select \
      "$selector_value" --repo "$repo_root"); then
    :
  else
    validation_result=$?
    if [[ "$validation_result" -eq 1 ]]; then
      dx_error "No top-level session matches '${selector_value}' in this repository."
    elif [[ "$validation_result" -ne 2 ]]; then
      dx_error "Dex could not resolve that session selector safely."
    fi
    return 1
  fi
  selected_file=$(mktemp "${TMPDIR:-/tmp}/dex-selected-resume.XXXXXX") \
    || return 1
  runtime_file=$(mktemp "${TMPDIR:-/tmp}/dex-selected-runtime.XXXXXX") || {
    command rm -f "$selected_file" 2>/dev/null || true
    return 1
  }
  printf '%s\n' "$selected_record" >| "$selected_file" || {
    command rm -f "$selected_file" "$runtime_file" 2>/dev/null || true
    return 1
  }
  session_id=$(python3 - "$selected_file" <<'PY'
import json
import re
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    record = json.load(source)
session_id = record.get("session_id")
if not isinstance(session_id, str) or not re.fullmatch(
    r"[A-Za-z0-9][A-Za-z0-9._-]{0,179}", session_id
):
    raise SystemExit(1)
print(session_id)
PY
  ) || validation_result=1
  if [[ "$validation_result" -ne 0 ]] \
    || ! dx_session_runtime_read "$session_id" >| "$runtime_file" 2>/dev/null; then
    command rm -f "$selected_file" "$runtime_file" 2>/dev/null || true
    dx_error "The selected session has no exact, verifiable runtime snapshot to recover."
    return 1
  fi
  runtime_snapshot=$(<"$runtime_file")
  validated_record=$(python3 - "$selected_file" "$runtime_file" <<'PY'
import json
import os
import re
import sys

with open(sys.argv[1], encoding="utf-8") as source:
    selected = json.load(source)
with open(sys.argv[2], encoding="utf-8") as source:
    runtime = json.load(source)

plain = re.compile(r"^[^\t\r\n]+$")
session_id = selected.get("session_id")
workspace = selected.get("workspace")
workspace_name = selected.get("workspace_name")
workspace_mode = selected.get("workspace_mode")
provider = selected.get("provider")
phase = selected.get("phase")
runtime_status = selected.get("runtime_status")
lifecycle_state = selected.get("lifecycle_state")
if (
    selected.get("is_child") is not False
    or selected.get("metadata_health") != "valid"
    or selected.get("runtime_health") != "dead"
    or runtime_status not in {"running", "paused", "blocked", "failed", "stopped", "abandoned", "completed"}
    or selected.get("unsafe_artifacts") not in ([], None)
    or selected.get("consistency_issues") not in ([], None)
    or not isinstance(lifecycle_state, str)
    or not plain.fullmatch(lifecycle_state)
    or type(phase) is not int
    or phase < 0
    or phase > 7
    or workspace_mode not in {"worktree", "in-place"}
    or provider not in {"claude", "codex"}
    or not isinstance(session_id, str)
    or not isinstance(workspace, str)
    or not os.path.isabs(workspace)
    or not isinstance(workspace_name, str)
    or not plain.fullmatch(session_id)
    or not plain.fullmatch(workspace)
    or not plain.fullmatch(workspace_name)
):
    raise SystemExit(1)
if (
    runtime.get("session_id") != session_id
    or runtime.get("provider") != provider
    or runtime.get("status") != runtime_status
    or not isinstance(runtime.get("workspace"), str)
    or os.path.realpath(runtime["workspace"]) != os.path.realpath(workspace)
    or selected.get("runtime_pid") != runtime.get("pid")
):
    raise SystemExit(1)
raw_input = selected.get("ticket") or workspace_name
if not isinstance(raw_input, str) or not plain.fullmatch(raw_input):
    raw_input = workspace_name
print("\t".join((
    session_id,
    workspace,
    workspace_name,
    workspace_mode,
    provider,
    str(phase),
    raw_input,
    lifecycle_state,
    runtime_status,
    str(runtime.get("pid")),
)))
PY
  ) || validation_result=1
  command rm -f "$selected_file" "$runtime_file" 2>/dev/null || validation_result=1
  if [[ "$validation_result" -ne 0 ]]; then
    dx_error "The selected session is live, completed, unsafe, inconsistent, or unsupported."
    return 1
  fi
  IFS=$'\t' read -r session_id workspace_dir workspace_name workspace_mode \
    provider_name selected_phase raw_input lifecycle_state runtime_status \
    runtime_pid <<< "$validated_record"

  if [[ "$legacy_resume" -eq 1 ]] \
    && ! __dx_selected_resume_legacy_mapping_matches \
      "$workspace_name" "$workspace_dir" "$workspace_mode" \
      "$expected_workspace_name" "$expected_workspace" \
      "$expected_workspace_mode"; then
    dx_error "The saved last-session mapping no longer matches this repository's exact lifecycle record."
    return 1
  fi
  if [[ "$legacy_resume" -eq 1 ]]; then
    legacy_canonical_workspace=$(
      cd "$expected_workspace" 2>/dev/null && pwd -P
    ) || {
      dx_error "The saved last-session mapping no longer resolves to a trusted workspace."
      return 1
    }
  fi

  if [[ "$lifecycle_state" == "completed" ]]; then
    if [[ "$legacy_resume" -ne 1 ]]; then
      dx_error "The selected session is already complete and cannot be relaunched."
      return 1
    fi
    if [[ "$selected_phase" != "7" || "$runtime_status" != "completed" ]] \
      || ! __dx_selected_resume_workspace_valid \
        "$repo_root" "$session_id" "$workspace_dir" "$workspace_mode" \
      || ! dx_lifecycle_terminal_commit_valid "$session_id" \
      || ! __dx_selected_resume_completed_catalog_matches \
        "$repo_root" "$session_id" "$workspace_dir" "$workspace_name" \
        "$workspace_mode" "$provider_name" "$runtime_pid"; then
      dx_error "Dex could not verify the completed lifecycle and its terminal proof."
      return 1
    fi
    echo "Ticket lifecycle already complete for ${workspace_name}."
    if [[ "$workspace_mode" == "worktree" ]]; then
      echo "Local cleanup should already be complete. If files remain, run dxrm ${workspace_name}."
    else
      echo "This lifecycle ran in the current checkout; local branch cleanup is handled at completion when safe."
    fi
    return 0
  fi

  if [[ -n "$requested_provider" && "$requested_provider" != "$provider_name" ]]; then
    dx_error "Session ${session_id} was recorded for ${provider_name}; refusing the requested ${requested_provider} provider override."
    return 1
  fi
  if ! __dx_selected_resume_workspace_valid \
      "$repo_root" "$session_id" "$workspace_dir" "$workspace_mode"; then
    dx_error "The selected workspace is missing, unregistered, dirty, or on the wrong lifecycle branch."
    return 1
  fi
  DX_AGENT_OVERRIDE="$provider_name"
  __dx_refresh_provider || return 1
  resolved_provider=$(__dx_resolved_provider_agent) || return 1
  if [[ "$resolved_provider" != "$provider_name" ]]; then
    dx_error "The selected provider cannot be restored by the current Dex configuration."
    return 1
  fi

  __dx_run_with_recovered_runtime "$session_id" "$runtime_snapshot" \
    __dx_selected_resume_after_claim "$session_id" "$repo_root" \
    "$workspace_dir" "$workspace_name" "$workspace_mode" "$provider_name" \
    "$selected_phase" "$raw_input" "$legacy_resume" \
    "$legacy_canonical_workspace"
}

# __dx_run_phases_inline <wt_name> <wt_dir> <default_branch> <start_step> <state_file> <times_file> <resume_hint> [workspace_mode] [session_id] [raw_input]
#
# Phase lifecycle entrypoint, and the same-session runner. The shell launches
# Claude once; the Stop hook advances phases by updating state/config files and
# injecting the next phase's instructions back into the existing session. This
# avoids the Claude TUI handoff problem where a completed phase leaves the user
# needing /exit + resume.
# Phase 6 (Complete) is autonomous: it marks the PR ready, requests configured
# reviewers (see dex.md § Reviewers), monitors CI/reviews, addresses comments,
# and closes the ticket. The user is in the loop only as a configured reviewer.
# Returns non-zero if the user interrupts or an error occurs.
__dx_run_phases_inline() {
  local wt_name="$1" wt_dir="$2" default_branch="$3" step="$4"
  local state_file="$5" times_file="$6" resume_hint="$7"
  local workspace_mode="${8:-worktree}"
  local session_id="${9:-}" raw_input="${10:-}"
  local claude_session_name workspace_cleanup_result=0
  claude_session_name=$(__dx_claude_session_name "$workspace_mode" "$wt_name")

  [[ "${DX_PROVIDER_APPLIED:-}" == "1" ]] || dx_provider_apply || return 1
  if [[ "${DX_PROVIDER_ENGINE:-}" != "codex-plugin" ]] && ! command -v claude &>/dev/null; then
    dx_error "Claude Code CLI not found in PATH."
    dx_info "Install it from https://docs.anthropic.com/en/docs/claude-code then try again."
    return 1
  fi

  [[ -n "$session_id" ]] || session_id=$(__dx_session_id_for_workspace "$workspace_mode" "$wt_name")

  local run_id
  if ! run_id=$(dx_run_prepare "$session_id" "$wt_dir" "$workspace_mode" "$wt_name" "$raw_input" "dx"); then
    dx_error "Unable to prepare Dex run journal."
    return 1
  fi
  dx_dexcode_prepare_run_sync "$run_id" "$wt_dir" "$workspace_mode" "$wt_name" "$raw_input" "dx" || return 1
  dx_run_maybe_emit_started "$run_id" "Dex lifecycle started" "{\"command\":\"dx\",\"start_phase\":${step},\"workspace_mode\":\"${workspace_mode}\",\"workspace_name\":\"${wt_name}\"}"
  dx_event_maybe_emit_phase_started "$run_id" "$step" "$(__dx_phase_name "$step")" "launcher"
  dx_run_log_append_safe "$run_id" "info" "dx" "Lifecycle started at Phase ${step}: $(__dx_phase_name "$step")"

  local had_times_file=0
  [[ -f "$times_file" ]] && had_times_file=1

  __dx_show_header "$wt_name" "$step" "$wt_dir" "$default_branch" "$session_id" "$workspace_mode"
  __dx_record_session_branch "$session_id" "$wt_dir" || return 1

  dx_provider_write_session_state "$session_id" 2>/dev/null || true
  local preflight_handoff_status=0
  __dx_codex_direct_phase_handoff "$session_id" "$step" "$state_file" "$wt_dir" control-only || preflight_handoff_status=$?
  if [[ "$preflight_handoff_status" -eq 0 ]]; then
    local preflight_step="$step"
    if [[ -e "$state_file" || -L "$state_file" ]]; then
      preflight_step=$(dx_lifecycle_phase_state "$session_id" 2>/dev/null) || {
        dx_provider_cleanup_session_state "$session_id"
        dx_error "Dex found an unsafe or malformed authoritative phase file. Repair it before continuing."
        return 1
      }
    fi
    if [[ "$preflight_step" -ge 7 ]]; then
      if ! dx_lifecycle_terminal_commit_valid "$session_id"; then
        dx_provider_cleanup_session_state "$session_id"
        dx_error "Dex found Phase 7 without a valid terminal commit proof. The lifecycle remains inert; repair or resume it instead of cleaning the workspace."
        return 1
      fi
      dx_provider_cleanup_session_state "$session_id"
      __dx_show_header "$wt_name" 7 "$wt_dir" "$default_branch" "$session_id" "$workspace_mode"
      echo ""
      echo "Ticket lifecycle complete."
      if dx_lifecycle_human_complete_valid "$session_id"; then
        dx_info "Human-controlled completion preserved the lifecycle workspace."
        __dx_runtime_set_terminal completed
        return 0
      fi
      __dx_cleanup_completed_workspace "$wt_name" "$wt_dir" "$default_branch" "$workspace_mode" "$session_id"
      workspace_cleanup_result=$?
      if [[ "$workspace_cleanup_result" -eq 0 ]]; then
        __dx_runtime_set_terminal completed
      else
        __dx_runtime_set_terminal failed
      fi
      return "$workspace_cleanup_result"
    fi
    __dx_run_phases_inline "$wt_name" "$wt_dir" "$default_branch" "$preflight_step" "$state_file" "$times_file" "$resume_hint" "$workspace_mode" "$session_id" "$raw_input"
    return $?
  elif [[ "$preflight_handoff_status" -eq 2 ]]; then
    __dx_runtime_set_terminal paused
    __dx_finish_inline_pause "$session_id" "$step" "$resume_hint" "$wt_name" "$wt_dir" \
      "$default_branch" "$workspace_mode"
    return $?
  elif [[ "$preflight_handoff_status" -eq 3 ]]; then
    dx_provider_cleanup_session_state "$session_id"
    dx_error "Dex found an unreadable or invalid lifecycle control receipt. Repair or remove it before restarting this lifecycle."
    return 1
  fi

  local completion_generation configure_status=0
  completion_generation=$(__dx_configure_inline_phase "$step" "$session_id") || configure_status=$?
  if [[ "$configure_status" -eq 2 ]]; then
    local reconciled_step
    reconciled_step=$(dx_lifecycle_phase_state "$session_id" 2>/dev/null || true)
    if [[ "$reconciled_step" =~ ^[0-6]$ ]]; then
      dx_info "Lifecycle state moved to Phase ${reconciled_step} before launch; using the authoritative phase."
      __dx_run_phases_inline "$wt_name" "$wt_dir" "$default_branch" "$reconciled_step" \
        "$state_file" "$times_file" "$resume_hint" "$workspace_mode" "$session_id" "$raw_input"
      return $?
    elif [[ "$reconciled_step" == "7" ]]; then
      if ! dx_lifecycle_terminal_commit_valid "$session_id"; then
        dx_provider_cleanup_session_state "$session_id"
        dx_error "Dex found Phase 7 without a valid terminal commit proof. The lifecycle remains inert; repair or resume it instead of cleaning the workspace."
        return 1
      fi
      dx_provider_cleanup_session_state "$session_id"
      __dx_show_header "$wt_name" 7 "$wt_dir" "$default_branch" "$session_id" "$workspace_mode"
      echo ""
      echo "Ticket lifecycle complete."
      if dx_lifecycle_human_complete_valid "$session_id"; then
        dx_info "Human-controlled completion preserved the lifecycle workspace."
        __dx_runtime_set_terminal completed
        return 0
      fi
      __dx_cleanup_completed_workspace "$wt_name" "$wt_dir" "$default_branch" \
        "$workspace_mode" "$session_id"
      workspace_cleanup_result=$?
      if [[ "$workspace_cleanup_result" -eq 0 ]]; then
        __dx_runtime_set_terminal completed
      else
        __dx_runtime_set_terminal failed
      fi
      return "$workspace_cleanup_result"
    fi
  fi
  if [[ "$configure_status" -ne 0 ]]; then
    dx_error "Could not prepare completion authorization for Phase ${step}."
    return 1
  fi

  if [[ $step -ge 2 ]]; then
    dx_checkpoint_tag "$step" "$wt_dir"
  fi

  local phase_start_epoch
  phase_start_epoch=$(date +%s)
  mkdir -p "$(dirname "$times_file")"
  echo "${step}:${phase_start_epoch}" >> "$times_file"

  local ctx_file
  ctx_file=$(__dx_build_system_context "$wt_name" "$step" "$session_id" "$wt_dir" "$workspace_mode" "$raw_input" "$completion_generation")

  local claude_args=("${DX_CLAUDE_FLAGS[@]}" -n "$claude_session_name")
  [[ $had_times_file -eq 1 ]] && claude_args+=(--resume)
  claude_args+=(--append-system-prompt-file "$ctx_file")
  claude_args+=(--settings "{\"statusLine\":{\"type\":\"command\",\"command\":\"bash '${DEX_DIR}/bin/status-line.sh'\"}}")

  local message
  message=$(__dx_phase_message "$step" "$raw_input" "$workspace_mode" "$wt_dir")

  local session_timeout="${DEX_SESSION_TIMEOUT:-$DX_SESSION_TIMEOUT}"
  local session_start_epoch
  session_start_epoch=$(date +%s)
  local _dx_watchdog_pid="" _dx_pidfile="" _dx_watchdog_reason_file=""
  # An unchecked mktemp leaves the path empty, and the watchdog below then
  # polls a file that can never appear, spinning for the whole session.
  if ! _dx_pidfile=$(mktemp "${TMPDIR:-/tmp}/dx-inline.XXXXXX"); then
    dx_completion_abandon "$session_id" 2>/dev/null || true
    dx_error "Could not create the phase handoff temp file"
    return 1
  fi
  _dx_watchdog_reason_file="${_dx_pidfile}.reason"

  (
    local watch_target="" watch_now watch_phase watch_phase_start watch_failure=""
    local watch_session_timeout="" watch_phase_timeout=""
    while [[ -z "$watch_target" ]]; do
      [[ -s "$_dx_pidfile" ]] && watch_target=$(<"$_dx_pidfile")
      [[ -z "$watch_target" ]] && sleep 0.2
    done
    while kill -0 "$watch_target" 2>/dev/null; do
      watch_now=$(date +%s)
      watch_phase=$(dx_lifecycle_current_phase "$session_id")
      [[ "$watch_phase" =~ ^[0-6]$ ]] || watch_phase="$step"
      watch_session_timeout=$(dx_override_effective "$session_id" \
        session.timeout "$session_timeout" "$watch_phase" 2>/dev/null) \
        || watch_failure="invalid-runtime-override"
      watch_phase_timeout=$(__dx_phase_timeout "$watch_phase" "$session_id" \
        2>/dev/null) || watch_failure="invalid-runtime-override"
      if [[ ! "$watch_session_timeout" =~ ^[0-9]+$ \
        || ! "$watch_phase_timeout" =~ ^[0-9]+$ ]]; then
        watch_failure="invalid-runtime-override"
      fi
      if [[ -z "$watch_failure" ]]; then
        watch_phase_start=$(dx_session_phase_start_epoch "$session_id" \
          "$watch_phase")
        [[ "$watch_phase_start" =~ ^[0-9]+$ ]] \
          || watch_phase_start="$watch_now"
        if [[ "$watch_session_timeout" -gt 0 \
          && $((watch_now - session_start_epoch)) -ge "$watch_session_timeout" ]]; then
          watch_failure="session-timeout"
        elif [[ "$watch_phase_timeout" -gt 0 \
          && $((watch_now - watch_phase_start)) -ge "$watch_phase_timeout" ]]; then
          watch_failure="phase-timeout"
        fi
      fi
      if [[ -n "$watch_failure" ]]; then
        (umask 077; printf '%s\n' "$watch_failure" \
          >| "$_dx_watchdog_reason_file")
        __dx_kill_process_tree "$watch_target" TERM
        sleep 2
        __dx_kill_process_tree "$watch_target" KILL
        break
      fi
      sleep 1
    done
  ) &
  _dx_watchdog_pid=$!
  # Disown the just-backgrounded watchdog so zsh doesn't print a job-control
  # "terminated" notice when we kill it during cleanup below. $! is already
  # captured, so `kill "$_dx_watchdog_pid"` still works after disowning.
  # (zsh's `disown` takes a job spec, not a PID, so disown the current job.)
  disown 2>/dev/null || true

  (
    sh -c 'echo $PPID' > "$_dx_pidfile"
    cd "$wt_dir" && \
    DEX_SESSION_ID="$session_id" \
    DEX_RUN_ID="$run_id" \
    DEX_HEADLESS_RUN="${DEX_HEADLESS_RUN:-}" \
    DEX_HEADLESS_RUN_SPEC_FILE="${DEX_HEADLESS_RUN_SPEC_FILE:-}" \
    DEX_HEADLESS_REQUIRES_PLAN_APPROVAL="${DEX_HEADLESS_REQUIRES_PLAN_APPROVAL:-}" \
    DEX_LOOP_ACTIVE=1 \
    DEX_LOOP_PROMISE="$(__dx_phase_promise "$step")" \
    DEX_LOOP_PHASE="$step" \
    DEX_PHASE_HANDOFF=inline \
    DEX_COMPLETE_MAX_CYCLES="${DEX_COMPLETE_MAX_CYCLES:-$DX_COMPLETE_MAX_CYCLES}" \
    DEX_COMPLETE_WAIT_MINUTES="${DEX_COMPLETE_WAIT_MINUTES:-$DX_COMPLETE_WAIT_MINUTES}" \
    DEX_DIR="$DEX_DIR" \
    DX_RUN_ROOT="$DX_RUN_ROOT" \
    __dx_claude "${claude_args[@]}" "$message"
  )
  local exit_code=$?
  local watchdog_reason=""
  [[ -s "$_dx_watchdog_reason_file" ]] \
    && watchdog_reason=$(<"$_dx_watchdog_reason_file")
  rm -f "$_dx_pidfile" "$_dx_watchdog_reason_file"
  [[ -n "$_dx_watchdog_pid" ]] && kill "$_dx_watchdog_pid" 2>/dev/null
  if [[ -n "$watchdog_reason" ]]; then
    if ! dx_lifecycle_pause "$session_id" "$watchdog_reason" phase-loop; then
      dx_error "Dex could not safely pause after the runtime watchdog fired."
      __dx_runtime_set_terminal failed
      return 1
    fi
    case "$watchdog_reason" in
      session-timeout)
        dx_error "Dex paused because the current session runtime budget expired."
        ;;
      phase-timeout)
        dx_error "Dex paused because the current phase runtime budget expired."
        ;;
      *)
        dx_error "Dex paused because its session override state is unsafe or invalid."
        ;;
    esac
  fi

  local final_step="$step"
  if [[ -e "$state_file" || -L "$state_file" ]]; then
    final_step=$(dx_lifecycle_phase_state "$session_id" 2>/dev/null) || {
      dx_lifecycle_completion_brake "$session_id" invalid-phase-state \
        dx 2>/dev/null || true
      dx_error "Dex found an unsafe or malformed authoritative phase file. Completion remains closed."
      return 1
    }
  fi
  [[ "$final_step" =~ ^[0-7]$ ]] || final_step="$step"

  local paused_file pause_context_rc=0
  paused_file=$(dx_paused_file "$session_id")
  dx_lifecycle_pause_context_state "$session_id" || pause_context_rc=$?
  if [[ "$pause_context_rc" -eq 2 ]]; then
    __dx_abandon_completion_state "$session_id" 2>/dev/null || true
    dx_lifecycle_completion_brake "$session_id" invalid-pause-state \
      dx 2>/dev/null || true
    dx_error "Dex found an unsafe or incomplete pause state. Completion authorization is closed; repair the lifecycle state before resuming."
    __dx_runtime_set_terminal failed
    return 1
  fi
  if [[ "$pause_context_rc" -eq 0 ]]; then
    if ! __dx_abandon_completion_state "$session_id"; then
      dx_error "Dex paused, but completion authorization could not be safely revoked. Repair the lifecycle state files before resuming."
      return 1
    fi
    __dx_runtime_set_terminal paused
    __dx_finish_inline_pause "$session_id" "$final_step" "$resume_hint" "$wt_name" "$wt_dir" \
      "$default_branch" "$workspace_mode"
    return $?
  fi

  local loop_file
  loop_file=$(dx_loop_file "$session_id")
  if [[ "$final_step" -lt 7 && -f "$loop_file" ]]; then
    local raw_iter iterations max_iterations pause_reason
    raw_iter=$(cat "$loop_file" 2>/dev/null || echo "0")
    iterations="${raw_iter%%:*}"
    [[ "$iterations" =~ ^[0-9]+$ ]] || iterations=0
    max_iterations="${DEX_LOOP_MAX_ITERATIONS:-30}"
    max_iterations=$(dx_override_effective "$session_id" loop.max-iterations \
      "$max_iterations" "$final_step" 2>/dev/null \
      || printf '%s\n' "$max_iterations")
    pause_reason="phase did not complete"
    if [[ "$iterations" -ge "$max_iterations" ]]; then
      pause_reason="max audit iterations reached (${iterations}/${max_iterations})"
    fi

    dx_completion_abandon "$session_id" 2>/dev/null || true
    rm -f "$loop_file" "$(dx_active_file "$session_id")" "$(dx_owner_file "$session_id")" "$(dx_loop_config_file "$session_id")" "$(dx_handoff_mode_file "$session_id")" "$(dx_paused_file "$session_id")" 2>/dev/null
    local terminal_data
    terminal_data=$(__dx_terminal_event_data "blocked" "$pause_reason" "$final_step" "$(__dx_phase_name "$final_step")" "" "$resume_hint")
    dx_event_emit_for_session "$session_id" "run.blocked" "warn" "Dex lifecycle paused at Phase ${final_step}: $(__dx_phase_name "$final_step")" "$final_step" "$terminal_data"
    dx_run_log_append_for_session "$session_id" "warn" "dx" "Lifecycle paused at Phase ${final_step}: ${pause_reason}"
    dx_run_write_summary_for_session "$session_id" "blocked" "Paused at Phase ${final_step}: ${pause_reason}"
    dx_provider_cleanup_session_state "$session_id"

    __dx_show_header "$wt_name" "$final_step" "$wt_dir" "$default_branch" "$session_id" "$workspace_mode"
    echo ""
    echo "Paused at Phase ${final_step}: $(__dx_phase_name "$final_step") (${pause_reason})"
    echo "Resume with: ${resume_hint}"
    __dx_runtime_set_terminal blocked
    return 1
  fi

  if [[ $exit_code -eq 0 && "$final_step" -ge 7 ]] \
    && dx_lifecycle_terminal_commit_valid "$session_id"; then
    dx_run_log_append_for_session "$session_id" "info" "dx" "Ticket lifecycle complete"
    dx_provider_cleanup_session_state "$session_id"
    rm -f "$(dx_active_file "$session_id")" "$(dx_owner_file "$session_id")" "$(dx_loop_config_file "$session_id")" "$(dx_handoff_mode_file "$session_id")" 2>/dev/null
    __dx_show_header "$wt_name" 7 "$wt_dir" "$default_branch" "$session_id" "$workspace_mode"
    echo ""
    echo "Ticket lifecycle complete."
    if dx_lifecycle_human_complete_valid "$session_id"; then
      dx_info "Human-controlled completion preserved the lifecycle workspace."
      __dx_runtime_set_terminal completed
      return 0
    fi
    __dx_cleanup_completed_workspace "$wt_name" "$wt_dir" "$default_branch" "$workspace_mode" "$session_id"
    workspace_cleanup_result=$?
    if [[ "$workspace_cleanup_result" -eq 0 ]]; then
      __dx_runtime_set_terminal completed
    else
      __dx_runtime_set_terminal failed
    fi
    return "$workspace_cleanup_result"
  fi

  if [[ $exit_code -ne 0 ]]; then
    local terminal_data terminal_reason="provider-exit" terminal_detail="exited"
    # 130 is Ctrl-C and 143 is SIGTERM. Recording those as a provider crash
    # makes an ordinary interruption indistinguishable from a real failure in
    # the run journal.
    if [[ $exit_code -eq 130 || $exit_code -eq 143 ]]; then
      terminal_reason="interrupted"
      terminal_detail="was interrupted"
    fi
    terminal_data=$(__dx_terminal_event_data "failed" "$terminal_reason" "$final_step" "$(__dx_phase_name "$final_step")" "$exit_code" "$resume_hint")
    dx_event_emit_for_session "$session_id" "run.failed" "error" "Dex lifecycle ${terminal_detail} at Phase ${final_step}: $(__dx_phase_name "$final_step")" "$final_step" "$terminal_data"
    dx_run_log_append_for_session "$session_id" "error" "dx" "Lifecycle ${terminal_detail} at Phase ${final_step} with code ${exit_code}"
    dx_run_write_summary_for_session "$session_id" "failed" "Lifecycle ${terminal_detail} at Phase ${final_step} with code ${exit_code}"
    # The loop is no longer running, so drop its ownership claim. Phase and
    # timing state stay put: that is what --resume reads.
    dx_completion_abandon "$session_id" 2>/dev/null || true
    rm -f "$(dx_active_file "$session_id")" "$(dx_owner_file "$session_id")" \
      "$(dx_loop_config_file "$session_id")" "$(dx_handoff_mode_file "$session_id")" 2>/dev/null
    __dx_show_header "$wt_name" "$final_step" "$wt_dir" "$default_branch" "$session_id" "$workspace_mode"
    echo ""
    echo "Paused at Phase ${final_step}: $(__dx_phase_name "$final_step") (exit ${exit_code})"
    echo "Resume with: ${resume_hint}"
    if [[ $exit_code -eq 130 || $exit_code -eq 143 ]]; then
      __dx_runtime_set_terminal stopped
    else
      __dx_runtime_set_terminal failed
    fi
    return "$exit_code"
  fi

  local final_handoff_status=0
  __dx_codex_direct_phase_handoff "$session_id" "$final_step" "$state_file" "$wt_dir" || final_handoff_status=$?
  if [[ "$final_handoff_status" -eq 0 ]]; then
    final_step="$step"
    if [[ -e "$state_file" || -L "$state_file" ]]; then
      final_step=$(dx_lifecycle_phase_state "$session_id" 2>/dev/null) || {
        dx_error "Dex found an unsafe or malformed authoritative phase file. Completion remains closed."
        return 1
      }
    fi
    if [[ "$final_step" -ge 7 ]]; then
      if ! dx_lifecycle_terminal_commit_valid "$session_id"; then
        dx_provider_cleanup_session_state "$session_id"
        dx_error "Dex found Phase 7 without a valid terminal commit proof. The lifecycle remains inert; repair or resume it instead of cleaning the workspace."
        return 1
      fi
      dx_provider_cleanup_session_state "$session_id"
      __dx_show_header "$wt_name" 7 "$wt_dir" "$default_branch" "$session_id" "$workspace_mode"
      echo ""
      echo "Ticket lifecycle complete."
      if dx_lifecycle_human_complete_valid "$session_id"; then
        dx_info "Human-controlled completion preserved the lifecycle workspace."
        __dx_runtime_set_terminal completed
        return 0
      fi
      __dx_cleanup_completed_workspace "$wt_name" "$wt_dir" "$default_branch" "$workspace_mode" "$session_id"
      workspace_cleanup_result=$?
      if [[ "$workspace_cleanup_result" -eq 0 ]]; then
        __dx_runtime_set_terminal completed
      else
        __dx_runtime_set_terminal failed
      fi
      return "$workspace_cleanup_result"
    fi
    __dx_run_phases_inline "$wt_name" "$wt_dir" "$default_branch" "$final_step" "$state_file" "$times_file" "$resume_hint" "$workspace_mode" "$session_id" "$raw_input"
    return $?
  elif [[ "$final_handoff_status" -eq 2 ]]; then
    __dx_runtime_set_terminal paused
    __dx_finish_inline_pause "$session_id" "$final_step" "$resume_hint" "$wt_name" "$wt_dir" \
      "$default_branch" "$workspace_mode"
    return $?
  fi

  local terminal_data
  terminal_data=$(__dx_terminal_event_data "blocked" "session-exited" "$final_step" "$(__dx_phase_name "$final_step")" "" "$resume_hint")
  dx_event_emit_for_session "$session_id" "run.blocked" "warn" "Claude session exited before Dex lifecycle completed" "$final_step" "$terminal_data"
  dx_run_log_append_for_session "$session_id" "warn" "dx" "Claude session exited before lifecycle completed at Phase ${final_step}"
  dx_run_write_summary_for_session "$session_id" "blocked" "Claude session exited at Phase ${final_step}"
  dx_completion_abandon "$session_id" 2>/dev/null || true
  rm -f \
    "$(dx_active_file "$session_id")" "$(dx_owner_file "$session_id")" \
    "$(dx_loop_config_file "$session_id")" "$(dx_handoff_mode_file "$session_id")" \
    "$(dx_paused_file "$session_id")" 2>/dev/null
  dx_provider_cleanup_session_state "$session_id"
  __dx_show_header "$wt_name" "$final_step" "$wt_dir" "$default_branch" "$session_id" "$workspace_mode"
  echo ""
  echo "Claude session exited at Phase ${final_step}: $(__dx_phase_name "$final_step")."
  echo "Resume with: ${resume_hint}"
  __dx_runtime_set_terminal blocked
  return 1
}

unalias __dx_run_spec_usage 2>/dev/null; unfunction __dx_run_spec_usage 2>/dev/null
__dx_run_spec_usage() {
  cat <<'USAGE'
Usage:
  dx run --spec <path> [--dry-run|--validate-only]
  dx run --spec-url <url> [--run-token <token>] [--dry-run|--validate-only]

Options:
  --spec <path>          Read a local run spec JSON file
  --spec-url <url>      Fetch a remote run spec JSON file
  --run-token <token>   Bearer token for remote spec fetch and Factory sync
  --dry-run             Validate, prepare the local run journal, and stop before launching the lifecycle
  --validate-only       Validate the spec only; do not prepare a run journal
  -h, --help            Show this help
USAGE
}

unalias __dx_run_spec_failure_json 2>/dev/null; unfunction __dx_run_spec_failure_json 2>/dev/null
__dx_run_spec_failure_json() {
  local source="$1" error="$2" stage="${3:-validation}"
  DX_RUN_SPEC_FAILURE_SOURCE="$source" \
  DX_RUN_SPEC_FAILURE_ERROR="$error" \
  DX_RUN_SPEC_FAILURE_STAGE="$stage" \
  python3 - <<'PY'
import json
import os

print(json.dumps({
    "source": os.environ.get("DX_RUN_SPEC_FAILURE_SOURCE", ""),
    "stage": os.environ.get("DX_RUN_SPEC_FAILURE_STAGE", "validation"),
    "error": os.environ.get("DX_RUN_SPEC_FAILURE_ERROR", ""),
}, sort_keys=True, separators=(",", ":")))
PY
}

unalias __dx_run_spec_record_failure 2>/dev/null; unfunction __dx_run_spec_record_failure 2>/dev/null
__dx_run_spec_record_failure() {
  local source="$1" message="$2" stage="${3:-validation}" repo_dir="${4:-$PWD}"
  local session_id run_id data_json
  if git -C "$repo_dir" rev-parse --show-toplevel >/dev/null 2>&1; then
    session_id=$(cd "$repo_dir" 2>/dev/null && dx_unique_session_id)
  else
    session_id=$(dx_unique_session_id)
    repo_dir="$PWD"
  fi
  if run_id=$(dx_run_prepare "headless-invalid-${session_id}" "$repo_dir" "headless" "invalid-run-spec" "$source" "dx run"); then
    data_json=$(__dx_run_spec_failure_json "$source" "$message" "$stage")
    dx_event_emit_safe "$run_id" "run.failed" "error" "Dex run spec ${stage} failed" "" "$data_json"
    dx_run_log_append_safe "$run_id" "error" "run-spec" "$message"
    dx_run_write_summary_safe "$run_id" "failed" "Dex run spec ${stage} failed"
    dx_warn "Failure event written to run journal ${run_id}."
  fi
}

unalias __dx_run_spec_apply_env 2>/dev/null; unfunction __dx_run_spec_apply_env 2>/dev/null
__dx_run_spec_apply_env() {
  local spec_file="$1" run_token="${2:-}"
  local token factory_url events_endpoint harness_name harness_model harness_effort plan_approval default_branch

  token=$(dx_run_spec_token "$run_token" 2>/dev/null || true)
  if [[ -n "$token" ]]; then
    export DEX_RUN_TOKEN="$token"
    [[ -n "${DEX_FACTORY_RUN_TOKEN:-}" ]] || export DEX_FACTORY_RUN_TOKEN="$token"
  fi

  factory_url=$(dx_run_spec_field "$spec_file" "sync.factory_url")
  events_endpoint=$(dx_run_spec_field "$spec_file" "sync.events_endpoint")
  if [[ -n "$factory_url" ]]; then
    export DEX_FACTORY_URL="$factory_url"
  fi
  if [[ -n "$events_endpoint" ]]; then
    export DEX_FACTORY_EVENTS_ENDPOINT="$events_endpoint"
  fi
  if [[ -z "${DEX_FACTORY_SYNC:-}" && -n "${factory_url}${events_endpoint}" ]]; then
    export DEX_FACTORY_SYNC=true
  fi

  harness_name=$(dx_run_spec_field "$spec_file" "harness.name")
  case "$harness_name" in
    codex)
      export DX_AGENT_OVERRIDE=codex
      ;;
    claude|claude-code|"")
      export DX_AGENT_OVERRIDE=claude
      ;;
    *)
      dx_error "Unsupported run spec harness: ${harness_name}"
      return 1
      ;;
  esac

  harness_model=$(dx_run_spec_field "$spec_file" "harness.model")
  if [[ -n "$harness_model" ]]; then
    dx_provider_validate_model_field "run spec harness.model" "$harness_model" || return 1
    export DX_MODEL_OVERRIDE="$harness_model"
  fi

  # Sent by DexCode beside the model, and applied the same way: the run says
  # how hard to think, and an older factory that sends nothing leaves the
  # profile's own setting alone.
  harness_effort=$(dx_run_spec_field "$spec_file" "harness.effort")
  if [[ -n "$harness_effort" ]]; then
    dx_provider_validate_effort_field "run spec harness.effort" "$harness_effort" || return 1
    export DX_EFFORT_OVERRIDE="$harness_effort"
  fi

  plan_approval=$(dx_run_spec_field "$spec_file" "workflow.requires_plan_approval")
  export DEX_HEADLESS_REQUIRES_PLAN_APPROVAL="$plan_approval"
  default_branch=$(dx_run_spec_field "$spec_file" "repository.default_branch")
  export DEX_HEADLESS_DEFAULT_BRANCH="$default_branch"
}

unalias __dx_run_spec_cli 2>/dev/null; unfunction __dx_run_spec_cli 2>/dev/null
__dx_run_spec_cli() {
  local spec_path="" spec_url="" run_token="" dry_run=0 validate_only=0
  local -x DEX_RUN_TOKEN="${DEX_RUN_TOKEN:-}"
  local -x DEX_FACTORY_RUN_TOKEN="${DEX_FACTORY_RUN_TOKEN:-}"
  local -x DEX_FACTORY_URL="${DEX_FACTORY_URL:-}"
  local -x DEX_FACTORY_EVENTS_ENDPOINT="${DEX_FACTORY_EVENTS_ENDPOINT:-}"
  local -x DEX_FACTORY_SYNC="${DEX_FACTORY_SYNC:-}"
  local -x DX_AGENT_OVERRIDE="${DX_AGENT_OVERRIDE:-}"
  local -x DX_MODEL_OVERRIDE="${DX_MODEL_OVERRIDE:-}"
  local -x DEX_HEADLESS_REQUIRES_PLAN_APPROVAL="${DEX_HEADLESS_REQUIRES_PLAN_APPROVAL:-}"
  local -x DEX_HEADLESS_DEFAULT_BRANCH="${DEX_HEADLESS_DEFAULT_BRANCH:-}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --spec)
        [[ $# -ge 2 && -n "${2:-}" ]] || { dx_error "--spec requires a path"; return 1; }
        spec_path="$2"
        shift 2
        ;;
      --spec=*)
        spec_path="${1#--spec=}"
        shift
        ;;
      --spec-url)
        [[ $# -ge 2 && -n "${2:-}" ]] || { dx_error "--spec-url requires a URL"; return 1; }
        spec_url="$2"
        shift 2
        ;;
      --spec-url=*)
        spec_url="${1#--spec-url=}"
        shift
        ;;
      --run-token)
        [[ $# -ge 2 && -n "${2:-}" ]] || { dx_error "--run-token requires a token"; return 1; }
        run_token="$2"
        shift 2
        ;;
      --run-token=*)
        run_token="${1#--run-token=}"
        shift
        ;;
      --dry-run)
        dry_run=1
        shift
        ;;
      --validate-only)
        validate_only=1
        shift
        ;;
      -h|--help|help)
        __dx_run_spec_usage
        return 0
        ;;
      *)
        dx_error "Unknown dx run option: $1"
        __dx_run_spec_usage
        return 1
        ;;
    esac
  done

  if [[ -n "$spec_path" && -n "$spec_url" ]]; then
    dx_error "Use either --spec or --spec-url, not both."
    return 1
  fi
  if [[ -z "$spec_path" && -z "$spec_url" ]]; then
    __dx_run_spec_usage
    return 1
  fi

  local tmp_dir source_label input_spec normalized_spec error_text
  tmp_dir=$(mktemp -d "${TMPDIR:-/tmp}/dex-run-spec.XXXXXX") || return 1
  normalized_spec="$tmp_dir/normalized-spec.json"
  if [[ -n "$spec_url" ]]; then
    source_label=$(dx_run_spec_redact_source "$spec_url")
    input_spec="$tmp_dir/remote-spec.json"
    local fetch_token
    fetch_token=$(dx_run_spec_token "$run_token" 2>/dev/null || true)
    if ! error_text=$(dx_run_spec_fetch "$spec_url" "$input_spec" "$fetch_token" 2>&1); then
      dx_error "$error_text"
      __dx_run_spec_record_failure "$source_label" "$error_text" "fetch" "$PWD"
      command rm -rf "$tmp_dir" 2>/dev/null || true
      return 1
    fi
  else
    source_label="$spec_path"
    input_spec="$spec_path"
  fi

  if ! error_text=$(dx_run_spec_normalize "$input_spec" "$normalized_spec" 2>&1); then
    dx_error "$error_text"
    __dx_run_spec_record_failure "$source_label" "$error_text" "validation" "$PWD"
    command rm -rf "$tmp_dir" 2>/dev/null || true
    return 1
  fi

  local run_id repo_dir workspace_input raw_input
  run_id=$(dx_run_spec_field "$normalized_spec" "run_id")
  repo_dir=$(dx_run_spec_field "$normalized_spec" "repository.working_directory")
  workspace_input=$(dx_run_spec_field "$normalized_spec" "workspace_name")
  raw_input=$(dx_run_spec_field "$normalized_spec" "input")

  if [[ $validate_only -eq 1 ]]; then
    dx_done "Run spec is valid: ${run_id}"
    command rm -rf "$tmp_dir" 2>/dev/null || true
    return 0
  fi

  if [[ ! -d "$repo_dir" ]]; then
    error_text="repository.working_directory does not exist: ${repo_dir}"
    dx_error "$error_text"
    __dx_run_spec_record_failure "$source_label" "$error_text" "startup" "$PWD"
    command rm -rf "$tmp_dir" 2>/dev/null || true
    return 1
  fi
  if ! git -C "$repo_dir" rev-parse --show-toplevel >/dev/null 2>&1; then
    error_text="repository.working_directory is not inside a git repository: ${repo_dir}"
    dx_error "$error_text"
    __dx_run_spec_record_failure "$source_label" "$error_text" "startup" "$repo_dir"
    command rm -rf "$tmp_dir" 2>/dev/null || true
    return 1
  fi

  local -x DEX_HEADLESS_RUN=1
  __dx_run_spec_apply_env "$normalized_spec" "$run_token" || {
    command rm -rf "$tmp_dir" 2>/dev/null || true
    return 1
  }

  local original_dir="$PWD"
  cd "$repo_dir" 2>/dev/null || return 1
  __dx_resolve_workspace_name "$workspace_input" || {
    cd "$original_dir" 2>/dev/null || true
    command rm -rf "$tmp_dir" 2>/dev/null || true
    return 1
  }
  local session_id
  session_id=$(__dx_session_id_for_workspace "in-place" "$_dx_wt_name")
  if ! __dx_startup_claim_acquire "$session_id"; then
    cd "$original_dir" 2>/dev/null || true
    command rm -rf "$tmp_dir" 2>/dev/null || true
    return 1
  fi

  local final_spec
  if ! final_spec=$(dx_run_spec_prepare_journal "$normalized_spec" "$session_id" "$repo_dir" "dx run"); then
    error_text="could not prepare local run journal for ${run_id}"
    dx_error "$error_text"
    __dx_run_spec_record_failure "$source_label" "$error_text" "startup" "$repo_dir"
    __dx_startup_claim_release || true
    cd "$original_dir" 2>/dev/null || true
    command rm -rf "$tmp_dir" 2>/dev/null || true
    return 1
  fi
  local -x DEX_HEADLESS_RUN_SPEC_FILE="$final_spec"
  local -x DEX_RUN_ID="$run_id"

  dx_meta_write "$session_id" \
    "wt_name=${_dx_wt_name}" \
    "wt_dir=${repo_dir}" \
    "workspace_mode=in-place" \
    "raw_input=${workspace_input}" \
    "headless=1" \
    "run_id=${run_id}" \
    "source_type=$(dx_run_spec_field "$normalized_spec" "source.type")" \
    "source_id=$(dx_run_spec_field "$normalized_spec" "source.id")" \
    "source_url=$(dx_run_spec_field "$normalized_spec" "source.url")"

  dx_run_maybe_emit_started "$run_id" "Dex headless run started" "{\"command\":\"dx run\",\"dry_run\":$([[ $dry_run -eq 1 ]] && printf true || printf false)}"
  dx_run_log_append_safe "$run_id" "info" "run-spec" "Prepared headless run spec ${run_id}"

  if [[ $dry_run -eq 1 ]]; then
    dx_event_emit_safe "$run_id" "run.blocked" "info" "Dex headless dry run completed before lifecycle launch" "" '{"reason":"dry-run"}'
    dx_run_write_summary_safe "$run_id" "blocked" "Headless dry run validated startup"
    dx_done "Run spec startup is valid: ${run_id}"
    dx_info "Repository: ${repo_dir}"
    dx_info "Journal: $(dx_run_dir "$run_id")"
    if ! __dx_startup_claim_release; then
      cd "$original_dir" 2>/dev/null || true
      command rm -rf "$tmp_dir" 2>/dev/null || true
      return 1
    fi
    cd "$original_dir" 2>/dev/null || true
    command rm -rf "$tmp_dir" 2>/dev/null || true
    return 0
  fi

  __dx_refresh_provider || {
    __dx_startup_claim_release || true
    cd "$original_dir" 2>/dev/null || true
    command rm -rf "$tmp_dir" 2>/dev/null || true
    return 1
  }

  __dx_setup_in_place "$workspace_input"
  local setup_status=$?
  if [[ $setup_status -ne 0 ]]; then
    error_text="could not prepare in-place lifecycle workspace"
    dx_event_emit_safe "$run_id" "run.failed" "error" "$error_text" "" "$(__dx_run_spec_failure_json "$source_label" "$error_text" "startup")"
    dx_run_write_summary_safe "$run_id" "failed" "$error_text"
    cd "$original_dir" 2>/dev/null || true
    command rm -rf "$tmp_dir" 2>/dev/null || true
    return "$setup_status"
  fi

  session_id="$_dx_session_id"
  final_spec=$(dx_run_spec_prepare_journal "$normalized_spec" "$session_id" "$repo_dir" "dx run") || {
    __dx_startup_claim_release || true
    cd "$original_dir" 2>/dev/null || true
    command rm -rf "$tmp_dir" 2>/dev/null || true
    return 1
  }
  local -x DEX_HEADLESS_RUN_SPEC_FILE="$final_spec"
  local -x DEX_RUN_ID="$run_id"
  dx_meta_write "$session_id" "headless=1" "run_id=${run_id}" "run_spec=${final_spec}"
  __dx_write_last_session "$_dx_wt_name" "$_dx_wt_dir" "$_dx_workspace_mode"

  local state_file times_file step=0
  state_file=$(dx_state_file "$session_id")
  times_file=$(dx_times_file "$session_id")
  if [[ -e "$state_file" || -L "$state_file" ]]; then
    step=$(dx_lifecycle_phase_state "$session_id" 2>/dev/null) || {
      dx_error "Dex found an unsafe or malformed authoritative phase file. Repair it before starting the headless run."
      __dx_startup_claim_release || true
      return 1
    }
  fi

  dx_info "Starting headless Dex run ${run_id}"
  local resume_hint="dx run --spec ${source_label}"
  [[ -n "$spec_url" ]] && resume_hint="dx run --spec-url ${source_label}"
  __dx_run_with_runtime "$session_id" "$_dx_wt_dir" __dx_run_phases_inline \
    "$_dx_wt_name" "$_dx_wt_dir" "$_dx_default_branch" "$step" "$state_file" \
    "$times_file" "$resume_hint" "$_dx_workspace_mode" "$session_id" "$raw_input"
  local run_status=$?
  cd "$original_dir" 2>/dev/null || true
  command rm -rf "$tmp_dir" 2>/dev/null || true
  return "$run_status"
}

# __dx_show_header <wt_name> <current_step> <wt_dir> [default_branch] [session_id] [workspace_mode]
# Display lifecycle progress between phases
__dx_show_header() {
  local wt_name="$1" step="$2" wt_dir="$3" default_branch="${4:-main}"
  local session_id="${5:-}" workspace_mode="${6:-worktree}"
  [[ -n "$session_id" ]] || session_id=$(__dx_session_id_for_workspace "$workspace_mode" "$wt_name")
  local times_file
  times_file=$(dx_times_file "$session_id")

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  DEX — ${wt_name}"
  echo ""

  # Phase progress line (Phase 0 setup + 6 autonomous phases)
  local progress="  "
  local i label outcome symbol
  local has_skipped=0 has_waived=0 has_unknown=0
  for i in 0 1 2 3 4 5 6; do
    label=$(__dx_phase_name "$i")
    if [[ $i -lt $step ]]; then
      outcome=$(dx_phase_outcome_latest "$session_id" "$i")
      case "$outcome" in
        completed) symbol="✓" ;;
        skipped) symbol="↷"; has_skipped=1 ;;
        waived) symbol="◇"; has_waived=1 ;;
        *) symbol="?"; has_unknown=1 ;;
      esac
      progress+="${symbol} ${label}"
    elif [[ $i -eq $step ]]; then
      progress+="→ ${label}"
    else
      progress+="○ ${label}"
    fi
    [[ $i -lt 6 ]] && progress+="  "
  done
  # Show completion suffix when all autonomous phases are done (step=7 sentinel)
  if [[ $step -ge 7 ]]; then
    progress+="  ✓ ticket complete"
  fi
  echo "$progress"
  if [[ $has_skipped -eq 1 || $has_waived -eq 1 || $has_unknown -eq 1 ]]; then
    local legend="  "
    [[ $has_skipped -eq 1 ]] && legend+="↷ skipped by human  "
    [[ $has_waived -eq 1 ]] && legend+="◇ marked done by human  "
    [[ $has_unknown -eq 1 ]] && legend+="? outcome not recorded"
    echo "$legend"
  fi
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
      actual_branch=$(dx_wt_branch "$wt_dir" "current-checkout")
    else
      actual_branch=$(dx_wt_branch "$wt_dir" "worktree-${wt_name}")
    fi
    local meta="  Branch: ${actual_branch}"
    [[ "$workspace_mode" == "in-place" ]] && meta+=" | mode: in-place"
    [[ "$files_changed" != "0" ]] && meta+=" | ${files_changed} files changed"
    [[ "$commits_count" != "0" ]] && meta+=" | ${commits_count} commits"
    echo "$meta"
  fi

  local run_id
  run_id=$(dx_run_read_for_session "$session_id" 2>/dev/null || true)
  [[ -n "$run_id" ]] && echo "  Run ID: ${run_id}"

  # Timing info
  if [[ -f "$times_file" ]] && [[ $step -gt 1 ]]; then
    local prev_step=$((step - 1))
    local prev_start total_start now phase_elapsed total_elapsed
    now=$(date +%s)

    # Previous phase elapsed
    prev_start=$(grep "^${prev_step}:" "$times_file" 2>/dev/null | tail -1 | cut -d: -f2)
    total_start=$(head -1 "$times_file" 2>/dev/null | cut -d: -f2)

    # Digits, not merely non-empty. Both shells evaluate an array subscript
    # inside $(( )) as an arithmetic expression, so a times file holding
    # `HOME[$(…)]` runs that command here; `set -u` does not stop it, because
    # naming a variable that is already set keeps nounset quiet. bin/log.sh
    # reads the same file and already checks this way.
    local timing=""
    if [[ "$prev_start" =~ ^[0-9]+$ ]]; then
      phase_elapsed=$((now - prev_start))
      timing+="  Phase ${prev_step} took $(dx_format_duration "$phase_elapsed")"
    fi
    if [[ "$total_start" =~ ^[0-9]+$ ]]; then
      total_elapsed=$((now - total_start))
      timing+=" | Total: $(dx_format_duration "$total_elapsed")"
    fi
    [[ -n "$timing" ]] && echo "$timing"
  fi

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}

# ─── dx — phased lifecycle wrapper ──────────────────────────────────────────

# The management commands and the lifecycle share one argument slot: whatever
# dx() does not recognise becomes a task description. That is the documented
# way to start work without a ticket, and it is also exactly what a mistyped
# subcommand looks like — so `dx statu` used to cut a worktree, a branch and a
# full agent run without a word, instead of printing the status.
#
# Only a single bare word that is nearly a real command earns an interruption.
# A multi-word description is unambiguous, a ticket is a ticket, and a word
# resembling nothing is a task somebody meant to type.
#
# Keep this list equal to the routing allowlist in dx() — minus the flag forms,
# plus `refine`, which dx() intercepts before that case. Both, plus `dx help`,
# are held together by tests/docs-consistency-test.sh.
unalias __dx_task_commands 2>/dev/null; unfunction __dx_task_commands 2>/dev/null
__dx_task_commands() {
  printf '%s\n' init sync login logout whoami dexcode worker maintain tools \
    test config provider run control sessions research install uninstall uninit status \
    reload help revert log refine
}

# Prints the nearest command within two edits, or nothing.
unalias __dx_nearest_command 2>/dev/null; unfunction __dx_nearest_command 2>/dev/null
__dx_nearest_command() {
  local word="$1"
  local candidates=("${(@f)$(__dx_task_commands)}")
  command -v python3 >/dev/null 2>&1 || return 1
  DX_TASK_WORD="$word" python3 - "${candidates[@]}" <<'PY'
import os
import sys

word = os.environ["DX_TASK_WORD"]


def edits(a, b):
    if abs(len(a) - len(b)) > 2:
        return 99
    previous = list(range(len(b) + 1))
    for index, left in enumerate(a, 1):
        current = [index]
        for offset, right in enumerate(b, 1):
            current.append(min(
                previous[offset] + 1,
                current[offset - 1] + 1,
                previous[offset - 1] + (left != right),
            ))
        previous = current
    return previous[-1]


best, score = "", 3
for candidate in sys.argv[1:]:
    distance = edits(word, candidate)
    if distance < score:
        best, score = candidate, distance
if best:
    print(best)
PY
}

# Returns non-zero when the user declines, and dx() stops.
unalias __dx_confirm_task_word 2>/dev/null; unfunction __dx_confirm_task_word 2>/dev/null
__dx_confirm_task_word() {
  local raw="$1" argc="$2" suggestion answer
  [[ "$argc" -eq 1 ]] || return 0
  [[ "$raw" != -* ]] || return 0
  [[ "$raw" != *[[:space:]]* ]] || return 0
  if __dx_is_ticket "$raw"; then
    return 0
  fi
  suggestion=$(__dx_nearest_command "$raw" 2>/dev/null) || return 0
  [[ -n "$suggestion" ]] || return 0

  dx_warn "'${raw}' is not a Dex command, so Dex would run it as a task description."
  dx_info "That starts a full lifecycle: a new worktree, a new branch, and an agent run."
  dx_info "Did you mean 'dx ${suggestion}'?"
  if [[ ! -t 0 || ! -t 1 ]]; then
    # Nothing to ask, and refusing here would break a script that has always
    # been allowed to pass a one-word task. The warning above is the record.
    dx_info "Not a terminal — continuing as a task description."
    return 0
  fi
  printf "Run '%s' as a task description? [y/N]: " "$raw"
  read -r answer
  case "${answer:0:1}" in
    y|Y) return 0 ;;
  esac
  dx_info "Nothing started. Run 'dx help' for the command list."
  return 1
}

unalias dx 2>/dev/null; unfunction dx 2>/dev/null
dx() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: dx <NUMBER>        (e.g. dx 999, dx ENG-999)"
    echo "       dx \"<description>\" (e.g. dx \"fix login bug\")"
    echo "       dx --agent codex --model gpt-5.3-codex \"<task>\""
    echo "       dx --no-worktree <task>"
    echo "       dx --resume        Resume the most recent session"
    echo "       dx --from-pr <N>   Resume session linked to a PR"
    echo "       dx refine <N|description>  Refine a ticket before implementation"
    echo ""
    echo "       dx init|sync|maintain|tools|test|config|provider|run|research|install|uninstall|uninit|status|reload|help"
    return 1
  fi

  local use_worktree=1
  local dx_agent_flag=""
  local dx_model_flag=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agent)
        if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
          dx_error "Usage: dx --agent <claude|codex> <command-or-task>"
          return 1
        fi
        dx_agent_flag="$2"
        shift 2
        ;;
      --agent=*)
        dx_agent_flag="${1#--agent=}"
        if [[ -z "$dx_agent_flag" ]]; then
          dx_error "Usage: dx --agent <claude|codex> <command-or-task>"
          return 1
        fi
        shift
        ;;
      --model)
        if [[ $# -lt 2 || -z "${2:-}" || "${2:-}" == --* ]]; then
          dx_error "Usage: dx --model <model> <command-or-task>"
          return 1
        fi
        dx_model_flag="$2"
        shift 2
        ;;
      --model=*)
        dx_model_flag="${1#--model=}"
        if [[ -z "$dx_model_flag" ]]; then
          dx_error "Usage: dx --model <model> <command-or-task>"
          return 1
        fi
        shift
        ;;
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

  if [[ -n "$dx_agent_flag" ]]; then
    dx_agent_flag=$(dx_agent_normalize "$dx_agent_flag") || return 1
    local -x DX_AGENT_OVERRIDE="$dx_agent_flag"
  fi
  if [[ -n "$dx_model_flag" ]]; then
    dx_provider_validate_model_field "dx --model" "$dx_model_flag" || return 1
    local -x DX_MODEL_OVERRIDE="$dx_model_flag"
  fi

  if [[ $# -eq 0 ]]; then
    echo "Usage: dx [--agent <claude|codex>] [--model <model>] <NUMBER|description|command>"
    return 1
  fi

  # Refine subcommand — intercept before worktree setup (read-only flow)
  if [[ "$1" == "refine" ]]; then
    shift
    dxrefine "$@"
    return $?
  fi

  # Branch naming is part of lifecycle setup, not a standalone command.
  if [[ "$1" == "rename" ]]; then
    dx_error "'dx rename' is not a command. Dex names lifecycle branches during ticket setup."
    return 1
  fi

  # Route management subcommands to the internal Dex dispatcher.
  case "$1" in
    init|sync|login|logout|whoami|dexcode|worker|maintain|tools|test|config|provider|run|control|sessions|research|install|uninstall|uninit|status|reload|help|--help|-h|revert|log)
      __dx_cli "$@"
      return $?
      ;;
  esac

  # Everything below this point runs the lifecycle. A single word that is
  # nearly a command is almost certainly a typo, so confirm before spending.
  __dx_confirm_task_word "$1" "$#" || return 1

  __dx_refresh_provider || return 1

  # Resume mode — find most recent session and continue from tracked phase
  if [[ "$1" == "--resume" ]]; then
    local last_session_file="$DX_STATE_DIR/last-session"
    if [[ ! -f "$last_session_file" ]]; then
      dx_error "No previous session found."
      dx_info "Start a new session with: dx <number>"
      return 1
    fi
    # last-session file format: "wt_name:wt_dir:mode". Older "wt_name:wt_dir"
    # files are still treated as worktree sessions.
    local last_info
    last_info=$(cat "$last_session_file" 2>/dev/null)
    __dx_parse_last_session "$last_info"
    local resume_selector="session:${_dx_session_id}"
    __dx_sessions_resume_selected "$resume_selector" "$dx_agent_flag" \
      legacy-last-session "$_dx_wt_name" "$_dx_wt_dir" \
      "$_dx_workspace_mode"
    return $?
  fi

  # PR-linked mode — resume a session associated with a GitHub PR
  if [[ "$1" == "--from-pr" ]]; then
    if [[ -z "${2:-}" ]]; then
      echo "Usage: dx --from-pr <PR_NUMBER|URL>"
      return 1
    fi
    local provider_prompt
    provider_prompt=$(__dx_provider_prompt)
    local pr_args=("${DX_CLAUDE_FLAGS[@]}")
    [[ -n "$provider_prompt" ]] && pr_args+=(--append-system-prompt "$provider_prompt")
    pr_args+=(--from-pr "$2")
    local session_id
    session_id="from-pr-$(dx_unique_session_id)"
    dx_provider_cleanup_session_state "$session_id"
    DEX_SESSION_ID="$session_id" __dx_claude "${pr_args[@]}"
    local exit_code=$?
    dx_provider_cleanup_session_state "$session_id"
    return $exit_code
  fi

  # Normal mode — setup workspace and run phased lifecycle
  local raw_input="${(j: :)@}"  # zsh: join all args with spaces

  if [[ $use_worktree -eq 1 ]]; then
    if ! __dx_setup_worktree "$raw_input"; then
      return 1
    fi
  else
    if ! __dx_setup_in_place "$raw_input"; then
      return 1
    fi
  fi

  local session_id state_file times_file
  session_id="$_dx_session_id"
  state_file=$(dx_state_file "$session_id")
  times_file=$(dx_times_file "$session_id")

  # Save as last session for --resume (atomic write to avoid corruption on interrupt)
  __dx_write_last_session "$_dx_wt_name" "$_dx_wt_dir" "$_dx_workspace_mode"

  # Read current phase (default: 0 — Setup runs before Plan on fresh tickets).
  local step=0
  if [[ -e "$state_file" || -L "$state_file" ]]; then
    step=$(dx_lifecycle_phase_state "$session_id" 2>/dev/null) || {
      dx_error "Dex found an unsafe or malformed authoritative phase file. Repair it before starting."
      __dx_startup_claim_release || true
      return 1
    }
  fi

  if [[ $step -gt 6 ]]; then
    if ! dx_lifecycle_terminal_commit_valid "$session_id"; then
      dx_error "Dex found Phase 7 without a valid terminal commit proof. The lifecycle remains inert; repair its state before treating it as complete."
      __dx_startup_claim_release || true
      return 1
    fi
    echo "Ticket lifecycle already complete for ${_dx_wt_name}."
    if [[ "$_dx_workspace_mode" == "worktree" ]]; then
      echo "Local cleanup should already be complete. If files remain, run dxrm ${raw_input}."
    else
      echo "This lifecycle ran in the current checkout; local branch cleanup is handled at completion when safe."
    fi
    if ! __dx_startup_claim_release; then
      return 1
    fi
    return 0
  fi

  if [[ $_dx_is_task -eq 1 ]]; then
    mkdir -p "$DX_LOOP_DIR"
    __dx_write_state "$(dx_prompt_file "$session_id")" "$raw_input"
  fi

  if [[ $step -gt 0 ]]; then
    echo "Resuming ${_dx_wt_name} from Phase ${step}: $(__dx_phase_name "$step")..."
  fi

  # ── Phase loop ──
  local resume_hint="dx ${raw_input}"
  [[ "$_dx_workspace_mode" == "in-place" ]] && resume_hint="dx --no-worktree ${raw_input}"
  cd "$_dx_wt_dir" 2>/dev/null || {
    __dx_startup_claim_release || true
    return 1
  }
  __dx_run_with_runtime "$session_id" "$_dx_wt_dir" __dx_run_phases_inline \
    "$_dx_wt_name" "$_dx_wt_dir" "$_dx_default_branch" "$step" "$state_file" \
    "$times_file" "$resume_hint" "$_dx_workspace_mode" "$session_id" "$raw_input"
  return $?
}

unalias dex 2>/dev/null; unfunction dex 2>/dev/null
dex() {
  dx "$@"
}

unalias dexter 2>/dev/null; unfunction dexter 2>/dev/null
dexter() {
  dx "$@"
}

# ─── dxloop — prompt loop (run until done) ─────────────────────────────────

unalias __dx_finalize_standalone_pause 2>/dev/null; unfunction __dx_finalize_standalone_pause 2>/dev/null
__dx_finalize_standalone_pause() {
  local session_id="$1" completion_mode="$2" completion_purpose="$3"
  local completion_phase="$4" completion_generation="$5"
  local control_snapshot control_action cleanup_rc=0 receipt_file control_file
  local pause_context_rc=0
  local finalize_attempts="${DEX_STANDALONE_FINALIZE_LOCK_ATTEMPTS:-400}"
  [[ "$completion_generation" =~ ^[0-9a-f]{32}$ ]] || return 2
  dx_completion_context_valid "$completion_mode" "$completion_purpose" \
    "$completion_phase" || return 2
  receipt_file=$(dx_completion_receipt_file "$session_id" \
    "$completion_generation")
  control_file=$(dx_lifecycle_control_file "$session_id")
  dx_lifecycle_control_lock_acquire "$session_id" "$finalize_attempts" || return 2
  control_snapshot=$(dx_lifecycle_control_snapshot_unlocked "$session_id")
  control_action=$(dx_lifecycle_control_value "$control_snapshot" action)
  dx_lifecycle_pause_context_state "$session_id" || pause_context_rc=$?
  [[ "$pause_context_rc" -eq 2 ]] && cleanup_rc=1
  if [[ "$pause_context_rc" -eq 1 \
    && ! -e "$control_file" && ! -L "$control_file" \
    && "$control_action" != "pause" && "$control_action" != "cancel" ]]; then
    # A successful Stop consumes the exact expectation and receipt, then
    # retires its launch context. Missing activation alone is not proof that
    # the completion gate ran.
    if [[ ! -e "$(dx_completion_expectation_file "$session_id")" \
      && ! -L "$(dx_completion_expectation_file "$session_id")" \
      && ! -e "$receipt_file" && ! -L "$receipt_file" \
      && ! -e "$(dx_loop_config_file "$session_id")" \
      && ! -L "$(dx_loop_config_file "$session_id")" \
      && ! -e "$(dx_active_file "$session_id")" \
      && ! -L "$(dx_active_file "$session_id")" ]]; then
      if ! dx_lifecycle_control_lock_release "$session_id"; then
        dx_lifecycle_completion_brake "$session_id" \
          completion-finalize-lock-release dxloop 2>/dev/null || true
        dx_lifecycle_control_lock_release_retained "$session_id" \
          2>/dev/null || true
        return 2
      fi
      return 1
    fi

    # The provider returned without completing the strict gate. Revoke the
    # outstanding generation while the transition decision is still locked.
    __dx_abandon_completion_state "$session_id" || cleanup_rc=1
    rm -f "$(dx_active_file "$session_id")" \
      "$(dx_owner_file "$session_id")" \
      "$(dx_loop_config_file "$session_id")" 2>/dev/null || cleanup_rc=1
    if ! dx_lifecycle_control_lock_release "$session_id"; then
      dx_lifecycle_completion_brake "$session_id" \
        missing-receipt-lock-release dxloop 2>/dev/null || true
      dx_lifecycle_control_lock_release_retained "$session_id" \
        2>/dev/null || true
      return 2
    fi
    [[ "$cleanup_rc" -eq 0 ]] || return 2
    return 3
  fi

  __dx_abandon_completion_state "$session_id" || cleanup_rc=1
  rm -f "$(dx_loop_file "$session_id")" "$(dx_complete_file "$session_id")" \
    "$(dx_active_file "$session_id")" "$(dx_owner_file "$session_id")" \
    "$(dx_loop_config_file "$session_id")" "$(dx_prompt_file "$session_id")" \
    "$(dx_paused_file "$session_id")" "$(dx_pause_state_file "$session_id")" \
    "$(dx_lifecycle_control_file "$session_id")" 2>/dev/null || cleanup_rc=1
  if ! dx_lifecycle_control_lock_release "$session_id"; then
    dx_lifecycle_completion_brake "$session_id" pause-cleanup-lock-release \
      dxloop 2>/dev/null || true
    dx_lifecycle_control_lock_release_retained "$session_id" \
      2>/dev/null || true
    return 2
  fi
  [[ "$cleanup_rc" -eq 0 ]] || return 2
  return 0
}

unalias dxloop 2>/dev/null; unfunction dxloop 2>/dev/null
dxloop() {
  if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
    echo "Usage: dxloop [prompt]"
    echo "Run a prompt through an audited implementation loop. Without a prompt, use the default codebase-improvement task."
    return 0
  fi
  __dx_refresh_provider || return 1

  local prompt=""
  if [[ $# -eq 0 ]]; then
    # No prompt given — load the default codebase improvement prompt
    local default_prompt_file="$DEX_DIR/prompts/default-loop.md"
    if [[ ! -f "$default_prompt_file" ]]; then
      dx_error "Default prompt not found at $default_prompt_file"
      return 1
    fi
    prompt=$(cat "$default_prompt_file")
    dx_info "No prompt given — using default: review, improve, and harden the codebase"
  else
    prompt="${(j: :)@}"
  fi

  local provider_agent
  provider_agent=$(__dx_resolved_provider_agent) || return 1
  if [[ "$provider_agent" == "codex" ]]; then
    dx_error "dxloop requires an interactive Claude Code session for plan approval and session resume."
    dx_info "The selected provider profile resolves to the non-interactive Codex CLI. Run 'DX_AGENT=claude dxloop <prompt>', or use 'dx --agent codex <task>' for the direct Codex lifecycle."
    return 1
  fi
  __dx_require_resolved_provider_cli || return 1

  # Validate we're in a git repo (needed for session ID derivation)
  local repo_root
  repo_root=$(dx_repo_root) || return 1

  # Derive a unique session ID so concurrent dxloops on the same branch don't collide
  local session_id
  session_id=$(dx_unique_session_id)

  __dx_run_with_runtime "$session_id" "$repo_root" __dxloop_run \
    "$prompt" "$repo_root" "$session_id"
  return $?
}

unalias __dxloop_run 2>/dev/null; unfunction __dxloop_run 2>/dev/null
__dxloop_run() {
  local prompt="$1" repo_root="$2" session_id="$3"
  : "$repo_root"

  # Remove any loop files that happen to share this unique session ID (harmless
  # no-op in practice since each dxloop gets a fresh ID via dx_unique_session_id).
  dx_provider_cleanup_session_state "$session_id"
  rm -f "$(dx_loop_file "$session_id")" "$(dx_complete_file "$session_id")" "$(dx_active_file "$session_id")" "$(dx_owner_file "$session_id")"

  # The activation helper clears stale state before each launch. Persist the
  # prompt after activation so an earlier run can never leak its task into this
  # one.
  local prompt_file
  prompt_file="$(dx_prompt_file "$session_id")"

  # Show header
  local branch
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
  local prompt_slug
  prompt_slug=$(dx_slugify "${prompt:0:40}")
  local session_name=""
  if [[ -n "$prompt_slug" ]]; then
    session_name="dxloop-${prompt_slug}"
  else
    session_name="dxloop-$(date +%s)"
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  DEX — dxloop (prompt loop)"
  echo ""
  echo "  Branch: ${branch}"
  echo "  Prompt: ${prompt:0:72}$([ ${#prompt} -gt 72 ] && echo '...')"
  echo "  Phase:  Plan → Implement"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  # ── Session 1: Plan ──
  # Dangerous skip permissions + EnterPlanMode — read-only without interactive prompts.
  # Plan mode's built-in approval is the quality gate. The Stop hook owns the
  # process handoff after approval so dxloop can continue to implementation.
  local plan_generation plan_config_file
  plan_config_file=$(dx_loop_config_file "$session_id")
  if ! plan_generation=$(bash "$DEX_DIR/bin/activate-loop.sh" \
    "$session_id" standalone dxloop-plan 1); then
    dx_error "Could not activate the dxloop planning audit. Another loop may already own this session."
    return 1
  fi
  mkdir -p "$(dirname "$prompt_file")"
  if ! __dx_write_state "$prompt_file" "$prompt"; then
    dx_completion_abandon "$session_id" 2>/dev/null || true
    rm -f "$(dx_active_file "$session_id")" "$plan_config_file" 2>/dev/null || true
    dx_error "Could not save the dxloop task for the planning audit."
    return 1
  fi
  local plan_args=("${DX_PLAN_FLAGS[@]}")
  [[ -n "$session_name" ]] && plan_args+=(-n "$session_name")
  plan_args+=(--append-system-prompt "You are in a dxloop planning session. You MUST be in plan mode — if not, call EnterPlanMode immediately. Your original task prompt is saved at ${prompt_file}. Re-read it with the Read tool if you lose track of the task. After ExitPlanMode is approved, stop this Claude Code session immediately so the dxloop wrapper can launch implementation. Do NOT ask whether to continue and do NOT wait for another user prompt. The Stop hook handles the process handoff back to dxloop. When the Stop hook prints the exact command after the audit threshold, run this literal command only if the plan is approved and every planning requirement is met, then stop again: bash \"\$DEX_DIR/bin/complete-receipt.sh\" \"${session_id}\" \"${plan_generation}\"")

  dx_info "Phase: Plan (read-only until approved)"
  DEX_SESSION_ID="$session_id" \
  DEX_LOOP_ACTIVE=1 \
  DEX_LOOP_PROMISE="PHASE_1_COMPLETE" \
  DEX_LOOP_PHASE="1" \
  DEX_DIR="$DEX_DIR" \
  __dx_claude "${plan_args[@]}" "Call EnterPlanMode now, then run /dxplan for the following task:

${prompt}

Gather context, explore the codebase, and create your implementation plan. When the plan is ready, use ExitPlanMode to present it for approval. After approval, stop this session immediately so dxloop can launch implementation automatically.
$(__dx_provider_prompt)"

  local plan_exit=$?
  local plan_status="advance" plan_pause_rc=0
  __dx_finalize_standalone_pause "$session_id" standalone dxloop-plan 1 \
    "$plan_generation" || plan_pause_rc=$?
  if [[ "$plan_pause_rc" -eq 0 ]]; then
    plan_status="human-pause"
    plan_exit=1
  elif [[ "$plan_pause_rc" -eq 2 ]]; then
    dx_provider_cleanup_session_state "$session_id"
    echo ""
    dx_error "dxloop stopped during planning, but Dex could not finish cleaning its loop state. The completion gate remains closed; wait for the active control to finish, then rerun dxloop."
    return 1
  elif [[ $plan_exit -eq 0 ]] && [[ -f "$(dx_loop_file "$session_id")" ]]; then
    plan_status="max-iter"
    plan_exit=1
  elif [[ "$plan_pause_rc" -eq 3 ]]; then
    plan_status="missing-receipt"
    plan_exit=1
  elif [[ $plan_exit -eq 0 ]] && [[ -f "$(dx_active_file "$session_id")" ]]; then
    plan_status="missing-receipt"
    plan_exit=1
  fi
  rm -f "$(dx_active_file "$session_id")" "$(dx_owner_file "$session_id")" \
    "$(dx_loop_file "$session_id")" 2>/dev/null
  rm -f "$plan_config_file" 2>/dev/null
  if [[ $plan_exit -ne 0 ]]; then
    dx_completion_abandon "$session_id" 2>/dev/null || true
    rm -f "$(dx_loop_file "$session_id")" \
          "$(dx_complete_file "$session_id")" \
          "$(dx_active_file "$session_id")" "$(dx_owner_file "$session_id")" \
          "$(dx_prompt_file "$session_id")" 2>/dev/null
    dx_provider_cleanup_session_state "$session_id"
    echo ""
    if [[ "$plan_status" == "human-pause" ]]; then
      dx_info "dxloop stopped during planning by direct human control. Your edits are untouched; rerun dxloop when you want to continue."
    elif [[ "$plan_status" == "max-iter" ]]; then
      dx_info "dxloop paused during planning: max audit iterations reached without completion."
    elif [[ "$plan_status" == "missing-receipt" ]]; then
      dx_info "dxloop paused during planning: the provider exited without a completion receipt."
    else
      dx_info "dxloop interrupted during planning (exit code: $plan_exit)."
    fi
    case "$plan_status" in
      human-pause) __dx_runtime_set_terminal paused ;;
      max-iter|missing-receipt) __dx_runtime_set_terminal blocked ;;
      *)
        if [[ $plan_exit -eq 129 || $plan_exit -eq 130 || $plan_exit -eq 143 ]]; then
          __dx_runtime_set_terminal stopped
        else
          __dx_runtime_set_terminal failed
        fi
        ;;
    esac
    return $plan_exit
  fi

  # ── Session 2: Implement ──
  # Autonomous mode with stop hook audit loop. Resumes the plan session.
  local impl_generation
  if ! impl_generation=$(bash "$DEX_DIR/bin/activate-loop.sh" \
    "$session_id" standalone dxloop-prompt prompt-loop); then
    rm -f "$(dx_prompt_file "$session_id")" 2>/dev/null || true
    dx_provider_cleanup_session_state "$session_id"
    dx_error "Could not activate the dxloop implementation audit."
    return 1
  fi
  if ! __dx_write_state "$prompt_file" "$prompt"; then
    dx_completion_abandon "$session_id" 2>/dev/null || true
    rm -f "$(dx_active_file "$session_id")" "$plan_config_file" 2>/dev/null || true
    dx_provider_cleanup_session_state "$session_id"
    dx_error "Could not save the dxloop task for the implementation audit."
    return 1
  fi
  local impl_args=("${DX_CLAUDE_FLAGS[@]}" --resume)
  [[ -n "$session_name" ]] && impl_args+=(-n "$session_name")
  impl_args+=(--append-system-prompt "You are in a dxloop session. Your original task prompt is saved at ${prompt_file}. Re-read it with the Read tool before any audit step, or when you lose track of what you are working on. When the Stop hook prints the exact command after the audit threshold, run this literal command only if every implementation and verification requirement is met, then stop again: bash \"\$DEX_DIR/bin/complete-receipt.sh\" \"${session_id}\" \"${impl_generation}\"")

  dx_info "Phase: Implement (autonomous)"
  DEX_SESSION_ID="$session_id" \
  DEX_LOOP_ACTIVE=1 \
  DEX_LOOP_PROMISE="PROMPT_COMPLETE" \
  DEX_LOOP_PHASE="prompt-loop" \
  DEX_DIR="$DEX_DIR" \
  __dx_claude "${impl_args[@]}" "The plan is approved. Implement it now. Work through all tasks, following TDD where the project has tests. The stop hook audit will guide you through quality verification and final review when you are done.
$(__dx_provider_prompt)"

  local exit_code=$?
  local loop_status="advance" loop_pause_rc=0
  __dx_finalize_standalone_pause "$session_id" standalone dxloop-prompt \
    prompt-loop "$impl_generation" || loop_pause_rc=$?
  if [[ "$loop_pause_rc" -eq 0 ]]; then
    loop_status="human-pause"
    exit_code=1
  elif [[ "$loop_pause_rc" -eq 2 ]]; then
    dx_provider_cleanup_session_state "$session_id"
    echo ""
    dx_error "dxloop stopped, but Dex could not finish cleaning its loop state. The completion gate remains closed; wait for the active control to finish, then rerun dxloop."
    return 1
  elif [[ $exit_code -eq 0 ]] && [[ -f "$(dx_loop_file "$session_id")" ]]; then
    loop_status="max-iter"
    exit_code=1
  elif [[ "$loop_pause_rc" -eq 3 ]]; then
    loop_status="missing-receipt"
    exit_code=1
  elif [[ $exit_code -eq 0 ]] && [[ -f "$(dx_active_file "$session_id")" ]]; then
    loop_status="missing-receipt"
    exit_code=1
  fi

  # Clean up state files
  if [[ $exit_code -ne 0 ]]; then
    dx_completion_abandon "$session_id" 2>/dev/null || true
  fi
  rm -f "$(dx_loop_file "$session_id")" \
        "$(dx_complete_file "$session_id")" \
        "$(dx_active_file "$session_id")" "$(dx_owner_file "$session_id")" \
        2>/dev/null
  rm -f "$plan_config_file" "$(dx_prompt_file "$session_id")" 2>/dev/null
  dx_provider_cleanup_session_state "$session_id"

  if [[ $exit_code -eq 0 ]]; then
    echo ""
    dx_done "dxloop complete."
    __dx_runtime_set_terminal completed
  else
    echo ""
    if [[ "$loop_status" == "human-pause" ]]; then
      dx_info "dxloop stopped by direct human control. Your edits are untouched; rerun dxloop when you want to continue."
    elif [[ "$loop_status" == "max-iter" ]]; then
      dx_info "dxloop paused: max audit iterations reached without completion."
    elif [[ "$loop_status" == "missing-receipt" ]]; then
      dx_info "dxloop paused: the provider exited without a completion receipt."
    else
      dx_info "dxloop interrupted (exit code: $exit_code)."
    fi
    case "$loop_status" in
      human-pause) __dx_runtime_set_terminal paused ;;
      max-iter|missing-receipt) __dx_runtime_set_terminal blocked ;;
      *)
        if [[ $exit_code -eq 129 || $exit_code -eq 130 || $exit_code -eq 143 ]]; then
          __dx_runtime_set_terminal stopped
        else
          __dx_runtime_set_terminal failed
        fi
        ;;
    esac
  fi

  return $exit_code
}

# ─── dxrefine — standalone ticket refinement (pre-implementation) ─────────
#
# Single Claude session in plan mode. Drives the user through 3+ batches of
# clarifying questions focused on high-level architecture and risks, then
# presents a PO-grade refined ticket via ExitPlanMode. On approval, the
# dxrefine skill posts architecture/risk comments and creates sub-tickets on
# the configured tracker; the parent ticket's description is left untouched.
#
# No worktree, no commits, no branch rename. No phase-loop participation.

unalias dxrefine 2>/dev/null; unfunction dxrefine 2>/dev/null
dxrefine() {
  if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
    echo "Usage: dxrefine <NUMBER|description>"
    echo "Refine a ticket or task through an interactive Claude planning session."
    return 0
  fi
  if [[ $# -eq 0 ]]; then
    echo "Usage: dxrefine <NUMBER>           (e.g. dxrefine 123, dxrefine ENG-123)"
    echo "       dxrefine \"<description>\"    (e.g. dxrefine \"streaming export pipeline\")"
    return 1
  fi

  __dx_refresh_provider || return 1

  local provider_agent
  provider_agent=$(__dx_resolved_provider_agent) || return 1
  if [[ "$provider_agent" == "codex" ]]; then
    dx_error "dxrefine requires an interactive Claude Code session for clarification and plan approval."
    dx_info "The selected provider profile resolves to the non-interactive Codex CLI. Run 'dx --agent claude refine <ticket-or-description>'."
    return 1
  fi
  __dx_require_resolved_provider_cli || return 1

  # Must be in a git repo so the skill can read AGENTS.md and codebase context.
  local repo_root
  repo_root=$(dx_repo_root) || return 1

  local raw_input="${(j: :)@}"

  # Session label for the Claude session name — stable across invocations on
  # the same input so the user can recognize it.
  local session_label
  if __dx_is_ticket "$raw_input"; then
    session_label="ticket-${raw_input//[^0-9]/}"
  else
    local slug
    slug=$(dx_slugify "${raw_input:0:40}")
    session_label="${slug:-$(date +%s)}"
  fi
  local session_name="dxrefine-${session_label}"

  # Unique state id so concurrent dxrefines don't collide on provider state.
  local session_id
  session_id="refine-$(dx_unique_session_id)"
  dx_provider_cleanup_session_state "$session_id"

  local branch
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  DEX — dxrefine (ticket refinement)"
  echo ""
  echo "  Branch: ${branch}"
  echo "  Input:  ${raw_input:0:72}$([ ${#raw_input} -gt 72 ] && echo '...')"
  echo "  Phase:  Refine (read-only until ExitPlanMode is approved)"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  local plan_args=("${DX_PLAN_FLAGS[@]}" -n "$session_name")
  plan_args+=(--append-system-prompt "You are in a dxrefine session — refinement only. Do NOT implement, do NOT commit, do NOT rename branches, do NOT set ticket status to In Progress. Stay in plan mode until you call ExitPlanMode. After approval, follow the dxrefine skill's write-back steps and stop.

Project constraints:
- Derive security, tenancy, scale, performance, and operational constraints from .dex/architecture.md, scoped .dex/memory/ entries, .dex/rules/, and code paths you read.
- Do not assume the target repo is multi-tenant, compute-heavy, high-traffic, or CRUD-oriented unless the project context proves it.
- If the project has tenant isolation, cascade recomputation, plugin boundaries, or other standing constraints, call them out with path-backed evidence.

Anchor every claim about where something lives to a real path in this repo. Reuse beats invent — justify every 'new X' against the existing X you found.")

  DEX_SESSION_ID="$session_id" \
  DEX_DIR="$DEX_DIR" \
  __dx_claude "${plan_args[@]}" \
    "This is a TECHNICAL refinement, not product discovery.

Input: ${raw_input}

Pre-flight (BEFORE EnterPlanMode — plan mode is read-only, so the architecture-map file write must happen first):
 0. Run: bash -lc 'test -f \"\$(git rev-parse --show-toplevel)/.dex/architecture.md\" && echo MAP_PRESENT || echo MAP_MISSING'
    - If MAP_MISSING: invoke the Skill tool with skill: \"dxarchitect\" to bootstrap .dex/architecture.md (it writes the file directly; the user reviews and commits it themselves — the skill does NOT commit). Remember in working memory that the map was freshly built so you can flag it in the final summary.
    - If MAP_PRESENT: continue.

Now call EnterPlanMode, then invoke the Skill tool with skill: \"dxrefine\". Skill flow:
 1. Gather ticket context (if a ticket id).
 2. Read .dex/architecture.md (C4 levels 1-3) — this is the canonical current-state map and the source of valid Domain values for sub-tickets.
 3. Ask the user at least four batches of clarifying questions covering scope, architecture & integration, scale & multi-tenancy, and operational risk. Skip PO-flavor probes (value hypothesis, user stories).
 4. Identify the design patterns that fit, with each tied to a sub-ticket (or record '— none, all sub-tickets are mechanical' if genuinely mechanical).
 5. Decompose into AT LEAST TWO sub-tickets, each tagged with a Domain (a C4 container or component name from the architecture map verbatim), a t-shirt size (XS/S/M/L/XL), and a dominant design pattern. Decomposition is the defining output of dxrefine — if the work cannot be split, bail out and tell the user to run dx <ticket> directly.
 6. Present a /dxplan-style summary via ExitPlanMode, including a per-Domain rollup so the user can dispatch sub-tickets to owners.
 7. After approval, create the sub-tickets (with Domain in body and as a label if the tracker supports it) and post five comments on the parent (architecture+component map, design patterns, risks, NFRs, open questions+decision log). Do NOT modify the parent ticket's description. If the architecture map was bootstrapped in step 0, remind the user to commit .dex/architecture.md themselves.
$(__dx_provider_prompt)"

  local exit_code=$?
  dx_provider_cleanup_session_state "$session_id"
  return $exit_code
}

# ─── dxcomplete — standalone Phase 6 (recovery / non-dx PRs) ───────────────

unalias dxcomplete 2>/dev/null; unfunction dxcomplete 2>/dev/null
dxcomplete() {
  if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
    echo "Usage: dxcomplete"
    echo "Complete the pull request for the current branch."
    return 0
  elif [[ $# -gt 0 ]]; then
    dx_error "dxcomplete does not accept arguments."
    return 1
  fi
  __dx_refresh_provider || return 1

  local provider_agent
  provider_agent=$(__dx_resolved_provider_agent) || return 1
  __dx_require_resolved_provider_cli || return 1

  # Must be in a git repo (PR is required)
  if ! git rev-parse --git-dir &>/dev/null; then
    dx_error "Not in a git repository."
    return 1
  fi

  # Check that a PR exists for the current branch
  if ! command -v gh &>/dev/null; then
    dx_error "GitHub CLI (gh) not found in PATH."
    return 1
  fi

  local pr_num
  pr_num=$(gh pr view --json number -q .number 2>/dev/null)
  if [[ -z "$pr_num" ]]; then
    dx_error "No PR found for the current branch."
    dx_info "Run the autonomous lifecycle first: dx <ticket>"
    return 1
  fi

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  DEX — dxcomplete (Phase 6: monitor, address, close)"
  echo ""
  echo "  PR:    #${pr_num}"
  echo "  Phase: Monitor CI → Address reviews → Close ticket"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  local session_id start_dir
  session_id=$(dx_session_id)
  start_dir=$(pwd)
  __dx_run_with_runtime "$session_id" "$start_dir" __dxcomplete_run \
    "$provider_agent" "$pr_num" "$session_id" "$start_dir"
  return $?
}

unalias __dxcomplete_run 2>/dev/null; unfunction __dxcomplete_run 2>/dev/null
__dxcomplete_run() {
  local provider_agent="$1" pr_num="$2" session_id="$3" start_dir="$4"
  local complete_max_cycles complete_wait_minutes
  complete_max_cycles=$(dx_complete_max_cycles "$session_id") || return 1
  complete_wait_minutes=$(dx_complete_wait_minutes "$session_id") || return 1

  # Use a session ID derived from the current location (worktree-aware via dx_session_id)
  local cleanup_repo_root cleanup_default_branch cleanup_mode="" cleanup_wt_name="" cleanup_wt_dir=""
  local complete_file paused_file completion_generation completion_config_file
  local completion_control_file
  local completion_activation_context="" completion_activation_conflict=0
  complete_file=$(dx_complete_file "$session_id")
  paused_file=$(dx_paused_file "$session_id")
  completion_config_file=$(dx_loop_config_file "$session_id")
  completion_control_file=$(dx_lifecycle_control_file "$session_id")
  cleanup_repo_root=$(dx_repo_root 2>/dev/null || echo "")
  cleanup_default_branch=$(dx_default_branch "$start_dir")
  if [[ -n "$cleanup_repo_root" && "$start_dir" == "${cleanup_repo_root}/.dex/worktrees/"* ]]; then
    cleanup_mode="worktree"
    cleanup_wt_name="${start_dir#"${cleanup_repo_root}/.dex/worktrees/"}"
    cleanup_wt_name="${cleanup_wt_name%%/*}"
    cleanup_wt_dir="${cleanup_repo_root}/.dex/worktrees/${cleanup_wt_name}"
  fi

  # Publish one standalone completion context without taking over a lifecycle
  # that already owns this checkout. A second dxcomplete launch sees the first
  # context under the same lock and leaves it alone.
  mkdir -p "$DX_LOOP_DIR"
  if ! dx_lifecycle_control_lock_acquire "$session_id"; then
    dx_error "Could not lock the dxcomplete launch state. Retry after the active lifecycle control finishes."
    return 1
  fi
  completion_activation_context=$(dx_lifecycle_completion_context_read \
    "$session_id" 2>/dev/null || true)
  if [[ -n "$completion_activation_context" \
    || -e "$(dx_active_file "$session_id")" \
    || -L "$(dx_active_file "$session_id")" \
    || -e "$completion_config_file" || -L "$completion_config_file" \
    || -e "$paused_file" || -L "$paused_file" \
    || -e "$(dx_state_file "$session_id")" \
    || -L "$(dx_state_file "$session_id")" \
    || -e "$(dx_handoff_mode_file "$session_id")" \
    || -L "$(dx_handoff_mode_file "$session_id")" \
    || -e "$completion_control_file" || -L "$completion_control_file" \
    || -n "$(dx_lifecycle_control_snapshot_unlocked "$session_id")" ]]; then
    completion_activation_conflict=1
  fi
  if [[ "$completion_activation_conflict" -eq 1 ]]; then
    if ! dx_lifecycle_control_lock_release_checked "$session_id"; then
      dx_error "Dex found an existing checkout owner but could not release the dxcomplete launch lock. Repair the transition lock before retrying."
      return 1
    fi
    dx_error "A Dex lifecycle or standalone loop already owns this checkout. Resume, pause, or finish that run before starting dxcomplete."
    return 1
  fi
  if ! completion_generation=$(dx_lifecycle_completion_issue_unlocked \
    "$session_id" standalone dxcomplete 6); then
    dx_lifecycle_control_lock_release_checked "$session_id" \
      2>/dev/null || true
    dx_error "Could not prepare the dxcomplete completion receipt."
    return 1
  fi
  rm -f "$complete_file" "$(dx_loop_file "$session_id")" \
    "$(dx_watch_pause_file "$session_id")" "$(dx_owner_file "$session_id")"
  if ! __dx_write_state "$completion_config_file" \
    "6:DEX_TICKET_COMPLETE:$DEX_DIR/prompts/phase-audits/6-complete.md:1:standalone:dxcomplete:${completion_generation}"; then
    dx_completion_abandon "$session_id" 2>/dev/null || true
    rm -f "$completion_config_file" 2>/dev/null || true
    dx_lifecycle_control_lock_release_checked "$session_id" \
      2>/dev/null || true
    dx_error "Could not persist the dxcomplete completion context."
    return 1
  fi
  # Direct Codex has no Stop hook. Its wrapper consumes the exact receipt, so
  # a file activation would only give an unrelated Claude session authority.
  if [[ "$provider_agent" != "codex" ]] \
    && ! dx_lifecycle_atomic_write "$(dx_active_file "$session_id")" active; then
    dx_completion_abandon "$session_id" 2>/dev/null || true
    rm -f "$completion_config_file" 2>/dev/null || true
    dx_lifecycle_control_lock_release_checked "$session_id" \
      2>/dev/null || true
    dx_error "Could not activate the dxcomplete audit."
    return 1
  fi
  if ! dx_lifecycle_control_lock_release "$session_id"; then
    dx_completion_abandon "$session_id" 2>/dev/null || true
    rm -f "$(dx_active_file "$session_id")" "$completion_config_file" 2>/dev/null || true
    dx_lifecycle_control_lock_release_retained "$session_id" \
      2>/dev/null || true
    dx_error "Could not release the dxcomplete launch lock. The audit was not started."
    return 1
  fi

  local completion_prompt
  completion_prompt="Invoke the Skill tool with skill: \"dxcomplete\". Run the full completion workflow: verify the PR is ready for review, request configured reviewers, post @mention comments, monitor CI and reviews via /loop 5m /dxwatchpr, address CI failures and review comments, and close the ticket when all checks pass and all successfully requested reviewers have approved.
When the Stop hook prints the exact command after the audit threshold, run this literal command only if every completion criterion is met, then stop again: bash \"\$DEX_DIR/bin/complete-receipt.sh\" \"${session_id}\" \"${completion_generation}\"
$(__dx_provider_prompt)"

  if [[ "$provider_agent" == "codex" ]]; then
    completion_prompt="Run the standalone Dex completion workflow for PR #${pr_num}. Read skills/dxcomplete/SKILL.md and skills/dxwatchpr/SKILL.md, then carry out their checks and fixes directly in this Codex session.

Direct Codex completion contract:
- Codex has no Claude Stop hook or /loop scheduler. Perform the bounded watcher cycles synchronously, with at most ${complete_max_cycles} cycles and the current ${complete_wait_minutes}-minute interval. Re-read dx_complete_max_cycles and dx_complete_wait_minutes before each cycle so in-session overrides take effect.
- Do not merge the PR.
- On success, and only after every completion criterion passes, run: bash \"\$DEX_DIR/bin/complete-receipt.sh\" \"${session_id}\" \"${completion_generation}\"
- If the bounded watch window expires or external state blocks completion, run: bash \"\$DEX_DIR/bin/escalate.sh\" \"${session_id}\" \"${completion_generation}\"
- Run exactly one of those generation-bound commands. Escalation pauses the run; it does not claim completion.

Use the humanizer skill before posting user-facing PR or ticket prose."
  fi

  DEX_SESSION_ID="$session_id" \
  DEX_LOOP_ACTIVE=1 \
  DEX_LOOP_PROMISE="DEX_TICKET_COMPLETE" \
  DEX_LOOP_PHASE="6" \
  DEX_COMPLETE_MAX_CYCLES="$complete_max_cycles" \
  DEX_COMPLETE_WAIT_MINUTES="$complete_wait_minutes" \
  DEX_DIR="$DEX_DIR" \
  __dx_claude "${DX_CLAUDE_FLAGS[@]}" -n "dxcomplete-pr-${pr_num}" \
    "$completion_prompt"

  local exit_code=$?
  local loop_status="advance" legacy_receipt=0 completion_cleanup_failed=0
  local complete_paused=0 completion_decision_locked=0 control_snapshot=""
  local paused_state_rc=0 completion_expectation_file completion_receipt_file
  completion_expectation_file=$(dx_completion_expectation_file "$session_id")
  completion_receipt_file=$(dx_completion_receipt_file "$session_id" \
    "$completion_generation")

  # Serialize the wrapper's terminal decision with human controls. Claude may
  # have consumed its receipt in the Stop hook already; direct Codex consumes
  # here, but both routes clean accepted intervention state under this lock.
  if ! dx_lifecycle_control_lock_acquire "$session_id"; then
    dx_write_pause_state "$session_id" "decision-lock-busy" "dxcomplete" \
      2>/dev/null || true
    if ! dx_lifecycle_atomic_write "$paused_file" paused; then
      rm -f "$(dx_active_file "$session_id")" 2>/dev/null || true
    fi
    if ! dx_lifecycle_control_lock_acquire "$session_id" 400; then
      dx_provider_cleanup_session_state "$session_id"
      dx_error "dxcomplete could not lock its completion decision. It left the loop paused and did not consume the receipt; retry after the active lifecycle control finishes."
      return 1
    fi
  fi
  completion_decision_locked=1
  control_snapshot=$(dx_lifecycle_control_snapshot_unlocked "$session_id")
  dx_lifecycle_pause_context_state "$session_id" || paused_state_rc=$?
  if [[ -n "$control_snapshot" \
    || -e "$completion_control_file" || -L "$completion_control_file" \
    || "$paused_state_rc" -ne 1 ]]; then
    complete_paused=1
  fi
  if [[ "$paused_state_rc" -eq 2 ]]; then
    completion_cleanup_failed=1
  fi

  # A direct human pause wins even if a provider also wrote a success receipt.
  # The exact generation is consumed only on the unambiguous success path.
  if [[ "$complete_paused" -eq 1 ]]; then
    exit_code=1
    __dx_abandon_completion_state "$session_id" || completion_cleanup_failed=1
    rm -f "$completion_control_file" 2>/dev/null \
      || completion_cleanup_failed=1
  elif [[ -e "$complete_file" || -L "$complete_file" ]]; then
    legacy_receipt=1
    exit_code=1
    rm -f "$complete_file" 2>/dev/null || true
    __dx_abandon_completion_state "$session_id" || completion_cleanup_failed=1
  elif [[ "$provider_agent" == "codex" && $exit_code -eq 0 ]]; then
    if ! dx_completion_consume "$session_id" standalone dxcomplete 6 "$completion_generation"; then
      loop_status="missing-receipt"
      exit_code=1
      __dx_abandon_completion_state "$session_id" || completion_cleanup_failed=1
    fi
  elif [[ "$provider_agent" != "codex" && $exit_code -eq 0 ]] \
    && [[ -e "$(dx_loop_file "$session_id")" || -L "$(dx_loop_file "$session_id")" ]]; then
    loop_status="max-iter"
    exit_code=1
    __dx_abandon_completion_state "$session_id" || completion_cleanup_failed=1
  elif [[ "$provider_agent" != "codex" && $exit_code -eq 0 ]]; then
    # Claude success is committed by the Stop hook. Do not infer success from
    # a missing active marker: detach and damaged-state paths can remove it
    # while leaving authorization or its context behind.
    if [[ -e "$completion_expectation_file" || -L "$completion_expectation_file" \
      || -e "$completion_receipt_file" || -L "$completion_receipt_file" \
      || -e "$completion_config_file" || -L "$completion_config_file" \
      || -e "$(dx_active_file "$session_id")" \
      || -L "$(dx_active_file "$session_id")" ]]; then
      loop_status="missing-receipt"
      exit_code=1
      __dx_abandon_completion_state "$session_id" || completion_cleanup_failed=1
    fi
  elif [[ $exit_code -ne 0 ]]; then
    __dx_abandon_completion_state "$session_id" || completion_cleanup_failed=1
  fi

  # Runtime cleanup belongs to the same decision transaction. Once this lock
  # is released, a newer human control must be free to publish without an old
  # wrapper deleting it afterward.
  if [[ "$completion_cleanup_failed" -eq 0 ]]; then
    rm -f "$(dx_active_file "$session_id")" "$(dx_owner_file "$session_id")" \
      "$(dx_loop_file "$session_id")" "$completion_config_file" "$complete_file" \
      "$paused_file" "$(dx_pause_state_file "$session_id")" 2>/dev/null \
      || completion_cleanup_failed=1
  fi

  if [[ "$completion_decision_locked" -eq 1 ]] \
    && ! dx_lifecycle_control_lock_release "$session_id"; then
    completion_cleanup_failed=1
    dx_lifecycle_completion_brake "$session_id" decision-lock-release \
      dxcomplete 2>/dev/null || true
    dx_lifecycle_control_lock_release_retained "$session_id" \
      2>/dev/null || true
  fi

  if [[ "$completion_cleanup_failed" -eq 1 ]]; then
    dx_error "dxcomplete could not prove that completion authorization was revoked. Repair its state files before retrying."
    exit_code=1
  fi
  dx_provider_cleanup_session_state "$session_id"

  if [[ $complete_paused -eq 1 ]]; then
    dx_info "dxcomplete paused before completion; local worktree/branch cleanup was skipped."
    exit_code=1
  elif [[ $legacy_receipt -eq 1 ]]; then
    dx_info "dxcomplete ignored a legacy .complete marker; the exact versioned receipt is required."
  elif [[ "$loop_status" == "max-iter" ]]; then
    dx_info "dxcomplete paused: max audit iterations reached without completion."
  elif [[ "$loop_status" == "missing-receipt" ]]; then
    dx_info "dxcomplete paused: the provider exited without a completion receipt."
  elif [[ $exit_code -eq 0 && "$cleanup_mode" == "worktree" ]]; then
    __dx_cleanup_completed_workspace "$cleanup_wt_name" "$cleanup_wt_dir" "$cleanup_default_branch" "$cleanup_mode" "$session_id"
    exit_code=$?
  elif [[ $exit_code -eq 0 ]]; then
    dx_info "dxcomplete finished; no Dex worktree was detected, so the current checkout and branch were left intact."
  fi

  if [[ "$completion_cleanup_failed" -eq 1 ]]; then
    __dx_runtime_set_terminal failed
  elif [[ "$complete_paused" -eq 1 ]]; then
    __dx_runtime_set_terminal paused
  elif [[ "$legacy_receipt" -eq 1 || "$loop_status" == "max-iter" \
    || "$loop_status" == "missing-receipt" ]]; then
    __dx_runtime_set_terminal blocked
  elif [[ $exit_code -eq 0 ]]; then
    __dx_runtime_set_terminal completed
  elif [[ $exit_code -eq 129 || $exit_code -eq 130 || $exit_code -eq 143 ]]; then
    __dx_runtime_set_terminal stopped
  else
    __dx_runtime_set_terminal failed
  fi
  return $exit_code
}

# ─── dxreviewloop — standalone risk-gated clean-pass review ───────────────
#
# Runs the same adversarial review loop dx Phase 3 uses, without requiring
# the full lifecycle. Scope is the full current change set when one exists; on
# a clean branch, the loop falls back to a whole-codebase review.
#
# Each iteration is a fresh CLI session that runs one full review wave:
# build/refresh a compact context pack, run deterministic checks, collect
# read-only review findings, verify/dedupe, batch-fix, re-check, then write a
# review-result signal. Only a wave with zero verified findings and zero fixes
# writes CLEAN. A preflight risk selection resolves small/normal/complex to
# the trusted policy's required clean waves, and a wave may escalate that tier upward.















unalias dxreviewloop 2>/dev/null; unfunction dxreviewloop 2>/dev/null
# Public command: the implementation lives in lib/review-loop.sh.
dxreviewloop() {
  dx_review_loop_run "$@"
}

# ─── dxrm — remove worktrees ──────────────────────────────────────────────

unalias dxrm 2>/dev/null; unfunction dxrm 2>/dev/null
dxrm() {
  if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
    echo "Usage: dxrm <NUMBER|name>"
    echo "       dxrm --all"
    return 0
  fi
  if [[ $# -eq 0 ]]; then
    echo "Usage: dxrm <NUMBER>     (e.g. dxrm 999)"
    echo "       dxrm <name>       (e.g. dxrm task-fix-login)"
    echo "       dxrm --all        Remove all worktrees"
    return 1
  fi

  # Find repo root — dx_repo_root handles worktree escaping.
  # If git fails (cwd was deleted), fall back to parsing the cwd path.
  local repo_root
  repo_root=$(dx_repo_root 2>/dev/null)
  if [[ -z "$repo_root" ]]; then
    local cwd
    cwd="$(pwd 2>/dev/null || echo "")"
    if [[ "$cwd" == *"/.dex/worktrees/"* ]]; then
      repo_root="${cwd%%/.dex/worktrees/*}"
    fi
  fi
  if [[ -z "$repo_root" ]]; then
    dx_error "Could not determine repo root. cd to the repo and try again."
    return 1
  fi

  local worktrees_dir="${repo_root}/.dex/worktrees"

  # Move to repo root first in case we're inside a worktree being removed.
  # Must succeed — subsequent git operations depend on being in the right directory.
  # Note: this intentionally does not restore the original cwd — if the user was
  # inside a worktree that got deleted, returning there would fail.
  cd "$repo_root" || return 1

  if [[ "$1" == "--all" ]]; then
    local found=0
    local skipped_active_in_place=0
    local removal_failed=0
    local renamed_branches=()
    local session_ids=()
    local wt_dir wt_name actual_branch branch active_in_place_phase
    local active_in_place_result last_session_result
    local last_session_active_in_place=0 sid

    if [[ -d "$worktrees_dir" ]]; then
      for wt_dir in "$worktrees_dir"/*(/N); do
        [[ -d "$wt_dir" ]] || continue
        found=1
        wt_name="$(basename "$wt_dir")"
        # The SessionStart hook may rename the worktree branch (e.g. from
        # worktree-ticket-999 to feat/ENG-999-description) to follow project
        # conventions. Track these renamed branches so we can delete them below
        # — they won't match the 'worktree-*' glob pattern.
        actual_branch=$(dx_wt_branch "$wt_dir")

        echo "Removing ${wt_name}..."
        dx_cleanup_checkpoints "$wt_dir"
        dx_unlink_claude_from_worktree "$wt_dir"
        if ! dx_wt_remove "$wt_dir"; then
          dx_error "Failed to remove worktree ${wt_name}; its branch and session state were left intact."
          removal_failed=1
          continue
        fi
        session_ids+=("$(dx_session_id "$wt_name")")
        if [[ -n "$actual_branch" && "$actual_branch" != "worktree-${wt_name}" ]]; then
          renamed_branches+=("$actual_branch")
        fi
      done
    fi

    while IFS= read -r branch; do
      [[ -z "$branch" ]] && continue
      found=1
      active_in_place_result=0
      active_in_place_phase=$(__dx_active_in_place_phase_for_branch "$branch") \
        || active_in_place_result=$?
      if [[ "$active_in_place_result" -eq 0 ]]; then
        echo "Skipping branch ${branch} (active in-place phase ${active_in_place_phase}/6: $(__dx_phase_name "$active_in_place_phase"))"
        skipped_active_in_place=1
        continue
      elif [[ "$active_in_place_result" -eq 2 ]]; then
        dx_warn "Skipping branch ${branch}: its lifecycle branch state is missing, unsafe, or malformed."
        skipped_active_in_place=1
        continue
      fi
      echo "Deleting branch ${branch}..."
      if git branch -D "$branch" 2>/dev/null; then
        __dx_cleanup_lifecycle_state_for_branch "$branch"
      fi
    done < <(git branch --list 'worktree-ticket-*' 'worktree-task-*' 2>/dev/null | sed 's/^[*+ ]*//')

    # Delete renamed branches that wouldn't match the worktree-* pattern
    for branch in "${renamed_branches[@]}"; do
      echo "Deleting renamed branch ${branch}..."
      git branch -D "$branch" 2>/dev/null || true
      found=1
    done

    git worktree prune 2>/dev/null

    last_session_result=0
    __dx_last_session_active_in_place || last_session_result=$?
    if [[ "$last_session_result" -eq 0 || "$last_session_result" -eq 2 ]]; then
      last_session_active_in_place=1
    fi

    # Clean up last-session pointer unless it still points at a resumable in-place session.
    if [[ $removal_failed -eq 0 && $last_session_active_in_place -eq 0 ]]; then
      rm -f "$DX_STATE_DIR/last-session" 2>/dev/null
    fi

    # Clean up state files for THIS repo's worktrees only (not cross-repo globs)
    for sid in "${session_ids[@]}"; do
      dx_cleanup_session "$sid"
    done

    if [[ $removal_failed -eq 1 ]]; then
      dx_warn "Some worktrees could not be removed. Resolve the errors above and run dxrm --all again."
      return 1
    elif [[ $found -eq 0 ]]; then
      dx_info "No worktrees or branches found."
    elif [[ $skipped_active_in_place -eq 1 || $last_session_active_in_place -eq 1 ]]; then
      echo "Finished. Active in-place lifecycle branch(es) were left intact."
    else
      echo "All worktrees removed."
    fi
    return 0
  fi

  local raw_input="${(j: :)@}"  # zsh: join all args with spaces

  local wt_name
  if __dx_is_ticket "$raw_input"; then
    local num="${raw_input//[^0-9]/}"  # strip everything except digits
    wt_name="ticket-${num}"
    if [[ ! -d "${worktrees_dir}/${wt_name}" ]] \
      && ! git show-ref --verify --quiet "refs/heads/worktree-${wt_name}" 2>/dev/null; then
      local resolution_status=0
      __dx_resolve_existing_workspace_by_ticket "$num" || resolution_status=$?
      if [[ $resolution_status -eq 0 ]]; then
        wt_name="$_dx_wt_name"
        dx_info "Resolved ticket ${num} to existing workspace ${wt_name}"
      elif [[ $resolution_status -ne 1 ]]; then
        return 1
      fi
    fi
  else
    # For freeform names, try multiple matches so the user can pass:
    #   "task-fix-login"  → exact dir name from dxls output
    #   "fix login"       → slugified to "fix-login", then prefixed with "task-"
    #   "fix-login"       → same after slugify
    local slug
    slug=$(dx_slugify "$raw_input")
    if [[ -z "$slug" ]]; then
      dx_error "Could not create a valid name from '$raw_input'"
      return 1
    fi
    if [[ -d "${worktrees_dir}/${slug}" ]]; then
      wt_name="$slug"
    elif [[ -d "${worktrees_dir}/task-${slug}" ]]; then
      wt_name="task-${slug}"
    elif [[ "$slug" == task-* ]] && git show-ref --verify --quiet "refs/heads/worktree-${slug}" 2>/dev/null; then
      wt_name="$slug"
    elif git show-ref --verify --quiet "refs/heads/worktree-task-${slug}" 2>/dev/null; then
      wt_name="task-${slug}"
    else
      dx_error "No worktree found matching '${raw_input}'."
      dx_info "Run dxls to see available worktrees."
      return 1
    fi
  fi

  local wt_dir="${worktrees_dir}/${wt_name}"
  local branch_name="worktree-${wt_name}"

  # Detect actual branch name (may have been renamed by ticket instructions)
  local actual_branch=""
  [[ -d "$wt_dir" ]] && actual_branch=$(dx_wt_branch "$wt_dir")

  local has_dir=0 has_branch=0
  [[ -d "$wt_dir" ]] && has_dir=1
  git show-ref --verify --quiet "refs/heads/${branch_name}" 2>/dev/null && has_branch=1

  # Also check for the actual branch if it differs from the expected name
  local has_actual_branch=0
  if [[ -n "$actual_branch" && "$actual_branch" != "$branch_name" ]]; then
    git show-ref --verify --quiet "refs/heads/${actual_branch}" 2>/dev/null && has_actual_branch=1
  fi

  if [[ $has_dir -eq 0 ]] && [[ $has_branch -eq 0 ]] && [[ $has_actual_branch -eq 0 ]]; then
    dx_error "No worktree or branch found for '${wt_name}'."
    return 1
  fi

  if [[ $has_dir -eq 0 ]] && [[ $has_branch -eq 1 ]]; then
    local active_in_place_phase active_in_place_result=0
    active_in_place_phase=$(__dx_active_in_place_phase_for_branch "$branch_name") \
      || active_in_place_result=$?
    if [[ "$active_in_place_result" -eq 0 ]]; then
      dx_error "Refusing to remove active in-place lifecycle branch ${branch_name} (phase ${active_in_place_phase}/6: $(__dx_phase_name "$active_in_place_phase"))."
      dx_info "Resume it with dx --resume, or finish the lifecycle before cleaning it up."
      return 1
    elif [[ "$active_in_place_result" -eq 2 ]]; then
      dx_error "Refusing to remove in-place lifecycle branch ${branch_name}: its branch state is missing, unsafe, or malformed."
      dx_info "Repair the private branch record before cleaning up this lifecycle."
      return 1
    fi
  fi

  echo "Removing ${wt_name}..."

  if [[ $has_dir -eq 1 ]]; then
    dx_cleanup_checkpoints "$wt_dir"
    dx_unlink_claude_from_worktree "$wt_dir"
    if ! dx_wt_remove "$wt_dir"; then
      dx_error "Failed to remove worktree ${wt_name}; its branch and session state were left intact."
      return 1
    fi
  fi

  if [[ $has_branch -eq 1 ]]; then
    echo "  Deleting branch ${branch_name}..."
    if git branch -D "$branch_name" 2>/dev/null && [[ $has_dir -eq 0 ]]; then
      __dx_cleanup_lifecycle_state_for_branch "$branch_name"
    fi
  fi

  if [[ $has_actual_branch -eq 1 ]]; then
    echo "  Deleting renamed branch ${actual_branch}..."
    git branch -D "$actual_branch" 2>/dev/null || true
  fi

  # Clean up state files and last-session pointer
  local session_id
  session_id=$(dx_session_id "$wt_name")
  dx_cleanup_session "$session_id"
  dx_cleanup_last_session "$wt_name"

  git worktree prune 2>/dev/null
  echo "Done."
}

# ─── dxls — list worktrees ────────────────────────────────────────────────

unalias dxls 2>/dev/null; unfunction dxls 2>/dev/null
dxls() {
  if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
    echo "Usage: dxls"
    echo "List Dex worktrees for the current repository."
    return 0
  elif [[ $# -gt 0 ]]; then
    dx_error "dxls does not accept arguments."
    return 1
  fi
  local repo_root
  repo_root=$(dx_repo_root) || return 1

  local worktrees_dir="${repo_root}/.dex/worktrees"
  if [[ ! -d "$worktrees_dir" ]]; then
    dx_info "No worktrees."
    return 0
  fi

  local count=0 wt_dir wt_name wt_status branch session_id phase_file phase_num phase_rc=0
  for wt_dir in "$worktrees_dir"/*(/N); do
    [[ -d "$wt_dir" ]] || continue
    count=$((count + 1))
    wt_name="$(basename "$wt_dir")"
    wt_status=""

    # Check git state is valid before querying status/branch
    if ! git -C "$wt_dir" rev-parse --git-dir &>/dev/null; then
      wt_status=" [corrupted git state]"
      echo "  ${wt_name}  (?)${wt_status}"
      continue
    fi

    if git -C "$wt_dir" status --porcelain 2>/dev/null | head -1 | grep -q .; then
      wt_status="${wt_status} [changes]"
    fi

    branch=$(dx_wt_branch "$wt_dir" "?")

    # Show phase status
    session_id=$(dx_session_id "$wt_name")
    phase_file=$(dx_state_file "$session_id")
    if [[ -e "$phase_file" || -L "$phase_file" ]]; then
      phase_rc=0
      phase_num=$(dx_lifecycle_phase_state "$session_id" 2>/dev/null) || phase_rc=$?
      if [[ "$phase_rc" -ne 0 ]]; then
        wt_status="${wt_status} [blocked: unsafe phase state]"
      elif [[ "$phase_num" =~ ^[0-6]$ ]]; then
        wt_status="${wt_status} [phase ${phase_num}/6: $(__dx_phase_name "$phase_num")]"
      elif [[ "$phase_num" == "7" ]] \
        && dx_lifecycle_terminal_commit_valid "$session_id"; then
        wt_status="${wt_status} [complete]"
      else
        wt_status="${wt_status} [blocked: terminal commit not verified]"
      fi
    fi

    [[ -z "$wt_status" ]] && wt_status=" [idle]"
    echo "  ${wt_name}  (${branch})${wt_status}"
  done

  if [[ $count -eq 0 ]]; then
    dx_info "No worktrees."
  fi
}

# ─── dxcd — navigate to a worktree or repo root ─────────────────────────────

unalias dxcd 2>/dev/null; unfunction dxcd 2>/dev/null
dxcd() {
  if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
    echo "Usage: dxcd [NUMBER|name]"
    echo "Open a Dex worktree, or return to the repository root without an argument."
    return 0
  elif [[ $# -gt 1 ]]; then
    dx_error "dxcd accepts at most one ticket or workspace name."
    return 1
  fi
  local repo_root
  repo_root=$(dx_repo_root) || return 1

  # No args → repo root
  if [[ $# -eq 0 ]]; then
    cd "$repo_root" || return 1
    return 0
  fi

  local target="$1"
  local worktrees_dir="${repo_root}/.dex/worktrees"

  # Ticket IDs may point to a task-named workspace after tracker intake linked
  # a freeform lifecycle to a ticket.
  if __dx_is_ticket "$target"; then
    local ticket_number="${target//[^0-9]/}"
    local ticket_dir="$worktrees_dir/ticket-${ticket_number}"
    if [[ -d "$ticket_dir" ]]; then
      if ! dx_wt_is_registered "$repo_root" "$ticket_dir"; then
        dx_error "Workspace path is not a registered Git worktree: ${ticket_dir}"
        return 1
      fi
      cd "$ticket_dir" || return 1
      return 0
    fi
    local resolution_status=0
    __dx_resolve_existing_workspace_by_ticket "$ticket_number" || resolution_status=$?
    if [[ $resolution_status -eq 0 ]]; then
      if [[ "$_dx_workspace_mode" == "in-place" ]]; then
        dx_info "Ticket ${ticket_number} uses the current checkout"
        cd "$repo_root" || return 1
        return 0
      fi
      local linked_dir="$worktrees_dir/$_dx_wt_name"
      if ! dx_wt_is_registered "$repo_root" "$linked_dir"; then
        dx_error "Workspace path is not a registered Git worktree: ${linked_dir}"
        return 1
      fi
      dx_info "Resolved ticket ${ticket_number} to existing workspace $_dx_wt_name"
      cd "$linked_dir" || return 1
      return 0
    elif [[ $resolution_status -ne 1 ]]; then
      return 1
    fi
  fi

  if [[ ! -d "$worktrees_dir" ]]; then
    dx_error "No worktrees found."
    return 1
  fi

  # Exact match first, but do not present a plain directory as a worktree.
  if [[ -d "$worktrees_dir/$target" ]]; then
    if ! dx_wt_is_registered "$repo_root" "$worktrees_dir/$target"; then
      dx_error "Workspace path is not a registered Git worktree: $worktrees_dir/$target"
      return 1
    fi
    cd "$worktrees_dir/$target" || return 1
    return 0
  fi

  # Prefix match: "ticket-123" or just "123" matches worktree names containing that string
  local matches=() wt_dir name m
  for wt_dir in "$worktrees_dir"/*(/N); do
    [[ -d "$wt_dir" ]] || continue
    dx_wt_is_registered "$repo_root" "$wt_dir" || continue
    name="$(basename "$wt_dir")"
    if [[ "$name" == *"$target"* ]]; then
      matches+=("$wt_dir")
    fi
  done

  if [[ ${#matches[@]} -eq 0 ]]; then
    dx_error "No worktree matching '$target'. Run dxls to see active worktrees."
    return 1
  elif [[ ${#matches[@]} -eq 1 ]]; then
    cd "${matches[1]}" || return 1
    return 0
  else
    dx_error "Multiple worktrees match '$target':"
    for m in "${matches[@]}"; do
      echo "  $(basename "$m")"
    done
    echo "Be more specific."
    return 1
  fi
}

# ─── dxclean — prune stale worktrees + gone branches ─────────────────────────

unalias dxclean 2>/dev/null; unfunction dxclean 2>/dev/null
dxclean() {
  if [[ $# -eq 1 && ( "$1" == "-h" || "$1" == "--help" ) ]]; then
    echo "Usage: dxclean"
    echo "Remove stale Dex worktrees, branches, and session files."
    return 0
  elif [[ $# -gt 0 ]]; then
    dx_error "dxclean does not accept arguments."
    return 1
  fi
  local repo_root
  repo_root=$(dx_repo_root) || return 1

  # cd to repo root so bare git commands (fetch, branch -D, branch --list) operate
  # on the correct repository. Note: this intentionally does not restore the original
  # cwd — if the user was inside a removed worktree, returning there would fail.
  cd "$repo_root" || return 1
  local cleaned=0 cleanup_failed=0
  local wt_dir wt_name session_id phase_file phase_val wt_branch branch
  local active_in_place_phase active_in_place_result has_worktree ticket_name
  local old_files old_phase_files

  # 1. Prune stale worktrees (no uncommitted changes)
  local worktrees_dir="${repo_root}/.dex/worktrees"
  if [[ -d "$worktrees_dir" ]]; then
    for wt_dir in "$worktrees_dir"/*(/N); do
      [[ -d "$wt_dir" ]] || continue
      wt_name="$(basename "$wt_dir")"

      # Skip worktrees with active phase state (still in a lifecycle)
      session_id=$(dx_session_id "$wt_name")
      phase_file=$(dx_state_file "$session_id")
      if [[ -f "$phase_file" ]]; then
        phase_val=$(cat "$phase_file" 2>/dev/null)
        if [[ "$phase_val" =~ ^[0-6]$ ]]; then
          echo "  Skipping ${wt_name} (active phase ${phase_val}/6: $(__dx_phase_name "$phase_val"))"
          continue
        fi
      fi

      # Skip worktrees with uncommitted changes
      if git -C "$wt_dir" status --porcelain 2>/dev/null | head -1 | grep -q .; then
        echo "  Skipping ${wt_name} (has uncommitted changes)"
        continue
      fi

      # Skip worktrees with unpushed commits
      wt_branch=$(dx_wt_branch "$wt_dir")
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
      dx_unlink_claude_from_worktree "$wt_dir"
      if ! dx_wt_remove "$wt_dir"; then
        dx_error "Failed to remove stale worktree ${wt_name}; its branch and session state were left intact."
        cleanup_failed=1
        continue
      fi

      # Delete the branch (wt_branch captured above; handles renamed branches too)
      [[ -n "$wt_branch" ]] && git branch -D "$wt_branch" 2>/dev/null || true

      # Clean up state files and last-session pointer
      dx_cleanup_session "$session_id"
      dx_cleanup_last_session "$wt_name"

      cleaned=$((cleaned + 1))
    done
  fi

  # 2. Prune dex branches whose remote tracking branch is gone.
  # Only targets worktree-* branches to avoid deleting non-dex feature branches.
  git fetch --prune 2>/dev/null || true

  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    # Only clean dex-managed branches (worktree-ticket-* or worktree-task-*)
    if [[ "$branch" != worktree-ticket-* ]] && [[ "$branch" != worktree-task-* ]]; then
      continue
    fi
    active_in_place_result=0
    active_in_place_phase=$(__dx_active_in_place_phase_for_branch "$branch") \
      || active_in_place_result=$?
    if [[ "$active_in_place_result" -eq 0 ]]; then
      echo "  Skipping branch ${branch} (active in-place phase ${active_in_place_phase}/6: $(__dx_phase_name "$active_in_place_phase"))"
      continue
    elif [[ "$active_in_place_result" -eq 2 ]]; then
      dx_warn "Skipping branch ${branch}: its lifecycle branch state is missing, unsafe, or malformed."
      continue
    fi
    # Don't delete branches with active worktrees
    has_worktree=0
    if [[ -d "$worktrees_dir" ]]; then
      for wt_dir in "$worktrees_dir"/*(/N); do
        [[ -d "$wt_dir" ]] || continue
        wt_branch=$(dx_wt_branch "$wt_dir")
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
    if git branch -D "$branch" 2>/dev/null; then
      __dx_cleanup_lifecycle_state_for_branch "$branch"
      cleaned=$((cleaned + 1))
    fi
  done < <(git branch -vv 2>/dev/null | grep ': gone]' | sed 's/^[*+ ]*//' | awk '{print $1}')

  # 3. Prune worktree branches that have no worktree directory
  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    active_in_place_result=0
    active_in_place_phase=$(__dx_active_in_place_phase_for_branch "$branch") \
      || active_in_place_result=$?
    if [[ "$active_in_place_result" -eq 0 ]]; then
      echo "  Skipping branch ${branch} (active in-place phase ${active_in_place_phase}/6: $(__dx_phase_name "$active_in_place_phase"))"
      continue
    elif [[ "$active_in_place_result" -eq 2 ]]; then
      dx_warn "Skipping branch ${branch}: its lifecycle branch state is missing, unsafe, or malformed."
      continue
    fi
    ticket_name="${branch#worktree-}"
    if [[ ! -d "$worktrees_dir/$ticket_name" ]]; then
      # In-place lifecycles and manually removed worktrees leave these
      # branches behind while still holding unpushed work; mirror the
      # push-safety guards from the stale-worktree pass above.
      if ! git rev-parse "origin/${branch}" &>/dev/null; then
        echo "  Skipping branch ${branch} (not pushed to remote)"
        continue
      fi
      if git log --oneline "origin/${branch}..${branch}" 2>/dev/null | head -1 | grep -q .; then
        echo "  Skipping branch ${branch} (has unpushed commits)"
        continue
      fi
      echo "  Deleting orphan branch: ${branch}"
      if git branch -D "$branch" 2>/dev/null; then
        __dx_cleanup_lifecycle_state_for_branch "$branch"
        cleaned=$((cleaned + 1))
      fi
    fi
  done < <(git branch --list 'worktree-ticket-*' 'worktree-task-*' 2>/dev/null | sed 's/^[*+ ]*//')

  git worktree prune 2>/dev/null

  # 4. Clean up old loop state files (older than 7 days).
  # 7 days gives enough time to resume interrupted sessions while preventing
  # indefinite accumulation. Most tickets complete within a day or two.
  # old_files is already declared at the top of dxclean. Naming it again with
  # no value does not redeclare it in zsh — it prints `old_files=<value>` to
  # stdout, which is how "old_files=''" ended up in dxclean's output.
  local old_review_credit=0
  old_review_credit=$(dx_cleanup_stale_review_credit 7) || cleanup_failed=1
  if [[ "$old_review_credit" -gt 0 ]]; then
    echo "  Cleaned ${old_review_credit} old review credit bundle(s)"
    cleaned=$((cleaned + old_review_credit))
  fi
  old_files=$(dx_cleanup_stale_files "$DX_LOOP_DIR" "state complete active owner prompt config findings debt provider review-state review-result review-context review-criteria.json review-criteria-approval review-selection review-evidence.json review-receipt busy busy-notice started ready watch-pause watch-lock" 7)
  if [[ "$old_files" -gt 0 ]]; then
    echo "  Cleaned ${old_files} old loop state file(s)"
    cleaned=$((cleaned + old_files))
  fi

  # 5. Clean up old phase state files (older than 7 days)
  old_phase_files=$(dx_cleanup_stale_files "$DX_STATE_DIR" "phase times system-context log branch" 7)
  if [[ "$old_phase_files" -gt 0 ]]; then
    echo "  Cleaned ${old_phase_files} old phase state file(s)"
    cleaned=$((cleaned + old_phase_files))
  fi

  if [[ $cleaned -eq 0 ]]; then
    echo "Nothing to clean."
  else
    echo "Cleaned ${cleaned} item(s)."
  fi
  [[ $cleanup_failed -eq 0 ]]
}

if [[ "${__DX_SH_EXECUTED:-0}" -eq 1 ]]; then
  dx "$@"
  __dx_script_status=$?
  exit $__dx_script_status
fi

unset __DX_SH_LOADED_PATH __DX_SH_LOADED_ABS __DX_SH_EXECUTED
