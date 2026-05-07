#!/usr/bin/env bash
# SessionStart hook — detects ticket context from branch name and prints instructions.
# Works with or without ticket trackers (Linear, GitHub Issues).
# Feeds context into the phase system — see docs/autonomous-mode.md for lifecycle flow.
set -euo pipefail

source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"

BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")

# Skip ticket extraction for task worktrees (e.g., worktree-task-fix-bug-123)
TICKET_NUM=""
if [[ "$BRANCH" != worktree-task-* ]]; then
  # Extract ticket number from branch name (handles: ticket-999, ENG-999, feature/ENG-999, etc.)
  TICKET_NUM=$(echo "$BRANCH" | grep -oE 'ticket-[0-9]+' | grep -oE '[0-9]+' || true)
  if [[ -z "$TICKET_NUM" ]]; then
    # Fallback: look for UPPERCASE project prefixes (e.g., ENG-123, PROJ-456).
    # Requires uppercase to avoid false positives on common branch name segments
    # like "add-3", "feat-1", "v-2" which aren't ticket references.
    TICKET_NUM=$(echo "$BRANCH" | grep -oE '[A-Z]{2,}-[0-9]+' | head -1 | grep -oE '[0-9]+' || true)
  fi
fi

REPO_TOP=$(git rev-parse --show-toplevel 2>/dev/null || echo ".")
SESSION_ID="${DOYAKEN_SESSION_ID:-$(dk_session_id)}"
TASK_PROMPT_FILE=$(dk_prompt_file "$SESSION_ID")

if [[ -n "$TICKET_NUM" ]]; then
  echo "Ticket number: ${TICKET_NUM}"
  echo "Branch: ${BRANCH}"
  echo ""

  # Load instructions template and substitute variables
  INSTRUCTIONS_FILE="$DOYAKEN_DIR/prompts/ticket-instructions.md"
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
  echo "Use /doyaken to begin work on this task, or work on it directly."
elif [[ -f "$REPO_TOP/.doyaken-prompt" ]]; then
  echo "Branch: ${BRANCH}"
  echo ""
  echo "Task: $(cat "$REPO_TOP/.doyaken-prompt")"
  echo ""
  echo "Use /doyaken to begin work on this task, or work on it directly."
else
  echo "Branch: ${BRANCH}"
  echo ""
  echo "No ticket number detected in branch name."
  echo "You can still use /doyaken to begin work — context will be gathered from the user and codebase."
fi

# Context-aware behavioural hints based on changed files.
# These generic patterns work without dk init — they detect common directory
# conventions (frontend/, backend/, migrations/, etc.). Project-specific focus
# areas can be defined in .doyaken/rules/ after running dk init.
# Uses origin/ prefix so the diff compares against the remote default branch,
# not a potentially stale local copy (consistent with dk.sh __dk_show_header).
DEFAULT_BRANCH=$(dk_default_branch "$REPO_TOP")
CHANGED_FILES=$(git diff "origin/${DEFAULT_BRANCH}...HEAD" --name-only 2>/dev/null || echo "")
FOCUS_AREAS=""

if printf '%s\n' "$CHANGED_FILES" | grep -qE '^frontend/|^admin/' 2>/dev/null; then
  FOCUS_AREAS="${FOCUS_AREAS} frontend"
fi
if printf '%s\n' "$CHANGED_FILES" | grep -q '^backend/' 2>/dev/null; then
  FOCUS_AREAS="${FOCUS_AREAS} backend"
fi
if printf '%s\n' "$CHANGED_FILES" | grep -qE 'guard|auth|rls|policy|security' 2>/dev/null; then
  FOCUS_AREAS="${FOCUS_AREAS} security"
fi
if printf '%s\n' "$CHANGED_FILES" | grep -qE '\.migration\.|migrations/' 2>/dev/null; then
  FOCUS_AREAS="${FOCUS_AREAS} migration"
fi

if [[ -n "$FOCUS_AREAS" ]]; then
  echo ""
  echo "Focus areas detected:${FOCUS_AREAS}"
  echo "Prioritise reading the relevant rules from .doyaken/rules/ for these areas."
fi
