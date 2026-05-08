#!/usr/bin/env bash
# shellcheck disable=SC2088,SC1091
# doyaken install — one-time global setup
# SC2088 suppressed: tilde in display strings is intentionally literal (e.g., "~/.claude/skills").
set -euo pipefail

if [[ -z "${DOYAKEN_DIR:-}" ]]; then
  SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
  DOYAKEN_DIR="$(dirname "$SCRIPT_DIR")"
  export DOYAKEN_DIR
fi
source "$DOYAKEN_DIR/lib/common.sh"
CLAUDE_DIR="$HOME/.claude"
SETTINGS_FILE="$CLAUDE_DIR/settings.json"
ZSHRC="$HOME/.zshrc"

echo "Doyaken — Global Install"
echo ""

# Ensure ~/.claude directory exists (Claude Code normally creates it, but we
# need it before creating symlinks in steps 1-2)
mkdir -p "$CLAUDE_DIR"

# 1. Symlink skills
if [[ -L "$CLAUDE_DIR/skills" ]]; then
  current=$(readlink "$CLAUDE_DIR/skills")
	  if [[ "$current" == "$DOYAKEN_DIR/skills" ]]; then
	    dk_ok "~/.claude/skills → $DOYAKEN_DIR/skills"
	  else
	    rm "$CLAUDE_DIR/skills"
	    if ln -s "$DOYAKEN_DIR/skills" "$CLAUDE_DIR/skills"; then
	      dk_done "Updated ~/.claude/skills → $DOYAKEN_DIR/skills (was: $current)"
	    else
	      dk_error "Failed to symlink ~/.claude/skills"
	    fi
	  fi
elif [[ -d "$CLAUDE_DIR/skills" ]]; then
  dk_warn "~/.claude/skills exists as a directory — back up and re-run:"
  echo "       mv ~/.claude/skills ~/.claude/skills.bak && dk install"
else
  if ln -s "$DOYAKEN_DIR/skills" "$CLAUDE_DIR/skills"; then
    dk_done "Symlinked ~/.claude/skills → $DOYAKEN_DIR/skills"
  else
    dk_error "Failed to symlink ~/.claude/skills"
  fi
fi

# 2. Symlink agents
if [[ -L "$CLAUDE_DIR/agents" ]]; then
  current=$(readlink "$CLAUDE_DIR/agents")
	  if [[ "$current" == "$DOYAKEN_DIR/agents" ]]; then
	    dk_ok "~/.claude/agents → $DOYAKEN_DIR/agents"
	  else
	    rm "$CLAUDE_DIR/agents"
	    if ln -s "$DOYAKEN_DIR/agents" "$CLAUDE_DIR/agents"; then
	      dk_done "Updated ~/.claude/agents → $DOYAKEN_DIR/agents (was: $current)"
	    else
	      dk_error "Failed to symlink ~/.claude/agents"
	    fi
	  fi
elif [[ -d "$CLAUDE_DIR/agents" ]]; then
  dk_warn "~/.claude/agents exists as a directory — back up and re-run:"
  echo "       mv ~/.claude/agents ~/.claude/agents.bak && dk install"
else
  if ln -s "$DOYAKEN_DIR/agents" "$CLAUDE_DIR/agents"; then
    dk_done "Symlinked ~/.claude/agents → $DOYAKEN_DIR/agents"
  else
    dk_error "Failed to symlink ~/.claude/agents"
  fi
fi

# 3. Install Codex skills without replacing Codex's skills directory.
if command -v codex &>/dev/null; then
  if ! dk_install_codex_skills; then
    dk_warn "Continuing install without complete Codex skill links"
  fi
else
  dk_skip "Codex CLI not found; skipping Codex skills"
fi

# 4. Install Doyaken-managed browser automation tooling.
if ! dk_install_ui_capture_tooling; then
  dk_warn "Continuing install without complete UI capture tooling"
fi

# 5. Merge hooks and settings into ~/.claude/settings.json
if [[ -f "$SETTINGS_FILE" ]]; then
  # Use jq if available, otherwise manual merge. Existing settings are always
  # merged through jq so stale/missing Doyaken hook entries are repaired.
  if command -v jq &>/dev/null; then
    local_settings=$(sed "s|\\\$HOME/work/doyaken|${DOYAKEN_DIR}|g" "$DOYAKEN_DIR/settings.json")
    # Merge Doyaken settings into existing settings.json.
    #
    # The jq expression processes two inputs: .[0] = existing settings, .[1] = Doyaken settings.
    # Hooks: For each hook category (SessionStart, UserPromptSubmit, PreToolUse, PostToolUse, Stop, PreCompact, SessionEnd) from .[1]:
    #   1. Take the existing entries for that category (.[0].hooks[category] // [])
    #   2. Filter OUT stale Doyaken hook commands by resolved path, $DOYAKEN_DIR path, or hook script name
    #   3. Append the fresh Doyaken entries from .[1]
    # Worktree: Deep-merge .[1].worktree into .[0].worktree (Doyaken values win).
    # This preserves non-Doyaken hooks and settings while replacing stale Doyaken entries.
    #
    # Claude Code settings.json hook structure:
    #   { "hooks": { "EventName": [ { "matcher": "...", "hooks": [ { "command": "..." } ] } ] } }
    # See: https://docs.anthropic.com/en/docs/claude-code/hooks
    if merged=$(jq -s --arg dir "$DOYAKEN_DIR" --arg home "$HOME" '
      def is_doyaken_cmd:
        type == "string" and (
          contains($dir + "/hooks/")
          or contains($home + "/work/doyaken/hooks/")
          or contains("$HOME/work/doyaken/hooks/")
          or contains("$DOYAKEN_DIR/hooks/")
          or (contains("export DOYAKEN_DIR=") and contains("/hooks/"))
          or test("(^|[[:space:]\\\"])[^[:space:]\\\"]*/doyaken(-cli)?/hooks/(load-ticket-context\\.sh|user-prompt-submit\\.sh|guard-handler\\.py|post-commit-guard\\.sh|phase-loop\\.sh|pre-compact\\.sh|session-end\\.sh)([[:space:]\\\"]|$)")
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
    ' "$SETTINGS_FILE" <(echo "$local_settings")) && [[ -n "$merged" ]]; then
      # Atomic write: write to temp file then mv to avoid corrupting
      # settings.json if the process is interrupted mid-write.
      TMPFILE="${SETTINGS_FILE}.tmp.$$"
      echo "$merged" > "$TMPFILE" && mv "$TMPFILE" "$SETTINGS_FILE"
      dk_done "Merged hooks and worktree settings into ~/.claude/settings.json"
    else
      dk_error "Failed to merge settings — settings.json left unchanged"
      echo "        Add settings manually from $DOYAKEN_DIR/settings.json"
    fi
  else
    dk_info "Add these settings to ~/.claude/settings.json manually:"
    echo ""
    sed "s|\\\$HOME/work/doyaken|${DOYAKEN_DIR}|g" "$DOYAKEN_DIR/settings.json"
    echo ""
  fi
else
  if sed "s|\\\$HOME/work/doyaken|${DOYAKEN_DIR}|g" "$DOYAKEN_DIR/settings.json" > "$SETTINGS_FILE"; then
    dk_done "Created ~/.claude/settings.json with hooks and worktree settings"
  else
    dk_error "Failed to copy settings.json"
  fi
fi

# 6. Source dk.sh in ~/.zshrc
if grep -qE 'doyaken/dk\.sh|DOYAKEN_DIR.*/dk\.sh' "$ZSHRC" 2>/dev/null; then
  # Ensure DOYAKEN_DIR export exists (upgrade path: older installs lack it)
  if ! grep -qE '^export DOYAKEN_DIR=' "$ZSHRC" 2>/dev/null; then
    # Insert the export line before the existing source line.
    # Uses awk instead of sed -i to avoid BSD/GNU sed portability issues.
    _DKDIR="$DOYAKEN_DIR" awk '
      /doyaken\/dk\.sh|DOYAKEN_DIR.*\/dk\.sh/ && !inserted { print "export DOYAKEN_DIR=\"" ENVIRON["_DKDIR"] "\""; inserted=1 }
      { print }
    ' "$ZSHRC" > "${ZSHRC}.tmp" && mv "${ZSHRC}.tmp" "$ZSHRC"
    dk_done "Added DOYAKEN_DIR export to ~/.zshrc (upgrade)"
  else
    dk_ok "dk.sh already sourced in ~/.zshrc"
  fi
else
  # Check for old Doyaken source lines (different path)
  if grep -qE 'doyaken.*dk\.sh|DOYAKEN_DIR.*/dk\.sh' "$ZSHRC" 2>/dev/null; then
    dk_info "Found old Doyaken dk.sh source line — replacing..."
    grep -vE 'doyaken.*dk\.sh|DOYAKEN_DIR.*/dk\.sh|export DOYAKEN_DIR=' "$ZSHRC" > "${ZSHRC}.tmp" && mv "${ZSHRC}.tmp" "$ZSHRC"
  fi
  {
    echo ""
    echo "# Doyaken"
    echo "export DOYAKEN_DIR=\"$DOYAKEN_DIR\""
    echo "source \"\$DOYAKEN_DIR/dk.sh\""
  } >> "$ZSHRC"
  dk_done "Added DOYAKEN_DIR export and source to ~/.zshrc"
fi

# 7. Make scripts executable
chmod +x "$DOYAKEN_DIR/hooks/"*.sh "$DOYAKEN_DIR/hooks/"*.py "$DOYAKEN_DIR/bin/"*.sh 2>/dev/null
dk_done "Made scripts executable"

echo ""
echo "Install complete. Run: source ~/.zshrc"
echo ""
echo "Next: cd to a repo and run 'dk init' to bootstrap it."
