#!/usr/bin/env bash
# shellcheck disable=SC1091
# PreCompact hook — injects a context-preservation reminder before conversation compaction.
# After compaction, Claude's system prompt context file (--append-system-prompt-file) will
# still be present, but in-conversation state (task progress, review findings, current step)
# may be lost. This hook prints a reminder that survives as a compaction instruction.
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

if [[ "${DEX_TRIAGE_ACTIVE:-0}" == 1 ]]; then
  printf '%s\n' "Dex triage: preserve scope, processed/pending tickets, stakeholders, decisions, approvals, and write links before compaction."
  printf '%s\n' "After compaction, re-read the triage skill and session context. Do not start implementation."
fi

SESSION_ID="${DEX_SESSION_ID:-$(dx_session_id)}"
CTX_FILE=$(dx_context_file "$SESSION_ID")

# Only output if we're in a Dex session with a context file
if [[ -f "$CTX_FILE" ]]; then
  echo "DEX COMPACTION NOTICE: After compaction, re-read your system context to re-orient."
  echo "If repo memory is relevant, re-read .dex/memory/index.md and load only scoped active entries."
  echo "If you have in-progress tasks, summarise your current position before compaction proceeds."
fi
