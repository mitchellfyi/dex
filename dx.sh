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
#   dx --resume             Resume the most recent session
#   dx --from-pr <N>        Resume session linked to a PR
#   dxcomplete              Standalone completion workflow (recovery / non-dx PRs)
#   dxreviewloop            Standalone adaptive review of changes, or whole codebase if clean
#   dxrm <number|name|--all>  Remove a worktree
#   dxls                   List worktrees
#   dxclean                Clean stale worktrees + gone branches
#   dxloop <prompt>         Run a prompt until fully implemented
#   dx sync                 Refresh repo memory/rules from verified observations
#   dx maintain             Run background maintenance or install workflow
#   dx tools                Check or install Claude/Codex tooling bootstrap
#   dex                   Alias for dx
#   dexter                Alias for dx

if [[ -z "${DEX_DIR:-}" ]]; then
  echo "ERROR: DEX_DIR not set. Run 'dx install' first." >&2
  return 1
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
    maintain)  bash "$DEX_DIR/bin/maintain.sh" "$@" ;;
    tools)     bash "$DEX_DIR/bin/tools.sh" "$@" ;;
    config)    bash "$DEX_DIR/bin/config.sh" "$@" ;;
    provider)  dx_provider_command "$@" ;;
    research)
      local _dx_has_max_cycles=0 _dx_arg
      for _dx_arg in "$@"; do
        if [[ "$_dx_arg" == "--max-cycles" || "$_dx_arg" == --max-cycles=* ]]; then
          _dx_has_max_cycles=1
          break
        fi
      done
      if [[ $_dx_has_max_cycles -eq 0 ]]; then
        bash "$DEX_DIR/research/orchestrate.sh" --max-cycles 20 "$@"
      else
        bash "$DEX_DIR/research/orchestrate.sh" "$@"
      fi
      ;;
    uninit)    bash "$DEX_DIR/bin/uninit.sh" "$@" ;;
    reload)
      source "$DEX_DIR/dx.sh"
      echo "Reloaded Dex shell functions."
      ;;
    status)    bash "$DEX_DIR/bin/status.sh" "$@" ;;
    help|--help|-h)
      echo "Dex — workflow automation for Claude Code"
      echo ""
      echo "Commands:"
      echo "  dx install          Global install (skills, hooks, zshrc)"
      echo "  dx uninstall        Global uninstall"
      echo "  dx init             Bootstrap current repo for Dex"
      echo "  dx sync             Refresh repo memory/rules from verified observations"
      echo "  dx maintain         Run background maintenance or install the GitHub workflow"
      echo "  dx tools            Check or install Claude/Codex tooling bootstrap"
      echo "  dx config           Configure integrations (ticket tracker, Figma, etc.)"
      echo "  dx provider         Configure provider/model execution profiles"
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
      echo "  dx --no-worktree <task> Run lifecycle in the current checkout instead"
      echo "  dx --resume            Resume the most recent session"
      echo "  dx --from-pr <N>      Resume session linked to a PR"
      echo "  dx revert <N> [phase] Revert worktree to a phase checkpoint"
      echo "  dx log [session_id]   Show structured phase execution log"
      echo "  dxrm <number|name>    Remove a worktree"
      echo "  dxrm --all            Remove all worktrees"
      echo "  dxls                  List worktrees"
      echo "  dxclean               Clean stale worktrees + gone branches"
      echo ""
      echo "Refinement (pre-implementation):"
      echo "  dx refine <N|description>  Refine a ticket — clarify with the user, raise risks, propose sub-tickets"
      echo ""
      echo "Standalone completion (recovery / non-dx PRs):"
      echo "  dxcomplete             Monitor CI/reviews, address comments, close ticket"
      echo ""
      echo "Standalone review (adaptive clean-pass loop, no full lifecycle needed):"
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
      local rev_name
      if __dx_is_ticket "$raw"; then
        rev_name="ticket-${raw//[^0-9]/}"
      else
        rev_name="task-$(dx_slugify "$raw")"
      fi
      local rev_root
      rev_root=$(dx_repo_root) || return 1
      local rev_dir="${rev_root}/.dex/worktrees/${rev_name}"
      if [[ ! -d "$rev_dir" ]]; then
        dx_error "Worktree ${rev_name} not found."
        return 1
      fi
      if [[ -z "$rev_phase" ]]; then
        # Find the most recent checkpoint
        local latest_tag
        latest_tag=$(git -C "$rev_dir" tag -l 'dx-checkpoint/phase-*' --sort=-version:refname 2>/dev/null | head -1)
        if [[ -z "$latest_tag" ]]; then
          dx_info "No checkpoints found for ${rev_name}."
          return 1
        fi
        rev_phase="${latest_tag##*-}"
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

# Default Claude flags for all dx-launched sessions:
#   --chrome           Enable browser automation tools (MCP)
#   --model            Use Opus for autonomous multi-phase work by default.
#                      Override with DX_CLAUDE_MODEL for gateways/custom models.
#   --dangerously-skip-permissions       No interactive permission prompts.
#   --permission-mode bypassPermissions  Keep Claude's permission mode explicit.
#   --effort           Maximum reasoning effort for complex tasks by default.
#                      Override with DX_CLAUDE_EFFORT if the provider differs.
unalias __dx_refresh_provider 2>/dev/null; unfunction __dx_refresh_provider 2>/dev/null
__dx_refresh_provider() {
  dx_provider_apply || return 1
  DX_CLAUDE_FLAGS=(--chrome --model "$DX_CLAUDE_MODEL" --dangerously-skip-permissions --permission-mode bypassPermissions --effort "$DX_CLAUDE_EFFORT")
  DX_PLAN_FLAGS=(--chrome --model "$DX_PLAN_MODEL" --dangerously-skip-permissions --permission-mode bypassPermissions --effort "$DX_PLAN_EFFORT")
}

DX_CLAUDE_FLAGS=(--chrome --model "${DX_CLAUDE_MODEL:-opus}" --dangerously-skip-permissions --permission-mode bypassPermissions --effort "${DX_CLAUDE_EFFORT:-max}")
DX_PLAN_FLAGS=(--chrome --model "${DX_PLAN_MODEL:-${DX_CLAUDE_MODEL:-opus}}" --dangerously-skip-permissions --permission-mode bypassPermissions --effort "${DX_PLAN_EFFORT:-${DX_CLAUDE_EFFORT:-max}}")

# Phase 1 uses dangerous skip permissions plus bypassPermissions to avoid
# interactive prompts. Claude calls EnterPlanMode as its first action to
# enforce read-only until user approves via ExitPlanMode.

unalias __dx_claude 2>/dev/null; unfunction __dx_claude 2>/dev/null
__dx_claude() {
  dx_provider_claude "$@"
}

unalias __dx_provider_prompt 2>/dev/null; unfunction __dx_provider_prompt 2>/dev/null
__dx_provider_prompt() {
  dx_provider_prompt
}

unalias __dx_phase_message 2>/dev/null; unfunction __dx_phase_message 2>/dev/null
__dx_phase_message() {
  local step="$1"
  local raw_input="${2:-}"
  local workspace_mode="${3:-worktree}"
  local wt_dir="${4:-}"
  if [[ "$step" -eq 0 ]]; then
    printf '%s\n' "$DX_PHASE_0_MESSAGE"
  elif [[ "$step" -eq 1 ]]; then
    cat <<'EOF'
Phase 0 setup (branch rename, push, ticket status → In Progress, assignment) is already complete. Do NOT redo it unless you find it missing.

Call EnterPlanMode now. Then immediately invoke the dxplan skill using the Skill tool with skill: "dxplan" (or /dxplan if slash skills are the available interface). Do not fetch the ticket again, rename branches, update tracker status, explore the codebase, or draft the plan by hand outside the dxplan skill unless the skill explicitly instructs you to.

The dxplan skill writes the required Phase 1 lifecycle markers. After the user approves the plan via ExitPlanMode, follow the dxplan completion instructions, then stop once so the Dex Stop hook can audit the approved plan and advance to Phase 2 automatically. Do NOT tell the user to run /dximplement and do NOT wait for another prompt.
EOF
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

# Phase definitions (zsh arrays are 1-indexed, so index 1 = Phase 1).
# Phase 0 (Setup) bootstraps ticket state before planning begins; its constants
# live in the DX_PHASE_0_* variables and the __dx_phase_* helpers below, kept
# out of the 1-indexed arrays because zsh aliases arr[0] to arr[1]. Phases 1-6
# then run autonomously via `dx`. Phase 6 marks the PR ready, requests the
# configured reviewers, monitors CI/reviews, and closes the ticket.
DX_PHASE_NAMES=("Plan" "Implement" "Review" "Verify & Commit" "PR" "Complete")

DX_PHASE_PROMISES=(\
  "PHASE_1_COMPLETE" \
  "PHASE_2_COMPLETE" \
  "PHASE_3_COMPLETE" \
  "PHASE_4_COMPLETE" \
  "PHASE_5_COMPLETE" \
  "DEX_TICKET_COMPLETE" \
)

DX_PHASE_MESSAGES=(\
  "Call EnterPlanMode now, then immediately invoke the dxplan skill. Do not perform exploration or planning by hand outside dxplan unless the skill explicitly instructs you to. Ticket setup (branch rename, status update, assignment, push) was already done in Phase 0; if anything looks incomplete (status still Backlog/Todo, no assignee, branch not renamed/pushed), finish it before calling EnterPlanMode. After the user approves the plan via ExitPlanMode, write the Phase 1 approval marker and stop once so the Stop hook can audit the approved plan and advance to Phase 2 automatically. Do NOT tell the user to run /dximplement and do NOT wait for another prompt." \
  "The plan is approved. You MUST invoke the Skill tool with skill: \"dximplement\" to begin implementation. Do NOT implement ad-hoc — the skill enforces TDD and quality gates. For UI-affecting changes, Phase 2 must invoke dxuicapture before UI edits for baseline evidence, then capture after evidence and link the visual manifest/screenshots/videos/traces before stopping. SCOPE BOUNDARIES: implementation, testing, and UI capture evidence ONLY. Do NOT commit, push, create branches, or create PRs during this phase — those are handled by later phases. When done, stop — the audit loop will verify your work." \
  "Begin Phase 3: Review. Invoke the Skill tool with skill: \"dxreviewloop\" to run the adaptive clean-pass review loop. Each pass is a full review wave: compact context pack, deterministic checks, domain issue harvest, verifier pass, batch fixes, and targeted recheck. Small low-risk changes may use fewer clean passes; high-risk changes must escalate to thorough review. Only waves that find zero verified findings and apply zero fixes count as CLEAN. SCOPE BOUNDARIES: review and fix ONLY. Do NOT commit, push, create branches, or create PRs. When the review loop is successful, stop — the audit loop will verify." \
  "Invoke the Skill tool with skill: \"dxverify\" to run the quality pipeline (format, lint, typecheck, test). Fix any failures and re-run until all green. Then invoke skill: \"dxcommit\" to commit and push. SCOPE BOUNDARIES: verify and commit ONLY. Do NOT create PRs or modify implementation beyond fixing verify failures. When pushed, stop — the audit loop will verify." \
  "Invoke the Skill tool with skill: \"dxpr\" to generate the PR description, prepare any UI visual evidence handoff, create the draft PR, and attach the configured 'request' reviewers from dex.md § Reviewers. SCOPE BOUNDARIES: PR creation, description, and artifact handoff ONLY. Do NOT mark the PR ready for review (Phase 6 owns that), do NOT post @mention comments, do NOT modify implementation code. When done, stop — the audit loop will verify." \
  "Invoke the Skill tool with skill: \"dxcomplete\". Phase 6 follows the cycle-loop audit prompt: mark the PR ready, request reviewers from dex.md § Reviewers, post @mention comments for mention-type reviewers, launch /loop 5m /dxwatchpr, wait DEX_COMPLETE_WAIT_MINUTES per cycle, address CI failures and review comments via the PR watcher, re-request reviewers after each push, and close the ticket when CI is green and all reviewers have approved. If the bounded wait expires, pause with manual follow-up instructions. Stop — the audit loop will verify." \
)

# Audit prompt file basenames (must match prompts/phase-audits/ filenames)
DX_PHASE_AUDIT_FILES=("1-plan" "2-implement" "3-review-loop" "4-verify" "5-pr" "6-complete")

# Phase 0 (Setup) constants — kept out of the 1-indexed arrays to avoid zsh's
# arr[0]==arr[1] aliasing. Surfaced through the __dx_phase_* helpers below.
DX_PHASE_0_NAME="Setup"
DX_PHASE_0_PROMISE="PHASE_0_COMPLETE"
DX_PHASE_0_AUDIT_FILE="0-setup"
DX_PHASE_0_MIN_AUDITS="1"
DX_PHASE_0_TIMEOUT="0"
DX_PHASE_0_MESSAGE="Begin Phase 0: Setup. This phase runs in NORMAL mode (no plan mode) so you can write to git and the tracker. Follow prompts/ticket-instructions.md (printed at SessionStart) end to end before doing anything else: (a) read the ticket from the configured tracker, including comments; (b) check the assignee — if unassigned, assign to the authenticated user; if assigned to someone else, STOP and warn; (c) rename the lifecycle branch to the tracker's git branch name and push it (do NOT create a draft PR — Phase 5 owns that); (d) set ticket status to In Progress; (e) if the description is empty/unclear, draft acceptance criteria, present to the user, and update the ticket. If no tracker is configured, push the current lifecycle branch and proceed. SCOPE BOUNDARIES: ticket setup only — do NOT call EnterPlanMode, do NOT draft a plan, do NOT implement, do NOT commit source code, do NOT create a draft PR. When setup is complete, write the Phase 0 ready marker (\`dx_phase_ready_file\` for step 0) and stop once so the Stop hook can audit and advance to Phase 1 automatically. Do NOT tell the user to run /dxplan and do NOT wait for another prompt."

# __dx_phase_name <step>
# Display name for the given phase number. Centralises Phase 0 (kept out of
# DX_PHASE_NAMES) without forcing callers to special-case the array lookup.
__dx_phase_name() {
  case "$1" in
    0) printf '%s' "$DX_PHASE_0_NAME" ;;
    *) printf '%s' "${DX_PHASE_NAMES[$1]:-Unknown}" ;;
  esac
}

# __dx_phase_promise <step>
__dx_phase_promise() {
  case "$1" in
    0) printf '%s' "$DX_PHASE_0_PROMISE" ;;
    *) printf '%s' "${DX_PHASE_PROMISES[$1]:-DEX_TICKET_COMPLETE}" ;;
  esac
}

# __dx_phase_audit_basename <step>
__dx_phase_audit_basename() {
  case "$1" in
    0) printf '%s' "$DX_PHASE_0_AUDIT_FILE" ;;
    *) printf '%s' "${DX_PHASE_AUDIT_FILES[$1]:-}" ;;
  esac
}

# __dx_phase_min_audits <step>
# Respects DEX_PHASE_<step>_MIN_AUDITS env override; falls back to defaults.
__dx_phase_min_audits() {
  # shellcheck disable=SC2034  # used via zsh ${(P)env_name} indirect expansion below
  local step="$1" env_name value
  # shellcheck disable=SC2034
  env_name="DEX_PHASE_${step}_MIN_AUDITS"
  value="${(P)env_name:-}"
  if [[ -n "$value" ]]; then
    printf '%s' "$value"
    return
  fi
  case "$step" in
    0) printf '%s' "$DX_PHASE_0_MIN_AUDITS" ;;
    *) printf '%s' "${DX_PHASE_MIN_AUDITS[$step]:-1}" ;;
  esac
}

# Session timeout in seconds — single budget for the entire dx run (all phases).
# Default: 86400 (24 hours). Set to 0 to disable.
# Override: DEX_SESSION_TIMEOUT=14400 (4h)
DX_SESSION_TIMEOUT=86400

# Minimum audit iterations per phase before the Stop hook authorizes completion.
# Phase 2 (Implement) requires 1 pass (completeness check; deep review is Phase 3).
# Phase 3 (Review) uses /dxreviewloop; the audit verifies that loop's SUCCESS report.
# Phase 6 (Complete) wait windows are enforced inside the audit prompt; min 1 here.
# Other phases require 1 pass (the audit prompt must be followed at least once).
# Override: DEX_PHASE_2_MIN_AUDITS=5
# zsh 1-indexed: [1]=Plan, [2]=Implement, [3]=Review, [4]=Verify, [5]=PR, [6]=Complete
DX_PHASE_MIN_AUDITS=("1" "1" "1" "1" "1" "1")

# Review sub-loop configuration.
# Lifecycle Phase 3 uses the /dxreviewloop skill in the same Claude session.
# The standalone dxreviewloop shell command also uses these defaults.
# DX_REVIEW_PROFILE: auto|light|standard|thorough.
# Auto chooses a starting depth from diff size/risk; review waves may escalate.
# Override depth: DEX_REVIEW_PROFILE=thorough
# Override exact loop gates: DEX_REVIEW_CLEAN_PASSES=5 DEX_REVIEW_MAX_ITERATIONS=25
DX_REVIEW_PROFILE=auto
DX_REVIEW_LIGHT_CLEAN_PASSES=1
DX_REVIEW_STANDARD_CLEAN_PASSES=2
DX_REVIEW_THOROUGH_CLEAN_PASSES=3
DX_REVIEW_LIGHT_MAX_ITERATIONS=4
DX_REVIEW_STANDARD_MAX_ITERATIONS=6
DX_REVIEW_THOROUGH_MAX_ITERATIONS=10
# Backward-compatible fallback for callers that source these constants directly.
# shellcheck disable=SC2034
DX_REVIEW_CLEAN_PASSES=$DX_REVIEW_THOROUGH_CLEAN_PASSES
# shellcheck disable=SC2034
DX_REVIEW_MAX_ITERATIONS=$DX_REVIEW_THOROUGH_MAX_ITERATIONS

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

# __dx_write_state <file> <content>
# Atomic file write via temp+mv — crash-safe (same pattern as phase-loop.sh).
# On crash mid-write, the temp file is lost and the original is untouched.
__dx_write_state() {
  local file="$1" content="$2"
  mkdir -p "$(dirname "$file")"
  local tmp="${file}.tmp.$$"
  if ! printf '%s\n' "$content" >| "$tmp" || ! command mv -f "$tmp" "$file"; then
    command rm -f "$tmp" 2>/dev/null
    return 1
  fi
}

# __dx_phase_timeout <step>
# Resolve the effective timeout for a phase (seconds). Returns 0 to disable.
# Priority: DEX_PHASE_N_TIMEOUT > DEX_PHASE_TIMEOUT > DX_PHASE_TIMEOUTS[step]
__dx_phase_timeout() {
  local step="$1"
  # shellcheck disable=SC2034  # used via zsh ${(P)env_var} indirect expansion below
  local env_var="DEX_PHASE_${step}_TIMEOUT"
  if [[ -n "${(P)env_var:-}" ]]; then
    echo "${(P)env_var}"
  elif [[ -n "${DEX_PHASE_TIMEOUT:-}" ]]; then
    echo "$DEX_PHASE_TIMEOUT"
  else
    case "$step" in
      0) echo "$DX_PHASE_0_TIMEOUT" ;;
      *) echo "${DX_PHASE_TIMEOUTS[$step]:-0}" ;;
    esac
  fi
}

# __dx_review_profile_clean_passes <profile>
# Print the default consecutive CLEAN waves required for a review profile.
unalias __dx_review_profile_clean_passes 2>/dev/null; unfunction __dx_review_profile_clean_passes 2>/dev/null
__dx_review_profile_clean_passes() {
  case "$1" in
    light) echo "$DX_REVIEW_LIGHT_CLEAN_PASSES" ;;
    standard) echo "$DX_REVIEW_STANDARD_CLEAN_PASSES" ;;
    thorough) echo "$DX_REVIEW_THOROUGH_CLEAN_PASSES" ;;
    *) echo "$DX_REVIEW_THOROUGH_CLEAN_PASSES" ;;
  esac
}

# __dx_review_profile_max_iterations <profile>
# Print the default safety-net iteration count for a review profile.
unalias __dx_review_profile_max_iterations 2>/dev/null; unfunction __dx_review_profile_max_iterations 2>/dev/null
__dx_review_profile_max_iterations() {
  case "$1" in
    light) echo "$DX_REVIEW_LIGHT_MAX_ITERATIONS" ;;
    standard) echo "$DX_REVIEW_STANDARD_MAX_ITERATIONS" ;;
    thorough) echo "$DX_REVIEW_THOROUGH_MAX_ITERATIONS" ;;
    *) echo "$DX_REVIEW_THOROUGH_MAX_ITERATIONS" ;;
  esac
}

# __dx_review_is_doc_path <path>
# Return 0 when a changed path is documentation-only for review-depth purposes.
unalias __dx_review_is_doc_path 2>/dev/null; unfunction __dx_review_is_doc_path 2>/dev/null
__dx_review_is_doc_path() {
  case "$1" in
    README|README.*|CHANGELOG|CHANGELOG.*|LICENSE|LICENSE.*|docs/*|*.md|*.mdx|*.rst|*.txt)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

# __dx_review_is_high_risk_path <path>
# Return 0 when a changed path should start at thorough review.
unalias __dx_review_is_high_risk_path 2>/dev/null; unfunction __dx_review_is_high_risk_path 2>/dev/null
__dx_review_is_high_risk_path() {
  case "$1" in
    dx.sh|install.sh|bin/*|hooks/*|lib/*|settings.json|.github/workflows/*|Dockerfile|Dockerfile.*|docker-compose.*|compose.*|package-lock.json|pnpm-lock.yaml|yarn.lock|Cargo.lock|go.sum|*.lock)
      return 0 ;;
  esac

  case "$1" in
    *auth*|*Auth*|*security*|*Security*|*permission*|*Permission*|*guard*|*Guard*|*secret*|*Secret*|*payment*|*Payment*|*billing*|*Billing*|*migration*|*Migration*|*schema*|*Schema*)
      return 0 ;;
    *)
      return 1 ;;
  esac
}

# __dx_review_auto_profile <committed_ref>
# Choose a conservative starting review profile from the current diff.
unalias __dx_review_auto_profile 2>/dev/null; unfunction __dx_review_auto_profile 2>/dev/null
__dx_review_auto_profile() {
  local committed_ref="$1"
  local file_count=0 total_lines=0 docs_only=1 high_risk=0
  local file add del changed_path line_count

  while IFS= read -r file; do
    [[ -n "$file" ]] || continue
    file_count=$((file_count + 1))
    __dx_review_is_doc_path "$file" || docs_only=0
    __dx_review_is_high_risk_path "$file" && high_risk=1
  done < <(
    {
      [[ -n "$committed_ref" ]] && git diff "$committed_ref" --name-only 2>/dev/null
      git diff --cached --name-only 2>/dev/null
      git diff --name-only 2>/dev/null
      git ls-files --others --exclude-standard 2>/dev/null
    } | sort -u
  )

  while IFS=$'\t' read -r add del changed_path; do
    [[ -n "$changed_path" ]] || continue
    [[ "$add" =~ ^[0-9]+$ ]] || add=0
    [[ "$del" =~ ^[0-9]+$ ]] || del=0
    total_lines=$((total_lines + add + del))
  done < <(
    {
      [[ -n "$committed_ref" ]] && git diff "$committed_ref" --numstat 2>/dev/null
      git diff --cached --numstat 2>/dev/null
      git diff --numstat 2>/dev/null
      while IFS= read -r file; do
        [[ -f "$file" ]] || continue
        line_count=$(wc -l < "$file" 2>/dev/null | tr -d ' ')
        [[ "$line_count" =~ ^[0-9]+$ ]] || line_count=0
        printf '%s\t0\t%s\n' "$line_count" "$file"
      done < <(git ls-files --others --exclude-standard 2>/dev/null)
    }
  )

  if [[ "$file_count" -eq 0 ]]; then
    echo "standard"
  elif [[ "$docs_only" -eq 1 ]]; then
    echo "light"
  elif [[ "$high_risk" -eq 1 || "$file_count" -gt 8 || "$total_lines" -gt 400 ]]; then
    echo "thorough"
  elif [[ "$file_count" -le 2 && "$total_lines" -le 80 ]]; then
    echo "light"
  else
    echo "standard"
  fi
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

# __dx_active_in_place_phase_for_branch <branch>
# Prints the active phase number when a worktree-* branch belongs to an
# in-place lifecycle that is still resumable. Returns non-zero otherwise.
__dx_active_in_place_phase_for_branch() {
  local branch="$1" wt_name phase_val

  if [[ "$branch" == worktree-ticket-* ]] || [[ "$branch" == worktree-task-* ]]; then
    wt_name="${branch#worktree-}"
    if phase_val=$(__dx_active_in_place_phase_for_workspace "$wt_name" "$branch"); then
      printf '%s\n' "$phase_val"
      return 0
    fi
  fi

  local repo_key phase_path candidate_session candidate_branch_file candidate_branch
  repo_key=$(dx_session_repo_key)
  [[ -d "$DX_STATE_DIR" ]] || return 1

  while IFS= read -r phase_path; do
    [[ -n "$phase_path" && -f "$phase_path" ]] || continue
    candidate_session="$(basename "$phase_path" .phase)"
    candidate_branch_file=$(dx_branch_file "$candidate_session")
    [[ -f "$candidate_branch_file" ]] || continue
    candidate_branch=$(cat "$candidate_branch_file" 2>/dev/null || echo "")
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
__dx_active_in_place_phase_for_workspace() {
  local wt_name="$1" expected_branch="${2:-}" session_id phase_file phase_val branch_file session_branch=""

  session_id=$(__dx_session_id_for_workspace "in-place" "$wt_name")
  phase_file=$(dx_state_file "$session_id")
  [[ -f "$phase_file" ]] || return 1

  phase_val=$(cat "$phase_file" 2>/dev/null || echo "")
  [[ "$phase_val" =~ ^[0-6]$ ]] || return 1

  branch_file=$(dx_branch_file "$session_id")
  if [[ -f "$branch_file" ]]; then
    session_branch=$(cat "$branch_file" 2>/dev/null || echo "")
    [[ -z "$expected_branch" || -z "$session_branch" || "$session_branch" == "$expected_branch" ]] || return 1
    [[ -z "$session_branch" ]] || git show-ref --verify --quiet "refs/heads/${session_branch}" 2>/dev/null || return 1
  else
    local canonical_branch="worktree-${wt_name}"
    git show-ref --verify --quiet "refs/heads/${canonical_branch}" 2>/dev/null || return 1
  fi

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
  local ticket="$1" record session_id wt_name wt_dir workspace_mode
  [[ -n "$ticket" ]] || return 1

  record=$(dx_meta_find_workspace_by_ticket "$ticket") || return 1
  [[ -n "$record" ]] || return 1

  session_id="${record%%$'\t'*}"
  record="${record#*$'\t'}"
  wt_name="${record%%$'\t'*}"
  record="${record#*$'\t'}"
  wt_dir="${record%%$'\t'*}"
  workspace_mode="${record#*$'\t'}"

  _dx_wt_name="$wt_name"
  _dx_wt_dir="$wt_dir"
  _dx_workspace_mode="${workspace_mode:-worktree}"
  _dx_session_id="$session_id"
  _dx_is_task=0
  [[ "$wt_name" == task-* ]] && _dx_is_task=1
  return 0
}

# __dx_setup_worktree <raw_input>
# Sets: _dx_wt_name, _dx_wt_dir, _dx_is_task, _dx_repo_root, _dx_default_branch,
# _dx_workspace_mode, _dx_session_id.
# Returns 0 if worktree exists or was created, 1 on error.
# See: docs/autonomous-mode.md for the full lifecycle that follows worktree creation.
unalias __dx_setup_worktree 2>/dev/null; unfunction __dx_setup_worktree 2>/dev/null
__dx_setup_worktree() {
  local raw_input="$1"

  _dx_repo_root=$(dx_repo_root) || return 1
  __dx_resolve_workspace_name "$raw_input" || return 1

  _dx_wt_dir="${_dx_repo_root}/.dex/worktrees/${_dx_wt_name}"
  _dx_default_branch=$(dx_default_branch)
  _dx_workspace_mode="worktree"
  _dx_session_id=$(__dx_session_id_for_workspace "$_dx_workspace_mode" "$_dx_wt_name")

  # If worktree exists, ensure links are set up (retroactive fix) and return
  if [[ -d "$_dx_wt_dir" ]]; then
    dx_link_claude_to_worktree "$_dx_repo_root" "$_dx_wt_dir"
    dx_record_session_branch "$_dx_session_id" "$_dx_wt_dir"
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
    if [[ -n "$ticket_number" ]] && __dx_resolve_existing_workspace_by_ticket "$ticket_number"; then
      if [[ "$_dx_workspace_mode" == "worktree" ]]; then
        dx_link_claude_to_worktree "$_dx_repo_root" "$_dx_wt_dir"
      fi
      _dx_default_branch=$(dx_default_branch "$_dx_wt_dir")
      dx_record_session_branch "$_dx_session_id" "$_dx_wt_dir"
      dx_meta_write "$_dx_session_id" "ticket_number=${ticket_number}"
      dx_info "Resuming existing workspace ${_dx_wt_name} for ticket ${ticket_number}"
      return 0
    fi
  fi

  # Auto-init if .dex doesn't exist yet
  if [[ ! -d "${_dx_repo_root}/.dex" ]]; then
    echo "Auto-initialising Dex for this repo..."
    bash "$DEX_DIR/bin/init.sh" --skip-analysis --skip-config
  fi

  # Create worktree
  echo "Creating worktree ${_dx_wt_name}..."
  git fetch origin "$_dx_default_branch" --quiet 2>/dev/null || true
  mkdir -p "${_dx_repo_root}/.dex/worktrees"

  if ! git worktree add --no-track "$_dx_wt_dir" -b "worktree-${_dx_wt_name}" "origin/${_dx_default_branch}" 2>&1; then
    dx_error "Failed to create worktree."
    return 1
  fi

  # Share .claude/ config and MCP auth with main repo
  dx_link_claude_to_worktree "$_dx_repo_root" "$_dx_wt_dir"
  dx_record_session_branch "$_dx_session_id" "$_dx_wt_dir"
  dx_meta_write "$_dx_session_id" "wt_name=${_dx_wt_name}" "wt_dir=${_dx_wt_dir}" "workspace_mode=worktree" "raw_input=${raw_input}" "original_branch=worktree-${_dx_wt_name}"
  [[ $_dx_is_task -eq 0 ]] && dx_meta_write "$_dx_session_id" "ticket_number=${_dx_wt_name#ticket-}"

  return 0
}

# __dx_restore_in_place_session_branch <session_id> <workspace_name> <workspace_dir> <resume_command>
# In-place sessions share the user's checkout, so make sure resume continues on
# the lifecycle branch recorded for this session.
__dx_restore_in_place_session_branch() {
  local session_id="$1" wt_name="$2" wt_dir="$3" resume_command="$4"
  local current_branch has_changes session_branch="" canonical_branch

  current_branch=$(git -C "$wt_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")
  has_changes=0
  git -C "$wt_dir" status --porcelain 2>/dev/null | head -1 | grep -q . && has_changes=1

  [[ -f "$(dx_branch_file "$session_id")" ]] && session_branch=$(cat "$(dx_branch_file "$session_id")" 2>/dev/null || echo "")
  canonical_branch="worktree-${wt_name}"
  if [[ -z "$session_branch" && "$current_branch" != "$canonical_branch" ]] && git -C "$wt_dir" show-ref --verify --quiet "refs/heads/${canonical_branch}" 2>/dev/null; then
    session_branch="$canonical_branch"
  fi
  if [[ -n "$session_branch" && "$current_branch" != "$session_branch" ]]; then
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

  dx_record_session_branch "$session_id" "$wt_dir"
}

# __dx_setup_in_place <raw_input>
# Sets the same workspace variables as __dx_setup_worktree, but points them at
# the current checkout and creates/switches the normal Dex branch there.
__dx_setup_in_place() {
  local raw_input="$1"

  _dx_repo_root=$(git rev-parse --show-toplevel 2>/dev/null || echo "")
  if [[ -z "$_dx_repo_root" ]]; then
    dx_error "Not in a git repository."
    return 1
  fi
  __dx_resolve_workspace_name "$raw_input" || return 1

  _dx_wt_dir="$_dx_repo_root"
  _dx_default_branch=$(dx_default_branch "$_dx_wt_dir")
  _dx_workspace_mode="in-place"
  _dx_session_id=$(__dx_session_id_for_workspace "$_dx_workspace_mode" "$_dx_wt_name")
  local branch_name="worktree-${_dx_wt_name}"

  dx_info "Running lifecycle in current checkout (no worktree): ${_dx_wt_dir}"

  git -C "$_dx_wt_dir" fetch origin "$_dx_default_branch" --quiet 2>/dev/null || true

  local current_branch has_changes
  current_branch=$(git -C "$_dx_wt_dir" rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")
  has_changes=0
  git -C "$_dx_wt_dir" status --porcelain 2>/dev/null | head -1 | grep -q . && has_changes=1

  if [[ -f "$(dx_state_file "$_dx_session_id")" ]]; then
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
    if [[ -n "$_ticket_number" ]] && __dx_resolve_existing_workspace_by_ticket "$_ticket_number"; then
      if [[ "$_dx_workspace_mode" == "worktree" ]]; then
        dx_link_claude_to_worktree "$_dx_repo_root" "$_dx_wt_dir"
      fi
      _dx_default_branch=$(dx_default_branch "$_dx_wt_dir")
      dx_record_session_branch "$_dx_session_id" "$_dx_wt_dir"
      dx_meta_write "$_dx_session_id" "ticket_number=${_ticket_number}"
      dx_info "Resuming existing workspace ${_dx_wt_name} for ticket ${_ticket_number}"
      return 0
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
      dx_error "Cannot create branch ${branch_name} from origin/${_dx_default_branch} with uncommitted changes in the current checkout."
      dx_info "Commit, stash, or discard those changes, then re-run: dx --no-worktree ${raw_input}"
      return 1
    fi
    dx_info "Creating branch ${branch_name} from origin/${_dx_default_branch}"
    if ! git -C "$_dx_wt_dir" switch --no-track -c "$branch_name" "origin/${_dx_default_branch}"; then
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

  dx_record_session_branch "$_dx_session_id" "$_dx_wt_dir"
  dx_meta_write "$_dx_session_id" "wt_name=${_dx_wt_name}" "wt_dir=${_dx_wt_dir}" "workspace_mode=in-place" "raw_input=${raw_input}" "original_branch=${branch_name}"
  [[ $_dx_is_task -eq 0 ]] && dx_meta_write "$_dx_session_id" "ticket_number=${_dx_wt_name#ticket-}"
  return 0
}

# dx_session_id is provided by lib/session.sh (sourced via lib/common.sh)

# __dx_build_system_context <wt_name> <step> <session_id> <wt_dir> [workspace_mode] [raw_input]
# Write a system prompt context file that persists across conversation compaction.
# Returns the file path on stdout. The file is passed to --append-system-prompt-file
# so Claude always knows which phase it is in, even after compaction.
__dx_build_system_context() {
  local wt_name="$1" step="$2" session_id="$3" wt_dir="$4"
  local workspace_mode="${5:-worktree}" raw_input="${6:-}"
  local ctx_file
  ctx_file=$(dx_context_file "$session_id")
  mkdir -p "$(dirname "$ctx_file")"

  # Build phase-specific scope boundaries
  local scope_lines=""
  case $step in
    0) scope_lines="- DO read the ticket, assign it to the authenticated user (if unassigned), rename the lifecycle branch to the tracker's git branch name, push the renamed branch, and set ticket status to In Progress
- DO operate in NORMAL mode — do NOT call EnterPlanMode in this phase
- Do NOT draft a plan, implement code, commit source changes, or create a draft PR
- DO write the Phase 0 ready marker (dx_phase_ready_file step 0) when setup is complete, then stop" ;;
    1) scope_lines="- DO invoke the dxplan skill immediately after entering Plan Mode
- Phase 0 already handled branch rename and ticket setup; do not redo them unless the markers are missing
- Do NOT explore code or draft a plan by hand outside dxplan unless the skill explicitly instructs you to
- DO wait for explicit user approval via ExitPlanMode before marking Phase 1 ready" ;;
    2) scope_lines="- Do NOT commit, push, create PRs, or modify git history
- DO implement, test, and verify completeness via the Skill tool" ;;
    3) scope_lines="- Do NOT commit, push, create PRs, or modify git history
- DO run /dxreviewloop, fix all findings, and reach a SUCCESS result" ;;
    4) scope_lines="- Do NOT create PRs or modify implementation beyond fixing verify failures
- DO run format/lint/typecheck/test, fix failures, commit, push" ;;
    5) scope_lines="- Do NOT mark the PR ready for review (that is Phase 6)
- Do NOT post @mention comments yet (those happen at Phase 6)
- DO create the draft PR, write the description, attach 'request' reviewers from dex.md § Reviewers" ;;
    6) scope_lines="- Do NOT modify implementation code unless fixing CI/review failures
- DO mark the PR ready, request reviewers (request type), post @mention comment (mention type),
- DO launch /loop 5m /dxwatchpr, address CI/review failures, close ticket only when checks and approvals are green" ;;
  esac

  local phase_label
  phase_label=$(__dx_phase_name "$step")
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
- Phase 3 must use /dxreviewloop for the adaptive clean-pass review loop.

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

# __dx_configure_inline_phase <step> <session_id>
# Prepare the Stop hook to audit the current phase and advance inline.
__dx_configure_inline_phase() {
  local step="$1" session_id="$2" audit_file min_audits promise
  audit_file=$(__dx_inline_audit_file "$step")
  mkdir -p "$DX_LOOP_DIR"
  touch "$(dx_active_file "$session_id")"
  printf '%s\n' "inline" > "$(dx_handoff_mode_file "$session_id")"
  rm -f "$(dx_complete_file "$session_id")" "$(dx_loop_file "$session_id")" "$(dx_findings_file "$session_id")" "$(dx_paused_file "$session_id")" "$(dx_watch_pause_file "$session_id")"

  min_audits=$(__dx_phase_min_audits "$step")
  promise=$(__dx_phase_promise "$step")
  __dx_write_state "$(dx_loop_config_file "$session_id")" "${step}:${promise}:${audit_file}:${min_audits}"
}

# __dx_run_phases_inline <wt_name> <wt_dir> <default_branch> <start_step> <state_file> <times_file> <resume_hint> [workspace_mode] [session_id] [raw_input]
#
# Same-session lifecycle runner. The shell launches Claude once; the Stop hook
# advances phases by updating state/config files and injecting the next phase's
# instructions back into the existing session. This avoids the Claude TUI
# handoff problem where a completed phase leaves the user needing /exit + resume.
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

__dx_run_phases_inline() {
  local wt_name="$1" wt_dir="$2" default_branch="$3" step="$4"
  local state_file="$5" times_file="$6" resume_hint="$7"
  local workspace_mode="${8:-worktree}"
  local session_id="${9:-}" raw_input="${10:-}"
  local claude_session_name
  claude_session_name=$(__dx_claude_session_name "$workspace_mode" "$wt_name")

  if ! command -v claude &>/dev/null; then
    dx_error "Claude Code CLI not found in PATH."
    dx_info "Install it from https://docs.anthropic.com/en/docs/claude-code then try again."
    return 1
  fi

  [[ -n "$session_id" ]] || session_id=$(__dx_session_id_for_workspace "$workspace_mode" "$wt_name")

  local had_times_file=0
  [[ -f "$times_file" ]] && had_times_file=1

  __dx_show_header "$wt_name" "$step" "$wt_dir" "$default_branch" "$session_id" "$workspace_mode"
  dx_record_session_branch "$session_id" "$wt_dir"
  __dx_write_state "$state_file" "$step"
  __dx_configure_inline_phase "$step" "$session_id"

  if [[ $step -ge 2 ]]; then
    dx_checkpoint_tag "$step" "$wt_dir"
  fi

  local phase_start_epoch
  phase_start_epoch=$(date +%s)
  mkdir -p "$(dirname "$times_file")"
  echo "${step}:${phase_start_epoch}" >> "$times_file"

  local ctx_file
  ctx_file=$(__dx_build_system_context "$wt_name" "$step" "$session_id" "$wt_dir" "$workspace_mode" "$raw_input")

  local claude_args=("${DX_CLAUDE_FLAGS[@]}" -n "$claude_session_name")
  [[ $had_times_file -eq 1 ]] && claude_args+=(--resume)
  claude_args+=(--append-system-prompt-file "$ctx_file")
  claude_args+=(--settings "{\"statusLine\":{\"type\":\"command\",\"command\":\"bash '${DEX_DIR}/bin/status-line.sh'\"}}")

  local message
  message=$(__dx_phase_message "$step" "$raw_input" "$workspace_mode" "$wt_dir")
  if [[ $step -eq 3 ]]; then
    message="Begin Phase 3: Review. Invoke the Skill tool with skill: \"dxreviewloop\" to run the adaptive clean-pass review loop. Each pass is a full review wave: compact context pack, deterministic checks, domain issue harvest, verifier pass, batch fixes, and targeted recheck. Small low-risk changes may use fewer clean passes; high-risk changes must escalate to thorough review. Only waves that find zero verified findings and apply zero fixes count as CLEAN. Scope boundaries: review and fix only; do not commit, push, create branches, or create PRs. When the review loop is successful, stop so the Stop hook can audit and advance."
  fi

  local session_timeout="${DEX_SESSION_TIMEOUT:-$DX_SESSION_TIMEOUT}"
  local _dx_watchdog_pid="" _dx_pidfile=""
  _dx_pidfile=$(mktemp "${TMPDIR:-/tmp}/dx-inline.XXXXXX")

  if [[ "$session_timeout" -gt 0 ]]; then
    (
      local tgt=""
      while [[ -z "$tgt" ]]; do
        [[ -s "$_dx_pidfile" ]] && tgt=$(<"$_dx_pidfile")
        [[ -z "$tgt" ]] && sleep 0.2
      done
      sleep "$session_timeout" 2>/dev/null
      __dx_kill_process_tree "$tgt" TERM
      sleep 2
      __dx_kill_process_tree "$tgt" KILL
    ) &
    _dx_watchdog_pid=$!
  fi

  (
    sh -c 'echo $PPID' > "$_dx_pidfile"
    cd "$wt_dir" && \
    DEX_SESSION_ID="$session_id" \
    DEX_LOOP_ACTIVE=1 \
    DEX_LOOP_PROMISE="${DX_PHASE_PROMISES[$step]}" \
    DEX_LOOP_PHASE="$step" \
    DEX_PHASE_HANDOFF=inline \
    DEX_COMPLETE_MAX_CYCLES="${DEX_COMPLETE_MAX_CYCLES:-$DX_COMPLETE_MAX_CYCLES}" \
    DEX_COMPLETE_WAIT_MINUTES="${DEX_COMPLETE_WAIT_MINUTES:-$DX_COMPLETE_WAIT_MINUTES}" \
    DEX_DIR="$DEX_DIR" \
    __dx_claude "${claude_args[@]}" "$message"
  )
  local exit_code=$?
  rm -f "$_dx_pidfile"
  [[ -n "$_dx_watchdog_pid" ]] && kill "$_dx_watchdog_pid" 2>/dev/null

  local final_step="$step"
  [[ -f "$state_file" ]] && final_step=$(cat "$state_file" 2>/dev/null || echo "$step")
  [[ "$final_step" =~ ^[0-7]$ ]] || final_step="$step"

  local paused_file
  paused_file=$(dx_paused_file "$session_id")
  if [[ -f "$paused_file" ]]; then
    rm -f \
      "$(dx_active_file "$session_id")" \
      "$(dx_loop_config_file "$session_id")" \
      "$(dx_loop_file "$session_id")" \
      "$(dx_handoff_mode_file "$session_id")" \
      "$paused_file" 2>/dev/null
    dx_provider_cleanup_session_state "$session_id"

    echo ""
    echo "Paused at Phase ${final_step}: $(__dx_phase_name "$final_step") (manual intervention requested)"
    echo "Resume with: ${resume_hint}"
    return 1
  fi

  local loop_file
  loop_file=$(dx_loop_file "$session_id")
  if [[ "$final_step" -lt 7 && -f "$loop_file" ]]; then
    local raw_iter iterations max_iterations pause_reason
    raw_iter=$(cat "$loop_file" 2>/dev/null || echo "0")
    iterations="${raw_iter%%:*}"
    [[ "$iterations" =~ ^[0-9]+$ ]] || iterations=0
    max_iterations="${DEX_LOOP_MAX_ITERATIONS:-30}"
    pause_reason="phase did not complete"
    if [[ "$iterations" -ge "$max_iterations" ]]; then
      pause_reason="max audit iterations reached (${iterations}/${max_iterations})"
    fi

    rm -f "$loop_file" "$(dx_active_file "$session_id")" "$(dx_loop_config_file "$session_id")" "$(dx_handoff_mode_file "$session_id")" "$(dx_paused_file "$session_id")" 2>/dev/null
    dx_provider_cleanup_session_state "$session_id"

    echo ""
    echo "Paused at Phase ${final_step}: $(__dx_phase_name "$final_step") (${pause_reason})"
    echo "Resume with: ${resume_hint}"
    return 1
  fi

	  if [[ "$final_step" -ge 7 ]]; then
	    dx_provider_cleanup_session_state "$session_id"
	    rm -f "$(dx_active_file "$session_id")" "$(dx_loop_config_file "$session_id")" "$(dx_handoff_mode_file "$session_id")" 2>/dev/null
	    __dx_show_header "$wt_name" 7 "$wt_dir" "$default_branch" "$session_id" "$workspace_mode"
	    echo ""
	    echo "Ticket lifecycle complete."
	    __dx_cleanup_completed_workspace "$wt_name" "$wt_dir" "$default_branch" "$workspace_mode" "$session_id"
	    return $?
	  fi

  if [[ $exit_code -ne 0 ]]; then
    echo ""
    echo "Paused at Phase ${final_step}: $(__dx_phase_name "$final_step") (exit ${exit_code})"
    echo "Resume with: ${resume_hint}"
    return "$exit_code"
  fi

  echo ""
  echo "Claude session exited at Phase ${final_step}: $(__dx_phase_name "$final_step")."
  echo "Resume with: ${resume_hint}"
  return 0
}

# __dx_run_phases <wt_name> <wt_dir> <default_branch> <start_step> <state_file> <times_file> <resume_hint> [workspace_mode] [session_id] [raw_input]
#
# Phase lifecycle entrypoint. Launches one Claude session and lets the Stop hook
# advance phases inline.
# Phase 6 (Complete) is autonomous: it marks the PR ready, requests configured
# reviewers (see dex.md § Reviewers), monitors CI/reviews, addresses comments,
# and closes the ticket. The user is in the loop only as a configured reviewer.
# Returns non-zero if user interrupts or an error occurs.
__dx_run_phases() {
  __dx_run_phases_inline "$@"
}

# __dx_format_elapsed <seconds>
# Format seconds as "Xm Ys"
__dx_format_elapsed() {
  local secs=$1
  if [[ $secs -lt 60 ]]; then
    echo "${secs}s"
  else
    echo "$((secs / 60))m $((secs % 60))s"
  fi
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
  local i label
  for i in 0 1 2 3 4 5 6; do
    label=$(__dx_phase_name "$i")
    if [[ $i -lt $step ]]; then
      progress+="✓ ${label}"
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
      timing+="  Phase ${prev_step} took $(__dx_format_elapsed $phase_elapsed)"
    fi
    if [[ -n "$total_start" ]]; then
      total_elapsed=$((now - total_start))
      timing+=" | Total: $(__dx_format_elapsed $total_elapsed)"
    fi
    [[ -n "$timing" ]] && echo "$timing"
  fi

  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""
}

# ─── dx — phased lifecycle wrapper ──────────────────────────────────────────

unalias dx 2>/dev/null; unfunction dx 2>/dev/null
dx() {
  if [[ $# -eq 0 ]]; then
    echo "Usage: dx <NUMBER>        (e.g. dx 999, dx ENG-999)"
    echo "       dx \"<description>\" (e.g. dx \"fix login bug\")"
    echo "       dx --no-worktree <task>"
    echo "       dx --resume        Resume the most recent session"
    echo "       dx --from-pr <N>   Resume session linked to a PR"
    echo "       dx refine <N|description>  Refine a ticket before implementation"
    echo ""
    echo "       dx init|sync|rename|maintain|tools|config|research|install|uninstall|uninit|status|reload|help"
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
    echo "Usage: dx --no-worktree <NUMBER|description>"
    return 1
  fi

  # Refine subcommand — intercept before worktree setup (read-only flow)
  if [[ "$1" == "refine" ]]; then
    shift
    dxrefine "$@"
    return $?
  fi

  # Route management subcommands to the internal Dex dispatcher.
  case "$1" in
    init|sync|rename|maintain|tools|config|provider|research|install|uninstall|uninit|status|reload|help|--help|-h|revert|log)
      __dx_cli "$@"
      return $?
      ;;
  esac

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
    if [[ ! -d "$_dx_wt_dir" ]]; then
      if [[ "$_dx_workspace_mode" == "in-place" ]]; then
        dx_error "Checkout for in-place session ${_dx_wt_name} no longer exists."
      else
        dx_error "Worktree ${_dx_wt_name} no longer exists."
      fi
      rm -f "$last_session_file"
      return 1
    fi

    # Validate workspace git state
    if ! git -C "$_dx_wt_dir" rev-parse --git-dir &>/dev/null; then
      dx_error "Workspace ${_dx_wt_name} has corrupted git state."
      if [[ "$_dx_workspace_mode" == "worktree" ]]; then
        dx_info "Run dxrm ${_dx_wt_name} and start fresh."
      fi
      return 1
    fi

    if [[ "$_dx_workspace_mode" == "in-place" ]]; then
      __dx_restore_in_place_session_branch "$_dx_session_id" "$_dx_wt_name" "$_dx_wt_dir" "dx --resume" || return 1
    else
      dx_record_session_branch "$_dx_session_id" "$_dx_wt_dir"
    fi

    # Reconstruct the original request for resume prompts. Freeform task
    # sessions persist the human-readable prompt; ticket sessions fall back to
    # the stable workspace name.
    local session_id state_file times_file
    session_id="$_dx_session_id"
    state_file=$(dx_state_file "$session_id")
    times_file=$(dx_times_file "$session_id")
    local raw_input="$_dx_wt_name"
    local prompt_file
    prompt_file=$(dx_prompt_file "$session_id")
    if [[ -s "$prompt_file" ]]; then
      raw_input=$(cat "$prompt_file" 2>/dev/null || echo "$raw_input")
    fi
    _dx_default_branch=$(dx_default_branch "$_dx_wt_dir")

    # Fall through to the phase loop below. Default to Phase 0 (Setup) for a
    # brand-new session; existing sessions keep whatever phase state recorded.
    local step=0
    [[ -f "$state_file" ]] && step=$(cat "$state_file" 2>/dev/null)
    [[ "$step" =~ ^[0-7]$ ]] || step=0

    if [[ $step -gt 6 ]]; then
      echo "Ticket lifecycle already complete for ${_dx_wt_name}."
	    if [[ "$_dx_workspace_mode" == "worktree" ]]; then
	      echo "Local cleanup should already be complete. If files remain, run dxrm ${_dx_wt_name}."
	    else
	      echo "This lifecycle ran in the current checkout; local branch cleanup is handled at completion when safe."
      fi
      return 0
    fi

    echo "Resuming ${_dx_wt_name} from Phase ${step}: $(__dx_phase_name "$step")..."

    cd "$_dx_wt_dir" 2>/dev/null || return 1
    __dx_run_phases "$_dx_wt_name" "$_dx_wt_dir" "$_dx_default_branch" "$step" "$state_file" "$times_file" "dx --resume" "$_dx_workspace_mode" "$session_id" "$raw_input"
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
  if [[ -f "$state_file" ]]; then
    step=$(cat "$state_file" 2>/dev/null)
    [[ "$step" =~ ^[0-7]$ ]] || step=0
  fi

	  if [[ $step -gt 6 ]]; then
	    echo "Ticket lifecycle already complete for ${_dx_wt_name}."
	    if [[ "$_dx_workspace_mode" == "worktree" ]]; then
	      echo "Local cleanup should already be complete. If files remain, run dxrm ${raw_input}."
	    else
	      echo "This lifecycle ran in the current checkout; local branch cleanup is handled at completion when safe."
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
  cd "$_dx_wt_dir" 2>/dev/null || return 1
  __dx_run_phases "$_dx_wt_name" "$_dx_wt_dir" "$_dx_default_branch" "$step" "$state_file" "$times_file" "$resume_hint" "$_dx_workspace_mode" "$session_id" "$raw_input"
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

unalias dxloop 2>/dev/null; unfunction dxloop 2>/dev/null
dxloop() {
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

  if ! command -v claude &>/dev/null; then
    dx_error "Claude Code CLI not found in PATH."
    dx_info "Install it from https://docs.anthropic.com/en/docs/claude-code then try again."
    return 1
  fi

  # Validate we're in a git repo (needed for session ID derivation)
  local repo_root
  repo_root=$(dx_repo_root) || return 1

  # Derive a unique session ID so concurrent dxloops on the same branch don't collide
  local session_id
  session_id=$(dx_unique_session_id)

  # Remove any loop files that happen to share this unique session ID (harmless
  # no-op in practice since each dxloop gets a fresh ID via dx_unique_session_id).
  dx_provider_cleanup_session_state "$session_id"
  rm -f "$(dx_loop_file "$session_id")" "$(dx_complete_file "$session_id")" "$(dx_active_file "$session_id")"

  # Persist the original prompt so the Stop hook can re-inject it on each audit
  # iteration. Context compaction may lose the initial message after several rounds.
  local prompt_file
  prompt_file="$(dx_prompt_file "$session_id")"
  mkdir -p "$(dirname "$prompt_file")"
  printf '%s\n' "$prompt" > "$prompt_file"

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
  local plan_args=("${DX_PLAN_FLAGS[@]}")
  [[ -n "$session_name" ]] && plan_args+=(-n "$session_name")
  plan_args+=(--append-system-prompt "You are in a dxloop planning session. You MUST be in plan mode — if not, call EnterPlanMode immediately. Your original task prompt is saved at ${prompt_file}. Re-read it with the Read tool if you lose track of the task. After ExitPlanMode is approved, stop this Claude Code session immediately so the dxloop wrapper can launch implementation. Do NOT ask whether to continue and do NOT wait for another user prompt. The Stop hook handles the process handoff back to dxloop.")

  local plan_audit_file="$DEX_DIR/prompts/phase-audits/1-plan.md"
  mkdir -p "$DX_LOOP_DIR"
  touch "$(dx_active_file "$session_id")"
  rm -f "$(dx_complete_file "$session_id")" "$(dx_loop_file "$session_id")" "$(dx_findings_file "$session_id")"
  __dx_write_state "$(dx_loop_config_file "$session_id")" "1:PHASE_1_COMPLETE:${plan_audit_file}:1"

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
  local plan_status="advance"
  if [[ $plan_exit -eq 0 ]] && [[ -f "$(dx_loop_file "$session_id")" ]]; then
    plan_status="max-iter"
    plan_exit=1
  fi
  rm -f "$(dx_active_file "$session_id")" "$(dx_loop_config_file "$session_id")" "$(dx_loop_file "$session_id")" 2>/dev/null
  if [[ $plan_exit -ne 0 ]]; then
    rm -f "$(dx_loop_file "$session_id")" \
          "$(dx_complete_file "$session_id")" \
          "$(dx_active_file "$session_id")" \
          "$(dx_prompt_file "$session_id")" 2>/dev/null
    dx_provider_cleanup_session_state "$session_id"
    echo ""
    if [[ "$plan_status" == "max-iter" ]]; then
      dx_info "dxloop paused during planning: max audit iterations reached without completion."
    else
      dx_info "dxloop interrupted during planning (exit code: $plan_exit)."
    fi
    return $plan_exit
  fi

  # ── Session 2: Implement ──
  # Autonomous mode with stop hook audit loop. Resumes the plan session.
  local impl_args=("${DX_CLAUDE_FLAGS[@]}" --resume)
  [[ -n "$session_name" ]] && impl_args+=(-n "$session_name")
  impl_args+=(--append-system-prompt "You are in a dxloop session. Your original task prompt is saved at ${prompt_file}. Re-read it with the Read tool before any audit step, or when you lose track of what you are working on.")

  dx_info "Phase: Implement (autonomous)"
  DEX_SESSION_ID="$session_id" \
  DEX_LOOP_ACTIVE=1 \
  DEX_LOOP_PROMISE="PROMPT_COMPLETE" \
  DEX_LOOP_PHASE="prompt-loop" \
  DEX_DIR="$DEX_DIR" \
  __dx_claude "${impl_args[@]}" "The plan is approved. Implement it now. Work through all tasks, following TDD where the project has tests. The stop hook audit will guide you through quality verification and final review when you are done.
$(__dx_provider_prompt)"

  local exit_code=$?
  local loop_status="advance"
  if [[ $exit_code -eq 0 ]] && [[ -f "$(dx_loop_file "$session_id")" ]]; then
    loop_status="max-iter"
    exit_code=1
  fi

  # Clean up state files
  rm -f "$(dx_loop_file "$session_id")" \
        "$(dx_complete_file "$session_id")" \
        "$(dx_active_file "$session_id")" \
        "$(dx_prompt_file "$session_id")" 2>/dev/null
  dx_provider_cleanup_session_state "$session_id"

  if [[ $exit_code -eq 0 ]]; then
    echo ""
    dx_done "dxloop complete."
  else
    echo ""
    if [[ "$loop_status" == "max-iter" ]]; then
      dx_info "dxloop paused: max audit iterations reached without completion."
    else
      dx_info "dxloop interrupted (exit code: $exit_code)."
    fi
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
  __dx_refresh_provider || return 1

  if [[ $# -eq 0 ]]; then
    echo "Usage: dxrefine <NUMBER>           (e.g. dxrefine 123, dxrefine ENG-123)"
    echo "       dxrefine \"<description>\"    (e.g. dxrefine \"streaming export pipeline\")"
    return 1
  fi

  if ! command -v claude &>/dev/null; then
    dx_error "Claude Code CLI not found in PATH."
    dx_info "Install it from https://docs.anthropic.com/en/docs/claude-code then try again."
    return 1
  fi

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
  __dx_refresh_provider || return 1

  if ! command -v claude &>/dev/null; then
    dx_error "Claude Code CLI not found in PATH."
    dx_info "Install it from https://docs.anthropic.com/en/docs/claude-code then try again."
    return 1
  fi

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

  # Use a session ID derived from the current location (worktree-aware via dx_session_id)
  local session_id start_dir cleanup_repo_root cleanup_default_branch cleanup_mode="" cleanup_wt_name="" cleanup_wt_dir=""
  session_id=$(dx_session_id)
  start_dir=$(pwd)
  cleanup_repo_root=$(dx_repo_root 2>/dev/null || echo "")
  cleanup_default_branch=$(dx_default_branch "$start_dir")
  if [[ -n "$cleanup_repo_root" && "$start_dir" == "${cleanup_repo_root}/.dex/worktrees/"* ]]; then
    cleanup_mode="worktree"
    cleanup_wt_name="${start_dir#"${cleanup_repo_root}/.dex/worktrees/"}"
    cleanup_wt_name="${cleanup_wt_name%%/*}"
    cleanup_wt_dir="${cleanup_repo_root}/.dex/worktrees/${cleanup_wt_name}"
  fi

  # Activate the prompt-loop variant of the audit loop so the Stop hook
  # enforces completion criteria. See: hooks/phase-loop.sh prompt-loop branch.
  mkdir -p "$DX_LOOP_DIR"
  touch "$(dx_active_file "$session_id")"
  rm -f "$(dx_complete_file "$session_id")" "$(dx_loop_file "$session_id")" "$(dx_paused_file "$session_id")" "$(dx_watch_pause_file "$session_id")"

  DEX_SESSION_ID="$session_id" \
  DEX_LOOP_ACTIVE=1 \
  DEX_LOOP_PROMISE="DEX_TICKET_COMPLETE" \
  DEX_LOOP_PHASE="6" \
  DEX_COMPLETE_MAX_CYCLES="${DEX_COMPLETE_MAX_CYCLES:-$DX_COMPLETE_MAX_CYCLES}" \
  DEX_COMPLETE_WAIT_MINUTES="${DEX_COMPLETE_WAIT_MINUTES:-$DX_COMPLETE_WAIT_MINUTES}" \
  DEX_DIR="$DEX_DIR" \
  __dx_claude "${DX_CLAUDE_FLAGS[@]}" -n "dxcomplete-pr-${pr_num}" \
    "Invoke the Skill tool with skill: \"dxcomplete\". Run the full completion workflow: verify the PR is ready for review, request configured reviewers, post @mention comments, monitor CI and reviews via /loop 5m /dxwatchpr, address CI failures and review comments, and close the ticket when all checks pass and reviewers have approved.
$(__dx_provider_prompt)"

  local exit_code=$?
  local loop_status="advance"
  if [[ $exit_code -eq 0 ]] && [[ -f "$(dx_loop_file "$session_id")" ]]; then
    loop_status="max-iter"
    exit_code=1
  fi
  local paused_file complete_paused=0
  paused_file=$(dx_paused_file "$session_id")
  [[ -f "$paused_file" ]] && complete_paused=1

  # Clean up
  rm -f "$(dx_active_file "$session_id")" "$(dx_loop_file "$session_id")" "$(dx_complete_file "$session_id")" "$paused_file" 2>/dev/null
  dx_provider_cleanup_session_state "$session_id"

  if [[ $complete_paused -eq 1 ]]; then
    dx_info "dxcomplete paused before completion; local worktree/branch cleanup was skipped."
    exit_code=1
  elif [[ "$loop_status" == "max-iter" ]]; then
    dx_info "dxcomplete paused: max audit iterations reached without completion."
  elif [[ $exit_code -eq 0 && "$cleanup_mode" == "worktree" ]]; then
    __dx_cleanup_completed_workspace "$cleanup_wt_name" "$cleanup_wt_dir" "$cleanup_default_branch" "$cleanup_mode" "$session_id"
    exit_code=$?
  elif [[ $exit_code -eq 0 ]]; then
    dx_info "dxcomplete finished; no Dex worktree was detected, so the current checkout and branch were left intact."
  fi

  return $exit_code
}

# ─── dxreviewloop — standalone adaptive clean-pass review ─────────────────
#
# Runs the same adversarial review loop dx Phase 3 uses, without requiring
# the full lifecycle. Scope is the full current change set when one exists; on
# a clean branch, the loop falls back to a whole-codebase review.
#
# Each iteration is a fresh CLI session that runs one full review wave:
# build/refresh a compact context pack, run deterministic checks, collect
# read-only review findings, verify/dedupe, batch-fix, re-check, then write a
# review-result signal. Only a wave with zero verified findings and zero fixes
# writes CLEAN. Auto depth starts light/standard/thorough based on diff risk;
# a wave may escalate itself to thorough if the starting depth is unsafe.

unalias dxreviewloop 2>/dev/null; unfunction dxreviewloop 2>/dev/null
dxreviewloop() {
  __dx_refresh_provider || return 1

  local agent_host
  agent_host=$(dx_agent_host)
  if [[ "$agent_host" == "codex" ]]; then
    if ! command -v codex &>/dev/null; then
      dx_error "Codex CLI not found in PATH."
      dx_info "Install Codex and sign in, then try again."
      return 1
    fi
  else
    if ! command -v claude &>/dev/null; then
      dx_error "Claude Code CLI not found in PATH."
      dx_info "Install it from https://docs.anthropic.com/en/docs/claude-code then try again."
      return 1
    fi
  fi

  if ! git rev-parse --git-dir &>/dev/null; then
    dx_error "Not in a git repository."
    return 1
  fi

  # Detect the full current change set instead of prioritizing one category.
  local scope_name="" scope_mode="changes" diff_cmd="" stat_cmd="" name_cmd=""
  local committed_diff_cmd="" committed_stat_cmd="" committed_name_cmd=""
  local committed_ref=""
  local has_committed=0 has_staged=0 has_unstaged=0 has_untracked=0
  local untracked_count
  local branch
  branch=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "HEAD")
  [[ -n "$branch" ]] || branch="HEAD"
  local default_branch
  default_branch=$(dx_default_branch)

  if [[ -n "$default_branch" ]] && \
       git rev-parse --verify --quiet "origin/${default_branch}" &>/dev/null && \
       git merge-base "origin/${default_branch}" HEAD &>/dev/null && \
       ! git diff --quiet "origin/${default_branch}...HEAD" 2>/dev/null; then
    has_committed=1
    committed_ref="origin/${default_branch}...HEAD"
    committed_diff_cmd="git diff origin/${default_branch}...HEAD"
    committed_stat_cmd="git diff origin/${default_branch}...HEAD --stat"
    committed_name_cmd="git diff origin/${default_branch}...HEAD --name-only"
  elif git rev-parse --abbrev-ref --symbolic-full-name '@{u}' &>/dev/null && \
       [[ -n "$(git log '@{u}..HEAD' --oneline 2>/dev/null)" ]]; then
    has_committed=1
    committed_ref="@{u}...HEAD"
    committed_diff_cmd="git diff @{u}...HEAD"
    committed_stat_cmd="git diff @{u}...HEAD --stat"
    committed_name_cmd="git diff @{u}...HEAD --name-only"
  fi

  git diff --cached --quiet 2>/dev/null || has_staged=1
  git diff --quiet 2>/dev/null || has_unstaged=1
  untracked_count=$(git ls-files --others --exclude-standard 2>/dev/null | wc -l | tr -d ' ')
  [[ "$untracked_count" =~ ^[0-9]+$ && "$untracked_count" -gt 0 ]] && has_untracked=1

  if [[ $has_committed -eq 1 || $has_staged -eq 1 || $has_unstaged -eq 1 || $has_untracked -eq 1 ]]; then
    scope_name="full current change set"
    diff_cmd="{ ${committed_diff_cmd:-:}; git diff --cached; git diff; git ls-files --others --exclude-standard -z | xargs -0 -I{} sh -c 'test -f \"\$1\" && git diff --no-index -- /dev/null \"\$1\" 2>/dev/null || true' sh {}; }"
    stat_cmd="{ ${committed_stat_cmd:-:}; git diff --cached --stat; git diff --stat; git ls-files --others --exclude-standard | sed 's/^/untracked: /'; }"
    name_cmd="{ ${committed_name_cmd:-:}; git diff --cached --name-only; git diff --name-only; git ls-files --others --exclude-standard; } | sort -u"
  fi

  if [[ -z "$scope_name" ]]; then
    scope_name="entire codebase"
    scope_mode="codebase"
    diff_cmd="git ls-files | sort"
    stat_cmd="git ls-files | awk '{count++} END {printf \"tracked files: %d\\n\", count+0}'"
    name_cmd="git ls-files | sort"
    dx_info "No current change set detected; falling back to an entire-codebase review."
  fi

  local requested_profile="${DEX_REVIEW_PROFILE:-$DX_REVIEW_PROFILE}"
  local review_profile="$requested_profile"
  case "$review_profile" in
    auto|"") review_profile="$(__dx_review_auto_profile "$committed_ref")" ;;
    light|standard|thorough) ;;
    *)
      dx_warn "Unknown DEX_REVIEW_PROFILE '${review_profile}'; using auto."
      review_profile="$(__dx_review_auto_profile "$committed_ref")" ;;
  esac

  local max_iter="${DEX_REVIEW_MAX_ITERATIONS:-$(__dx_review_profile_max_iterations "$review_profile")}"
  local required_clean="${DEX_REVIEW_CLEAN_PASSES:-$(__dx_review_profile_clean_passes "$review_profile")}"

  # File count preview for the review scope without eval.
  local files_changed
  if [[ "$scope_mode" == "codebase" ]]; then
    files_changed=$(git ls-files 2>/dev/null | wc -l | tr -d ' ') || files_changed="?"
  else
    files_changed=$(
      {
        [[ -n "$committed_ref" ]] && git diff "$committed_ref" --name-only 2>/dev/null
        git diff --cached --name-only 2>/dev/null
        git diff --name-only 2>/dev/null
        git ls-files --others --exclude-standard 2>/dev/null
      } | sort -u | wc -l | tr -d ' '
    ) || files_changed="?"
  fi
  [[ -n "$files_changed" ]] || files_changed="?"

  echo ""
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo "  DEX — dxreviewloop (${review_profile}, ${required_clean} clean pass(es))"
  echo ""
  echo "  Agent:  $(dx_agent_host_label)"
  echo "  Branch: ${branch}"
  echo "  Scope:  ${scope_name} (${files_changed} files)"
  echo "  Depth:  ${review_profile} (${required_clean} clean, max ${max_iter} iterations)"
  echo "  Input:  ${diff_cmd}"
  echo "━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━"
  echo ""

  local session_id
  session_id=$(dx_session_id)
  local review_context_file
  review_context_file=$(dx_review_context_file "$session_id")
  local pass_complete_file
  pass_complete_file=$(dx_complete_file "$session_id")
  local prompt_file
  prompt_file=$(dx_prompt_file "$session_id")
  local standalone_review_prompt=0
  if [[ "${DEX_LOOP_ACTIVE:-}" != "1" ]]; then
    standalone_review_prompt=1
    __dx_write_state "$prompt_file" "Standalone /dxreviewloop invocation for branch ${branch}.

Review scope: ${scope_name} (${files_changed} files).

No ticket, plan, or acceptance criteria were supplied by this wrapper. Mark plan-dependent sections as N/A unless explicit criteria are present in the review-pass prompt."
  fi
  rm -f "$review_context_file" 2>/dev/null

  local clean_passes=0
  local review_iteration=0

  # Standalone review uses the detailed single-pass adversarial audit.
  local audit_file="$DEX_DIR/prompts/phase-audits/3-review.md"
  local audit_prompt=""
  [[ -f "$audit_file" ]] && audit_prompt=$(cat "$audit_file")

  local session_name
  session_name="dxreviewloop-$(dx_slugify "$branch")"

  local scope_source_detail scope_boundary
  if [[ "$scope_mode" == "codebase" ]]; then
    scope_source_detail="IMPORTANT: No current change set was found, so this pass is a whole-codebase review. Do not stop because \`git diff\` is empty. Use these commands as the authoritative codebase inventory, then read and review the listed files as needed:"
    scope_boundary="SCOPE BOUNDARIES: review and fix the entire codebase in this repository. Do NOT commit, push, or create PRs."
  else
    scope_source_detail="IMPORTANT: When the audit prompt or /dxreview SKILL.md tells you to scope with \`git diff origin/<default>...HEAD\`, override that — use these commands instead. This is the full current change set, including committed branch changes, staged changes, unstaged changes, and untracked files:"
    scope_boundary="SCOPE BOUNDARIES: review and fix the full current change set above ONLY. Do NOT commit, push, or create PRs."
  fi

  local message_template
  message_template="Run one full Dex review wave using /dxreview --single-pass, scoped to **${scope_name}** on branch \`${branch}\`.

${scope_source_detail}

- Scope input: \`${diff_cmd}\`
- Stat:        \`${stat_cmd}\`
- File names:  \`${name_cmd}\`

Use this review context pack path: \`${review_context_file}\`
Use this per-pass completion path only after the review result signal and findings hash are written: \`${pass_complete_file}\`

Review depth profile for this pass: \`__REVIEW_PROFILE__\`.
- \`light\`: deterministic checks, core domain sweep, verifier pass, batch fix, targeted recheck.
- \`standard\`: core sweep plus targeted domain sweeps for concrete changed surfaces, verifier pass.
- \`thorough\`: all domain sweeps, verifier pass, batch fix, targeted recheck.

Follow the audit prompt and \`prompts/review-wave.md\`: first materialize a non-empty compact context pack, run deterministic checks, harvest candidate issues according to the depth profile, verify and deduplicate findings, batch-fix verified issues, re-check, and write the review result signal file. Run in the current checkout; do not create or switch branches or worktrees.

Result semantics:
- Write \`CLEAN\` only if this wave found zero verified findings and applied zero fixes.
- Write \`FINDINGS_FIXED:N\` if this wave found and fixed N verified findings; this intentionally resets the outer clean-pass counter.
- Do not stop after only reporting verified findings. Fix safe verified findings before writing the result.
- Write \`FINDINGS:N\` only if verified findings remain after a concrete local fix attempt is blocked, unsafe, or requires user judgment. Write \`BLOCKED:reason\` if the wave cannot complete.
- Write \`ESCALATE_THOROUGH:reason\` if the profile is too shallow for the observed risk. Examples: auth/security/data-loss risk, public contract changes, broad dependency impact, complex shell/hooks/CI behavior, unclear acceptance coverage, or the review wave cannot rule out serious issues at the current depth.

If no approved plan / acceptance criteria are explicitly available in this prompt for this scope, mark plan-dependent sections (acceptance criteria verification, evidence table) as N/A and proceed without them. Do not infer criteria from stale session prompt files, previous conversation turns, session titles, AGENTS instructions, or unrelated ticket context.

${scope_boundary}

After writing the review result signal and findings hash, touch the per-pass completion path above, output \`${DX_PHASE_PROMISES[3]}\`, and then stop. That completion file only exits this one review-wave pass; it does not make a non-CLEAN result count as clean.
$(__dx_provider_prompt)"

  while [[ $review_iteration -lt $max_iter ]] && [[ $clean_passes -lt $required_clean ]]; do
    review_iteration=$((review_iteration + 1))

    echo ""
    echo "  Iteration ${review_iteration}/${max_iter} (${clean_passes}/${required_clean} clean passes)"
    echo ""

    rm -f "$review_context_file" "$(dx_review_result_file "$session_id")"
    mkdir -p "$DX_LOOP_DIR"
    touch "$(dx_active_file "$session_id")"
    rm -f "$(dx_complete_file "$session_id")" "$(dx_loop_file "$session_id")" "$(dx_findings_file "$session_id")"

    # Stop hook config: phase 3, MIN_AUDITS=1
    __dx_write_state "$(dx_loop_config_file "$session_id")" "3:${DX_PHASE_PROMISES[3]}:${audit_file}:1"

    local message="${message_template//__REVIEW_PROFILE__/$review_profile}"
    local exit_code=0
    if [[ "$agent_host" == "codex" ]]; then
      local codex_message
      codex_message="You are running this Dex review-wave pass inside Codex.

Use Codex directly. Do not launch Claude and do not rely on Claude Stop hooks.
If an instruction says to run /dxreview --single-pass, implement that by reading
skills/dxreview/SKILL.md and prompts/review-wave.md and performing the same
single-pass review-wave contract yourself.

Dex review waves cover the requested review domains inside this CLI pass.

Before your final response, you MUST write exactly one allowed result to:
  $(dx_review_result_file "$session_id")

Then touch:
  ${pass_complete_file}

Allowed results: CLEAN, FINDINGS_FIXED:N, FINDINGS:N, BLOCKED:reason, ESCALATE_THOROUGH:reason.

${message}"

      DEX_SESSION_ID="$session_id" \
      DEX_LOOP_ACTIVE=1 \
      DEX_LOOP_PROMISE="${DX_PHASE_PROMISES[3]}" \
      DEX_LOOP_PROMPT="$audit_prompt" \
      DEX_LOOP_PHASE="3" \
      DEX_REVIEW_PASS_ACTIVE=1 \
      DEX_REVIEW_PROFILE="$review_profile" \
      DEX_DIR="$DEX_DIR" \
      dx_provider_codex_exec "$codex_message" "$(pwd)"
      exit_code=$?
    else
      local pass_session_name="${session_name}-pass-${review_iteration}"
      local claude_args=("${DX_CLAUDE_FLAGS[@]}" -n "$pass_session_name")

      DEX_SESSION_ID="$session_id" \
      DEX_LOOP_ACTIVE=1 \
      DEX_LOOP_PROMISE="${DX_PHASE_PROMISES[3]}" \
      DEX_LOOP_PROMPT="$audit_prompt" \
      DEX_LOOP_PHASE="3" \
      DEX_REVIEW_PASS_ACTIVE=1 \
      DEX_REVIEW_PROFILE="$review_profile" \
      DEX_DIR="$DEX_DIR" \
      __dx_claude "${claude_args[@]}" "$message"
      exit_code=$?
    fi

    local audit_max_iter=0
    if [[ $exit_code -eq 0 ]] && [[ -f "$(dx_loop_file "$session_id")" ]]; then
      audit_max_iter=1
    fi

    rm -f "$(dx_active_file "$session_id")" "$(dx_loop_config_file "$session_id")" "$(dx_loop_file "$session_id")" "$(dx_complete_file "$session_id")" 2>/dev/null

    if [[ $audit_max_iter -eq 1 ]]; then
      echo ""
      dx_info "dxreviewloop paused: max audit iterations reached without completion."
      dx_provider_cleanup_session_state "$session_id"
      [[ $standalone_review_prompt -eq 1 ]] && rm -f "$prompt_file" 2>/dev/null
      return 1
    fi

    if [[ $exit_code -ne 0 ]]; then
      echo ""
      dx_info "dxreviewloop interrupted (exit code: $exit_code)."
      dx_provider_cleanup_session_state "$session_id"
      [[ $standalone_review_prompt -eq 1 ]] && rm -f "$prompt_file" 2>/dev/null
      return $exit_code
    fi

    local result="UNKNOWN"
    local result_file
    result_file=$(dx_review_result_file "$session_id")
    [[ -f "$result_file" ]] && result=$(cat "$result_file" 2>/dev/null || echo "UNKNOWN")
    if [[ "$result" != "CLEAN" && "$result" != BLOCKED:* && "$result" != ESCALATE_THOROUGH:* ]] && \
       ! printf '%s\n' "$result" | grep -Eq '^(FINDINGS_FIXED|FINDINGS):[0-9]+$'; then
      echo ""
      dx_info "dxreviewloop received invalid review result from ${agent_host}: ${result}"
      dx_provider_cleanup_session_state "$session_id"
      [[ $standalone_review_prompt -eq 1 ]] && rm -f "$prompt_file" 2>/dev/null
      return 1
    fi

    if [[ "$result" == "CLEAN" ]]; then
      clean_passes=$((clean_passes + 1))
      echo "  Iteration ${review_iteration}: CLEAN (${clean_passes}/${required_clean})"
    elif [[ "$result" == ESCALATE_THOROUGH* ]]; then
      clean_passes=0
      if [[ "$review_profile" != "thorough" ]]; then
        review_profile="thorough"
        [[ -z "${DEX_REVIEW_CLEAN_PASSES:-}" ]] && required_clean="$DX_REVIEW_THOROUGH_CLEAN_PASSES"
        [[ -z "${DEX_REVIEW_MAX_ITERATIONS:-}" ]] && max_iter="$DX_REVIEW_THOROUGH_MAX_ITERATIONS"
        echo "  Iteration ${review_iteration}: ${result} — escalating to thorough (${required_clean} clean, max ${max_iter} iterations)"
      else
        echo "  Iteration ${review_iteration}: ${result} — already thorough; resetting clean pass counter"
      fi
    else
      clean_passes=0
      echo "  Iteration ${review_iteration}: ${result} — resetting clean pass counter"
    fi
  done

  rm -f "$(dx_review_result_file "$session_id")" 2>/dev/null
  dx_provider_cleanup_session_state "$session_id"
  [[ $standalone_review_prompt -eq 1 ]] && rm -f "$prompt_file" 2>/dev/null

  echo ""
  if [[ $clean_passes -ge $required_clean ]]; then
    dx_done "Review complete: ${clean_passes} consecutive clean passes."
    return 0
  else
    dx_info "Review reached max iterations (${max_iter}) with ${clean_passes}/${required_clean} clean passes."
    return 1
  fi
}

# ─── dxrm — remove worktrees ──────────────────────────────────────────────

unalias dxrm 2>/dev/null; unfunction dxrm 2>/dev/null
dxrm() {
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
    local renamed_branches=()
    local session_ids=()

    if [[ -d "$worktrees_dir" ]]; then
      for wt_dir in "$worktrees_dir"/*(/N); do
        [[ -d "$wt_dir" ]] || continue
        found=1
        local wt_name
        wt_name="$(basename "$wt_dir")"
        session_ids+=("$(dx_session_id "$wt_name")")

        # The SessionStart hook may rename the worktree branch (e.g. from
        # worktree-ticket-999 to feat/ENG-999-description) to follow project
        # conventions. Track these renamed branches so we can delete them below
        # — they won't match the 'worktree-*' glob pattern.
        local actual_branch
        actual_branch=$(dx_wt_branch "$wt_dir")
        if [[ -n "$actual_branch" && "$actual_branch" != "worktree-${wt_name}" ]]; then
          renamed_branches+=("$actual_branch")
        fi

        echo "Removing ${wt_name}..."
        dx_cleanup_checkpoints "$wt_dir"
        dx_unlink_claude_from_worktree "$wt_dir"
        dx_wt_remove "$wt_dir"
      done
    fi

    local branch
    while IFS= read -r branch; do
      [[ -z "$branch" ]] && continue
      found=1
      local active_in_place_phase
      if active_in_place_phase=$(__dx_active_in_place_phase_for_branch "$branch"); then
        echo "Skipping branch ${branch} (active in-place phase ${active_in_place_phase}/6: $(__dx_phase_name "$active_in_place_phase"))"
        skipped_active_in_place=1
        continue
      fi
      echo "Deleting branch ${branch}..."
      if git branch -D "$branch" 2>/dev/null; then
        __dx_cleanup_lifecycle_state_for_branch "$branch"
      fi
    done < <(git branch --list 'worktree-ticket-*' 'worktree-task-*' 2>/dev/null | sed 's/^[* ]*//')

    # Delete renamed branches that wouldn't match the worktree-* pattern
    for branch in "${renamed_branches[@]}"; do
      echo "Deleting renamed branch ${branch}..."
      git branch -D "$branch" 2>/dev/null || true
      found=1
    done

    git worktree prune 2>/dev/null

    local last_session_active_in_place=0
    __dx_last_session_active_in_place && last_session_active_in_place=1

    # Clean up last-session pointer unless it still points at a resumable in-place session.
    if [[ $last_session_active_in_place -eq 0 ]]; then
      rm -f "$DX_STATE_DIR/last-session" 2>/dev/null
    fi

    # Clean up state files for THIS repo's worktrees only (not cross-repo globs)
    local sid
    for sid in "${session_ids[@]}"; do
      dx_cleanup_session "$sid"
    done

    if [[ $found -eq 0 ]]; then
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
    local active_in_place_phase
    if active_in_place_phase=$(__dx_active_in_place_phase_for_branch "$branch_name"); then
      dx_error "Refusing to remove active in-place lifecycle branch ${branch_name} (phase ${active_in_place_phase}/6: $(__dx_phase_name "$active_in_place_phase"))."
      dx_info "Resume it with dx --resume, or finish the lifecycle before cleaning it up."
      return 1
    fi
  fi

  echo "Removing ${wt_name}..."

  [[ $has_dir -eq 1 ]] && dx_cleanup_checkpoints "$wt_dir"
  [[ $has_dir -eq 1 ]] && dx_unlink_claude_from_worktree "$wt_dir"
  [[ $has_dir -eq 1 ]] && dx_wt_remove "$wt_dir"

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
  local repo_root
  repo_root=$(dx_repo_root) || return 1

  local worktrees_dir="${repo_root}/.dex/worktrees"
  if [[ ! -d "$worktrees_dir" ]]; then
    dx_info "No worktrees."
    return 0
  fi

  local count=0
  for wt_dir in "$worktrees_dir"/*(/N); do
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
    branch=$(dx_wt_branch "$wt_dir" "?")

    # Show phase status
    local session_id
    session_id=$(dx_session_id "$wt_name")
    local phase_file
    phase_file=$(dx_state_file "$session_id")
    if [[ -f "$phase_file" ]]; then
      local phase_num
      phase_num=$(cat "$phase_file" 2>/dev/null)
      if [[ "$phase_num" =~ ^[0-6]$ ]]; then
        wt_status="${wt_status} [phase ${phase_num}/6: $(__dx_phase_name "$phase_num")]"
      elif [[ "$phase_num" =~ ^[0-9]+$ ]] && [[ "$phase_num" -gt 6 ]]; then
        wt_status="${wt_status} [complete]"
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
  local repo_root
  repo_root=$(dx_repo_root) || return 1

  # No args → repo root
  if [[ $# -eq 0 ]]; then
    cd "$repo_root" || return 1
    return 0
  fi

  local target="$1"
  local worktrees_dir="${repo_root}/.dex/worktrees"

  if [[ ! -d "$worktrees_dir" ]]; then
    dx_error "No worktrees found."
    return 1
  fi

  # Exact match first
  if [[ -d "$worktrees_dir/$target" ]]; then
    cd "$worktrees_dir/$target" || return 1
    return 0
  fi

  # Prefix match: "ticket-123" or just "123" matches worktree names containing that string
  local matches=()
  for wt_dir in "$worktrees_dir"/*(/N); do
    [[ -d "$wt_dir" ]] || continue
    local name
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
  local repo_root
  repo_root=$(dx_repo_root) || return 1

  # cd to repo root so bare git commands (fetch, branch -D, branch --list) operate
  # on the correct repository. Note: this intentionally does not restore the original
  # cwd — if the user was inside a removed worktree, returning there would fail.
  cd "$repo_root" || return 1
  local cleaned=0

  # 1. Prune stale worktrees (no uncommitted changes)
  local worktrees_dir="${repo_root}/.dex/worktrees"
  if [[ -d "$worktrees_dir" ]]; then
    for wt_dir in "$worktrees_dir"/*(/N); do
      [[ -d "$wt_dir" ]] || continue
      local wt_name
      wt_name="$(basename "$wt_dir")"

      # Skip worktrees with active phase state (still in a lifecycle)
      local session_id phase_file
      session_id=$(dx_session_id "$wt_name")
      phase_file=$(dx_state_file "$session_id")
      if [[ -f "$phase_file" ]]; then
        local phase_val
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
      local wt_branch
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
      dx_wt_remove "$wt_dir"

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

  local branch
  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    # Only clean dex-managed branches (worktree-ticket-* or worktree-task-*)
    if [[ "$branch" != worktree-ticket-* ]] && [[ "$branch" != worktree-task-* ]]; then
      continue
    fi
    local active_in_place_phase
    if active_in_place_phase=$(__dx_active_in_place_phase_for_branch "$branch"); then
      echo "  Skipping branch ${branch} (active in-place phase ${active_in_place_phase}/6: $(__dx_phase_name "$active_in_place_phase"))"
      continue
    fi
    # Don't delete branches with active worktrees
    local has_worktree=0
    if [[ -d "$worktrees_dir" ]]; then
      for wt_dir in "$worktrees_dir"/*(/N); do
        [[ -d "$wt_dir" ]] || continue
        local wt_branch
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
  done < <(git branch -vv 2>/dev/null | grep ': gone]' | sed 's/^[* ]*//' | awk '{print $1}')

  # 3. Prune worktree branches that have no worktree directory
  while IFS= read -r branch; do
    [[ -z "$branch" ]] && continue
    local active_in_place_phase
    if active_in_place_phase=$(__dx_active_in_place_phase_for_branch "$branch"); then
      echo "  Skipping branch ${branch} (active in-place phase ${active_in_place_phase}/6: $(__dx_phase_name "$active_in_place_phase"))"
      continue
    fi
    local ticket_name="${branch#worktree-}"
    if [[ ! -d "$worktrees_dir/$ticket_name" ]]; then
      echo "  Deleting orphan branch: ${branch}"
      if git branch -D "$branch" 2>/dev/null; then
        __dx_cleanup_lifecycle_state_for_branch "$branch"
        cleaned=$((cleaned + 1))
      fi
    fi
  done < <(git branch --list 'worktree-ticket-*' 'worktree-task-*' 2>/dev/null | sed 's/^[* ]*//')

  git worktree prune 2>/dev/null

  # 4. Clean up old loop state files (older than 7 days).
  # 7 days gives enough time to resume interrupted sessions while preventing
  # indefinite accumulation. Most tickets complete within a day or two.
  local old_files
  old_files=$(dx_cleanup_stale_files "$DX_LOOP_DIR" "state complete active prompt config findings debt provider review-state review-result review-context busy busy-notice started ready watch-pause watch-lock" 7)
  if [[ "$old_files" -gt 0 ]]; then
    echo "  Cleaned ${old_files} old loop state file(s)"
    cleaned=$((cleaned + old_files))
  fi

  # 5. Clean up old phase state files (older than 7 days)
  local old_phase_files
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
}
