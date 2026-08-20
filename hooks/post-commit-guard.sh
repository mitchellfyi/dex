#!/usr/bin/env bash
# PostToolUse hook (Bash) — validates commits after creation
# Checks conventional commit format, then delegates to guard-handler.py
# for markdown-based guard evaluation.
set -euo pipefail

__dx_post_commit_hook_field() {
  local raw="$1" field="$2"
  [[ -n "$raw" ]] || return 1
  DX_HOOK_RAW="$raw" python3 - "$field" <<'PY'
import json
import os
import sys

field = sys.argv[1]
try:
    payload = json.loads(os.environ.get("DX_HOOK_RAW", ""))
except Exception:
    sys.exit(1)

if field == "command":
    value = payload.get("tool_input", {}).get("command", "")
elif field == "exit_code":
    response = payload.get("tool_response", {})
    value = response.get("exit_code", response.get("status", ""))
else:
    value = ""

if value is None:
    sys.exit(1)
print(value)
PY
}

__dx_post_commit_is_json_payload() {
  local raw="$1"
  [[ -n "$raw" ]] || return 1
  DX_HOOK_RAW="$raw" python3 - <<'PY'
import json
import os
import sys

try:
    json.loads(os.environ.get("DX_HOOK_RAW", ""))
except Exception:
    sys.exit(1)
sys.exit(0)
PY
}

__dx_post_commit_is_git_commit() {
  local command_text="$1"
  DX_HOOK_COMMAND="$command_text" \
    python3 "${DEX_DIR:-$HOME/work/dex}/hooks/git-commit-target.py"
}

HOOK_INPUT=""
if [[ ! -t 0 ]]; then
  HOOK_INPUT=$(cat)
fi
if [[ -z "$HOOK_INPUT" ]]; then
  HOOK_INPUT="${CLAUDE_TOOL_USE_INPUT:-}"
fi

# Only run after actual git commit commands.
# Uses word-boundary matching to avoid false positives on git commit-tree,
# comments containing "git commit", etc.
# Cheap prefilter before any interpreter starts. This hook runs after every
# Bash tool call, and the parse below costs two python3 launches plus a full
# shell parse — about 50ms on each `ls`. Everything the detector can match
# ends in a literal `commit` token (see git_commit_creates_commit), so a
# payload without that substring cannot be a commit this hook would validate.
case "$HOOK_INPUT" in
  *commit*) ;;
  *) exit 0 ;;
esac

TOOL_INPUT="$HOOK_INPUT"
if [[ -n "$HOOK_INPUT" ]]; then
  TOOL_INPUT=$(__dx_post_commit_hook_field "$HOOK_INPUT" "command" 2>/dev/null || printf '%s' "$HOOK_INPUT")
fi
COMMIT_REPO=$(__dx_post_commit_is_git_commit "$TOOL_INPUT") || {
  exit 0
}

# Check if a commit was actually created (exit code 0 means success). Claude
# hook stdin is authoritative; env is only a no-stdin/non-JSON fallback.
TOOL_EXIT=""
HOOK_INPUT_IS_JSON=0
if [[ -n "$HOOK_INPUT" ]]; then
  if __dx_post_commit_is_json_payload "$HOOK_INPUT"; then
    HOOK_INPUT_IS_JSON=1
    TOOL_EXIT=$(__dx_post_commit_hook_field "$HOOK_INPUT" "exit_code" 2>/dev/null || printf '0')
  fi
fi
if [[ -z "$TOOL_EXIT" && $HOOK_INPUT_IS_JSON -eq 0 ]]; then
  TOOL_EXIT="${CLAUDE_TOOL_USE_EXIT_CODE:-}"
fi
TOOL_EXIT="${TOOL_EXIT:-0}"
if [[ "$TOOL_EXIT" != "0" ]]; then
  exit 0
fi

# Delegate to guard handler for markdown-based guard evaluation
source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"
COMMITTED_FILES=$(git -C "$COMMIT_REPO" diff-tree --root --no-commit-id --name-only -r HEAD 2>/dev/null || echo "")
COMMIT_MSG=$(git -C "$COMMIT_REPO" log -1 --pretty=format:%s 2>/dev/null || echo "")

export DEX_GUARD_EVENT="commit"
export CLAUDE_TOOL_USE_INPUT="${COMMITTED_FILES}"$'\n'"${COMMIT_MSG}"

GUARD_EXIT=0
if [[ -d "$COMMIT_REPO" ]]; then
  (cd "$COMMIT_REPO" && python3 "$DEX_DIR/hooks/guard-handler.py") || GUARD_EXIT=$?
else
  python3 "$DEX_DIR/hooks/guard-handler.py" || GUARD_EXIT=$?
fi

# Validate conventional commit format (handled here, not in guards, because
# it needs to check the commit message specifically, not the combined text)
# Full set of conventional commit types per https://www.conventionalcommits.org
CONVENTIONAL_REGEX='^(feat|fix|refactor|perf|docs|test|chore|build|ci|style|revert)(\([^)]+\))?!?: .+'
if [[ -n "$COMMIT_MSG" ]] && ! grep -qE "$CONVENTIONAL_REGEX" <<< "${COMMIT_MSG}"; then
  echo "Commit message does not follow conventional format." >&2
  echo "Expected: <type>[(<scope>)][!]: <description>" >&2
  echo "Got: $COMMIT_MSG" >&2
  echo "Amend the commit with a properly formatted message." >&2
  GUARD_EXIT=2
fi

exit $GUARD_EXIT
