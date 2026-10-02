#!/usr/bin/env bash
# shellcheck disable=SC1091
# SessionStart hook — detects ticket context from branch name and prints instructions.
# Works with or without ticket trackers (Linear, GitHub Issues).
# Feeds context into the phase system — see docs/autonomous-mode.md for lifecycle flow.
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

if [[ "${DEX_SESSION_ONLY:-0}" == 1 ]]; then
  dx_info "Dex session only: follow the user's prompt directly. No ticket intake or lifecycle is active."
  exit 0
fi

if [[ "${DEX_TRIAGE_ACTIVE:-0}" == 1 ]]; then
  printf '%s\n' "Dex triage session: invoke /dxtriage. Do not start implementation or infer a target from the branch."
  exit 0
fi

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
# Sanitise the branch name before embedding it in template substitutions.
# git branch names are constrained, but strip anything outside the safe set
# to prevent unexpected behaviour in bash ${var//pattern/replacement}.
BRANCH="${BRANCH//[^A-Za-z0-9._\/\-]/_}"

# Skip ticket extraction for task worktrees (e.g., worktree-task-fix-bug-123)
TICKET_NUM=""
if [[ "$BRANCH" != worktree-task-* ]]; then
  # Extract ticket number from branch name (handles: ticket-999, ENG-999, feature/ENG-999, etc.)
  TICKET_NUM=$(grep -oE 'ticket-[0-9]+' <<< "${BRANCH}" | head -1 | grep -oE '[0-9]+' || true)
  if [[ -z "$TICKET_NUM" ]]; then
    # Fallback: look for UPPERCASE project prefixes (e.g., ENG-123, PROJ-456).
    # Requires uppercase to avoid false positives on common branch name segments
    # like "add-3", "feat-1", "v-2" which aren't ticket references.
    TICKET_NUM=$(echo "$BRANCH" | grep -oE '[A-Z]{2,}-[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
  fi
fi

REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
SESSION_ID="${DEX_SESSION_ID:-$(dx_session_id)}"
TASK_PROMPT_FILE=$(dx_prompt_file "$SESSION_ID")

if [[ -n "$TICKET_NUM" ]]; then
  echo "Ticket number: ${TICKET_NUM}"
  echo "Branch: ${BRANCH}"
  echo ""

  # Load instructions template and substitute variables
  INSTRUCTIONS_FILE="$DEX_DIR/prompts/ticket-instructions.md"
  if [[ -f "$INSTRUCTIONS_FILE" ]]; then
    # Use bash substitution instead of sed to avoid special character issues
    # in branch names (& and | break sed replacement/delimiter)
    TEMPLATE=$(<"$INSTRUCTIONS_FILE")
    TEMPLATE="${TEMPLATE//\{\{TICKET_NUM\}\}/$TICKET_NUM}"
    TEMPLATE="${TEMPLATE//\{\{BRANCH\}\}/$BRANCH}"
    printf '%s\n' "$TEMPLATE"
  fi
elif [[ -f "$TASK_PROMPT_FILE" ]]; then
  echo "Branch: ${BRANCH}"
  echo ""
  echo "Task: $(cat "$TASK_PROMPT_FILE")"
  echo ""
  echo "Use /dex to begin work on this task, or work on it directly."
else
  echo "Branch: ${BRANCH}"
  echo ""
  echo "No ticket number detected in branch name."
  echo "You can still use /dex to begin work — context will be gathered from the user and codebase."
fi

# Context-aware behavioural hints based on changed files.
# These generic patterns work without dx init — they detect common directory
# conventions (frontend/, backend/, migrations/, etc.). Project-specific focus
# areas can be defined in .dex/rules/ after running dx init.
# Uses origin/ prefix so the diff compares against the remote default branch,
# not a potentially stale local copy (consistent with dx.sh __dx_show_header).
DEFAULT_BRANCH=$(dx_default_branch "$REPO_TOP")
CHANGED_FILES=$(git diff "origin/${DEFAULT_BRANCH}...HEAD" --name-only 2>/dev/null || echo "")
FOCUS_AREAS=""

if grep -qE '^frontend/|^admin/' <<< "${CHANGED_FILES}" 2>/dev/null; then
  FOCUS_AREAS="${FOCUS_AREAS} frontend"
fi
if grep -q '^backend/' <<< "${CHANGED_FILES}" 2>/dev/null; then
  FOCUS_AREAS="${FOCUS_AREAS} backend"
fi
if grep -qE 'guard|auth|rls|policy|security' <<< "${CHANGED_FILES}" 2>/dev/null; then
  FOCUS_AREAS="${FOCUS_AREAS} security"
fi
if grep -qE '\.migration\.|migrations/' <<< "${CHANGED_FILES}" 2>/dev/null; then
  FOCUS_AREAS="${FOCUS_AREAS} migration"
fi

if [[ -n "$FOCUS_AREAS" ]]; then
  echo ""
  echo "Focus areas detected:${FOCUS_AREAS}"
  echo "Prioritise reading the relevant rules from .dex/rules/ for these areas."
fi

# Repo memory, scoped to the files this branch changed: the active curated
# entries whose paths match plus verified observations from the external
# store, after a recheck so an entry whose source moved is named as stale
# rather than shown as current. Every retrieval leaves a trace in the store.
__dx_require_lib memory.sh 2>/dev/null || true
if [[ "${DEX_MEMORY_RETRIEVAL:-1}" != 0 ]] && command -v dx_memory_retrieve >/dev/null 2>&1 \
  && { [[ -f "$REPO_TOP/.dex/memory/index.md" ]] || [[ -d "$(dx_memory_store_dir "$REPO_TOP" 2>/dev/null || true)" ]]; }; then
  # What the session is working on: the branch's commits plus whatever is
  # modified or new in the working tree right now (an in-place session may
  # have committed nothing yet). Bounded so a huge tree does not flood the
  # query.
  MEMORY_PATHS=$( { printf '%s\n' "$CHANGED_FILES"; git diff --name-only 2>/dev/null; \
    git ls-files --others --exclude-standard 2>/dev/null; } | sed '/^$/d' | sort -u | head -200 | paste -sd, -)
  dx_memory_store "$REPO_TOP" recheck --repo "$REPO_TOP" >/dev/null 2>&1 || true
  if MEMORY_BLOCK=$(dx_memory_retrieve "$REPO_TOP" "$MEMORY_PATHS" "$SESSION_ID" lead "${DEX_LOOP_PHASE:-}" 2>/dev/null); then
    echo ""
    echo "Repo memory (scoped to this branch's changed files; index: .dex/memory/index.md):"
    printf '%s\n' "$MEMORY_BLOCK"
  fi
fi

# Mission mode: what the ledger knows, so the lead starts from recorded state
# rather than from the transcript it may no longer have.
if [[ "${DX_MISSION_ACTIVE:-0}" == 1 ]]; then
  __dx_require_lib mission.sh 2>/dev/null || true
  if command -v dx_mission_context_summary >/dev/null 2>&1; then
    echo ""
    dx_mission_context_summary "$SESSION_ID" start || true
  fi
fi
