#!/usr/bin/env bash
# shellcheck disable=SC1091
# PreCompact hook — injects a context-preservation reminder before conversation compaction.
# After compaction, Claude's system prompt context file (--append-system-prompt-file) will
# still be present, but in-conversation state (task progress, review findings, current step)
# may be lost. This hook prints a reminder that survives as a compaction instruction.
set -euo pipefail

source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"

SESSION_ID="${DOYAKEN_SESSION_ID:-$(dk_session_id)}"
CTX_FILE=$(dk_context_file "$SESSION_ID")

# Only output if we're in a Doyaken session with a context file
if [[ -f "$CTX_FILE" ]]; then
  echo "DOYAKEN COMPACTION NOTICE: After compaction, re-read your system context to re-orient."
  echo "If repo memory is relevant, re-read .doyaken/memory/index.md and load only scoped active entries."
  echo "If you have in-progress tasks, summarise your current position before compaction proceeds."
fi
