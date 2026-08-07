#!/usr/bin/env bash
# shellcheck disable=SC2088,SC1091
# Install or refresh Dex's Claude Code settings entries.
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"

QUIET=0
for arg in "$@"; do
  case "$arg" in
    --quiet) QUIET=1 ;;
  esac
done

CLAUDE_DIR="$HOME/.claude"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
INSTALL_STATE_FILE="$CLAUDE_DIR/.dex-install-state.json"
SETTINGS_JSON_HELPER="$DEX_DIR/scripts/settings-json.py"
mkdir -p "$CLAUDE_DIR"

say_done() {
  [[ $QUIET -eq 1 ]] || dx_done "$1"
}

say_error() {
  [[ $QUIET -eq 1 ]] || dx_error "$1"
}

__dx_settings_json() {
  python3 "$SETTINGS_JSON_HELPER" "$@"
}

__dx_record_managed_worktree_dirs() {
  local dirs_json="$1"
  local tmpfile

  tmpfile="${INSTALL_STATE_FILE}.tmp.$$"
  if __dx_settings_json merge-install-state "$INSTALL_STATE_FILE" "$dirs_json" > "$tmpfile" \
    && [[ -s "$tmpfile" ]] \
    && mv "$tmpfile" "$INSTALL_STATE_FILE"; then
    return 0
  fi

  rm -f "$tmpfile" 2>/dev/null || true
  say_error "Failed to record Dex-managed worktree settings"
  return 1
}

if ! command -v python3 >/dev/null 2>&1; then
  say_error "Python 3 is required to install Dex settings"
  exit 1
fi
if [[ ! -f "$SETTINGS_JSON_HELPER" ]]; then
  say_error "Missing settings helper: $SETTINGS_JSON_HELPER"
  exit 1
fi
if ! local_settings=$(__dx_settings_json render-template "$DEX_DIR/settings.json" "$DEX_DIR"); then
  say_error "Failed to customise the settings template"
  exit 1
fi

if [[ -f "$SETTINGS_FILE" ]]; then
  if ! managed_worktree_dirs_json=$(__dx_settings_json managed-dirs-added \
    "$SETTINGS_FILE" "$DEX_DIR/settings.json" "$DEX_DIR" "$HOME"); then
    say_error "Failed to inspect existing worktree settings"
    exit 1
  fi

  if merged=$(__dx_settings_json merge-settings \
    "$SETTINGS_FILE" "$DEX_DIR/settings.json" "$DEX_DIR" "$HOME") \
    && [[ -n "$merged" ]]; then
    tmpfile="${SETTINGS_FILE}.tmp.$$"
    if printf '%s\n' "$merged" > "$tmpfile" && mv "$tmpfile" "$SETTINGS_FILE"; then
      __dx_record_managed_worktree_dirs "$managed_worktree_dirs_json" || exit 1
      say_done "Merged hooks and worktree settings into ~/.claude/settings.json"
    else
      rm -f "$tmpfile" 2>/dev/null || true
      say_error "Failed to merge settings — settings.json left unchanged"
      exit 1
    fi
  else
    say_error "Failed to merge settings — settings.json left unchanged"
    exit 1
  fi
else
  tmpfile="${SETTINGS_FILE}.tmp.$$"
  if printf '%s\n' "$local_settings" > "$tmpfile" && mv "$tmpfile" "$SETTINGS_FILE"; then
    managed_worktree_dirs_json=$(__dx_settings_json template-dirs "$DEX_DIR/settings.json")
    __dx_record_managed_worktree_dirs "$managed_worktree_dirs_json" || exit 1
    say_done "Created ~/.claude/settings.json with hooks and worktree settings"
  else
    rm -f "$tmpfile" 2>/dev/null || true
    say_error "Failed to copy settings.json"
    exit 1
  fi
fi
