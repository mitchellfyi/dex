#!/usr/bin/env bash
# shellcheck disable=SC2088,SC1091
# Install or refresh Doyaken's Claude Code settings entries.
set -euo pipefail

source "${DOYAKEN_DIR:-$HOME/work/doyaken}/lib/common.sh"

QUIET=0
for arg in "$@"; do
  case "$arg" in
    --quiet) QUIET=1 ;;
  esac
done

CLAUDE_DIR="$HOME/.claude"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
mkdir -p "$CLAUDE_DIR"

say_done() {
  [[ $QUIET -eq 1 ]] || dk_done "$1"
}

say_info() {
  [[ $QUIET -eq 1 ]] || dk_info "$1"
}

say_error() {
  [[ $QUIET -eq 1 ]] || dk_error "$1"
}

local_settings=$(sed "s|\\\$HOME/work/doyaken|${DOYAKEN_DIR}|g" "$DOYAKEN_DIR/settings.json")

if [[ -f "$SETTINGS_FILE" ]]; then
  if command -v jq >/dev/null 2>&1; then
    if merged=$(jq -s --arg dir "$DOYAKEN_DIR" --arg home "$HOME" '
      def is_doyaken_cmd:
        type == "string" and (
          contains($dir + "/hooks/")
          or contains($home + "/work/doyaken/hooks/")
          or contains("$HOME/work/doyaken/hooks/")
          or contains("$DOYAKEN_DIR/hooks/")
          or (contains("export DOYAKEN_DIR=") and contains("/hooks/"))
          or test("(^|[[:space:]\\\"])[^[:space:]\\\"]*/doyaken(-cli)?/hooks/(load-ticket-context\\.sh|user-prompt-submit\\.sh|guard-handler\\.py|post-commit-guard\\.sh|phase-loop\\.sh|stop-sound\\.sh|pre-compact\\.sh|session-end\\.sh)([[:space:]\\\"]|$)")
        );
      .[0] + {hooks: (reduce (.[1].hooks | to_entries[]) as $e (
        (.[0].hooks // {});
        .[$e.key] = (
          [
            (.[$e.key] // [])[]
            | .hooks = ([.hooks[]? | select((.command | is_doyaken_cmd) | not)])
            | select((.hooks // []) | length > 0)
          ]
          + $e.value
        )
      ))} + {worktree: ((.[0].worktree // {}) * (.[1].worktree // {}))}
    ' "$SETTINGS_FILE" <(printf '%s\n' "$local_settings")) && [[ -n "$merged" ]]; then
      tmpfile="${SETTINGS_FILE}.tmp.$$"
      printf '%s\n' "$merged" > "$tmpfile" && mv "$tmpfile" "$SETTINGS_FILE"
      say_done "Merged hooks and worktree settings into ~/.claude/settings.json"
    else
      say_error "Failed to merge settings — settings.json left unchanged"
      [[ $QUIET -eq 1 ]] || printf '        Add settings manually from %s/settings.json\n' "$DOYAKEN_DIR"
      exit 1
    fi
  else
    say_info "Add these settings to ~/.claude/settings.json manually:"
    if [[ $QUIET -ne 1 ]]; then
      printf '\n%s\n\n' "$local_settings"
    fi
  fi
else
  if printf '%s\n' "$local_settings" > "$SETTINGS_FILE"; then
    say_done "Created ~/.claude/settings.json with hooks and worktree settings"
  else
    say_error "Failed to copy settings.json"
    exit 1
  fi
fi
