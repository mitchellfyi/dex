#!/usr/bin/env bash
# shellcheck disable=SC2088,SC1091
# dex uninstall — remove global installation
# SC2088 suppressed: tilde in display strings is intentionally literal (e.g., "~/.claude/skills").
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"
CLAUDE_DIR="$HOME/.claude"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
INSTALL_STATE_FILE="$CLAUDE_DIR/.dex-install-state.json"
ZSHRC="$HOME/.zshrc"

__dx_settings_have_dex_hooks() {
  [[ -f "$SETTINGS_FILE" ]] || return 1
  if command -v jq &>/dev/null; then
    jq -e --arg dir "$DEX_DIR" --arg home "$HOME" '
      def is_dex_cmd:
        type == "string" and (
          contains($dir + "/hooks/")
          or contains($home + "/work/dex/hooks/")
          or contains("$HOME/work/dex/hooks/")
          or contains("$DEX_DIR/hooks/")
          or (contains("export DEX_DIR=") and contains("/hooks/"))
          or test("(^|[[:space:]\\\"])[^[:space:]\\\"]*/dex(-cli)?/hooks/(load-ticket-context\\.sh|user-prompt-submit\\.sh|guard-handler\\.py|rtk-claude-hook\\.sh|post-commit-guard\\.sh|phase-loop\\.sh|stop-sound\\.sh|pre-compact\\.sh|session-end\\.sh)([[:space:]\\\"]|$)")
        );
      [(.hooks // {}) | to_entries[] | .value[]? | .hooks[]? | .command | select(is_dex_cmd)] | length > 0
    ' "$SETTINGS_FILE" >/dev/null 2>&1
    return $?
  fi
  grep -Fq "$DEX_DIR/hooks/" "$SETTINGS_FILE" 2>/dev/null && return 0
  grep -Fq "$HOME/work/dex/hooks/" "$SETTINGS_FILE" 2>/dev/null && return 0
  grep -Fq "\$HOME/work/dex/hooks/" "$SETTINGS_FILE" 2>/dev/null && return 0
  grep -Fq "\$DEX_DIR/hooks/" "$SETTINGS_FILE" 2>/dev/null && return 0
  grep -Eq 'export DEX_DIR=.*hooks/|/dex(-cli)?/hooks/(load-ticket-context\.sh|user-prompt-submit\.sh|guard-handler\.py|rtk-claude-hook\.sh|post-commit-guard\.sh|phase-loop\.sh|stop-sound\.sh|pre-compact\.sh|session-end\.sh)' "$SETTINGS_FILE" 2>/dev/null
}

__dx_settings_have_dex_worktree_settings() {
  [[ -f "$SETTINGS_FILE" ]] || return 1
  command -v jq >/dev/null 2>&1 || return 1
  if [[ -f "$INSTALL_STATE_FILE" ]]; then
    jq -e '
      (.worktree.managedSymlinkDirectories // []) | type == "array" and length > 0
    ' "$INSTALL_STATE_FILE" >/dev/null 2>&1
    return $?
  fi
  return 1
}

__dx_managed_worktree_dirs_json() {
  command -v jq >/dev/null 2>&1 || return 1
  if [[ -f "$INSTALL_STATE_FILE" ]]; then
    jq -c '(.worktree.managedSymlinkDirectories // []) | if type == "array" then . else [] end' "$INSTALL_STATE_FILE"
  else
    printf '%s\n' "[]"
  fi
}

echo "Dex — Global Uninstall"
echo ""

# 1. Remove skills symlink (only if it points to Dex)
if [[ -L "$CLAUDE_DIR/skills" ]]; then
  target=$(readlink "$CLAUDE_DIR/skills")
  if [[ "$target" == "$DEX_DIR/skills" ]]; then
    rm "$CLAUDE_DIR/skills"
    dx_done "Removed ~/.claude/skills symlink"
  else
    dx_skip "~/.claude/skills points to $target (not Dex)"
  fi
else
  if [[ -d "$CLAUDE_DIR/skills" ]]; then
    removed=0
    failed=0
    while IFS= read -r target; do
      [[ -L "$target" ]] || continue
      current=$(readlink "$target")
      skill_name=$(basename "$target")
      case "$skill_name:$current" in
        *:"$DEX_DIR"/skills/*)
          if rm "$target"; then
            removed=$((removed + 1))
          else
            dx_warn "Could not remove ${target}"
            failed=$((failed + 1))
          fi
          ;;
      esac
    done < <(find "$CLAUDE_DIR/skills" -mindepth 1 -maxdepth 1 -type l 2>/dev/null)
    if [[ $failed -gt 0 ]]; then
      dx_warn "Removed ${removed} Claude skill link(s); failed ${failed}"
    elif [[ $removed -gt 0 ]]; then
      dx_done "Removed ${removed} Claude skill link(s)"
    else
      dx_skip "No Dex Claude skill links found"
    fi
  else
    dx_skip "~/.claude/skills is not a symlink"
  fi
fi

# 2. Remove Codex skill links
if ! dx_uninstall_codex_skills; then
  dx_warn "Continuing uninstall after incomplete Codex skill cleanup"
fi

# 3. Remove Dex hooks from settings (preserve non-Dex hooks)
if __dx_settings_have_dex_hooks; then
  if command -v jq &>/dev/null; then
    if jq --arg dir "$DEX_DIR" --arg home "$HOME" '
      def is_dex_cmd:
        type == "string" and (
          contains($dir + "/hooks/")
          or contains($home + "/work/dex/hooks/")
          or contains("$HOME/work/dex/hooks/")
          or contains("$DEX_DIR/hooks/")
          or (contains("export DEX_DIR=") and contains("/hooks/"))
          or test("(^|[[:space:]\\\"])[^[:space:]\\\"]*/dex(-cli)?/hooks/(load-ticket-context\\.sh|user-prompt-submit\\.sh|guard-handler\\.py|rtk-claude-hook\\.sh|post-commit-guard\\.sh|phase-loop\\.sh|stop-sound\\.sh|pre-compact\\.sh|session-end\\.sh)([[:space:]\\\"]|$)")
        );
      .hooks |= (
        (. // {})
        | with_entries(
            .value |= map(
              .hooks = ([.hooks[]? | select((.command | is_dex_cmd) | not)])
              | select((.hooks // []) | length > 0)
            )
          )
        | with_entries(select((.value // []) | length > 0))
      )
      | if ((.hooks // {}) | length) == 0 then del(.hooks) else . end
    ' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp"; then
      mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
      dx_done "Removed hooks from ~/.claude/settings.json"
    else
      rm -f "${SETTINGS_FILE}.tmp"
      dx_error "Failed to remove Dex hooks from ~/.claude/settings.json"
    fi
  else
    dx_info "Manually remove hooks containing '$DEX_DIR/hooks/' or '\$DEX_DIR/hooks/' from ~/.claude/settings.json"
  fi
else
  dx_skip "No Dex hooks in settings"
fi

# 4. Remove Dex-managed worktree settings while preserving user entries
if __dx_settings_have_dex_worktree_settings; then
  managed_dirs_json=$(__dx_managed_worktree_dirs_json)
  if jq --argjson managed_dirs "$managed_dirs_json" '
    .worktree.symlinkDirectories = [(.worktree.symlinkDirectories // [])[] | . as $dir | select(($managed_dirs | index($dir)) | not)]
    | if ((.worktree.symlinkDirectories // []) | length) == 0 then del(.worktree.symlinkDirectories) else . end
    | if ((.worktree // {}) | length) == 0 then del(.worktree) else . end
  ' "$SETTINGS_FILE" > "${SETTINGS_FILE}.tmp"; then
    mv "${SETTINGS_FILE}.tmp" "$SETTINGS_FILE"
    rm -f "$INSTALL_STATE_FILE"
    dx_done "Removed worktree settings from ~/.claude/settings.json"
  else
    rm -f "${SETTINGS_FILE}.tmp"
    dx_error "Failed to remove Dex worktree settings from ~/.claude/settings.json"
  fi
else
  dx_skip "No Dex-managed worktree settings in settings"
fi
rm -f "$INSTALL_STATE_FILE" 2>/dev/null || true

# 5. Remove source line and Dex comment from zshrc
if grep -qE 'dex/dx\.sh|DEX_DIR.*/dx\.sh' "$ZSHRC" 2>/dev/null; then
  # -x matches entire line; removes "# Dex" or "# Dex — ..." exact lines.
  # Also removes the DEX_DIR export and source lines.
  # || true: grep -v exits 1 when no lines survive filtering (valid when .zshrc
  # contained only Dex lines); without this, set -e + pipefail aborts the script.
  grep -vxE '# Dex( —.*)?' "$ZSHRC" | grep -vE '^export DEX_DIR=' | grep -vE 'dex.*dx\.sh|DEX_DIR.*/dx\.sh' > "${ZSHRC}.tmp" || true
  mv "${ZSHRC}.tmp" "$ZSHRC"
  dx_done "Removed Dex lines from ~/.zshrc"
else
  dx_skip "No Dex source line in ~/.zshrc"
fi

echo ""
echo "Uninstall complete. Run: source ~/.zshrc"
echo ""
echo "Note: $DEX_DIR was NOT deleted. Remove it manually if you want."
