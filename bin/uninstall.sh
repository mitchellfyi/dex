#!/usr/bin/env bash
# shellcheck disable=SC2088,SC1091
# dex uninstall — remove global installation
# SC2088 suppressed: tilde in display strings is intentionally literal (e.g., "~/.claude/skills").
set -euo pipefail

source "${DEX_DIR:-$HOME/work/dex}/lib/common.sh"
CLAUDE_DIR="$HOME/.claude"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
INSTALL_STATE_FILE="$CLAUDE_DIR/.dex-install-state.json"
SETTINGS_JSON_HELPER="$DEX_DIR/scripts/settings-json.py"
ZSHRC="$HOME/.zshrc"

__dx_settings_json() {
  python3 "$SETTINGS_JSON_HELPER" "$@"
}

__dx_settings_have_dex_hooks() {
  [[ -f "$SETTINGS_FILE" ]] || return 1
  __dx_settings_json has-dex-hooks "$SETTINGS_FILE" "$DEX_DIR" "$HOME"
}

__dx_managed_worktree_dirs_json() {
  [[ -f "$INSTALL_STATE_FILE" ]] || {
    printf '%s\n' "[]"
    return 0
  }

  __dx_settings_json state-dirs "$INSTALL_STATE_FILE"
}

__dx_remove_dex_hooks_json() {
  __dx_settings_json remove-dex-hooks "$SETTINGS_FILE" "$DEX_DIR" "$HOME"
}

__dx_remove_worktree_settings_json() {
  local managed_dirs_json="$1"
  __dx_settings_json remove-worktree-dirs "$SETTINGS_FILE" "$managed_dirs_json"
}

usage() {
  cat <<'USAGE'
Usage: dx uninstall

Remove Dex's global skills, hooks, and shell integration for the current user.
The Dex source checkout is left in place.

Options:
  -h, --help  Show this help
USAGE
}

show_help=0
for arg in "$@"; do
  case "$arg" in
    -h|--help) show_help=1 ;;
    *)
      dx_error "Unknown uninstall option: $arg"
      usage >&2
      exit 1
      ;;
  esac
done
if [[ $show_help -eq 1 ]]; then
  usage
  exit 0
fi

echo "Dex — Global Uninstall"
echo ""

uninstall_failed=0

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
  settings_tmp="${SETTINGS_FILE}.tmp.$$"
  if __dx_remove_dex_hooks_json > "$settings_tmp" && [[ -s "$settings_tmp" ]]; then
    mv "$settings_tmp" "$SETTINGS_FILE"
    dx_done "Removed hooks from ~/.claude/settings.json"
  else
    rm -f "$settings_tmp"
    dx_error "Failed to remove Dex hooks from ~/.claude/settings.json. Install Python 3, then run 'dx uninstall' again."
    uninstall_failed=1
  fi
else
  hook_status=$?
  if [[ $hook_status -eq 1 ]]; then
    dx_skip "No Dex hooks in settings"
  else
    dx_error "Failed to inspect ~/.claude/settings.json. Install Python 3, then run 'dx uninstall' again."
    uninstall_failed=1
  fi
fi

# 4. Remove Dex-managed worktree settings while preserving user entries
worktree_cleanup_complete=0
if [[ -f "$INSTALL_STATE_FILE" ]]; then
  if managed_dirs_json=$(__dx_managed_worktree_dirs_json); then
    if [[ "$managed_dirs_json" == "[]" || ! -f "$SETTINGS_FILE" ]]; then
      dx_skip "No Dex-managed worktree settings in settings"
      worktree_cleanup_complete=1
    else
      settings_tmp="${SETTINGS_FILE}.tmp.$$"
      if __dx_remove_worktree_settings_json "$managed_dirs_json" > "$settings_tmp" && [[ -s "$settings_tmp" ]]; then
        mv "$settings_tmp" "$SETTINGS_FILE"
        dx_done "Removed worktree settings from ~/.claude/settings.json"
        worktree_cleanup_complete=1
      else
        rm -f "$settings_tmp"
        dx_error "Failed to remove Dex worktree settings from ~/.claude/settings.json"
        uninstall_failed=1
      fi
    fi
  else
    dx_error "Failed to read Dex install state; keeping $INSTALL_STATE_FILE for a later uninstall attempt"
    uninstall_failed=1
  fi
else
  dx_skip "No Dex-managed worktree settings in settings"
  worktree_cleanup_complete=1
fi
if [[ $worktree_cleanup_complete -eq 1 ]]; then
  rm -f "$INSTALL_STATE_FILE" 2>/dev/null || true
fi

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
if [[ $uninstall_failed -eq 1 ]]; then
  dx_error "Uninstall finished with incomplete settings cleanup. Resolve the errors above and run 'dx uninstall' again."
  exit 1
fi

echo "Uninstall complete. Run: source ~/.zshrc"
echo ""
echo "Note: $DEX_DIR was NOT deleted. Remove it manually if you want."
